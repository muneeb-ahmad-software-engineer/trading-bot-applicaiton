# The strategy payload. Read by the MT5 Expert Advisor
# (ParseStrategy in mt5/Include/GoldGrid/Strategy.mqh) and by mobile clients.
#
# Renaming or removing a key here stops an EA trading. test/integration/
# ea_contract_test.rb pins every key the EA depends on.
class StrategySerializer < ApplicationSerializer
  def as_json(*)
    {
      id: object.id,
      name: object.name,
      symbol: object.symbol,
      status: object.status,
      category: object.category,
      direction: object.direction,
      grid: grid,
      trailing: trailing,
      entry: entry,
      basket: basket,
      risk: risk,
      started_at: timestamp(object.started_at),
      stopped_at: timestamp(object.stopped_at),
      updated_at: timestamp(object.updated_at),
      # Changes whenever the row does, at microsecond precision (updated_at
      # above is whole seconds). The report response carries the same value;
      # see Api::V1::Trading::ReportsController.
      config_version: object.config_version
    }
  end

  private

  def grid
    {
      spacing_points: object.grid_spacing_points,
      levels: object.grid_levels,
      initial_lot: lots(object.initial_lot),
      lot_mode: object.lot_mode,
      lot_multiplier: decimal(object.lot_multiplier, 2)
    }
  end

  # Null distance means the EA trails nothing. It is sent for every strategy,
  # including grids, because a grid may opt into the exit as well.
  def trailing
    {
      stop_points: object.trailing_stop_points,
      activation_points: object.trailing_activation_points,
      step_points: object.trailing_step_points
    }
  end

  # The flat bracket of a reversal strategy. The effective value is sent — the
  # trailing distance when the user left it blank — so the EA never has to
  # guess a default. Null for every other category, which places no bracket.
  def entry
    { distance_points: object.effective_entry_distance_points }
  end

  def basket
    {
      take_profit: money(object.basket_take_profit),
      stop_loss: money(object.basket_stop_loss)
    }
  end

  def risk
    {
      max_positions: object.max_positions,
      max_exposure_lots: lots(object.max_exposure_lots),
      max_drawdown_percent: percent(object.max_drawdown_percent),
      min_margin_level_percent: percent(object.min_margin_level_percent),
      max_spread_points: object.max_spread_points,
      max_daily_loss: money(object.max_daily_loss),
      # While true the EA closes every position and pending order of this
      # strategy and opens nothing. Cleared only by starting the strategy.
      emergency_stop: object.emergency_stopped?,
      maximum_theoretical_lots: lots(object.maximum_theoretical_lots)
    }
  end
end
