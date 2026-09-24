class SeparateAccountStateFromHistory < ActiveRecord::Migration[8.0]
  # Current account figures, one row per user, updated in place.
  #
  # Previously every terminal report inserted an account_snapshots row. At the
  # documented ten-second reporting interval that is 8,640 rows per user per
  # day — roughly 3.2 billion rows and 400 GB a year at a thousand users — and
  # nothing read any of it except the most recent row.
  #
  # Live state now lives here and is upserted, so it does not grow. History
  # stays in account_snapshots, written at a much lower frequency and pruned.
  def change
    create_table :account_states do |t|
      t.references :user, null: false, foreign_key: true, index: { unique: true }
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

    # Retention and downsampling both query by age, and the drawdown check asks
    # for a maximum equity within a window.
    add_index :account_snapshots, :recorded_at
    add_index :events, :occurred_at
    add_index :notifications, :created_at
  end
end
