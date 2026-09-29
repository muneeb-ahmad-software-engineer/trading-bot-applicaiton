module Strategies
  # The emergency stop: stop the strategy AND have the EA close everything it
  # holds for it — positions and pending orders — at market.
  #
  # Like Stop, it has no preconditions. The EA picks it up from the next
  # report response (every few seconds) rather than waiting for its regular
  # configuration refresh; see StrategySerializer#risk and ReportsController.
  class EmergencyStop < ApplicationService
    def initialize(strategy:, actor:, source: "web", ip_address: nil)
      @strategy = strategy
      @actor = actor
      @source = source
      @ip_address = ip_address
    end

    def call
      strategy.emergency_stop!

      Event.record("strategy.emergency_stopped",
                   user: actor, subject: strategy, source:, ip_address:,
                   metadata: { name: strategy.name, symbol: strategy.symbol })

      success(strategy)
    rescue ActiveRecord::RecordInvalid => e
      failure("validation_failed", e.record.errors.full_messages.to_sentence)
    end

    private

    attr_reader :strategy, :actor, :source, :ip_address
  end
end
