module Api
  module V1
    # Strategy configuration over the API.
    #
    # This is the endpoint the MT5 Expert Advisor polls to learn what it should
    # be doing, and that a mobile client uses to configure and control a bot.
    #
    # Starting a strategy is a trading action, so it requires a verified email
    # address. Stopping one never does: a user must always be able to halt.
    class StrategiesController < BaseController
      before_action :set_strategy, only: %i[show update start stop emergency_stop]

      def index
        render json: { strategies: current_user.strategies.ordered.map { StrategySerializer.new(_1).as_json } }
      end

      def show
        render json: { strategy: StrategySerializer.new(@strategy).as_json }
      end

      def create
        strategy = current_user.strategies.new(strategy_params)

        if strategy.save
          Event.record("strategy.created", user: current_user, subject: strategy,
                       source: "api", ip_address: request.remote_ip,
                       metadata: { name: strategy.name })
          render json: { strategy: StrategySerializer.new(strategy).as_json }, status: :created
        else
          render_validation_errors(strategy)
        end
      end

      def update
        unless @strategy.editable?
          return render_error("strategy_running", "Stop the strategy before changing its configuration.", :conflict)
        end

        if @strategy.update(strategy_params)
          render json: { strategy: StrategySerializer.new(@strategy).as_json }
        else
          render_validation_errors(@strategy)
        end
      end

      def start
        result = ::Strategies::Start.call(strategy: @strategy, actor: current_user,
                                          source: "api", ip_address: request.remote_ip)

        if result.success?
          render json: { strategy: StrategySerializer.new(@strategy.reload).as_json }
        else
          render_error(result.error_code, result.error_message, status_for(result.error_code))
        end
      end

      def stop
        ::Strategies::Stop.call(strategy: @strategy, actor: current_user,
                                source: "api", ip_address: request.remote_ip)

        render json: { strategy: StrategySerializer.new(@strategy.reload).as_json }
      end

      def emergency_stop
        result = ::Strategies::EmergencyStop.call(strategy: @strategy, actor: current_user,
                                                  source: "api", ip_address: request.remote_ip)

        if result.success?
          render json: { strategy: StrategySerializer.new(@strategy.reload).as_json }
        else
          render_error(result.error_code, result.error_message, :unprocessable_entity)
        end
      end

      private

      # Maps a service error onto the HTTP status a client should branch on.
      def status_for(code)
        case code
        when "already_running"  then :conflict
        when "email_unverified" then :forbidden
        else :unprocessable_entity
        end
      end

      # Scoped to the token's owner, so another account's strategy is a 404.
      def set_strategy
        @strategy = current_user.strategies.find(params[:id])
      end

      def render_validation_errors(record)
        render json: {
          error: {
            code: "validation_failed",
            message: record.errors.full_messages.to_sentence,
            details: record.errors.to_hash
          }
        }, status: :unprocessable_entity
      end

      def strategy_params
        params.expect(strategy: %i[
          name direction grid_spacing_points grid_levels initial_lot lot_mode
          lot_multiplier basket_take_profit basket_stop_loss max_positions
          max_exposure_lots max_drawdown_percent min_margin_level_percent max_spread_points max_daily_loss
        ])
      end
    end
  end
end
