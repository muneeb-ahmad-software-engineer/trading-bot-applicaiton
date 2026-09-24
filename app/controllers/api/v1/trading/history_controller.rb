module Api
  module V1
    module Trading
      # Closed positions, newest first.
      class HistoryController < BaseController
        MAX_PAGE_SIZE = 200

        def index
          positions = ::Position.where(strategy: current_user.strategies)
                                .closed
                                .order(closed_at: :desc)
                                .limit(page_size)

          render json: {
            positions: PositionSerializer.collection(positions),
            realised_profit: format("%.2f", positions.sum(&:net_profit))
          }
        end

        private

        def page_size
          [ params.fetch(:limit, 50).to_i, MAX_PAGE_SIZE ].min.clamp(1, MAX_PAGE_SIZE)
        end
      end
    end
  end
end
