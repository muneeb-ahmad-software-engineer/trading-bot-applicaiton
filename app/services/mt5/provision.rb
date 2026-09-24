module Mt5
  # Creates a user's terminal: allocates it a home, a display, an identity and a
  # token, and lays down its directory tree. Does not start it.
  #
  # Idempotent by design. Calling it twice returns the existing instance rather
  # than building a second one — and the database enforces that independently,
  # because two concurrent calls would both pass a Ruby-level check and both
  # spawn a terminal against the same broker account.
  class Provision < ApplicationService
    # Display and magic-number collisions between concurrent provisions are
    # resolved by re-reading and trying again. Three is enough that losing
    # twice in a row is vanishingly unlikely, and small enough that a genuinely
    # exhausted node still fails quickly rather than spinning.
    MAX_PLACEMENT_ATTEMPTS = 3

    def initialize(user:, strategy: nil, actor: nil, source: "web", allow_trading: false)
      @user = user
      @strategy = strategy
      @actor = actor || user
      @source = source
      @allow_trading = allow_trading
    end

    def call
      existing = user.mt5_instances.not_terminated.first
      return success(existing) if existing

      return failure("email_unverified", "Verify your email address before provisioning a terminal.") unless user.may_trade?

      credential = user.broker_credential
      return failure("no_broker_credential", "Add your broker account details before provisioning a terminal.") if credential.nil?

      place_and_build(credential)
    end

    private

    attr_reader :user, :strategy, :actor, :source, :allow_trading

    # Placement reads which displays and magic numbers are free, then this
    # creates a row using them — so two users provisioning in the same instant
    # can both be handed the same display. The unique indexes are what actually
    # keeps them apart; the loser simply chose from a stale picture and needs to
    # look again. Retrying is the entire fix, and it is worth writing out
    # because the obvious alternative — reporting a conflict — would tell a user
    # their own terminal was already being built when nothing of theirs was.
    def place_and_build(credential)
      attempts = 0

      begin
        attempts += 1

        placement = Placement.call(user:)
        return failure(placement.error_code, placement.error_message) if placement.failure?

        build_and_prepare(placement.payload, credential)
      rescue ActiveRecord::RecordNotUnique
        # The one-live-terminal-per-user index. Somebody else provisioned for
        # this same user concurrently and won; their instance is the right
        # answer, so this is a success rather than an error.
        mine = user.mt5_instances.not_terminated.first
        return success(mine) if mine

        retry if attempts < MAX_PLACEMENT_ATTEMPTS

        failure("provision_conflict",
                "Could not find a free slot for a terminal. Please try again in a moment.")
      end
    end

    def build_and_prepare(placement, credential)
      instance = claim_slot(placement)

      instance.events.create!(action: "instance.provisioning", to_state: "provisioning",
                              source:, user: actor, occurred_at: Time.current,
                              metadata: { node: placement[:node].name, display: placement[:display_number] })

      token = issue_token(instance)
      result = placement[:node].runtime.prepare(instance, context_for(instance, credential, token))

      return rollback(instance, token, result) if result.failed?

      instance.update!(api_token: token, provisioned_at: Time.current)
      instance.transition_to!("stopped", action: "instance.provisioned", source:, actor:,
                              metadata: { instance_dir: instance.instance_dir })

      Rails.logger.info("mt5.provisioned #{instance.to_log.to_json}")
      success(instance.reload)
    end

    # The row, and nothing else, inside a savepoint of its own.
    #
    # A unique-index violation aborts the transaction it happens in, and in
    # PostgreSQL every statement after that fails until it is unwound. Without a
    # savepoint here, losing a placement race would poison whatever transaction
    # the caller happened to be inside, and the retry above would then die on
    # its first query with an error that says nothing about placement at all.
    def claim_slot(placement)
      ActiveRecord::Base.transaction(requires_new: true) do
        user.mt5_instances.create!(
          worker_node: placement[:node],
          strategy:,
          display_number: placement[:display_number],
          state: "provisioning",
          desired_state: "stopped",
          last_transition_at: Time.current
        )
      end
    end

    # A token per instance, not per user. Revoking one terminal must not sign
    # out a user's phone, and a leaked token must be traceable to exactly one
    # terminal.
    def issue_token(instance)
      ApiToken.issue(user:, name: "MT5 terminal #{instance.uuid.last(8)}")
    end

    def context_for(instance, credential, token)
      TerminalContext.for(instance:, credential:, api_token: token, strategy:, allow_trading:)
    end

    # A half-provisioned instance is worse than none: it holds a display and a
    # unique-per-user slot while being unable to run. Unwind completely.
    def rollback(instance, token, result)
      token&.revoke!
      instance.worker_node.runtime.destroy(instance)
      instance.transition_to!("terminated", action: "instance.provision_failed",
                              reason: result.error_message, source:, actor:)

      Rails.logger.error("mt5.provision_failed #{instance.to_log.merge(error: result.error_code).to_json}")
      failure(result.error_code, result.error_message)
    end
  end
end
