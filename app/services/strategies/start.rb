module Strategies
  # Starting a strategy.
  #
  # Every rule about whether a strategy may start lives here, so the web
  # interface and the API cannot disagree about it.
  #
  # Starting is two things, not one: the control plane records that this
  # configuration is live, and the execution layer gets a terminal up that can
  # act on it. Both have to happen, and if the second cannot, the first is
  # undone — a strategy showing "running" while nothing is connected to a broker
  # is the single most misleading state this application could present.
  #
  # Users who run their own MT5 terminal against an API token have no broker
  # credentials stored here, and for them the execution layer is not ours to
  # bring up. That case is detected by the absence of a credential rather than
  # by a setting, because it is the credential itself that we would need.
  class Start < ApplicationService
    def initialize(strategy:, actor:, source: "web", ip_address: nil)
      @strategy = strategy
      @actor = actor
      @source = source
      @ip_address = ip_address
    end

    def call
      return failure("email_unverified", "Verify your email address before starting a strategy.") unless actor.may_trade?
      return failure("already_running", "This strategy is already running.") if strategy.running?

      strategy.start!

      terminal = bring_up_terminal
      return withdraw(terminal) if terminal&.failure?

      Event.record("strategy.started",
                   user: actor, subject: strategy, source:, ip_address:,
                   metadata: event_metadata(terminal&.payload))

      success(strategy)
    rescue Strategy::NotVerified
      failure("email_unverified", "Verify your email address before starting a strategy.")
    rescue Strategy::AlreadyRunning
      failure("already_running", "Another strategy is already running for #{strategy.symbol}.")
    rescue ActiveRecord::RecordInvalid => e
      failure("validation_failed", e.record.errors.full_messages.to_sentence)
    end

    private

    attr_reader :strategy, :actor, :source, :ip_address

    # nil means "not ours to run" — the user drives their own terminal.
    def bring_up_terminal
      return nil if strategy.user.broker_credential.nil?

      provisioned = Mt5::Provision.call(user: strategy.user, strategy:, actor:, source:, allow_trading: true)
      return provisioned if provisioned.failure?

      instance = provisioned.payload

      # A terminal survives between strategies, so the one we just got back may
      # still be configured for whichever strategy ran last. Pointing it at this
      # one is a no-op when it already is.
      reconfigured = Mt5::Reconfigure.call(instance:, strategy:, actor:, source:)
      return reconfigured if reconfigured.failure?

      # A user starting a strategy is asking for the terminal again, the same
      # signal the Retry button gives. Without this, failures left over from an
      # earlier strategy block every start, and Retry needs a running strategy,
      # so nothing could ever lift the crash-loop cap.
      reconfigured.payload.clear_failures! if reconfigured.payload.crash_looping?

      Mt5::Start.call(instance: reconfigured.payload, actor:, source:)
    end

    # The strategy was marked running before the terminal was attempted, because
    # provisioning needs a running strategy to configure the terminal for. If
    # the terminal cannot come up, that intent has to be taken back rather than
    # left standing.
    def withdraw(result)
      strategy.stop!

      Rails.logger.error(
        "strategy.start_aborted #{{ strategy_id: strategy.id, user_id: strategy.user_id, error: result.error_code }.to_json}"
      )

      failure(result.error_code, "Your strategy was not started: #{result.error_message}")
    end

    # Captured at the moment of starting, so the audit trail records the
    # configuration that was actually put live rather than whatever it was
    # edited to afterwards.
    def event_metadata(instance = nil)
      {
        name: strategy.name,
        symbol: strategy.symbol,
        direction: strategy.direction,
        category: strategy.category,
        grid_levels: strategy.grid_levels,
        trailing_stop_points: strategy.trailing_stop_points,
        initial_lot: strategy.initial_lot.to_s,
        max_positions: strategy.max_positions,
        max_exposure_lots: strategy.max_exposure_lots.to_s,
        maximum_theoretical_lots: strategy.maximum_theoretical_lots.to_s,
        terminal: instance&.uuid
      }
    end
  end
end
