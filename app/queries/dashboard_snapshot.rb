# Everything the dashboard shows, gathered in one place.
#
# Used by both the controller and the live broadcast. A broadcast runs without a
# controller, so the two would otherwise assemble the same figures separately
# and could drift apart — which on a trading dashboard means the page you are
# watching stops matching the page you would get by refreshing.
class DashboardSnapshot
  STALE_AFTER = TerminalConnection::STALE_AFTER

  attr_reader :user

  def initialize(user)
    @user = user
  end

  def strategies = @strategies ||= user.strategies.ordered

  def running = @running ||= strategies.find(&:running?)

  def connection
    @connection ||= user.terminal_connections.order(last_report_at: :desc).first
  end

  # Live state, not the history table — see AccountState.
  def account = @account ||= user.account_state

  def positions
    @positions ||= running ? running.positions.open.recent_first.to_a : []
  end

  def basket_profit = @basket_profit ||= positions.sum(&:net_profit)

  def total_volume = @total_volume ||= positions.sum(&:volume)

  # Rendered into the page so the browser can go stale on its own. Without it a
  # live dashboard that stops receiving updates would keep showing "connected"
  # indefinitely — the most dangerous possible failure of a real-time view.
  def last_report_iso = connection&.last_report_at&.utc&.iso8601
end
