module Mt5
  # Stops a terminal and starts it again.
  #
  # Sequential rather than a "reload": MT5 holds broker state in memory and a
  # file lock on its data directory, so the only reliable restart is a full one.
  class Restart < ApplicationService
    def initialize(instance:, actor: nil, source: "web", reason: nil)
      @instance = instance
      @actor = actor
      @source = source
      @reason = reason
    end

    def call
      stopped = Stop.call(instance:, actor:, source:, reason: reason || "restart")
      return failure(stopped.error_code, stopped.error_message) if stopped.failure?

      instance.reload
      instance.events.create!(action: "instance.restarting", from_state: instance.state,
                              to_state: instance.state, source:, user: actor,
                              reason:, occurred_at: Time.current)
      instance.increment!(:restart_count)

      Start.call(instance:, actor:, source:)
    end

    private

    attr_reader :instance, :actor, :source, :reason
  end
end
