# Phase 7 of grid-strategy-plan.md.
#
# terminal_connections.cycle_number, resting_orders, filled_orders,
#   basket_profit, pause_seconds_left: what a grid EA reports its cycle is
#   doing, beside the execution state it already reports. Null for the other
#   categories and for EAs that predate the ladder.
class AddGridCycleToTerminalConnections < ActiveRecord::Migration[8.0]
  def change
    add_column :terminal_connections, :cycle_number, :integer
    add_column :terminal_connections, :resting_orders, :integer
    add_column :terminal_connections, :filled_orders, :integer
    add_column :terminal_connections, :basket_profit, :decimal, precision: 15, scale: 2
    add_column :terminal_connections, :pause_seconds_left, :integer
  end
end
