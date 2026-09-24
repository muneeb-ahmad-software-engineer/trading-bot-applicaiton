# The live stop level a position is carrying.
#
# Without it the platform cannot show where a trailing stop has ratcheted to,
# which is the one number a user watching a trailing strategy actually wants.
# Reported by the EA on every cycle, like every other position field.
class AddStopLossToPositions < ActiveRecord::Migration[8.0]
  def change
    add_column :positions, :stop_loss, :decimal, precision: 15, scale: 5
  end
end
