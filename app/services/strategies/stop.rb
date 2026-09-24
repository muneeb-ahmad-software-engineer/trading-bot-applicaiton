module Strategies
  # Stopping a strategy.
  #
  # Deliberately has no preconditions beyond the strategy existing. Halting must
  # never be blocked — not by an unverified email, not by anything else. If a
  # user wants to stop, they stop.
  class Stop < ApplicationService
    def initialize(strategy:, actor:, source: "web", ip_address: nil)
      @strategy = strategy
      @actor = actor
      @source = source
      @ip_address = ip_address
    end

    def call
      strategy.stop!

      Event.record("strategy.stopped",
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
