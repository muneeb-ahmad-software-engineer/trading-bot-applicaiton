class OrderSerializer < ApplicationSerializer
  def as_json(*)
    {
      ticket: object.ticket,
      strategy_id: object.strategy_id,
      order_type: object.order_type,
      grid_level: object.grid_level,
      volume: lots(object.volume),
      price: price(object.price),
      status: object.status,
      placed_at: timestamp(object.placed_at)
    }
  end
end
