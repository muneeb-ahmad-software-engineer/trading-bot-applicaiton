require "fileutils"

module Mt5
  module Runtime
    # Runs terminals as child processes on the machine Rails is running on.
    #
    # This is the real runtime for the single-VPS deployment. MetaTrader is a
    # Windows program, so on Linux it runs under Wine, and Wine needs an X
    # display even for a terminal nobody looks at — hence Xvfb and a display
    # number per instance.
    #
    # Isolation is structural rather than conventional. Each instance gets its
    # own directory, its own Wine prefix inside it, its own X display, its own
    # MetaTrader tree and its own log file. There is no shared writable path
    # anywhere in the tree, so one user's terminal cannot read, corrupt or fill
    # up another's — including by filling the disk, since each tree is
    # separately prunable.
    #
    # The MetaTrader tree is built from a prepared template rather than
    # installed per user. The template is a normal MT5 installation with the EA
    # compiled into it and the platform URL added to the WebRequest whitelist by
    # hand, once. Everything in it that a terminal only reads is linked; the
    # handful of paths a terminal writes are real directories belonging to the
    # instance. See doc/EXECUTION_ARCHITECTURE.md for preparing the template.
    class Local < Base
      # Directories are the user's trading configuration and logs. 0700 so that
      # another account on the box cannot read a broker login.
      DIR_MODE = 0o700
      FILE_MODE = 0o600

      # Linked from the template: a terminal reads these and never writes them,
      # so every instance can share one copy. MQL5/Experts is here because it
      # holds the compiled EA, which is the same file for everybody.
      SHARED_PATHS = [
        "terminal64.exe", "Sounds",
        "MQL5/Experts", "MQL5/Include", "MQL5/Libraries",
        "MQL5/Indicators", "MQL5/Scripts", "MQL5/Services", "MQL5/Images"
      ].freeze

      # Created empty and owned by the instance. MetaTrader repopulates what it
      # needs. Bases is the downloaded price history — shared, it would be two
      # terminals writing one set of files; per instance it is merely a download
      # each.
      PRIVATE_PATHS = %w[config logs temp Bases Tester MQL5/Presets MQL5/Files MQL5/Logs MQL5/Profiles].freeze

      # Carries the WebRequest whitelist, whose value MetaTrader stores
      # encrypted — so it cannot be written from here, only inherited from a
      # template where it was set once by hand. Without it every call the EA
      # makes to the platform fails and the terminal never reports in.
      TEMPLATE_CONFIG = "config/common.ini".freeze

      def prepare(instance, context)
        return failure("no_template", "No MetaTrader template is installed on this node.") unless template_ready?

        FileUtils.mkdir_p(instance.instance_dir, mode: DIR_MODE)
        [ instance.config_dir, instance.data_dir, instance.log_dir, instance.run_dir ].each do |dir|
          FileUtils.mkdir_p(dir, mode: DIR_MODE)
        end

        build_terminal_tree(instance)
        write_terminal_config(instance, context)
        write_ea_config(instance, context)

        ok(details: { instance_dir: instance.instance_dir })
      rescue SystemCallError => e
        # Leave nothing half-built: a partially written config is worse than no
        # config, because it can start.
        FileUtils.rm_rf(instance.instance_dir)
        failure("prepare_failed", "Could not prepare #{instance.uuid}: #{e.class}")
      end

      def start(instance)
        return ok(pid: instance.pid, process_token: instance.process_token, details: { already_running: true }) if alive?(instance)

        return failure("terminal_missing", "MT5 terminal binary is not installed on this node.") unless File.exist?(instance.terminal_binary)

        process_token = SecureRandom.hex(16)
        File.write(instance.token_file, process_token, perm: FILE_MODE)

        pid = spawn_terminal(instance)
        File.write(instance.pid_file, pid.to_s, perm: FILE_MODE)

        # Detach so the terminal is not left as a zombie when this Rails process
        # exits — a deploy must not reap every user's terminal.
        Process.detach(pid)

        ok(pid:, process_token:)
      rescue SystemCallError, Errno::ENOENT => e
        failure("spawn_failed", "Could not start #{instance.uuid}: #{e.class} #{e.message}")
      end

      # Both halves, because either alone is a terminal that starts and does
      # nothing useful: the executable without the preset is an expert with no
      # strategy, and the preset without the executable is nothing at all.
      def prepared?(instance)
        File.exist?(instance.terminal_binary) && File.exist?(instance.ea_preset)
      end

      def stop(instance, timeout: nil)
        timeout ||= Mt5Instance::STOP_TIMEOUT
        pid = instance.pid

        return ok(details: { already_stopped: true }) if pid.blank? || !alive?(instance)

        # The whole process group: Wine spawns helpers, and signalling only the
        # parent leaves them holding the display and the data directory.
        signal_group(pid, "TERM")

        deadline = Time.current + timeout
        sleep_interval = 0.2
        while Time.current < deadline
          return finish_stop(instance, graceful: true) unless alive?(instance)

          sleep sleep_interval
        end

        signal_group(pid, "KILL")
        sleep sleep_interval
        finish_stop(instance, graceful: false)
      end

      # Two questions, both of which must be yes: is there a process with this
      # pid, and is it ours? PIDs are reused after a reboot, and signalling a
      # stranger's process on a shared host is not a recoverable mistake.
      def alive?(instance)
        pid = instance.pid
        return false if pid.blank?
        return false unless process_exists?(pid)

        recorded = instance.process_token
        return true if recorded.blank?

        File.exist?(instance.token_file) && File.read(instance.token_file).strip == recorded
      rescue SystemCallError
        false
      end

      def destroy(instance)
        # Refuse to delete anything that is not demonstrably inside the
        # configured root. A bug that produced an empty instance_dir must not
        # become `rm -rf /`.
        root = File.expand_path(Mt5.config.instances_root)
        path = File.expand_path(instance.instance_dir.to_s)

        unless path.start_with?("#{root}/") && path != root
          return failure("unsafe_path", "Refusing to remove #{path}: outside #{root}")
        end

        FileUtils.rm_rf(path)
        ok(details: { removed: path })
      rescue SystemCallError => e
        failure("destroy_failed", "Could not remove #{instance.uuid}: #{e.class}")
      end

      def resource_usage(instance)
        return { rss_bytes: nil, cpu_percent: nil } unless alive?(instance)

        # An argument array, not a shell string: no shell is involved, so a pid
        # that somehow became a string cannot become a command.
        output = IO.popen([ "ps", "-o", "rss=,pcpu=", "-p", instance.pid.to_i.to_s ], &:read).to_s.strip
        rss, cpu = output.split
        return { rss_bytes: nil, cpu_percent: nil } if rss.blank?

        { rss_bytes: rss.to_i * 1024, cpu_percent: cpu.to_f }
      rescue StandardError
        { rss_bytes: nil, cpu_percent: nil }
      end

      private

      # ------------------------------------------------------ Terminal tree

      def template_dir = Mt5.config.template_dir.to_s

      def template_ready?
        template_dir.present? &&
          File.exist?(File.join(template_dir, "terminal64.exe")) &&
          File.exist?(File.join(template_dir, "MQL5/Experts/GoldGrid.ex5")) &&
          template_config_path.present?
      end

      # Where the template's common.ini actually is, spelled as it is on disk.
      #
      # MetaTrader creates this directory as `Config`, and keeps that capital
      # under Wine. Every path an instance owns is lowercase, and Wine's
      # case-insensitive lookup folds the two for MetaTrader — but not for us:
      # Linux filesystems are case-sensitive and Ruby does not fold case, so
      # reading the template from here has to match how MetaTrader spelled it.
      def template_config_path
        Dir.glob(File.join(template_dir, "[Cc]onfig", "common.ini")).first
      end

      def build_terminal_tree(instance)
        FileUtils.mkdir_p(instance.mql5_dir, mode: DIR_MODE)

        PRIVATE_PATHS.each { |path| FileUtils.mkdir_p(File.join(instance.terminal_dir, path), mode: DIR_MODE) }
        SHARED_PATHS.each { |path| link_from_template(instance, path) }

        # Inherited whole, because the whitelist inside it is encrypted by
        # MetaTrader and there is no way to write one from out here. Written to
        # the lowercase name the instance uses throughout; MetaTrader asks for
        # `Config` and Wine resolves that to this file.
        source = template_config_path
        raise Errno::ENOENT, File.join(template_dir, TEMPLATE_CONFIG) if source.nil?

        target = File.join(instance.terminal_dir, TEMPLATE_CONFIG)
        FileUtils.cp(source, target)
        File.chmod(FILE_MODE, target)
      end

      # Hard-linked where the filesystem allows it, symlinked otherwise.
      #
      # terminal64.exe is 116 MB and /portable resolves its data directory from
      # the path the executable was invoked by — so a hard link gives each
      # instance a genuine directory entry of its own at no cost in space, which
      # a symlink to the template would not.
      def link_from_template(instance, path)
        source = File.join(template_dir, path)
        target = File.join(instance.terminal_dir, path)
        return unless File.exist?(source)

        FileUtils.mkdir_p(File.dirname(target), mode: DIR_MODE)

        if File.directory?(source)
          FileUtils.ln_s(source, target, force: true)
        else
          begin
            FileUtils.ln(source, target, force: true)
          rescue Errno::EXDEV, Errno::EPERM, NotImplementedError
            # A different filesystem, or one that will not hard-link. Falls back
            # rather than failing: a symlinked executable still runs, it merely
            # costs the instance its own /portable root, which is why this is
            # the fallback and not the default.
            FileUtils.ln_s(source, target, force: true)
          end
        end
      end

      # ------------------------------------------------------------ Launching

      def spawn_terminal(instance)
        Process.spawn(
          environment(instance),
          Mt5.config.wine_binary, instance.terminal_binary,
          "/portable",
          "/config:#{windows_path(instance.startup_ini)}",
          # A new process group, so stop can signal the terminal and everything
          # Wine spawned underneath it as one unit.
          pgroup: true,
          chdir: instance.terminal_dir,
          out: File.join(instance.log_dir, "terminal.out.log"),
          err: File.join(instance.log_dir, "terminal.err.log"),
          unsetenv_others: true
        )
      end

      # MetaTrader is a Windows program and parses /config: as a Windows path; a
      # POSIX one is read as a relative filename and silently ignored, which
      # presents as a terminal that starts with no configuration at all. Wine
      # maps the host root to Z:, so that is the drive every instance path is
      # reached through — the tree lives under the instances root, not inside
      # any Wine prefix.
      def windows_path(path)
        "Z:#{File.expand_path(path).tr('/', '\\')}"
      end

      # A deliberately minimal environment. Inheriting the Rails process's
      # environment would hand every terminal the database URL, the Rails master
      # key and every other secret this application holds.
      def environment(instance)
        {
          "HOME" => instance.instance_dir,
          "PATH" => "/usr/bin:/bin",
          "DISPLAY" => ":#{instance.display_number}",
          "WINEPREFIX" => File.join(instance.instance_dir, "wine"),
          "WINEDEBUG" => "-all",
          # Every instance gets an empty prefix, so every instance start is also
          # a first run of Wine — and a first run offers to download Mono and
          # Gecko, in a modal dialog, on a display nobody is watching. The
          # terminal then waits on a button nobody will ever press. MetaTrader
          # is native Win32 and wants neither, so both are disabled outright
          # rather than installed.
          "WINEDLLOVERRIDES" => "mscoree,mshtml=",
          "TZ" => "UTC"
        }
      end

      def process_exists?(pid)
        Process.kill(0, pid.to_i)
        true
      rescue Errno::ESRCH
        false
      rescue Errno::EPERM
        # Exists, owned by somebody else. Treat as alive so nothing tries to
        # reuse the pid, but never signal it.
        true
      end

      def signal_group(pid, signal)
        Process.kill(signal, -pid.to_i)
      rescue Errno::ESRCH
        nil
      rescue Errno::EPERM
        Rails.logger.warn("mt5.signal_denied pid=#{pid} signal=#{signal}")
      end

      def finish_stop(instance, graceful:)
        FileUtils.rm_f(instance.pid_file)
        FileUtils.rm_f(instance.token_file)
        ok(details: { graceful: })
      end

      # ----------------------------------------------------------- Config files

      # The terminal's own startup settings, read once when it launches.
      #
      # MetaTrader writes 0 and 1 here, not true and false: a value it cannot
      # parse is treated as absent, so `AllowLiveTrading=false` does not disable
      # trading, it fails to say anything about it.
      def write_terminal_config(instance, context)
        ini = +<<~INI
          ; Generated by the GoldGrid execution manager. Do not edit by hand:
          ; this file is rewritten on every provision.
          [Common]
          Login=#{context[:broker_login]}
          Password=#{context[:broker_password]}
          Server=#{context[:broker_server]}
          AutoConfiguration=0
          EnableNews=0
          EnableDDE=0
        INI

        # Written only when this terminal is meant to trade.
        #
        # AllowLiveTrading is MetaTrader's Algo Trading master switch, and it is
        # off by default. The EA's own InpAllowTrading is a second, independent
        # gate — but leaving the master switch on for a terminal provisioned
        # without permission to trade would make that gate the only thing
        # standing between a configuration bug and a real order.
        if context.fetch(:allow_trading, false)
          ini << <<~INI

            [Experts]
            AllowLiveTrading=1
            AllowDllImport=0
            Enabled=1
            Account=0
            Profile=0
          INI
        end

        ini << <<~INI

          [StartUp]
          Expert=GoldGrid
          Symbol=#{context[:symbol]}
          Period=M15
          ExpertParameters=#{File.basename(instance.ea_preset)}
        INI

        File.write(instance.startup_ini, ini, perm: FILE_MODE)
      end

      # The EA's inputs. The API token lives here and nowhere else on disk.
      #
      # It goes in MQL5/Presets because that is the only place MetaTrader looks
      # for the file named by ExpertParameters; anywhere else and the expert
      # starts with every input at its default, which means strategy id zero and
      # an EA that refuses to run.
      def write_ea_config(instance, context)
        inputs = <<~INI
          InpBaseUrl=#{context[:base_url]}
          InpApiToken=#{context[:api_token]}
          InpStrategyId=#{context[:strategy_id]}
          InpReportSeconds=#{Mt5.config.report_seconds}
          InpConfigSeconds=30
          InpMagicNumber=#{instance.magic_number}
          InpSlippagePoints=20
          InpAllowTrading=#{context.fetch(:allow_trading, false)}
        INI

        File.write(instance.ea_preset, inputs, perm: FILE_MODE)
      end
    end
  end
end
