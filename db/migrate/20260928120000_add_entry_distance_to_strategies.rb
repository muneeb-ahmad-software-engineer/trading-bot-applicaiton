# Reversal strategy: how far from the market the initial Buy Stop / Sell Stop
# bracket is placed while flat.
#
# Nullable on purpose: blank means "the same as the trailing distance", which
# is what the EA used before this column existed, so every existing strategy
# keeps behaving exactly as it did.
class AddEntryDistanceToStrategies < ActiveRecord::Migration[8.0]
  def change
    add_column :strategies, :entry_distance_points, :integer
  end
end
