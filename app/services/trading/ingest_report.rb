module Trading
  # Applies a full state report from an MT5 terminal.
  #
  # The report is a complete snapshot rather than a stream of deltas, which
  # makes ingestion naturally idempotent: a retried or duplicated report
  # produces the same end state, and a terminal that misses several reports
  # recovers on its next one without any reconciliation logic. For a client that
  # runs unattended for weeks over an unreliable connection, that property
  # matters more than the bandwidth a delta protocol would save.
  #
  # Positions are matched on the broker's ticket number, so a ticket seen twice
  # updates one row rather than creating two.
  class IngestReport
    Result = Struct.new(:success?, :connection, :errors, keyword_init: true)

    def initialize(user:, api_token:, params:)
      @user = user
      @api_token = api_token
      @params = params
    end

    def call
      strategy = find_strategy
      return failure([ "Unknown strategy" ]) if strategy_requested? && strategy.nil?

      ActiveRecord::Base.transaction do
        connection = upsert_connection(strategy)
        record_account(strategy)
        sync_positions(strategy) if strategy
        sync_orders(strategy) if strategy

        Result.new(success?: true, connection:, errors: [])
      end.tap { broadcast_dashboard(strategy) }
    rescue ActiveRecord::RecordInvalid => e
      failure(e.record.errors.full_messages)
    end

    private

    attr_reader :user, :api_token, :params

    def strategy_requested? = params[:strategy_id].present?

    def find_strategy
      return nil unless strategy_requested?

      user.strategies.find_by(id: params[:strategy_id])
    end

    def upsert_connection(strategy)
      connection = TerminalConnection.find_or_initialize_by(api_token: api_token)
      terminal = params.fetch(:terminal, {})
      tick = params.fetch(:tick, {})
      # Absent from EAs that predate the state machine (and from grid
      # strategies' reports on those builds). Absent means unknown, so the
      # columns are cleared rather than left showing an old state.
      execution = params.fetch(:execution, {})

      connection.assign_attributes(
        user:,
        strategy:,
        ea_version: terminal[:ea_version],
        broker: terminal[:broker],
        account_login: terminal[:account_login],
        symbol: terminal[:symbol].presence || "XAUUSD",
        bid: tick[:bid],
        ask: tick[:ask],
        spread_points: tick[:spread_points],
        execution_state: execution[:state].presence,
        execution_reason: execution[:reason].to_s.truncate(255).presence,
        reversal_level: positive_decimal(execution[:reversal_level]),
        daily_profit: execution[:daily_profit].presence,
        risk_halt: execution[:risk_halt].to_s.truncate(255).presence,
        # The grid's cycle. Null from the other categories, which have none.
        cycle_number: whole_number(execution[:cycle]),
        resting_orders: whole_number(execution[:resting_orders]),
        filled_orders: whole_number(execution[:filled_orders]),
        basket_profit: execution[:basket_profit].presence,
        pause_seconds_left: whole_number(execution[:pause_seconds_left]),
        last_report_at: Time.current
      )
      first_report = connection.new_record? || connection.last_report_at.nil?
      connection.save!

      if first_report
        Event.record("terminal.connected", user:, subject: connection, source: "api",
                     metadata: { broker: connection.broker, symbol: connection.symbol,
                                 ea_version: connection.ea_version })
      end

      # A report is also proof that this terminal's process is alive and
      # reaching the platform, which is the only thing that moves an execution
      # manager instance to `running`. Deliberately never allowed to affect
      # ingestion: trading data must land whether or not the control plane can
      # record the heartbeat.
      begin
        Mt5::RecordHeartbeat.call(api_token:)
      rescue StandardError => e
        Rails.logger.warn("mt5.heartbeat_failed token=#{api_token&.id} #{e.class}: #{e.message}")
      end

      connection
    end

    # Live figures are upserted on every report; history is sampled.
    #
    # Writing a history row per report was 8,640 inserts per user per day to
    # serve reads that only ever wanted the newest one.
    def record_account(strategy)
      account = params[:account]
      return if account.blank?

      attributes = {
        strategy_id: strategy&.id,
        currency: account[:currency].presence || "USD",
        balance: account[:balance],
        equity: account[:equity],
        margin: account[:margin],
        free_margin: account[:free_margin],
        margin_level_percent: account[:margin_level_percent],
        recorded_at: Time.current
      }

      AccountState.record(user:, attributes:)

      AccountSnapshot.create!(attributes.merge(user:)) if AccountSnapshot.due_for?(user)
    end

    # MT5 reports "no stop attached" as a price of zero. That is a different
    # fact from a stop at price zero, and storing it as a number would put a
    # 0.00000 stop level in front of the user on every position that has none.
    # A price the EA sends as zero when it has none.
    def whole_number(value)
      return nil if value.blank?

      Integer(value.to_s, 10)
    rescue ArgumentError
      nil
    end

    def positive_decimal(value)
      return nil if value.blank?
      return nil if value.to_d <= 0

      value
    end

    def reported_stop_loss(value)
      return nil if value.blank?
      return nil if value.to_d.zero?

      value
    end

    def sync_positions(strategy)
      reported = Array(params[:positions])
      return if params[:positions].nil?

      seen = []

      reported.each do |attrs|
        position = strategy.positions.find_or_initialize_by(ticket: attrs[:ticket].to_s)
        position.assign_attributes(
          direction: attrs[:direction],
          grid_level: attrs[:grid_level],
          volume: attrs[:volume],
          open_price: attrs[:open_price],
          current_price: attrs[:current_price],
          stop_loss: reported_stop_loss(attrs[:stop_loss]),
          profit: attrs[:profit],
          swap: attrs[:swap],
          commission: attrs[:commission],
          opened_at: attrs[:opened_at] || position.opened_at || Time.current
        )
        position.save!
        seen << position.ticket
      end

      apply_closed_positions(strategy)

      # A position that was open and is no longer reported has been closed at the
      # broker. It is marked closed rather than deleted, so trading history
      # survives and the record of what happened is not silently discarded.
      #
      # This is the fallback, not the record. The EA reports recent closes with
      # the broker's own deal price and profit, and those numbers land above;
      # this sweep only catches a close the terminal never got to report — a
      # crash between the deal and the next report — where the last seen price
      # is the best information anyone still has.
      strategy.positions.open.where.not(ticket: seen).find_each do |position|
        position.update!(closed_at: Time.current, close_price: position.current_price)
      end
    end

    # The broker's account of each recently closed position: the deal price it
    # actually executed at, and the realised profit, swap and commission. The
    # floating figures the position carried while open can be seconds stale by
    # the time a stop fires — observed on a trailing stop that executed at
    # 4292.96 while the last report still said 4291.94 — so the deal record
    # overwrites them, even on a position the vanish sweep already closed. The
    # EA re-reports closes for a while, which is what makes this self-healing:
    # a close recorded from stale data is corrected on the next report.
    def apply_closed_positions(strategy)
      Array(params[:closed_positions]).each do |attrs|
        position = strategy.positions.find_by(ticket: attrs[:ticket].to_s)
        next if position.nil?

        position.update!(
          close_price: attrs[:close_price],
          current_price: attrs[:close_price],
          profit: attrs[:profit],
          swap: attrs[:swap],
          commission: attrs[:commission],
          closed_at: attrs[:closed_at].presence || position.closed_at || Time.current
        )
      end
    end

    def sync_orders(strategy)
      reported = Array(params[:orders])
      return if params[:orders].nil?

      seen = []

      reported.each do |attrs|
        order = strategy.orders.find_or_initialize_by(ticket: attrs[:ticket].to_s)
        order.assign_attributes(
          order_type: attrs[:order_type],
          grid_level: attrs[:grid_level],
          volume: attrs[:volume],
          price: attrs[:price],
          status: "pending",
          placed_at: attrs[:placed_at] || order.placed_at || Time.current
        )
        order.save!
        seen << order.ticket
      end

      # An order that stopped being reported either filled or was cancelled.
      # A stop order that fills becomes a position under the SAME ticket (MT5
      # keeps the number), so a vanished order whose ticket is now a position
      # of this strategy filled; anything else was cancelled or deleted.
      vanished = strategy.orders.pending.where.not(ticket: seen)
      filled   = strategy.positions.where(ticket: vanished.pluck(:ticket)).pluck(:ticket)
      strategy.orders.pending.where(ticket: filled).update_all(status: "filled", updated_at: Time.current)
      strategy.orders.pending.where.not(ticket: seen + filled).update_all(status: "cancelled", updated_at: Time.current)
    end

    # Pushes the refreshed dashboard to any browser this account has open.
    #
    # Enqueued rather than rendered inline: a push to the browser must not add
    # latency to the terminal's report, and a failure to reach a browser must
    # never fail the ingestion of trading data.
    def broadcast_dashboard(strategy)
      # The dashboard's live region (a page without the target ignores it).
      broadcasting("dashboard") do
        Turbo::StreamsChannel.broadcast_replace_later_to(
          [ user, :dashboard ], target: "dashboard-live", partial: "dashboard/live", locals: { user: user }
        )
      end
      # The sidebar's connection badge, on every signed-in page: replacing it
      # restarts the browser's staleness count from this report.
      broadcasting("sidebar badge") do
        Turbo::StreamsChannel.broadcast_replace_later_to(
          [ user, :dashboard ], target: "sidebar-connection-status", partial: "shared/connection_badge",
          locals: { user: user }
        )
      end
      # The strategy's own page re-renders in place (a morph refresh), so its
      # terminal panel, robot state, positions and orders follow the reports.
      # Turbo debounces these, so a burst of reports is one refresh.
      return if strategy.nil?

      broadcasting("strategy page") { Turbo::StreamsChannel.broadcast_refresh_later_to(strategy, :live) }
    end

    # Each broadcast on its own: one that fails (a queue or cable hiccup) must
    # neither fail the terminal's report nor stop the others from going out.
    def broadcasting(what)
      yield
    rescue StandardError => e
      Rails.logger.warn("#{what} broadcast failed for user #{user.id}: #{e.class} #{e.message}")
    end

    def failure(errors) = Result.new(success?: false, connection: nil, errors:)
  end
end
