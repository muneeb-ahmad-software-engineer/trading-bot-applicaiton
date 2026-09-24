module Mt5
  # Removes a terminal entirely: stops the process, revokes its token, and
  # deletes its directory tree.
  #
  # The order matters and is not negotiable. Deleting the directory of a running
  # terminal leaves a process with open file handles trading against files
  # nobody can read, and revoking the token first would leave the EA unable to
  # report the shutdown it is in the middle of.
  class Deprovision < ApplicationService
    def initialize(instance:, actor: nil, source: "web", reason: nil)
      @instance = instance
      @actor = actor
      @source = source
      @reason = reason
    end

    def call
      return success(instance) if instance.terminated?

      instance.update!(desired_state: "absent")

      stopped = Stop.call(instance:, actor:, source:, reason: reason || "deprovision")
      return failure(stopped.error_code, "Cannot remove a terminal that will not stop: #{stopped.error_message}") if stopped.failure?

      instance.reload
      removal = instance.worker_node.runtime.destroy(instance)
      return failure(removal.error_code, removal.error_message) if removal.failed?

      instance.api_token&.revoke!
      instance.transition_to!("terminated", action: "instance.terminated", reason:, source:, actor:)

      Rails.logger.info("mt5.terminated #{instance.to_log.to_json}")
      success(instance)
    end

    private

    attr_reader :instance, :actor, :source, :reason
  end
end
