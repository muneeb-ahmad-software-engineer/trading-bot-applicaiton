# Trailing stop: a second strategy category, and an exit that grid strategies
# can also use.
#
# The distance is stored in points, like every other price distance on this
# table (grid_spacing_points, max_spread_points). On XAUUSD a point is 0.01, so
# a $2 loss margin is 200 points.
class AddTrailingStopToStrategies < ActiveRecord::Migration[8.0]
  def up
    add_column :strategies, :category, :string, default: "grid", null: false
    add_column :strategies, :trailing_stop_points, :integer
    add_column :strategies, :trailing_activation_points, :integer
    add_column :strategies, :trailing_step_points, :integer

    # A trailing strategy has no grid, so these stop being universally
    # required. The invariant they carried is not dropped, only narrowed to the
    # category it belongs to — see the check constraint below.
    change_column_null :strategies, :grid_spacing_points, true
    change_column_null :strategies, :grid_levels, true

    add_check_constraint :strategies,
      "category <> 'grid' OR (grid_spacing_points IS NOT NULL AND grid_levels IS NOT NULL)",
      name: "grid_strategies_have_a_grid"

    add_check_constraint :strategies,
      "category <> 'trailing' OR trailing_stop_points IS NOT NULL",
      name: "trailing_strategies_have_a_distance"

    add_index :strategies, [ :user_id, :category ]
  end

  def down
    remove_index :strategies, [ :user_id, :category ]
    remove_check_constraint :strategies, name: "trailing_strategies_have_a_distance"
    remove_check_constraint :strategies, name: "grid_strategies_have_a_grid"

    # Restoring NOT NULL would fail against any trailing strategy that exists,
    # so those rows go first. Rolling this migration back means the trailing
    # category no longer exists; keeping the rows would leave a strategy the
    # application cannot represent.
    execute "DELETE FROM strategies WHERE category = 'trailing'"
    change_column_null :strategies, :grid_levels, false
    change_column_null :strategies, :grid_spacing_points, false

    remove_column :strategies, :trailing_step_points
    remove_column :strategies, :trailing_activation_points
    remove_column :strategies, :trailing_stop_points
    remove_column :strategies, :category
  end
end
