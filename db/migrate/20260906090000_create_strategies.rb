class CreateStrategies < ActiveRecord::Migration[8.0]
  def change
    create_table :strategies do |t|
      t.references :user, null: false, foreign_key: true
      t.string :name, null: false

      # Only XAUUSD is supported, but the column exists so adding instruments
      # later is a data change rather than a schema migration.
      t.string :symbol, null: false, default: "XAUUSD"

      # draft / running / stopped
      t.string :status, null: false, default: "draft"

      # ---------------------------------------------------------- Grid setup
      t.string  :direction, null: false, default: "both"   # both / buy / sell
      t.integer :grid_spacing_points, null: false
      t.integer :grid_levels, null: false

      # Lot sizes are money-adjacent quantities: decimal, never float, so a
      # 0.01 lot step cannot drift through binary rounding.
      t.decimal :initial_lot, precision: 10, scale: 2, null: false
      t.string  :lot_mode, null: false, default: "fixed"   # fixed / multiplier
      t.decimal :lot_multiplier, precision: 6, scale: 2

      # ------------------------------------------------- Basket exit targets
      t.decimal :basket_take_profit, precision: 15, scale: 2
      t.decimal :basket_stop_loss, precision: 15, scale: 2

      # ------------------------------------------------------ Risk controls
      t.integer :max_positions, null: false
      t.decimal :max_exposure_lots, precision: 10, scale: 2, null: false
      t.decimal :max_drawdown_percent, precision: 5, scale: 2
      t.decimal :min_margin_level_percent, precision: 8, scale: 2
      t.integer :max_spread_points

      t.datetime :started_at
      t.datetime :stopped_at

      t.timestamps
    end

    add_index :strategies, %i[user_id status]

    # A user may only have one running strategy per symbol. Enforced in the
    # database, not just the model: two concurrent start requests would both
    # pass a Ruby-level check and leave two bots trading the same account.
    add_index :strategies, %i[user_id symbol],
              unique: true,
              where: "status = 'running'",
              name: "index_strategies_one_running_per_symbol"
  end
end
