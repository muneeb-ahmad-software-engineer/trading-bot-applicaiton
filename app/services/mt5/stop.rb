module Mt5
  # Stops a user's terminal.
  #
  # Like stopping a strategy, this must never be blocked. An unverified email, a
  # crash-looping instance, a node that has gone offline — none of them are
  # reasons to refuse someone the ability to halt a program that is trading
  # their money. The only outcome that is not success is "the process is still
  # there afterwards".
  class Stop < ApplicationService
    # preserve_desired_state is for stopping a terminal without withdrawing the
    # intent that it should be running — draining a node before a reboot, for
    # instance. The process goes away; `desired_state` still says running, so
    # the reconciler brings it back once the node is available again. Every
    # user-initiated stop leaves it false, because a user pressing stop means
    # stop, not "stop until something restarts you".
    def initialize(instance:, actor: nil, source: "web", reason: nil, timeout: nil,
                   preserve_desired_state: false)
      @instance = instance
      @actor = actor
      @source = source
      @reason = reason
      @timeout = timeout
      @preserve_desired_state = preserve_desired_state
    end

    def call
      instance.with_lock do
        instance.update!(desired_state: "stopped") unless instance.wants_absent? || preserve_desired_state?

        return success(instance) if instance.stopped? || instance.terminated?
        return halt_without_process if instance.provisioning?

        instance.transition_to!("stopping", action: "instance.stopping", reason:, source:, actor:) unless instance.stopping?

        shut_down
      end
    end

    private

    attr_reader :instance, :actor, :source, :reason, :timeout

    def preserve_desired_state? = @preserve_desired_state

    def shut_down
      result = instance.worker_node.runtime.stop(instance, timeout:)

      if result.failed?
        # The process is still there. Refusing to mark it stopped is the whole
        # point: a row claiming "stopped" while a terminal keeps trading is the
        # most dangerous lie this system could tell.
        instance.record_failure!(code: result.error_code, message: result.error_message, source:)
        Rails.logger.error("mt5.stop_failed #{instance.to_log.merge(error: result.error_code).to_json}")
        return failure(result.error_code, result.error_message)
      end

      instance.update!(pid: nil, process_token: nil)
      instance.transition_to!("stopped", action: "instance.stopped", reason:, source:, actor:,
                              metadata: { graceful: result.details&.dig(:graceful) })

      Rails.logger.info("mt5.stopped #{instance.to_log.merge(graceful: result.details&.dig(:graceful)).to_json}")
      success(instance)
    end

    # Nothing was ever spawned, so there is nothing to signal.
    def halt_without_process
      instance.transition_to!("stopped", action: "instance.stopped", reason: reason || "never started",
                              source:, actor:)
      success(instance)
    end
  end
end
