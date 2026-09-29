module Api
  module V1
    module Trading
      # Ingestion endpoint for the MT5 Expert Advisor.
      #
      # The EA posts its complete current state here on a fixed interval. This
      # is the only write endpoint the terminal needs, and it doubles as the
      # heartbeat: receiving a report is what marks the terminal live.
      class ReportsController < BaseController
        def create
          result = ::Trading::IngestReport.new(
            user: current_user,
            api_token: current_api_token,
            params: report_params
          ).call

          if result.success?
            render json: {
              accepted_at: Time.current.utc.iso8601,
              connection: { status: result.connection.status, symbol: result.connection.symbol },
              # The EA compares this with the config_version of the
              # configuration it holds and re-fetches at once when they differ,
              # so a stop or an emergency stop reaches it within one report
              # interval rather than at its next scheduled refresh.
              config_version: result.connection.strategy&.config_version
            }, status: :accepted
          else
            render json: { error: { code: "invalid_report", message: result.errors.to_sentence } },
                   status: :unprocessable_entity
          end
        end

        private

        def report_params
          params.permit(
            :strategy_id,
            terminal: %i[ea_version broker account_login symbol],
            execution: %i[state reason reversal_level daily_profit risk_halt],
            tick: %i[bid ask spread_points],
            account: %i[currency balance equity margin free_margin margin_level_percent],
            positions: %i[ticket direction grid_level volume open_price current_price stop_loss profit swap commission opened_at],
            closed_positions: %i[ticket close_price profit swap commission closed_at],
            orders: %i[ticket order_type grid_level volume price placed_at]
          )
        end
      end
    end
  end
end
