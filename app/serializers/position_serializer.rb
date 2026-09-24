class PositionSerializer < ApplicationSerializer
  def as_json(*)
    {
      ticket: object.ticket,
      strategy_id: object.strategy_id,
      direction: object.direction,
      grid_level: object.grid_level,
      volume: lots(object.volume),
      open_price: price(object.open_price),
      current_price: price(object.current_price),
      stop_loss: price(object.stop_loss),
      close_price: price(object.close_price),
      profit: money(object.profit),
      swap: money(object.swap),
      commission: money(object.commission),
      net_profit: money(object.net_profit),
      opened_at: timestamp(object.opened_at),
      closed_at: timestamp(object.closed_at)
    }
  end
end
