module Mt5
  module Runtime
    # The contract every runtime implements.
    #
    # Two rules hold for all of them, and the services above depend on both:
    #
    #   1. Every method is idempotent. `start` on something already running
    #      succeeds; `stop` on something already stopped succeeds; `destroy` on
    #      a directory that is gone succeeds. The reconciler calls these in a
    #      loop against state it does not fully trust, and a method that raises
    #      on a repeat would turn a small inconsistency into a stuck instance.
    #
    #   2. Nothing raises for an expected failure. A broker refusing a login is
    #      an outcome, not an exception, and is returned as a Result so it can
    #      be recorded against the instance and shown to the user.
    class Base
      attr_reader :worker_node

      def initialize(worker_node)
        @worker_node = worker_node
      end

      # Create the instance's isolated directory tree and write its
      # configuration. Must leave nothing behind if it fails halfway.
      def prepare(_instance, _context) = raise NotImplementedError

      # Does this instance's tree still exist and hold everything the terminal
      # needs to start? Asked separately from `alive?` because a directory and
      # a process fail independently: a node rebuilt from an image, a disk
      # filled and cleaned, an operator tidying /opt all leave the row intact
      # and the tree gone.
      def prepared?(_instance) = raise NotImplementedError

      # Spawn the terminal. Returns a Result carrying the pid and the process
      # token that proves the pid is ours.
      def start(_instance) = raise NotImplementedError

      # Ask the terminal to exit, then insist. Returns ok when the process is
      # gone, however it went.
      def stop(_instance, timeout: nil) = raise NotImplementedError

      # Is this instance's process running *right now*? The only source of truth
      # the reconciler trusts about liveness.
      def alive?(_instance) = raise NotImplementedError

      # Remove the instance's directory tree. Irreversible.
      def destroy(_instance) = raise NotImplementedError

      # Coarse resource usage, for capacity decisions and for showing a user why
      # their terminal is slow. Nil entries mean "not measurable here".
      def resource_usage(_instance) = { rss_bytes: nil, cpu_percent: nil }

      private

      def ok(**attributes) = Result.new(ok: true, **attributes)

      def failure(code, message, **attributes)
        Result.new(ok: false, error_code: code, error_message: message, **attributes)
      end
    end
  end
end
