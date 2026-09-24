module Api
  module V1
    module Trading
      class PositionsController < BaseController
        def index
          positions = scope.open.recent_first

          render json: {
            positions: PositionSerializer.collection(positions),
            basket: basket_summary(positions)
          }
        end

        private

        def scope
          ::Position.where(strategy: current_user.strategies)
        end

        # Basket totals are computed here rather than trusted from the terminal,
        # so the figure shown always matches the positions listed beside it.
        def basket_summary(positions)
          {
            open_positions: positions.size,
            total_volume: format("%.2f", positions.sum(&:volume)),
            profit: format("%.2f", positions.sum(&:net_profit))
          }
        end
      end
    end
  end
end
