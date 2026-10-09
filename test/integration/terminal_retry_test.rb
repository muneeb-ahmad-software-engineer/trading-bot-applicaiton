require "test_helper"

# A managed terminal that will not connect. The user has to be able to see why,
# and to try again once they have fixed it — the reconciler stops retrying on
# its own after repeated failures, and nothing else would ever lift that.
class TerminalRetryTest < ActionDispatch::IntegrationTest
  PASSWORD = "a-long-test-password".freeze

  VALID = {
    name: "XAUUSD grid", direction: "both",
    grid_spacing_points: 150, grid_buy_orders: 5, grid_sell_orders: 5, basket_take_profit: 2,
    initial_lot: 0.01,
    max_positions: 10, max_exposure_lots: 0.5
  }.freeze

  setup do
    @user = users(:verified)
    post login_path, params: { email_address: @user.email_address, password: PASSWORD }
  end

  def started_strategy
    strategy = @user.strategies.create!(VALID)
    result = Strategies::Start.call(strategy:, actor: @user)
    raise "start failed: #{result.error_message}" if result.failure?

    strategy
  end

  def crash_loop!(instance)
    instance.update_columns(state: "failed", consecutive_failures: Mt5Instance::MAX_CONSECUTIVE_FAILURES,
                            last_error_code: "process_gone",
                            last_error_message: "The terminal process is no longer running.",
                            pid: nil)
  end

  test "a crash-looping terminal says so, says why, and offers a retry" do
    with_mt5_sandbox do
      worker_node
      broker_credential_for(@user)
      strategy = started_strategy
      crash_loop!(@user.mt5_instances.sole)

      get strategy_path(strategy)

      assert_response :success
      assert_match "Your terminal keeps failing", response.body
      assert_match "The terminal process is no longer running.", response.body
      assert_match(/automatic restarts are paused/, response.body)
      assert_select "form[action=?] button", restart_terminal_path, text: "Retry connection"
    end
  end

  test "a running strategy whose terminal is down is not shown as plainly running" do
    with_mt5_sandbox do
      worker_node
      broker_credential_for(@user)
      strategy = started_strategy
      crash_loop!(@user.mt5_instances.sole)

      get strategy_path(strategy)
      assert_match "Running · terminal offline", response.body
      assert_match(/Waiting for the terminal/, response.body)

      get strategies_path
      assert_match "Running · terminal offline", response.body
    end
  end

  test "retrying lifts the crash-loop cap and starts the terminal again" do
    with_mt5_sandbox do
      worker_node
      broker_credential_for(@user)
      strategy = started_strategy
      instance = @user.mt5_instances.sole
      crash_loop!(instance)

      post restart_terminal_path, headers: { "HTTP_REFERER" => strategy_url(strategy) }

      assert_redirected_to strategy_url(strategy)
      assert_match(/Reconnecting your terminal/, flash[:notice])
      instance.reload
      assert_predicate instance, :connecting?
      assert_equal 0, instance.consecutive_failures
      assert_equal "running", instance.desired_state
      assert Event.exists?(user: @user, action: "terminal.retried")
    end
  end

  test "retrying restarts a terminal that is up but not reporting" do
    with_mt5_sandbox do
      worker_node
      broker_credential_for(@user)
      started_strategy
      instance = @user.mt5_instances.sole

      assert_difference -> { instance.reload.restart_count }, 1 do
        post restart_terminal_path
      end

      assert_predicate instance.reload, :connecting?
    end
  end

  # Retry needs a running strategy, so starting one has to lift the cap itself,
  # or a terminal that crash-looped under a stopped strategy is stuck for good.
  test "starting a strategy lifts a crash-loop cap left over from an earlier one" do
    with_mt5_sandbox do
      worker_node
      broker_credential_for(@user)
      first = started_strategy
      instance = @user.mt5_instances.sole
      Strategies::Stop.call(strategy: first, actor: @user)
      crash_loop!(instance.reload)

      second = @user.strategies.create!(VALID.merge(name: "XAUUSD grid 2"))
      result = Strategies::Start.call(strategy: second, actor: @user)

      assert result.success?, result.error_message
      assert_predicate second.reload, :running?
      instance.reload
      assert_predicate instance, :connecting?
      assert_equal 0, instance.consecutive_failures
    end
  end

  test "there is nothing to retry without a running strategy" do
    with_mt5_sandbox do
      worker_node
      instance = provision!(@user)

      post restart_terminal_path

      assert_match(/Start a strategy/, flash[:alert])
      assert_predicate instance.reload, :stopped?
    end
  end

  # A managed terminal gets a new API token each time it is pointed at a
  # strategy, and each token reports into its own connection row. The page
  # must read the one that is reporting, not whichever the database found
  # first.
  test "a strategy with several connections is judged by the one reporting now" do
    strategy = @user.strategies.create!(VALID)
    strategy.update_columns(status: "running", started_at: 10.minutes.ago)
    [ 3.hours.ago, 5.seconds.ago, nil ].each do |reported_at|
      TerminalConnection.create!(user: @user, strategy:, symbol: "XAUUSD", last_report_at: reported_at,
                                 api_token: ApiToken.issue(user: @user, name: "t #{reported_at}"))
    end

    assert strategy.reload.terminal_connection.live?

    get strategy_path(strategy)
    assert_match "Your terminal is connected", response.body
    assert_no_match(/terminal offline|Waiting for the terminal/, response.body)
  end

  test "a page waiting on a terminal that is signing in refreshes itself" do
    with_mt5_sandbox do
      worker_node
      broker_credential_for(@user)
      strategy = started_strategy

      get strategy_path(strategy)
      assert_select "[data-controller=auto-refresh] .status", text: /Waiting for the terminal/

      crash_loop!(@user.mt5_instances.sole)
      get strategy_path(strategy)
      assert_select "[data-controller=auto-refresh]", 0, "nothing will change without the user"
    end
  end

  test "there is nothing to retry without a managed terminal" do
    post restart_terminal_path

    assert_match(/don't have a managed terminal/, flash[:alert])
  end
end
