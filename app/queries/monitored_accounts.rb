# Everything the alert monitor needs, loaded in a fixed number of queries.
#
# The monitor previously walked users one at a time, costing about fourteen
# queries each. At a thousand running strategies that is fourteen thousand
# queries a minute, and the job takes longer than the interval it runs on — so
# runs overlap and the queue backs up. Loading the whole working set up front
# keeps the cost flat as the number of accounts grows.
class MonitoredAccounts
  include Enumerable

  DRAWDOWN_WINDOW = 30.days

  # One account under supervision: a running strategy and the state around it.
  Account = Struct.new(:user, :strategy, :connection, :state, :peak_equity, :open_alerts,
                       keyword_init: true) do
    def open_alert?(dedup_key) = open_alerts.include?(dedup_key)
  end

  def initialize(now: Time.current)
    @now = now
  end

  def each(&block) = accounts.each(&block)

  def size = accounts.size

  private

  attr_reader :now

  def accounts
    @accounts ||= begin
      strategies = Strategy.where(status: "running").includes(:user).to_a
      return [] if strategies.empty?

      user_ids = strategies.map(&:user_id).uniq

      connections = newest_connection_per_user(user_ids)
      states = AccountState.where(user_id: user_ids).index_by(&:user_id)
      peaks = peak_equity_per_user(user_ids)
      alerts = open_alerts_per_user(user_ids)

      strategies.map do |strategy|
        Account.new(
          user: strategy.user,
          strategy: strategy,
          connection: connections[strategy.user_id],
          state: states[strategy.user_id],
          peak_equity: peaks[strategy.user_id],
          open_alerts: alerts.fetch(strategy.user_id, [])
        )
      end
    end
  end

  # DISTINCT ON keeps this to one row per user rather than loading every
  # connection and discarding most of them in Ruby.
  def newest_connection_per_user(user_ids)
    TerminalConnection
      .where(user_id: user_ids)
      .from(
        TerminalConnection
          .select("DISTINCT ON (user_id) *")
          .where(user_id: user_ids)
          .order(:user_id, last_report_at: :desc),
        :terminal_connections
      )
      .index_by(&:user_id)
  end

  def peak_equity_per_user(user_ids)
    AccountSnapshot
      .where(user_id: user_ids)
      .where(recorded_at: (now - DRAWDOWN_WINDOW)..)
      .group(:user_id)
      .maximum(:equity)
  end

  # Preloaded so the monitor can tell "already reported" from "new" without a
  # query per account per minute.
  def open_alerts_per_user(user_ids)
    Notification
      .unresolved
      .where(user_id: user_ids)
      .pluck(:user_id, :dedup_key)
      .group_by(&:first)
      .transform_values { |pairs| pairs.map(&:last) }
  end
end
