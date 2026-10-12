require "test_helper"
require "tmpdir"

# The local runtime, exercised as far as it can be without MetaTrader.
#
# Everything here is about the layout it builds, because the layout is the part
# that silently does the wrong thing: MetaTrader started with /portable keeps
# its state next to its executable and reads expert inputs from exactly one
# directory, so a file written a level away is not a misconfiguration the
# terminal complains about — it is a terminal that starts with every input at
# its default and an expert that refuses to run.
class LocalRuntimeTest < ActiveSupport::TestCase
  WHITELIST_BLOB = "WebRequest=1\nWebRequestUrl=3DBBB97E1926F7BF93F45F78".freeze

  setup do
    @user = users(:verified)
    @other = User.create!(email_address: "second@example.com",
                          password: "another-long-test-password", verified_at: Time.current)
  end

  # A stand-in for a prepared MetaTrader installation: the executable, the
  # compiled EA, the shared read-only trees, and a common.ini carrying a
  # whitelist that was configured by hand.
  def with_template
    Dir.mktmpdir("mt5-template") do |template|
      FileUtils.mkdir_p(File.join(template, "MQL5/Experts/Include/GoldGrid"))
      FileUtils.mkdir_p(File.join(template, "MQL5/Include"))
      FileUtils.mkdir_p(File.join(template, "MQL5/Indicators"))
      FileUtils.mkdir_p(File.join(template, "config"))
      FileUtils.mkdir_p(File.join(template, "Sounds"))

      File.write(File.join(template, "terminal64.exe"), "MZ fake terminal")
      File.write(File.join(template, "MQL5/Experts/GoldGrid.ex5"), "fake compiled expert")
      File.write(File.join(template, "MQL5/Include/Trade.mqh"), "fake include")
      File.write(File.join(template, "config/common.ini"), "[Experts]\n#{WHITELIST_BLOB}\n")

      yield template
    end
  end

  def with_local_runtime(**overrides, &block)
    with_template do |template|
      with_mt5_sandbox(runtime: :local, template_dir: template, **overrides) do
        worker_node
        block.call(template)
      end
    end
  end

  # ------------------------------------------------------------ The template

  test "provisioning is refused when no MetaTrader template is installed" do
    with_mt5_sandbox(runtime: :local, template_dir: "/nonexistent") do
      worker_node
      broker_credential_for(@user)

      result = Mt5::Provision.call(user: @user)

      assert_equal "no_template", result.error_code
    end
  end

  test "a template without the compiled EA is not usable" do
    with_template do |template|
      FileUtils.rm(File.join(template, "MQL5/Experts/GoldGrid.ex5"))

      with_mt5_sandbox(runtime: :local, template_dir: template) do
        worker_node
        broker_credential_for(@user)

        assert_equal "no_template", Mt5::Provision.call(user: @user).error_code
      end
    end
  end

  # -------------------------------------------------------- The instance tree

  test "each instance gets its own terminal executable to run" do
    with_local_runtime do
      instance = provision!(@user)

      assert File.exist?(instance.terminal_binary),
        "/portable derives the data directory from the executable's own path"
      assert_equal File.join(instance.instance_dir, "terminal", "terminal64.exe"), instance.terminal_binary
    end
  end

  test "the expert's inputs are written where MetaTrader looks for them" do
    with_local_runtime do
      strategy = @user.strategies.create!(
        name: "XAUUSD grid", direction: "both", grid_spacing_points: 150, grid_buy_orders: 5, grid_sell_orders: 5, basket_take_profit: 2,
        initial_lot: 0.01, max_positions: 10, max_exposure_lots: 0.5
      )
      instance = provision!(@user, strategy:)

      assert_equal File.join(instance.instance_dir, "terminal/MQL5/Presets/GoldGrid.set"), instance.ea_preset
      assert File.exist?(instance.ea_preset)
      assert_match "InpStrategyId=#{strategy.id}", File.read(instance.ea_preset)
    end
  end

  test "the startup file names the preset by basename, which is all MetaTrader resolves" do
    with_local_runtime do
      instance = provision!(@user)

      assert_match "ExpertParameters=GoldGrid.set", File.read(instance.startup_ini)
    end
  end

  test "the WebRequest whitelist is inherited from the template" do
    with_local_runtime do
      instance = provision!(@user)

      inherited = File.read(File.join(instance.terminal_dir, "config/common.ini"))
      assert_match WHITELIST_BLOB, inherited,
        "MetaTrader encrypts the whitelist, so it can only be copied, never written"
    end
  end

  test "two users share the read-only tree and nothing they write" do
    with_local_runtime do
      broker_credential_for(@other)
      mine = provision!(@user)
      theirs = provision!(@other)

      # Shared: one compiled EA, linked, not two copies.
      assert_equal File.stat(File.join(mine.mql5_dir, "Experts/GoldGrid.ex5")).ino,
                   File.stat(File.join(theirs.mql5_dir, "Experts/GoldGrid.ex5")).ino

      # Private: the file that says which strategy to trade.
      assert_not_equal mine.ea_preset, theirs.ea_preset
      assert_not_equal File.stat(mine.ea_preset).ino, File.stat(theirs.ea_preset).ino
      assert_not_equal File.stat(mine.presets_dir).ino, File.stat(theirs.presets_dir).ino
    end
  end

  test "preparing an instance again never writes into the shared template" do
    with_local_runtime do
      instance = provision!(@user)
      runtime = instance.worker_node.runtime

      # Twice more: what a re-provision or a repair does to an existing tree.
      2.times { runtime.send(:build_terminal_tree, instance) }

      Mt5::Runtime::Local::SHARED_PATHS.each do |path|
        source = File.join(Mt5.config.template_dir.to_s, path)
        next unless File.directory?(source)

        nested = File.join(source, File.basename(path))
        assert_not File.symlink?(nested), "#{path}: a link was created inside the template (#{nested})"
        assert_equal source, File.readlink(File.join(instance.terminal_dir, path))
      end
    end
  end

  test "every path a terminal writes to belongs to its own instance" do
    with_local_runtime do
      instance = provision!(@user)

      Mt5::Runtime::Local::PRIVATE_PATHS.each do |path|
        full = File.join(instance.terminal_dir, path)
        assert File.directory?(full), "#{path} is missing"
        assert_not File.symlink?(full), "#{path} is writable and must not be shared with another instance"
      end
    end
  end

  # A tree that is half-linked is worse than none: it has an executable and no
  # expert inputs, which is a terminal that starts and trades nothing while
  # holding a display and the user's only slot.
  test "a tree that cannot be built completely leaves nothing behind" do
    with_local_runtime do
      broker_credential_for(@user)

      result = with_tree_building_failing { Mt5::Provision.call(user: @user) }

      assert_equal "prepare_failed", result.error_code
      assert_empty Dir.children(Mt5.config.instances_root)
    end
  end

  # ------------------------------------------------------- Trading permission

  # AllowLiveTrading is MetaTrader's Algo Trading master switch. It is off by
  # default, and a terminal provisioned without permission to trade must not
  # have it turned on — otherwise the EA's own input is the only gate left.
  test "the algo trading switch is left alone unless trading was asked for" do
    with_local_runtime do
      instance = provision!(@user, allow_trading: false)

      assert_no_match(/AllowLiveTrading/, File.read(instance.startup_ini))
      assert_match "InpAllowTrading=false", File.read(instance.ea_preset)
    end
  end

  test "the algo trading switch is written as a number MetaTrader can parse" do
    with_local_runtime do
      instance = provision!(@user, allow_trading: true)
      startup = File.read(instance.startup_ini)

      assert_match "AllowLiveTrading=1", startup
      assert_no_match(/AllowLiveTrading=true/, startup,
        "MetaTrader treats a value it cannot parse as absent, so `true` does not enable anything")
      assert_match "AllowDllImport=0", startup
    end
  end

  # -------------------------------------------------------------- Secrecy

  test "a broker password reaches the terminal's own config and nothing else" do
    with_local_runtime do
      credential = broker_credential_for(@user)
      instance = provision!(@user)

      assert_match credential.password, File.read(instance.startup_ini)

      elsewhere = Dir.glob(File.join(instance.instance_dir, "**/*")).select { File.file?(_1) } - [ instance.startup_ini ]
      leaked = elsewhere.select { |path| File.read(path).include?(credential.password) rescue false }
      assert_empty leaked, "the broker password must exist in exactly one file"
    end
  end

  test "instance files are readable only by the account that owns the process" do
    with_local_runtime do
      instance = provision!(@user)

      assert_equal 0o600, File.stat(instance.startup_ini).mode & 0o777
      assert_equal 0o600, File.stat(instance.ea_preset).mode & 0o777
      assert_equal 0o700, File.stat(instance.terminal_config_dir).mode & 0o777
    end
  end

  # ------------------------------------------------------------ Windows paths

  # MetaTrader parses /config: as a Windows path. A POSIX one is read as a
  # relative filename and quietly ignored, which presents as a terminal that
  # starts with no configuration at all.
  test "the startup file is handed to the terminal as a Windows path" do
    with_local_runtime do
      instance = provision!(@user)
      runtime = Mt5::Runtime::Local.new(instance.worker_node)

      windows = runtime.send(:windows_path, instance.startup_ini)

      assert windows.start_with?("Z:"), "Wine reaches the host filesystem through Z:"
      assert_not_includes windows, "/"
      assert windows.end_with?('\\goldgrid.ini')
    end
  end

  # ------------------------------------------------------- Finding the process

  # LiveUpdate applies an update by exiting and relaunching MetaTrader, so the
  # pid we spawned goes away while the terminal carries on. Judged by that pid
  # alone, a healthy terminal was a crash every minute, and every restart a
  # second copy that exited at once — until the crash-loop cap stopped trying.
  test "a terminal relaunched under a pid we did not spawn is still alive" do
    with_local_runtime do
      instance = provision!(@user)
      instance.update_columns(pid: 999_999_999, process_token: nil)
      runtime = Mt5::Runtime::Local.new(instance.worker_node)

      with_discovered_pids([ 4242 ]) do
        assert runtime.alive?(instance)
        assert_equal 4242, runtime.current_pid(instance)
      end

      with_discovered_pids([]) { assert_not runtime.alive?(instance) }
    end
  end

  # A container recreate starts PIDs from scratch, so a pid recorded before it
  # can now belong to any other process — here, a plain `sleep` that never
  # touched this instance. That pid must not be taken for the terminal, or the
  # reconciler waits on a process that does not exist and never restarts it.
  test "a recorded pid that now belongs to another process is not this terminal" do
    with_local_runtime do
      instance = provision!(@user)
      stranger = Process.spawn("sleep", "60")
      begin
        instance.update_columns(pid: stranger, process_token: nil)
        runtime = Mt5::Runtime::Local.new(instance.worker_node)

        with_discovered_pids([]) { assert_not runtime.alive?(instance) }
      ensure
        Process.kill("KILL", stranger) rescue nil
        Process.wait(stranger) rescue nil
      end
    end
  end

  test "a recorded pid whose command line names this instance is still the terminal" do
    with_local_runtime do
      instance = provision!(@user)
      # argv0 puts the uuid on the command line the way start.exe's does.
      ours = Process.spawn([ "sleep", "sleep-#{instance.uuid}" ], "60")
      begin
        instance.update_columns(pid: ours, process_token: nil)
        runtime = Mt5::Runtime::Local.new(instance.worker_node)

        with_discovered_pids([]) do
          assert runtime.alive?(instance)
          assert_equal ours, runtime.current_pid(instance)
        end
      ensure
        Process.kill("KILL", ours) rescue nil
        Process.wait(ours) rescue nil
      end
    end
  end

  test "start does not spawn a second terminal into a tree one is already running from" do
    with_local_runtime do
      instance = provision!(@user)
      runtime = Mt5::Runtime::Local.new(instance.worker_node)
      runtime.define_singleton_method(:spawn_terminal) { |_| flunk "spawned a second terminal" }

      with_discovered_pids([ 4242 ]) do
        result = runtime.start(instance)

        assert_predicate result, :ok?
        assert_equal 4242, result.pid
        assert result.details[:already_running]
      end
    end
  end

  test "the reconciler adopts a relaunched terminal rather than calling it a crash" do
    with_local_runtime do
      instance = provision!(@user)
      instance.update_columns(state: "running", desired_state: "running", pid: 999_999_999,
                              process_token: nil, last_heartbeat_at: Time.current)

      with_discovered_pids([ 4242 ]) { Mt5::Reconcile.call(instance:) }

      instance.reload
      assert_predicate instance, :running?
      assert_equal 4242, instance.pid
      assert_equal 0, instance.consecutive_failures
    end
  end

  # ------------------------------------------------------------- Diagnostics

  test "diagnostics surface what MetaTrader and the EA said went wrong, once each" do
    with_local_runtime do
      instance = provision!(@user)
      # MetaTrader stamps its logs in the local time of the machine it runs on,
      # and the parser reads them that way. The start time has to be built in
      # the same zone, or the test only passes on a machine set to UTC.
      instance.update_columns(started_at: Time.new(2026, 9, 28, 16, 0))
      runtime = Mt5::Runtime::Local.new(instance.worker_node)

      write_log(File.join(instance.terminal_dir, "logs"), [
        "AA\t0\t16:13:15.556\tTerminal\tMetaTrader 5 x64 build 6230 started",
        "BB\t0\t16:13:30.164\tNetwork\t'500123': authorization on Demo-Server failed (Invalid account)",
        "CC\t2\t16:19:11.321\tMQL5.community\tauthorization failed",
        "DD\t2\t16:20:17.791\tLiveUpdate\tdownload 'MT5CLWIDE64' failed",
        "EE\t1\t16:36:23.167\tNetwork\t'500123': connection to Demo-Server lost"
      ])
      write_log(File.join(instance.mql5_dir, "Logs"), [
        "FF\t0\t16:34:31.513\tGoldGrid (XAUUSD,M15)\tGoldGrid: configuration refresh failed — API token rejected.",
        "GG\t0\t16:35:01.513\tGoldGrid (XAUUSD,M15)\tGoldGrid: configuration refresh failed — API token rejected.",
        "HH\t0\t16:35:02.000\tGoldGrid (XAUUSD,M15)\tGoldGrid: platform reachable."
      ])

      messages = runtime.diagnostics(instance).map { |entry| entry[:message] }

      assert_equal [
        "'500123': authorization on Demo-Server failed (Invalid account)",
        "GoldGrid: configuration refresh failed — API token rejected.",
        "'500123': connection to Demo-Server lost"
      ], messages
    end
  end

  test "diagnostics are empty for a terminal that has never written a log" do
    with_local_runtime do
      instance = provision!(@user)

      assert_equal [], Mt5::Runtime::Local.new(instance.worker_node).diagnostics(instance)
    end
  end

  private

  # Stands in for scanning /proc, which only exists on Linux.
  def with_discovered_pids(pids)
    original = Mt5::Runtime::Local.instance_method(:discovered_pids)
    Mt5::Runtime::Local.define_method(:discovered_pids) { |_instance| pids }
    yield
  ensure
    Mt5::Runtime::Local.define_method(:discovered_pids, original)
  end

  # MetaTrader's logs are UTF-16LE with a byte-order mark, one file per day.
  def write_log(dir, lines)
    FileUtils.mkdir_p(dir)
    text = "\uFEFF" + lines.map { |line| "#{line}\r\n" }.join
    File.binwrite(File.join(dir, "20260928.log"), text.encode(Encoding::UTF_16LE))
  end

  # Fails partway through building the tree, after the instance directory
  # exists — which is the only interesting moment, because that is when there
  # is something to clean up.
  def with_tree_building_failing
    original = Mt5::Runtime::Local.instance_method(:build_terminal_tree)
    Mt5::Runtime::Local.define_method(:build_terminal_tree) do |instance|
      FileUtils.mkdir_p(instance.presets_dir)
      raise Errno::ENOSPC, instance.terminal_dir
    end
    yield
  ensure
    Mt5::Runtime::Local.define_method(:build_terminal_tree, original)
  end
end
