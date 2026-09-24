require "test_helper"

# The state machine, in isolation from the services that drive it.
#
# Everything the execution manager does is a transition, and an invalid one that
# is allowed through does not fail loudly — it produces a row claiming a
# terminal is stopped while a process keeps trading. So the machine refuses
# anything it was not told to permit.
class Mt5InstanceTest < ActiveSupport::TestCase
  setup do
    @user = users(:verified)
    @node = worker_node
  end

  def build_instance(**overrides)
    Mt5.with_config(runtime: :simulated, instances_root: "/tmp/mt5-unit", display_base: 100) do
      @user.mt5_instances.create!({ worker_node: @node, state: "provisioning",
                                    last_transition_at: Time.current }.merge(overrides))
    end
  end

  # -------------------------------------------------------------- Identity

  test "an instance names itself, claims a magic number and a home" do
    instance = build_instance

    assert_match(/\Amt5-[0-9a-f-]{36}\z/, instance.uuid)
    assert_operator instance.magic_number, :>=, Mt5Instance::MAGIC_NUMBER_BASE
    assert_equal File.join("/tmp/mt5-unit", instance.uuid), instance.instance_dir
  end

  test "magic numbers are never reused" do
    # Two terminals sharing a magic number would each treat the other's
    # positions at the broker as its own.
    first = build_instance
    first.update!(state: "terminated")
    second = users(:unverified).mt5_instances.create!(worker_node: @node, state: "provisioning",
                                                      last_transition_at: Time.current)

    assert_not_equal first.magic_number, second.magic_number
    assert_operator second.magic_number, :>, first.magic_number
  end

  test "every path an instance uses lives under its own directory" do
    instance = build_instance
    paths = [ instance.config_dir, instance.data_dir, instance.log_dir, instance.run_dir,
              instance.pid_file, instance.token_file ]

    paths.each do |path|
      assert path.start_with?("#{instance.instance_dir}/"), "#{path} escapes the instance directory"
    end
  end

  test "one live instance per user, enforced by the database" do
    build_instance

    assert_raises(ActiveRecord::RecordNotUnique) do
      @user.mt5_instances.insert!({ worker_node_id: @node.id, state: "provisioning",
                                    uuid: "mt5-#{SecureRandom.uuid}", magic_number: 999_999,
                                    instance_dir: "/tmp/x", desired_state: "stopped",
                                    created_at: Time.current, updated_at: Time.current })
    end
  end

  test "a terminated instance frees the user's slot" do
    build_instance.update!(state: "terminated")

    assert_nothing_raised { build_instance }
  end

  # ------------------------------------------------------------ Transitions

  test "the machine permits only the transitions it declares" do
    instance = build_instance(state: "running")

    assert instance.may_transition_to?("stopping")
    assert_not instance.may_transition_to?("starting"),
               "a running terminal must be stopped before it can be started again"
  end

  test "an undeclared transition is refused rather than quietly applied" do
    instance = build_instance(state: "stopped")

    assert_raises(Mt5Instance::InvalidTransition) do
      instance.transition_to!("running", action: "test")
    end
    assert_equal "stopped", instance.reload.state
  end

  test "a transition and its audit record land together or not at all" do
    instance = build_instance(state: "stopped")

    assert_difference "Mt5InstanceEvent.count", 1 do
      instance.transition_to!("starting", action: "instance.starting", reason: "operator")
    end

    event = instance.events.last
    assert_equal %w[stopped starting], [ event.from_state, event.to_state ]
    assert_equal "operator", event.reason
  end

  test "a transition stamps the timestamp belonging to the state it entered" do
    instance = build_instance(state: "stopped")

    instance.transition_to!("starting", action: "a")
    assert_not_nil instance.started_at

    instance.transition_to!("connecting", action: "b")
    assert_not_nil instance.connected_at

    instance.transition_to!("stopped", action: "c")
    assert_not_nil instance.stopped_at
  end

  test "terminated is final" do
    instance = build_instance(state: "stopped")
    instance.transition_to!("terminated", action: "instance.terminated")

    assert_predicate instance, :terminal?
    assert_raises(Mt5Instance::InvalidTransition) { instance.transition_to!("starting", action: "x") }
  end

  test "an audit record cannot be rewritten after the fact" do
    instance = build_instance(state: "stopped")
    instance.transition_to!("starting", action: "instance.starting")

    assert_raises(ActiveRecord::ReadOnlyRecord) { instance.events.last.update!(reason: "something else") }
  end

  # --------------------------------------------------------------- Liveness

  test "running is not the same as healthy" do
    # A row saying running with no recent report is exactly the state that must
    # never be shown to a user as connected.
    instance = build_instance(state: "running", last_heartbeat_at: 5.minutes.ago)

    assert_predicate instance, :running?
    assert_not instance.healthy?
  end

  test "a fresh heartbeat makes a running instance healthy" do
    instance = build_instance(state: "running")
    instance.record_heartbeat!

    assert_predicate instance.reload, :healthy?
  end

  test "an instance that never reported is not healthy" do
    assert_not build_instance(state: "running", last_heartbeat_at: nil).healthy?
  end

  test "a process is only expected in states where one should exist" do
    %w[starting connecting running stopping].each do |state|
      assert build_instance(state:).process_expected?, "#{state} should expect a process"
      Mt5Instance.delete_all
    end

    %w[provisioning stopped failed terminated].each do |state|
      assert_not build_instance(state:).process_expected?, "#{state} should not expect a process"
      Mt5Instance.delete_all
    end
  end

  # --------------------------------------------------------------- Timeouts

  test "a start that outlives the boot budget is stuck, not slow" do
    instance = build_instance(state: "starting", last_transition_at: Time.current)
    assert_not instance.start_timed_out?

    instance.update!(last_transition_at: (Mt5Instance::START_TIMEOUT + 1.second).ago)
    assert_predicate instance, :start_timed_out?
  end

  test "timeouts apply only in the state they describe" do
    # Otherwise a long-running healthy terminal would be torn down by the
    # start timeout, because its last transition is hours old by design.
    instance = build_instance(state: "running", last_transition_at: 1.day.ago)

    assert_not instance.start_timed_out?
    assert_not instance.connect_timed_out?
    assert_not instance.stop_timed_out?
  end

  # ------------------------------------------------------- Failure handling

  test "a failure is recorded with a reason and a time to try again" do
    instance = build_instance(state: "running")

    instance.record_failure!(code: "process_gone", message: "The terminal process is no longer running.")

    assert_predicate instance, :failed?
    assert_equal 1, instance.consecutive_failures
    assert_equal "process_gone", instance.last_error_code
    assert_not_nil instance.next_restart_at
  end

  test "restarts back off as failures repeat" do
    instance = build_instance(state: "running")
    delays = []

    Mt5Instance::RESTART_BACKOFF.length.times do
      instance.record_failure!(code: "process_gone", message: "gone")
      delays << (instance.next_restart_at - Time.current).round
      instance.update!(state: "starting", last_transition_at: Time.current) if instance.may_transition_to?("starting")
      instance.update!(state: "running") if instance.starting?
    end

    assert_equal delays.sort, delays, "each failure must wait at least as long as the one before"
    assert_operator delays.last, :>, delays.first
  end

  test "a crash loop stops being retried rather than burning the node" do
    instance = build_instance(state: "running")
    instance.update!(consecutive_failures: Mt5Instance::MAX_CONSECUTIVE_FAILURES)

    assert_predicate instance, :crash_looping?
    assert_not instance.restart_allowed_now?, "a crash-looping instance must not restart on its own"
  end

  test "recovering clears the failure record so the next problem starts from zero" do
    instance = build_instance(state: "running")
    instance.record_failure!(code: "process_gone", message: "gone")

    instance.clear_failures!

    assert_equal 0, instance.consecutive_failures
    assert_nil instance.next_restart_at
    assert_nil instance.last_error_code
  end

  # ---------------------------------------------------------------- Logging

  test "the log representation carries context but no credentials" do
    instance = build_instance(state: "running")
    log = instance.to_log.to_json

    assert_match instance.uuid, log
    assert_match "running", log
    %w[token password secret api_token].each do |forbidden|
      assert_no_match(/#{forbidden}/i, log, "#{forbidden} must never reach a log line")
    end
  end
end
