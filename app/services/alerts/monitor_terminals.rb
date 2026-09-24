module Alerts
  # Finds situations that warrant an alert, and clears those that have ended.
  #
  # Runs on a schedule rather than in response to a report, because the
  # condition that matters most is the *absence* of reports: nothing arrives to
  # trigger anything when a terminal dies, so it has to be checked from outside.
  #
  # The working set is loaded once by MonitoredAccounts rather than per user, so
  # the cost stays flat as accounts are added.
  class MonitorTerminals < ApplicationService
    # Account data older than this is not acted on: alerting from a stale
    # reading would report a state that may be long gone.
    FRESH_ENOUGH = 10.minutes

    def call
      accounts = MonitoredAccounts.new

      accounts.each do |account|
        check_terminal(account)
        check_account_health(account)
      end

      success(accounts.size)
    end

    private

    # ------------------------------------------------------------- Terminal

    def check_terminal(account)
      connection = account.connection
      key = "terminal_stale:#{account.strategy.id}"

      # Never having reported is a setup step, not an incident.
      return if connection.nil? || connection.last_report_at.nil?

      if connection.live?
        resolve_stale_terminal(account, key)
      elsif !account.open_alert?(key)
        raise_stale_terminal(account, key, connection)
      end
    end

    def raise_stale_terminal(account, key, connection)
      Notifications::Deliver.call(
        user: account.user, alert_type: "terminal_stale", subject: account.strategy,
        dedup_key: key,
        body: "#{account.strategy.name} is running but your MT5 terminal stopped reporting " \
              "#{time_ago(connection.last_report_at)}. Positions may be open with no " \
              "terminal managing them. Check that MetaTrader is running and connected.",
        url: "/dashboard",
        metadata: { strategy_id: account.strategy.id, last_report_at: connection.last_report_at }
      )
    end

    def resolve_stale_terminal(account, key)
      return unless account.open_alert?(key)

      Notifications::Resolve.call(user: account.user, dedup_key: key)

      Notifications::Deliver.call(
        user: account.user, alert_type: "terminal_recovered", subject: account.strategy,
        dedup_key: "terminal_recovered:#{account.strategy.id}:#{account.connection.last_report_at.to_i}",
        body: "#{account.strategy.name}: your MT5 terminal is reporting again.",
        url: "/dashboard",
        metadata: { strategy_id: account.strategy.id }
      )
    end

    # ------------------------------------------------------ Account health

    def check_account_health(account)
      state = account.state
      return if state.nil? || state.recorded_at < FRESH_ENOUGH.ago

      check_margin(account, state)
      check_drawdown(account, state)
    end

    def check_margin(account, state)
      minimum = account.strategy.min_margin_level_percent
      level = state.margin_level_percent
      key = "margin_low:#{account.strategy.id}"

      # Zero margin level means no open positions, not danger.
      return if minimum.blank? || level.blank? || level <= 0

      if level < minimum
        return if account.open_alert?(key)

        Notifications::Deliver.call(
          user: account.user, alert_type: "margin_low", subject: account.strategy, dedup_key: key,
          body: "#{account.strategy.name}: margin level is #{level.to_f.round(2)}%, below your " \
                "configured minimum of #{minimum.to_f.round(2)}%. Your Expert Advisor " \
                "will not open new positions while this holds.",
          url: "/dashboard",
          metadata: { strategy_id: account.strategy.id, margin_level: level.to_s }
        )
      elsif account.open_alert?(key)
        Notifications::Resolve.call(user: account.user, dedup_key: key)
      end
    end

    def check_drawdown(account, state)
      limit = account.strategy.max_drawdown_percent
      key = "drawdown_threshold:#{account.strategy.id}"
      peak = account.peak_equity

      return if limit.blank? || peak.blank? || peak <= 0

      drawdown = ((peak - state.equity) / peak * 100).round(2)

      if drawdown >= limit
        return if account.open_alert?(key)

        Notifications::Deliver.call(
          user: account.user, alert_type: "drawdown_threshold", subject: account.strategy,
          dedup_key: key,
          body: "#{account.strategy.name}: account drawdown is #{drawdown}%, at or beyond your " \
                "configured limit of #{limit.to_f.round(2)}%. Your Expert Advisor will " \
                "not open new positions while this holds.",
          url: "/dashboard",
          metadata: { strategy_id: account.strategy.id, drawdown_percent: drawdown.to_s }
        )
      elsif account.open_alert?(key)
        Notifications::Resolve.call(user: account.user, dedup_key: key)
      end
    end

    def time_ago(time)
      "#{ActionController::Base.helpers.time_ago_in_words(time)} ago"
    end
  end
end
