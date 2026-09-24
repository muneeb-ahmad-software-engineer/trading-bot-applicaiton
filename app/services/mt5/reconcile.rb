module Mt5
  # Brings one instance's recorded state into line with what is actually true,
  # then into line with what was asked for.
  #
  # This is the recovery mechanism, and it is deliberately not written as a set
  # of handlers for particular failures. A VPS reboot, a Rails deploy mid-start,
  # an MT5 segfault and an operator killing a process by hand all present
  # identically from here: the row says one thing, the kernel says another.
  # Comparing observed facts to desired state — rather than trying to detect
  # *why* they diverged — is what makes this correct after failures nobody
  # anticipated, which is most of them.
  #
  # Runs every minute against every instance, so it must be cheap, idempotent,
  # and safe to interrupt at any line.
  class Reconcile < ApplicationService
    def initialize(instance:)
      @instance = instance
    end

    def call
      return success(:terminated) if instance.terminated?

      instance.with_lock do
        alive = runtime.alive?(instance)

        # Facts first. Nothing may act on desired state until the row agrees
        # with the machine, or the action will be based on a fiction.
        outcome = settle_observed_state(alive)
        return success(outcome) if outcome

        converge_towards_desire
      end
    rescue StandardError => e
      # A reconciler that dies on one bad instance stops reconciling every other
      # user's terminal. Report loudly, keep going.
      Rails.logger.error("mt5.reconcile_error #{instance.to_log.merge(error: e.class.name, message: e.message).to_json}")
      Rails.error.report(e, handled: true, context: { instance: instance.uuid })
      failure("reconcile_error", e.message)
    end

    private

    attr_reader :instance

    def runtime = @runtime ||= instance.worker_node.runtime

    # ------------------------------------------------------- Observed state

    def settle_observed_state(alive)
      if instance.stopping? && !alive
        return finish_stop
      elsif instance.process_expected? && !alive
        return handle_crash
      elsif !instance.process_expected? && alive
        return handle_orphan
      end

      return handle_start_timeout if instance.start_timed_out?
      return handle_connect_timeout if instance.connect_timed_out?
      return handle_stop_timeout if instance.stop_timed_out?
      return handle_lost_heartbeat if instance.running? && !instance.heartbeat_fresh?

      nil
    end

    # The stop we asked for completed while we were not looking.
    def finish_stop
      instance.update!(pid: nil, process_token: nil)
      instance.transition_to!("stopped", action: "instance.stopped", reason: "process exited during shutdown")
      :stopped
    end

    # The row says a terminal is up; the machine says otherwise. This is the
    # case that matters most — it is what a crash looks like from here.
    def handle_crash
      log(:crash_detected, previous_state: instance.state)
      instance.update!(pid: nil, process_token: nil)
      instance.record_failure!(code: "process_gone",
                               message: "The terminal process is no longer running.",
                               metadata: { detected_by: "reconciler" })
      :crashed
    end

    # A process exists that nothing believes in. Left alone it would keep
    # trading against a configuration the control plane thinks is stopped, which
    # is strictly worse than being down.
    def handle_orphan
      log(:orphan_detected)
      runtime.stop(instance, timeout: Mt5Instance::STOP_TIMEOUT)
      instance.events.create!(action: "instance.orphan_killed", from_state: instance.state,
                              to_state: instance.state, source: "system", occurred_at: Time.current,
                              reason: "a process was running for an instance that is #{instance.state}")
      instance.update!(pid: nil, process_token: nil)
      :orphan_killed
    end

    def handle_start_timeout
      fail_and_clean("start_timeout", "The terminal did not start within #{Mt5Instance::START_TIMEOUT.inspect}.")
    end

    # Up, but never called in. Almost always a bad token, a broker refusing the
    # login, or the platform URL missing from MetaTrader's WebRequest whitelist
    # — all of which look the same from outside, so the message says so.
    def handle_connect_timeout
      # Recorded against the credential as well as the instance. A user whose
      # broker details are wrong looks at the broker settings page, not at a
      # terminal's event log, and a blank page there while a terminal quietly
      # fails is how someone concludes the product is broken.
      instance.user.broker_credential&.record_verification_failure!(
        "A terminal signed in with these details never reported back. Check the server name and " \
        "account number, and that the password is the trading password rather than the investor one."
      )

      fail_and_clean("connect_timeout",
                     "The terminal started but never reported in. Check the broker login, the API token, " \
                     "and that the platform URL is allowed in MetaTrader's WebRequest list.")
    end

    # A graceful stop that has run out of patience.
    def handle_stop_timeout
      log(:stop_timeout)
      runtime.stop(instance, timeout: 1.second)
      instance.update!(pid: nil, process_token: nil)
      instance.transition_to!("stopped", action: "instance.stopped", reason: "killed after graceful stop timed out")
      :force_stopped
    end

    # The process is alive but the EA has gone quiet. Demoted rather than failed:
    # a terminal that loses the network for two minutes should show as trying to
    # reconnect, not be torn down. If it stays quiet, the connect timeout fails
    # it on a later pass.
    def handle_lost_heartbeat
      log(:heartbeat_lost, last_heartbeat_at: instance.last_heartbeat_at)
      instance.transition_to!("connecting", action: "instance.heartbeat_lost",
                              reason: "no report for longer than #{Mt5Instance::HEARTBEAT_TIMEOUT.inspect}")
      :heartbeat_lost
    end

    def fail_and_clean(code, message)
      log(code)
      runtime.stop(instance, timeout: 5.seconds)
      instance.update!(pid: nil, process_token: nil)
      instance.record_failure!(code:, message:)
      code.to_sym
    end

    # ------------------------------------------------------- Desired state

    def converge_towards_desire
      case instance.desired_state
      when "running" then converge_to_running
      when "stopped" then converge_to_stopped
      when "absent" then success(Deprovision.call(instance:, source: "system", reason: "reconciler").payload && :terminated)
      else success(:noop)
      end
    end

    def converge_to_running
      return success(:noop) unless instance.stopped? || instance.failed?
      return success(:crash_looping) if instance.crash_looping?
      return success(:backing_off) unless instance.restart_allowed_now?
      return success(:node_unavailable) unless instance.worker_node.schedulable?

      log(:restarting, attempt: instance.consecutive_failures + 1)
      # Counted here as well as in Restart: restart_count answers "how often has
      # this terminal had to be brought back?", and an automatic recovery is the
      # answer people most want. Leaving it to the manual path would make a
      # crash-looping instance look pristine.
      instance.increment!(:restart_count)
      result = Start.call(instance:, source: "system")
      success(result.success? ? :restarted : :restart_failed)
    end

    def converge_to_stopped
      return success(:noop) unless instance.process_expected?

      Stop.call(instance:, source: "system", reason: "desired state is stopped")
      success(:stopped)
    end

    # ------------------------------------------------------------- Logging

    # One structured line per decision. These are the only record of what
    # happened to a terminal at 3am, so they carry the whole instance context
    # rather than an id somebody has to go and look up.
    def log(event, **extra)
      Rails.logger.warn("mt5.#{event} #{instance.to_log.merge(extra).to_json}")
    end
  end
end
