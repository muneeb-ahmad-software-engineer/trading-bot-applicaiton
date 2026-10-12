require "test_helper"
require "rake"

# The deploy gate decides whether a deploy may interrupt terminals. Open
# positions must never block it (doc §11.1), but an unsettled terminal must.
class Mt5DeployGateTest < ActiveSupport::TestCase
  PASSWORD = "a-long-test-password".freeze

  VALID = {
    name: "XAUUSD grid", direction: "both",
    grid_spacing_points: 150, grid_buy_orders: 5, grid_sell_orders: 5, basket_take_profit: 2,
    initial_lot: 0.01,
    max_positions: 10, max_exposure_lots: 0.5
  }.freeze

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("mt5:deploy_gate")
    Rake::Task["mt5:deploy_gate"].reenable
    @user = users(:verified)
  end

  def instance_in(state)
    node = WorkerNode.create!(name: "gate-test-node", hostname: "gate-test", max_instances: 4, status: "online")
    Mt5Instance.create!(user: @user, worker_node: node, uuid: SecureRandom.uuid,
                        instance_dir: "/tmp/gate-test", magic_number: rand(1..2**31), state:)
  end

  def run_gate
    capture_io { Rake::Task["mt5:deploy_gate"].invoke }
  end

  test "passes when there are no terminals" do
    out, = run_gate
    assert_match "deploy gate: ok (0 terminal(s) not terminated)", out
  end

  test "passes while a terminal is running, even with trades open" do
    instance_in("running")
    out, = run_gate
    assert_match "deploy gate: ok (1 terminal(s) not terminated)", out
  end

  test "passes when the only terminal is terminated" do
    instance_in("terminated")
    out, = run_gate
    assert_match "deploy gate: ok (0 terminal(s) not terminated)", out
  end

  %w[starting connecting stopping failed].each do |state|
    test "blocks the deploy while a terminal is #{state}" do
      instance = instance_in(state)
      error = nil
      out, err = capture_io do
        error = assert_raises(SystemExit) { Rake::Task["mt5:deploy_gate"].invoke }
      end
      assert_equal 1, error.status
      assert_match "BLOCKED #{instance.uuid} #{state}", out
      assert_match "deploy gate: 1 terminal(s) in an unsettled state", err
    end
  end
end
