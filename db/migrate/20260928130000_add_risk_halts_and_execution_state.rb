# Phase 6 of the trailing-strategy refactor.
#
# strategies.max_daily_loss: realised + floating loss, in account currency, at
#   which the EA closes this strategy's positions and opens nothing more until
#   the broker's next trading day. Null means no daily limit.
# strategies.emergency_stopped_at: set by the emergency stop. While present the
#   EA closes every position and pending order of this strategy and opens
#   nothing; starting the strategy again clears it.
#
# terminal_connections.execution_*: what the EA reports it is doing, so the
#   dashboard can show the state machine instead of inferring it.
class AddRiskHaltsAndExecutionState < ActiveRecord::Migration[8.0]
  def change
    add_column :strategies, :max_daily_loss, :decimal, precision: 15, scale: 2
    add_column :strategies, :emergency_stopped_at, :datetime

    add_column :terminal_connections, :execution_state, :string
    add_column :terminal_connections, :execution_reason, :string
    add_column :terminal_connections, :reversal_level, :decimal, precision: 15, scale: 5
    add_column :terminal_connections, :daily_profit, :decimal, precision: 15, scale: 2
    add_column :terminal_connections, :risk_halt, :string
  end
end
