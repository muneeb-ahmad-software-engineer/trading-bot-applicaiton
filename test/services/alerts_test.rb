require "test_helper"

# Alerting. The behaviour that decides whether this is useful or just noise is
# suppression: an ongoing situation must be reported once, not once per check.
class AlertsTest < ActiveSupport::TestCase
  VALID = {
    name: "XAUUSD grid", direction: "both",
    grid_spacing_points: 150, grid_levels: 5,
    initial_lot: 0.01, lot_mode: "fixed",
    max_positions: 10, max_exposure_lots: 0.5
  }.freeze

  setup do
    @user = users(:verified)
    @strategy = @user.strategies.create!(VALID)
    @strategy.start!
    @token = ApiToken.issue(user: @user, name: "MT5")
  end

  def connect(last_report_at: Time.current)
    TerminalConnection.create!(
      user: @user, api_token: @token, strategy: @strategy,
      symbol: "XAUUSD", last_report_at:
    )
  end

  # Mirrors Trading::IngestReport: live figures go to AccountState, history to
  # AccountSnapshot. The monitor reads current state from the former and the
  # drawdown peak from the latter.
  def report_account(equity:, margin_level: nil, recorded_at: Time.current)
    attributes = { strategy_id: @strategy.id, currency: "USD", balance: 10_000,
                   equity:, margin_level_percent: margin_level, recorded_at: }

    AccountState.record(user: @user, attributes:)
    AccountSnapshot.create!(attributes.merge(user: @user))
  end

  # History only, for seeding an earlier equity peak.
  def history(equity:, recorded_at:)
    AccountSnapshot.create!(user: @user, strategy: @strategy, currency: "USD",
                            balance: 10_000, equity:, recorded_at:)
  end

  # ------------------------------------------------------ Stale terminal

  test "a running strategy with a silent terminal raises a critical alert" do
    connect(last_report_at: 10.minutes.ago)

    assert_difference "Notification.count", 1 do
      Alerts::MonitorTerminals.call
    end

    notification = @user.notifications.last
    assert_equal "terminal_stale", notification.alert_type
    assert_equal "critical", notification.severity
    assert_match(/stopped reporting/i, notification.body)
  end

  test "an ongoing situation is reported once, not once per check" do
    connect(last_report_at: 10.minutes.ago)

    assert_difference "Notification.count", 1 do
      5.times { Alerts::MonitorTerminals.call }
    end
  end

  test "a live terminal raises nothing" do
    connect(last_report_at: 5.seconds.ago)

    assert_no_difference "Notification.count" do
      Alerts::MonitorTerminals.call
    end
  end

  test "a terminal that never reported is not an incident" do
    TerminalConnection.create!(user: @user, api_token: @token, strategy: @strategy,
                              symbol: "XAUUSD", last_report_at: nil)

    # Not yet connected is a setup step, not a failure worth waking someone for.
    assert_no_difference "Notification.count" do
      Alerts::MonitorTerminals.call
    end
  end

  test "a stopped strategy with a silent terminal raises nothing" do
    @strategy.stop!
    connect(last_report_at: 1.hour.ago)

    assert_no_difference "Notification.count" do
      Alerts::MonitorTerminals.call
    end
  end

  test "recovery resolves the alert and reports once" do
    connection = connect(last_report_at: 10.minutes.ago)
    Alerts::MonitorTerminals.call
    stale = @user.notifications.find_by(alert_type: "terminal_stale")

    connection.update!(last_report_at: Time.current)
    Alerts::MonitorTerminals.call

    assert_not_nil stale.reload.resolved_at
    assert_equal 1, @user.notifications.where(alert_type: "terminal_recovered").count
  end

  test "a situation that recurs after resolution alerts again" do
    connection = connect(last_report_at: 10.minutes.ago)
    Alerts::MonitorTerminals.call
    connection.update!(last_report_at: Time.current)
    Alerts::MonitorTerminals.call

    connection.update!(last_report_at: 10.minutes.ago)

    assert_difference -> { @user.notifications.where(alert_type: "terminal_stale").count }, 1 do
      Alerts::MonitorTerminals.call
    end
  end

  # ------------------------------------------------------- Account health

  test "margin below the configured minimum alerts" do
    @strategy.update!(min_margin_level_percent: 200)
    connect
    report_account(equity: 9_000, margin_level: 150)

    Alerts::MonitorTerminals.call

    assert @user.notifications.exists?(alert_type: "margin_low")
  end

  test "a margin level of zero means no positions, not danger" do
    @strategy.update!(min_margin_level_percent: 200)
    connect
    report_account(equity: 10_000, margin_level: 0)

    assert_no_difference "Notification.count" do
      Alerts::MonitorTerminals.call
    end
  end

  test "margin recovering resolves the alert" do
    @strategy.update!(min_margin_level_percent: 200)
    connect
    report_account(equity: 9_000, margin_level: 150)
    Alerts::MonitorTerminals.call

    report_account(equity: 9_900, margin_level: 900, recorded_at: Time.current)
    Alerts::MonitorTerminals.call

    assert_not_nil @user.notifications.find_by(alert_type: "margin_low").resolved_at
  end

  test "drawdown beyond the configured limit alerts" do
    @strategy.update!(max_drawdown_percent: 20)
    connect
    history(equity: 10_000, recorded_at: 2.hours.ago)
    report_account(equity: 7_000)

    Alerts::MonitorTerminals.call

    notification = @user.notifications.find_by(alert_type: "drawdown_threshold")
    assert_not_nil notification
    assert_match(/30\.0%/, notification.body)
  end

  test "stale account data is not used to raise health alerts" do
    @strategy.update!(min_margin_level_percent: 200)
    connect
    # Old snapshot: acting on it would alert about a state that may be long gone.
    report_account(equity: 9_000, margin_level: 150, recorded_at: 2.hours.ago)

    assert_no_difference "Notification.count" do
      Alerts::MonitorTerminals.call
    end
  end

  test "one user's situation never alerts another" do
    connect(last_report_at: 10.minutes.ago)
    Alerts::MonitorTerminals.call

    assert_equal 0, users(:unverified).notifications.count
  end
end
