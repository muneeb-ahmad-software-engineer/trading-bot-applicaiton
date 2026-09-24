module Mt5
  # Starts a user's terminal.
  #
  # Records the intent (`desired_state`) before attempting the action, so that a
  # crash between the two leaves the reconciler enough to finish the job. A
  # start that is interrupted by a deploy must end with the terminal running,
  # not with a user staring at a button that did nothing.
  class Start < ApplicationService
    def initialize(instance:, actor: nil, source: "web")
      @instance = instance
      @actor = actor
      @source = source
    end

    def call
      instance.with_lock do
        instance.update!(desired_state: "running")

        return success(instance) if already_up?
        return failure("terminated", "This terminal has been removed.") if instance.terminated?
        return failure("crash_looping", crash_message) if instance.crash_looping?
        return failure("invalid_state", "Cannot start a terminal that is #{instance.state}.") unless instance.may_transition_to?("starting")

        launch
      end
    end

    private

    attr_reader :instance, :actor, :source

    # Idempotent: asking a running terminal to start is a success, not an error.
    # The reconciler and an impatient user both do this routinely.
    def already_up? = instance.running? || instance.connecting? || instance.starting?

    def launch
      instance.transition_to!("starting", action: "instance.starting", source:, actor:)

      result = instance.worker_node.runtime.start(instance)

      if result.failed?
        instance.record_failure!(code: result.error_code, message: result.error_message, source:)
        Rails.logger.error("mt5.start_failed #{instance.to_log.merge(error: result.error_code).to_json}")
        return failure(result.error_code, result.error_message)
      end

      instance.update!(pid: result.pid, process_token: result.process_token, process_started_at: Time.current)

      # Started, but not yet running: the process exists, the EA has not called
      # in. Only a heartbeat moves it to running, so a terminal that boots and
      # then fails to reach the platform is visibly stuck rather than falsely
      # green.
      instance.transition_to!("connecting", action: "instance.started", source:, actor:,
                              metadata: { pid: result.pid })

      Rails.logger.info("mt5.started #{instance.to_log.to_json}")
      success(instance)
    end

    def crash_message
      "This terminal has failed #{instance.consecutive_failures} times in a row and will not be restarted " \
      "automatically. Last error: #{instance.last_error_message}"
    end
  end
end
