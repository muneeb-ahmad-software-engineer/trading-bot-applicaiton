require "fileutils"

module Mt5
  module Runtime
    # A runtime that does everything the local one does except run MetaTrader.
    #
    # This is not a test double bolted on afterwards — it is how the execution
    # manager is developed and how it is exercised in CI, neither of which has a
    # Windows trading terminal available. It builds the same directory tree,
    # writes the same configuration files, allocates the same displays and
    # obeys the same state machine, so everything except the last inch is real.
    #
    # It also stays useful after MetaTrader is installed: it is the only way to
    # exercise crash recovery on demand, which is otherwise a matter of waiting
    # for a real terminal to fall over.
    class Simulated < Base
      # Faults a test or a developer can inject, keyed by instance uuid.
      # Deliberately process-local: nothing here is allowed to leak into a
      # deployment where the real runtime is configured.
      class << self
        def faults = @faults ||= {}

        def inject(uuid, fault) = faults[uuid] = fault

        def clear! = @faults = {}

        # Pretends a running process died, the way a crash actually presents:
        # the row still says running, the process is simply gone.
        def kill(uuid) = inject(uuid, :dead)
      end

      def prepare(instance, context)
        FileUtils.mkdir_p(instance.instance_dir, mode: 0o700)
        [ instance.config_dir, instance.data_dir, instance.log_dir, instance.run_dir,
          instance.terminal_config_dir, instance.presets_dir ].each do |dir|
          FileUtils.mkdir_p(dir, mode: 0o700)
        end

        return failure("prepare_failed", "Injected prepare failure") if fault_for(instance) == :prepare_failure

        # The same files in the same places as the local runtime, minus the
        # broker password: a simulated instance never signs in anywhere, so
        # there is no reason for a credential to touch the disk. The paths
        # matter — writing the preset somewhere MetaTrader does not read is
        # precisely the kind of mistake this runtime exists to catch early.
        File.write(instance.startup_ini,
                   "; simulated\nServer=#{context[:broker_server]}\nLogin=#{context[:broker_login]}\n" \
                   "AllowLiveTrading=#{context.fetch(:allow_trading, false) ? 1 : 0}\n", perm: 0o600)
        File.write(instance.ea_preset,
                   "InpBaseUrl=#{context[:base_url]}\nInpStrategyId=#{context[:strategy_id]}\n" \
                   "InpMagicNumber=#{instance.magic_number}\nInpApiToken=<redacted>\n" \
                   "InpAllowTrading=#{context.fetch(:allow_trading, false)}\n", perm: 0o600)

        ok(details: { instance_dir: instance.instance_dir, simulated: true })
      end

      def start(instance)
        case fault_for(instance)
        when :start_failure then return failure("spawn_failed", "Injected start failure")
        when :terminal_missing then return failure("terminal_missing", "MT5 terminal binary is not installed on this node.")
        end

        return ok(pid: instance.pid, process_token: instance.process_token, details: { already_running: true }) if alive?(instance)

        # A new process genuinely starts, so a previously injected death no
        # longer applies. Without this a killed instance could never come back,
        # which would make crash *recovery* impossible to exercise.
        Simulated.faults.delete(instance.uuid) if fault_for(instance) == :dead

        token = SecureRandom.hex(16)
        pid = 900_000 + rand(90_000)

        FileUtils.mkdir_p(instance.run_dir, mode: 0o700)
        File.write(instance.token_file, token, perm: 0o600)
        File.write(instance.pid_file, pid.to_s, perm: 0o600)

        ok(pid:, process_token: token)
      end

      def prepared?(instance) = File.exist?(instance.ea_preset)

      def stop(instance, timeout: nil)
        return failure("stop_failed", "Injected stop failure") if fault_for(instance) == :stop_failure

        graceful = fault_for(instance) != :ignores_sigterm
        Simulated.faults.delete(instance.uuid)

        FileUtils.rm_f(instance.pid_file)
        FileUtils.rm_f(instance.token_file)

        ok(details: { graceful:, simulated: true })
      end

      # Alive means the marker files this runtime wrote are still there and no
      # fault says otherwise. Same shape of question as the local runtime asks
      # the kernel, so the reconciler cannot tell the difference.
      def alive?(instance)
        return false if fault_for(instance) == :dead
        return false if instance.pid.blank?

        File.exist?(instance.pid_file) && File.exist?(instance.token_file)
      end

      def destroy(instance)
        root = File.expand_path(Mt5.config.instances_root)
        path = File.expand_path(instance.instance_dir.to_s)

        unless path.start_with?("#{root}/") && path != root
          return failure("unsafe_path", "Refusing to remove #{path}: outside #{root}")
        end

        Simulated.faults.delete(instance.uuid)
        FileUtils.rm_rf(path)
        ok(details: { removed: path })
      end

      def resource_usage(instance)
        return { rss_bytes: nil, cpu_percent: nil } unless alive?(instance)

        { rss_bytes: 420 * 1024 * 1024, cpu_percent: 1.5 }
      end

      private

      def fault_for(instance) = Simulated.faults[instance.uuid]
    end
  end
end
