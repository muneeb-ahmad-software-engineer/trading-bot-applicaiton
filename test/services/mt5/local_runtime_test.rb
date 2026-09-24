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
        name: "XAUUSD grid", direction: "both", grid_spacing_points: 150, grid_levels: 5,
        initial_lot: 0.01, lot_mode: "fixed", max_positions: 10, max_exposure_lots: 0.5
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

  private

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
