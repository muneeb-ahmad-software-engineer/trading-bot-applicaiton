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
      end.tap { broadcast_dashboard }
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

      # A position that was open and is no longer reported has been closed at the
      # broker. It is marked closed rather than deleted, so trading history
      # survives and the record of what happened is not silently discarded.
      strategy.positions.open.where.not(ticket: seen).find_each do |position|
        position.update!(closed_at: Time.current, close_price: position.current_price)
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

      strategy.orders.pending.where.not(ticket: seen).update_all(status: "cancelled", updated_at: Time.current)
    end

    # Pushes the refreshed dashboard to any browser this account has open.
    #
    # Enqueued rather than rendered inline: a push to the browser must not add
    # latency to the terminal's report, and a failure to reach a browser must
    # never fail the ingestion of trading data.
    def broadcast_dashboard
      Turbo::StreamsChannel.broadcast_replace_later_to(
        [ user, :dashboard ],
        target: "dashboard-live",
        partial: "dashboard/live",
        locals: { user: user }
      )
    rescue StandardError => e
      Rails.logger.warn("Dashboard broadcast failed for user #{user.id}: #{e.class} #{e.message}")
    end

    def failure(errors) = Result.new(success?: false, connection: nil, errors:)
  end
end
