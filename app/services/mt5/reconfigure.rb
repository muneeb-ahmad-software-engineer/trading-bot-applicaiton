module Mt5
  # Points an existing terminal at a different strategy.
  #
  # Necessary because the Expert Advisor reads its strategy id as an MQL5 input
  # at OnInit and never revisits it — it refreshes that strategy's parameters
  # every 30 seconds, but nothing tells it to follow a different strategy. So
  # switching strategies means rewriting the terminal's configuration on disk
  # and restarting the process. Anything less leaves a user watching a terminal
  # that reports as healthy while it trades the strategy they stopped.
  #
  # The API token is reissued rather than reused: the plaintext is written into
  # the EA's input file and nowhere else, and the digest kept in the database
  # cannot be turned back into it. Rewriting the file therefore requires a new
  # token, and the old one is revoked once the new one is safely on disk.
  class Reconfigure < ApplicationService
    def initialize(instance:, strategy:, actor: nil, source: "web", allow_trading: true)
      @instance = instance
      @strategy = strategy
      @actor = actor
      @source = source
      @allow_trading = allow_trading
    end

    def call
      return failure("terminated", "This terminal has been removed.") if instance.terminated?

      # Nothing to do only when the terminal is already pointed at this
      # strategy *and* still has a tree to be pointed at. A node rebuilt from
      # an image, or a disk cleaned out by hand, leaves the row saying a
      # terminal exists and the directory gone — and every start from then on
      # fails with "terminal missing" until someone deletes the row. Writing
      # the configuration again rebuilds it, so the repair costs nothing beyond
      # noticing.
      return success(instance) if instance.strategy_id == strategy&.id && runtime.prepared?(instance)

      credential = instance.user.broker_credential
      return failure("no_broker_credential", "Add your broker account details before starting a terminal.") if credential.nil?

      was_live = instance.process_expected?

      rewritten = rewrite_configuration(credential)
      return rewritten if rewritten.failure?

      # A stopped terminal picks the new configuration up when it next starts,
      # so there is nothing to interrupt. Restarting one anyway would turn an
      # edit into an outage.
      return success(instance.reload) unless was_live

      Restart.call(instance:, actor:, source:, reason: "strategy changed")
    end

    private

    attr_reader :instance, :strategy, :actor, :source, :allow_trading

    def runtime = @runtime ||= instance.worker_node.runtime

    def rewrite_configuration(credential)
      previous_token_id = instance.api_token_id
      token = ApiToken.issue(user: instance.user, name: "MT5 terminal #{instance.uuid.last(8)}")

      context = TerminalContext.for(instance:, credential:, api_token: token, strategy:, allow_trading:)
      result = runtime.prepare(instance, context)

      if result.failed?
        # The terminal still holds its previous, working configuration. Leave it
        # that way and throw away the token nothing ever received.
        token.revoke!
        Rails.logger.error("mt5.reconfigure_failed #{instance.to_log.merge(error: result.error_code).to_json}")
        return failure(result.error_code, result.error_message)
      end

      instance.transaction do
        instance.update!(strategy:, api_token: token)
        instance.events.create!(
          action: "instance.reconfigured", from_state: instance.state, to_state: instance.state,
          source:, user: actor, occurred_at: Time.current,
          metadata: { strategy_id: strategy&.id, symbol: strategy&.symbol }
        )
      end

      # Only now: until the new configuration is on disk and recorded, the old
      # token is the only one the terminal can authenticate with.
      #
      # Looked up afresh rather than kept from `instance.api_token` above. That
      # object carries a loaded has_one back to this terminal, and saving it
      # writes its own id onto the terminal again — silently handing the
      # terminal back the very token being revoked, leaving it unable to
      # authenticate at all.
      ApiToken.find_by(id: previous_token_id)&.revoke!

      Rails.logger.info("mt5.reconfigured #{instance.to_log.merge(strategy_id: strategy&.id).to_json}")
      success(instance)
    end
  end
end
