# The grid becomes a ladder of resting stop orders.
#
# The old grid averaged into a move: one market order per level as price moved
# against the basket, with a level count and an optional lot multiplier. The
# new grid rests `grid_buy_orders` Buy Stops above the market and
# `grid_sell_orders` Sell Stops below it, one `grid_spacing_points` apart,
# closes everything that filled when the combined profit reaches
# basket_take_profit, and places the ladder again `grid_cycle_pause_seconds`
# later. Every order carries the same lot, so lot_mode and lot_multiplier go.
# See grid-strategy-plan.md.
class RebuildTheGridAsALadder < ActiveRecord::Migration[8.0]
  def up
    add_column :strategies, :grid_buy_orders, :integer
    add_column :strategies, :grid_sell_orders, :integer
    add_column :strategies, :grid_cycle_pause_seconds, :integer, default: 10, null: false

    # An existing grid keeps its size: the old level count becomes the count on
    # each side, cut so that the ladder (both sides together) fits the grid's
    # own maximum-positions ceiling — the model and the EA refuse a ladder
    # larger than that. Nothing is left in a state the check constraint below
    # refuses. A grid without a basket take profit still needs one before it
    # can run again: the new grid has no other exit, and inventing one here
    # would be inventing a trading decision.
    execute <<~SQL
      UPDATE strategies
         SET grid_buy_orders  = LEAST(grid_levels, GREATEST(max_positions / 2, 1)),
             grid_sell_orders = LEAST(grid_levels, GREATEST(max_positions / 2, 1))
       WHERE category = 'grid'
    SQL

    remove_check_constraint :strategies, name: "grid_strategies_have_a_grid"
    add_check_constraint :strategies,
      "category <> 'grid' OR (grid_spacing_points IS NOT NULL AND grid_buy_orders IS NOT NULL AND grid_sell_orders IS NOT NULL)",
      name: "grid_strategies_have_a_grid"

    remove_column :strategies, :grid_levels
    remove_column :strategies, :lot_mode
    remove_column :strategies, :lot_multiplier
  end

  def down
    add_column :strategies, :grid_levels, :integer
    add_column :strategies, :lot_mode, :string, default: "fixed", null: false
    add_column :strategies, :lot_multiplier, :decimal, precision: 6, scale: 2

    execute <<~SQL
      UPDATE strategies
         SET grid_levels = GREATEST(grid_buy_orders, grid_sell_orders)
       WHERE category = 'grid'
    SQL

    remove_check_constraint :strategies, name: "grid_strategies_have_a_grid"
    add_check_constraint :strategies,
      "category <> 'grid' OR (grid_spacing_points IS NOT NULL AND grid_levels IS NOT NULL)",
      name: "grid_strategies_have_a_grid"

    remove_column :strategies, :grid_cycle_pause_seconds
    remove_column :strategies, :grid_sell_orders
    remove_column :strategies, :grid_buy_orders
  end
end
