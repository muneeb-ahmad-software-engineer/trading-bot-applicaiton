class CreateTradingTables < ActiveRecord::Migration[8.0]
  def change
    # One row per connected MT5 terminal, identified by the API token it uses.
    # "Is a terminal connected?" is answered by last_report_at, not by a boolean,
    # so a terminal that stops reporting goes stale on its own rather than
    # remaining "connected" forever.
    create_table :terminal_connections do |t|
      t.references :user, null: false, foreign_key: true
      t.references :api_token, null: false, foreign_key: true, index: { unique: true }
      t.references :strategy, foreign_key: true

      t.string :ea_version
      t.string :broker
      t.string :account_login
      t.string :symbol, null: false, default: "XAUUSD"

      # Latest quote reported by the terminal. Decimal, never float.
      t.decimal :bid, precision: 15, scale: 5
      t.decimal :ask, precision: 15, scale: 5
      t.integer :spread_points

      t.datetime :last_report_at

      t.timestamps
    end

    # Append-only account state history.
    create_table :account_snapshots do |t|
      t.references :user, null: false, foreign_key: true
      t.references :strategy, foreign_key: true

      t.string  :currency, null: false, default: "USD"
      t.decimal :balance, precision: 18, scale: 2, null: false
      t.decimal :equity, precision: 18, scale: 2, null: false
      t.decimal :margin, precision: 18, scale: 2
      t.decimal :free_margin, precision: 18, scale: 2
      t.decimal :margin_level_percent, precision: 10, scale: 2

      t.datetime :recorded_at, null: false

      t.timestamps
    end
    add_index :account_snapshots, %i[user_id recorded_at]

    create_table :positions do |t|
      t.references :strategy, null: false, foreign_key: true

      # The broker's ticket number. Unique per strategy so a retried report
      # updates the existing row instead of duplicating it.
      t.string :ticket, null: false

      t.string  :direction, null: false          # buy / sell
      t.integer :grid_level
      t.decimal :volume, precision: 10, scale: 2, null: false
      t.decimal :open_price, precision: 15, scale: 5, null: false
      t.decimal :current_price, precision: 15, scale: 5
      t.decimal :profit, precision: 18, scale: 2
      t.decimal :swap, precision: 18, scale: 2
      t.decimal :commission, precision: 18, scale: 2

      t.datetime :opened_at, null: false
      t.datetime :closed_at
      t.decimal :close_price, precision: 15, scale: 5

      t.timestamps
    end
    add_index :positions, %i[strategy_id ticket], unique: true
    add_index :positions, %i[strategy_id closed_at]

    create_table :orders do |t|
      t.references :strategy, null: false, foreign_key: true

      t.string  :ticket, null: false
      t.string  :order_type, null: false         # buy_limit / sell_limit / buy_stop / sell_stop
      t.integer :grid_level
      t.decimal :volume, precision: 10, scale: 2, null: false
      t.decimal :price, precision: 15, scale: 5, null: false
      t.string  :status, null: false, default: "pending"

      t.datetime :placed_at, null: false

      t.timestamps
    end
    add_index :orders, %i[strategy_id ticket], unique: true
  end
end
