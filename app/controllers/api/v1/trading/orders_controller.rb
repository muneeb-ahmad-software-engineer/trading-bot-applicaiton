module Api
  module V1
    module Trading
      class OrdersController < BaseController
        def index
          orders = ::Order.where(strategy: current_user.strategies).pending.order(:price)

          render json: { orders: OrderSerializer.collection(orders) }
        end
      end
    end
  end
end
