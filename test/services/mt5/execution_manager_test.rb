require "test_helper"

# The execution manager end to end: provisioning, the lifecycle, isolation
# between users, and recovery from every way a terminal can fail.
#
# These run against real directories and the simulated runtime, so the directory
# tree, the configuration files, display allocation and cleanup are all exercised
# for real. Only spawning MetaTrader itself is stood in for — and the simulated
# runtime answers the same questions the local one does, so the services above
# cannot tell which they are talking to.
class Mt5ExecutionManagerTest < ActiveSupport::TestCase
  setup do
    @user = users(:verified)
    @other = users(:unverified)
  end

  # ------------------------------------------------------------ Provisioning

  test "provisioning gives a terminal a home, a display and its own token" do
    with_mt5_sandbox do |root|
      worker_node
      instance = provision!(@user)

      assert_predicate instance, :stopped?, "a provisioned terminal is not yet running"
      assert instance.instance_dir.start_with?("#{root}/")
      assert Dir.exist?(instance.config_dir)
      assert_not_nil instance.api_token
      assert_not_nil instance.display_number
      assert_not_nil instance.provisioned_at
    end
  end

  test "provisioning twice returns the same terminal rather than building a second" do
    with_mt5_sandbox do
      worker_node
      first = provision!(@user)
      second = Mt5::Provision.call(user: @user).payload

      assert_equal first.id, second.id
      assert_equal 1, @user.mt5_instances.count
    end
  end

  test "a terminal cannot be provisioned without a verified email address" do
    with_mt5_sandbox do
      worker_node
      broker_credential_for(@other)

      result = Mt5::Provision.call(user: @other)

      assert_equal "email_unverified", result.error_code
      assert_equal 0, @other.mt5_instances.count
    end
  end

  test "a terminal cannot be provisioned without broker credentials to sign in with" do
    with_mt5_sandbox do
      worker_node

      result = Mt5::Provision.call(user: @user)

      assert_equal "no_broker_credential", result.error_code
    end
  end

  test "provisioning is refused when no node has capacity" do
    with_mt5_sandbox do
      worker_node(max_instances: 1)
      provision!(@user)
      broker_credential_for(@other)
      @other.verify!

      result = Mt5::Provision.call(user: @other)

      assert_equal "no_capacity", result.error_code
    end
  end

  test "an offline node is not scheduled onto" do
    with_mt5_sandbox do
      worker_node(status: "offline")
      broker_credential_for(@user)

      assert_equal "no_capacity", Mt5::Provision.call(user: @user).error_code
    end
  end

  test "a node that has stopped reporting is not scheduled onto" do
    # A VPS that has crashed still has `status: online` in the database — it
    # never got the chance to say otherwise. Freshness is what rules it out.
    with_mt5_sandbox do
      worker_node(last_heartbeat_at: 1.hour.ago)
      broker_credential_for(@user)

      assert_equal "no_capacity", Mt5::Provision.call(user: @user).error_code
    end
  end

  test "a failed provision leaves nothing behind holding a slot" do
    with_mt5_sandbox do
      worker_node
      broker_credential_for(@user)

      result = with_prepare_failing { Mt5::Provision.call(user: @user) }

      assert_predicate result, :failure?
      assert_equal 0, @user.mt5_instances.not_terminated.count,
                   "a half-provisioned terminal must not hold the user's only slot"
      assert_equal 0, Dir.children(Mt5.config.instances_root).size,
                   "a failed provision must leave no directory behind"
    end
  end

  # -------------------------------------------------------------- Isolation

  test "no two live terminals share a directory, a display, a magic number or a token" do
    with_mt5_sandbox do
      worker_node
      @other.verify!
      third = User.create!(email_address: "third@example.com", password: "averylongpassword1",
                           verified_at: Time.current)

      instances = [ @user, @other, third ].map { provision!(_1) }

      %i[instance_dir display_number magic_number api_token_id].each do |attribute|
        values = instances.map { _1.public_send(attribute) }
        assert_equal 3, values.uniq.size, "#{attribute} is shared between terminals: #{values.inspect}"
      end
    end
  end

  test "no terminal's directory sits inside another's" do
    with_mt5_sandbox do
      worker_node
      @other.verify!
      dirs = [ provision!(@user).instance_dir, provision!(@other).instance_dir ]

      assert_not dirs.any? { |a| dirs.any? { |b| a != b && a.start_with?("#{b}/") } }
    end
  end

  test "instance directories are readable only by the account that owns the process" do
    # A broker login and an API token live in here. Another account on the box
    # must not be able to read them.
    with_mt5_sandbox do
      worker_node
      instance = provision!(@user)

      [ instance.instance_dir, instance.config_dir ].each do |dir|
        assert_equal "700", format("%o", File.stat(dir).mode & 0o777), "#{dir} is too permissive"
      end
    end
  end

  test "one user's terminal is untouched by another's whole lifecycle" do
    with_mt5_sandbox do
      worker_node
      @other.verify!
      mine = running_instance(@user)
      theirs = running_instance(@other)

      Mt5::Runtime::Simulated.kill(theirs.uuid)
      Mt5::Reconcile.call(instance: theirs)
      Mt5::Deprovision.call(instance: theirs.reload)

      mine.reload
      assert_predicate mine, :running?
      assert Dir.exist?(mine.instance_dir)
      assert_predicate mine.api_token.reload, :active?
    end
  end

  # -------------------------------------------------------------- Lifecycle

  test "a terminal reaches running only once it has actually reported in" do
    with_mt5_sandbox do
      worker_node
      instance = provision!(@user)

      Mt5::Start.call(instance:)
      assert_predicate instance.reload, :connecting?,
                       "a spawned process is not a connected terminal"

      Mt5::RecordHeartbeat.call(api_token: instance.api_token)
      assert_predicate instance.reload, :running?
    end
  end

  test "starting records the intent before attempting the action" do
    # So that a crash between the two leaves the reconciler enough to finish.
    with_mt5_sandbox do
      worker_node
      instance = provision!(@user)

      Mt5::Start.call(instance:)

      assert_predicate instance.reload, :wants_running?
    end
  end

  test "starting an already-running terminal is a success, not an error" do
    with_mt5_sandbox do
      worker_node
      instance = running_instance(@user)

      result = Mt5::Start.call(instance:)

      assert_predicate result, :success?
      assert_predicate instance.reload, :running?
    end
  end

  test "stopping is idempotent" do
    with_mt5_sandbox do
      worker_node
      instance = running_instance(@user)

      assert_predicate Mt5::Stop.call(instance:), :success?
      assert_predicate Mt5::Stop.call(instance: instance.reload), :success?
      assert_predicate instance.reload, :stopped?
    end
  end

  test "stopping releases the process and its identity" do
    with_mt5_sandbox do
      worker_node
      instance = running_instance(@user)

      Mt5::Stop.call(instance:)

      instance.reload
      assert_nil instance.pid
      assert_nil instance.process_token
      assert_not instance.worker_node.runtime.alive?(instance)
    end
  end

  test "a terminal that never started can still be stopped" do
    with_mt5_sandbox do
      worker_node
      instance = provision!(@user)

      assert_predicate Mt5::Stop.call(instance:), :success?
    end
  end

  test "a stop that fails does not claim the terminal is stopped" do
    # The most dangerous lie available: a row saying stopped while a terminal
    # keeps trading.
    with_mt5_sandbox do
      worker_node
      instance = running_instance(@user)
      Mt5::Runtime::Simulated.inject(instance.uuid, :stop_failure)

      result = Mt5::Stop.call(instance:)

      assert_predicate result, :failure?
      assert_not instance.reload.stopped?
    end
  end

  test "restarting stops and starts, and is counted" do
    with_mt5_sandbox do
      worker_node
      instance = running_instance(@user)

      Mt5::Restart.call(instance:)

      instance.reload
      assert_predicate instance, :connecting?
      assert_equal 1, instance.restart_count
    end
  end

  test "deprovisioning stops the terminal, wipes its directory and revokes its token" do
    with_mt5_sandbox do
      worker_node
      instance = running_instance(@user)
      directory = instance.instance_dir
      token = instance.api_token

      Mt5::Deprovision.call(instance:)

      instance.reload
      assert_predicate instance, :terminated?
      assert_not Dir.exist?(directory)
      assert_not token.reload.active?
    end
  end

  test "a crashed terminal can still be cleaned up" do
    # A failed instance may still hold a live process — a stop that fails
    # records a failure while the terminal keeps running — so halting has to be
    # reachable from `failed`. Without it a user could never get rid of a
    # terminal that had crashed, which is exactly when they most want to.
    with_mt5_sandbox do
      worker_node
      instance = running_instance(@user)
      Mt5::Runtime::Simulated.kill(instance.uuid)
      Mt5::Reconcile.call(instance:)
      assert_predicate instance.reload, :failed?

      result = Mt5::Deprovision.call(instance:)

      assert_predicate result, :success?
      assert_predicate instance.reload, :terminated?
      assert_not Dir.exist?(instance.instance_dir)
    end
  end

  test "a failed terminal that still holds a process can be stopped" do
    with_mt5_sandbox do
      node = worker_node
      instance = running_instance(@user)
      Mt5::Runtime::Simulated.inject(instance.uuid, :stop_failure)
      Mt5::Stop.call(instance:)
      assert_predicate instance.reload, :failed?
      assert node.runtime.alive?(instance), "the process outlived the failed stop"

      Mt5::Runtime::Simulated.clear!
      assert_predicate Mt5::Stop.call(instance:), :success?
      assert_predicate instance.reload, :stopped?
      assert_not node.runtime.alive?(instance)
    end
  end

  test "deprovisioning is idempotent" do
    with_mt5_sandbox do
      worker_node
      instance = running_instance(@user)
      Mt5::Deprovision.call(instance:)

      assert_predicate Mt5::Deprovision.call(instance: instance.reload), :success?
    end
  end

  test "a terminal that will not stop is not deprovisioned" do
    with_mt5_sandbox do
      worker_node
      instance = running_instance(@user)
      Mt5::Runtime::Simulated.inject(instance.uuid, :stop_failure)

      result = Mt5::Deprovision.call(instance:)

      assert_predicate result, :failure?
      assert Dir.exist?(instance.instance_dir), "the directory of a live terminal must not be removed"
    end
  end

  test "a start that cannot spawn is recorded as a failure with a reason" do
    with_mt5_sandbox do
      worker_node
      instance = provision!(@user)
      Mt5::Runtime::Simulated.inject(instance.uuid, :terminal_missing)

      result = Mt5::Start.call(instance:)

      assert_predicate result, :failure?
      assert_equal "terminal_missing", instance.reload.last_error_code
      assert_predicate instance, :failed?
    end
  end

  # --------------------------------------------------------------- Recovery

  test "a crashed terminal is detected and recorded, not left claiming to run" do
    with_mt5_sandbox do
      worker_node
      instance = running_instance(@user)

      Mt5::Runtime::Simulated.kill(instance.uuid)
      outcome = Mt5::Reconcile.call(instance:)

      instance.reload
      assert_equal :crashed, outcome.payload
      assert_predicate instance, :failed?
      assert_equal "process_gone", instance.last_error_code
      assert_nil instance.pid
    end
  end

  test "a crashed terminal is restarted once its backoff has elapsed" do
    with_mt5_sandbox do
      worker_node
      instance = running_instance(@user)
      Mt5::Runtime::Simulated.kill(instance.uuid)
      Mt5::Reconcile.call(instance:)

      assert_equal :backing_off, Mt5::Reconcile.call(instance: instance.reload).payload,
                   "a crash must not be retried immediately"

      instance.reload.update!(next_restart_at: 1.second.ago)
      assert_equal :restarted, Mt5::Reconcile.call(instance:).payload
      assert_predicate instance.reload, :connecting?
    end
  end

  test "recovery is complete only when the terminal reports in again" do
    with_mt5_sandbox do
      worker_node
      instance = running_instance(@user)
      Mt5::Runtime::Simulated.kill(instance.uuid)
      Mt5::Reconcile.call(instance:)
      instance.reload.update!(next_restart_at: 1.second.ago)
      Mt5::Reconcile.call(instance:)

      Mt5::RecordHeartbeat.call(api_token: instance.reload.api_token)

      instance.reload
      assert_predicate instance, :running?
      assert_equal 0, instance.consecutive_failures, "a recovered terminal starts from a clean slate"
      assert_nil instance.next_restart_at
    end
  end

  test "a terminal that will not stay up is given up on rather than restarted forever" do
    with_mt5_sandbox do
      worker_node
      instance = running_instance(@user)

      Mt5Instance::MAX_CONSECUTIVE_FAILURES.times do
        Mt5::Runtime::Simulated.kill(instance.uuid)
        Mt5::Reconcile.call(instance: instance.reload)
        instance.reload.update!(next_restart_at: 1.second.ago)
        Mt5::Reconcile.call(instance: instance.reload)
      end

      instance.reload
      assert_predicate instance, :crash_looping?
      assert_equal :crash_looping, Mt5::Reconcile.call(instance:).payload
      assert_equal "crash_looping", Mt5::Start.call(instance:).error_code
    end
  end

  test "a process nobody believes in is killed" do
    # After a Rails crash mid-stop, or an operator starting something by hand.
    # Left alone it would keep trading against a configuration the control plane
    # believes is stopped.
    with_mt5_sandbox do
      node = worker_node
      instance = provision!(@user)
      Mt5::Start.call(instance:)
      instance.reload.update_columns(state: "stopped", desired_state: "stopped")

      outcome = Mt5::Reconcile.call(instance:)

      assert_equal :orphan_killed, outcome.payload
      assert_not node.runtime.alive?(instance.reload)
    end
  end

  test "a terminal that goes quiet is demoted before it is failed" do
    # Two minutes of lost network should show as reconnecting, not tear the
    # terminal down.
    with_mt5_sandbox do
      worker_node
      instance = running_instance(@user)
      instance.update_columns(last_heartbeat_at: 5.minutes.ago)

      assert_equal :heartbeat_lost, Mt5::Reconcile.call(instance:).payload
      assert_predicate instance.reload, :connecting?
      assert instance.worker_node.runtime.alive?(instance), "the process is still there"
    end
  end

  test "a terminal that never reports in is failed with an actionable reason" do
    with_mt5_sandbox do
      worker_node
      instance = provision!(@user)
      Mt5::Start.call(instance:)
      instance.reload.update_columns(last_transition_at: (Mt5Instance::CONNECT_TIMEOUT + 1.minute).ago)

      assert_equal :connect_timeout, Mt5::Reconcile.call(instance:).payload

      instance.reload
      assert_predicate instance, :failed?
      assert_match(/broker login|API token|WebRequest/i, instance.last_error_message)
    end
  end

  test "a graceful stop that hangs is escalated to a kill" do
    with_mt5_sandbox do
      worker_node
      instance = running_instance(@user)
      instance.update_columns(state: "stopping", last_transition_at: (Mt5Instance::STOP_TIMEOUT + 1.second).ago)

      assert_equal :force_stopped, Mt5::Reconcile.call(instance:).payload
      assert_predicate instance.reload, :stopped?
    end
  end

  test "the reconciler survives an instance it cannot handle" do
    # One bad row must not stop every other user's terminal being reconciled.
    with_mt5_sandbox do
      worker_node
      broken = running_instance(@user)

      with_liveness_check_raising do
        assert_nothing_raised { Mt5::Reconcile.call(instance: broken) }
        assert_predicate Mt5::Reconcile.call(instance: broken), :failure?
      end

      # And the next pass, once the fault clears, works normally.
      assert_predicate Mt5::Reconcile.call(instance: broken.reload), :success?
    end
  end

  test "reconciling is safe to run repeatedly" do
    with_mt5_sandbox do
      worker_node
      instance = running_instance(@user)

      3.times { Mt5::Reconcile.call(instance: instance.reload) }

      assert_predicate instance.reload, :running?
      assert_equal 0, instance.consecutive_failures
    end
  end

  test "nothing is restarted onto a node that is not available" do
    with_mt5_sandbox do
      node = worker_node
      instance = provision!(@user)
      instance.update!(state: "failed", desired_state: "running", failed_at: Time.current)
      node.update!(status: "offline")

      assert_equal :node_unavailable, Mt5::Reconcile.call(instance: instance.reload).payload
      assert_predicate instance.reload, :failed?
    end
  end

  # ----------------------------------------------------------- Heartbeats

  test "a terminal report is a heartbeat" do
    with_mt5_sandbox do
      worker_node
      instance = running_instance(@user)
      instance.update_columns(last_heartbeat_at: 1.hour.ago)

      Mt5::RecordHeartbeat.call(api_token: instance.api_token)

      assert_predicate instance.reload, :heartbeat_fresh?
    end
  end

  test "a heartbeat for a token with no terminal is harmless" do
    with_mt5_sandbox do
      worker_node
      token = ApiToken.issue(user: @user, name: "phone")

      assert_predicate Mt5::RecordHeartbeat.call(api_token: token), :success?
    end
  end

  test "a heartbeat never promotes a terminated terminal" do
    with_mt5_sandbox do
      worker_node
      instance = running_instance(@user)
      token = instance.api_token
      Mt5::Deprovision.call(instance:)

      Mt5::RecordHeartbeat.call(api_token: token)

      assert_predicate instance.reload, :terminated?
    end
  end

  # ------------------------------------------------------------- Reaping

  test "a terminal whose user is not trading is stopped, not destroyed" do
    with_mt5_sandbox do
      worker_node
      instance = running_instance(@user)
      instance.update_columns(last_heartbeat_at: 2.hours.ago, started_at: 2.hours.ago,
                              last_transition_at: 2.hours.ago)

      assert_equal 1, Mt5::ReapIdle.call.payload

      instance.reload
      assert_predicate instance, :stopped?
      assert Dir.exist?(instance.instance_dir), "reaping frees memory, not configuration"
      assert_predicate instance.api_token.reload, :active?
    end
  end

  test "a terminal belonging to a user who is trading is left alone" do
    with_mt5_sandbox do
      worker_node
      strategy = @user.strategies.create!(name: "g", grid_spacing_points: 150, grid_buy_orders: 5, grid_sell_orders: 5, basket_take_profit: 2,
                                          initial_lot: 0.01, max_positions: 10, max_exposure_lots: 0.5)
      strategy.start!
      instance = running_instance(@user)
      instance.update_columns(last_heartbeat_at: 2.hours.ago, started_at: 2.hours.ago,
                              last_transition_at: 2.hours.ago)

      assert_equal 0, Mt5::ReapIdle.call.payload
      assert_predicate instance.reload, :running?
    end
  end

  test "a recently active terminal is not reaped" do
    with_mt5_sandbox do
      worker_node
      running_instance(@user)

      assert_equal 0, Mt5::ReapIdle.call.payload
    end
  end

  # ------------------------------------------------------------ Monitoring

  test "the monitor reconciles everything and records that the node is alive" do
    with_mt5_sandbox do
      node = worker_node
      @other.verify!
      running_instance(@user)
      running_instance(@other)
      node.update_columns(last_heartbeat_at: 1.hour.ago)

      Mt5::Monitor.call

      assert_predicate node.reload, :heartbeat_fresh?
    end
  end

  test "the monitor reports what it did" do
    with_mt5_sandbox do
      worker_node
      instance = running_instance(@user)
      Mt5::Runtime::Simulated.kill(instance.uuid)

      outcomes = Mt5::Monitor.call.payload

      assert_equal 1, outcomes[:crashed]
    end
  end

  test "a node can be drained and its terminals come back by themselves" do
    # The planned-reboot path. An operator stops everything; nobody has to
    # write down which terminals were running, because the intent survives.
    with_mt5_sandbox do
      node = worker_node
      instance = running_instance(@user)

      Mt5::Stop.call(instance:, source: "system", reason: "node quiesce", preserve_desired_state: true)

      instance.reload
      assert_predicate instance, :stopped?
      assert_predicate instance, :wants_running?, "the intent to run must survive a drain"

      # Node comes back; the reconciler restores it with no operator action.
      node.update!(status: "online", last_heartbeat_at: Time.current)
      assert_equal :restarted, Mt5::Reconcile.call(instance:).payload
      assert_predicate instance.reload, :connecting?
    end
  end

  test "a user pressing stop is not undone by the reconciler" do
    with_mt5_sandbox do
      worker_node
      instance = running_instance(@user)

      Mt5::Stop.call(instance:, actor: @user, source: "web")

      assert_predicate instance.reload, :wants_stopped?
      assert_equal :noop, Mt5::Reconcile.call(instance:).payload
      assert_predicate instance.reload, :stopped?
    end
  end

  # ------------------------------------------------- Account deletion

  test "deleting an account tears the terminal down rather than stranding it" do
    # Deleting the rows alone would leave an MT5 process on the node that
    # nothing in this system can see any more, holding memory and a broker
    # connection forever.
    with_mt5_sandbox do
      node = worker_node
      user = User.create!(email_address: "leaving@example.com", password: "averylongpassword1",
                          verified_at: Time.current)
      instance = running_instance(user)
      directory = instance.instance_dir

      user.destroy!

      assert_not Dir.exist?(directory), "the terminal's directory outlived the account"
      assert_not node.runtime.alive?(instance)
      assert_equal 0, Mt5Instance.where(user_id: user.id).count
    end
  end

  test "a terminal that cannot be stopped does not block account deletion" do
    # Deletion is a legal obligation. The orphan is reported instead.
    with_mt5_sandbox do
      worker_node
      user = User.create!(email_address: "leaving2@example.com", password: "averylongpassword1",
                          verified_at: Time.current)
      instance = running_instance(user)
      Mt5::Runtime::Simulated.inject(instance.uuid, :stop_failure)

      assert_nothing_raised { user.destroy! }
      assert_not User.exists?(user.id)
    end
  end

  # -------------------------------------------------------------- Security

  test "a broker password is never written by the simulated runtime" do
    with_mt5_sandbox do
      worker_node
      instance = provision!(@user)

      contents = Dir.glob("#{instance.instance_dir}/**/*").select { File.file?(_1) }.map { File.read(_1) }.join

      assert_no_match(/s3cret-broker-password/, contents)
    end
  end

  test "a broker password is encrypted at rest" do
    with_mt5_sandbox do
      credential = broker_credential_for(@user)

      stored = BrokerCredential.connection.select_value(
        "SELECT password FROM broker_credentials WHERE id = #{credential.id}"
      )

      assert_no_match(/s3cret-broker-password/, stored.to_s)
      assert_equal "s3cret-broker-password", credential.reload.password
    end
  end

  test "a credential never renders its password, however it is printed" do
    with_mt5_sandbox do
      credential = broker_credential_for(@user)

      assert_no_match(/s3cret-broker-password/, credential.inspect)
      assert_no_match(/s3cret-broker-password/, credential.to_log.to_json)
      assert_no_match(/500123/, credential.to_log.to_json)
    end
  end

  test "destroying refuses any path outside the configured root" do
    # The guard that stops a bug in path construction becoming rm -rf /.
    with_mt5_sandbox do
      node = worker_node
      instance = provision!(@user)
      instance.update_columns(instance_dir: "/etc")

      result = node.runtime.destroy(instance)

      assert_predicate result, :failed?
      assert_equal "unsafe_path", result.error_code
      assert Dir.exist?("/etc")
    end
  end

  private

  # Makes the runtime's liveness check blow up, standing in for a node that has
  # become unreachable in a way the runtime did not anticipate.
  def with_liveness_check_raising
    original = Mt5::Runtime::Simulated.instance_method(:alive?)
    Mt5::Runtime::Simulated.define_method(:alive?) { |_instance| raise Errno::ECONNREFUSED, "node agent" }
    yield
  ensure
    Mt5::Runtime::Simulated.define_method(:alive?, original)
  end
end
