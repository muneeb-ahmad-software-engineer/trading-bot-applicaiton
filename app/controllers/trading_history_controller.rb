# Closed positions, with filtering and pagination.
class TradingHistoryController < ApplicationController
  PER_PAGE = 25

  # Mirrors Position#net_profit. NULL swap or commission must not annul the row.
  NET_PROFIT_SQL = Arel.sql(
    "COALESCE(positions.profit, 0) + COALESCE(positions.swap, 0) + COALESCE(positions.commission, 0)"
  ).freeze

  def index
    @strategies = current_user.strategies.ordered
    @filter = filter_params

    scope = filtered_scope
    @total = scope.count
    @page = [ params[:page].to_i, 1 ].max
    @pages = [ (@total / PER_PAGE.to_f).ceil, 1 ].max
    @positions = scope.order(closed_at: :desc)
                      .offset((@page - 1) * PER_PAGE)
                      .limit(PER_PAGE)
                      .includes(:strategy)

    # Totals describe the whole filtered set, not just the visible page — a
    # realised P/L that changed when you turned the page would be worse than
    # useless.
    #
    # Summed in SQL, not in Ruby. Summing in Ruby loads every matching row to
    # add three columns: measured at 2,000 rows that is 95ms and 103k object
    # allocations against 10ms and 1.4k for the same answer in the database,
    # and it grows without bound as history accumulates.
    @realised_profit = scope.sum(NET_PROFIT_SQL)
    @closed_count = @total

    # The closes grouped into the cycles they were closed in, so a grid's
    # ladder reads as one result. Follows the strategy filter, so it always
    # matches the list below it.
    @cycles = @strategies
                .select { |strategy| @filter[:strategy_id].blank? || strategy.id.to_s == @filter[:strategy_id].to_s }
                .map { |strategy| [ strategy, strategy.closed_cycles(limit: 10) ] }
                .reject { |_strategy, cycles| cycles.empty? }
  end

  private

  def filter_params
    {
      strategy_id: params[:strategy_id].presence,
      direction: (params[:direction] if Position::DIRECTIONS.include?(params[:direction])),
      from: parse_date(params[:from]),
      to: parse_date(params[:to])
    }
  end

  def parse_date(value)
    return nil if value.blank?

    Date.parse(value)
  rescue Date::Error
    nil
  end

  def filtered_scope
    # Always scoped through the current user's strategies, so a crafted
    # strategy_id cannot reach another account's history.
    scope = Position.where(strategy: current_user.strategies).closed

    scope = scope.where(strategy_id: @filter[:strategy_id]) if @filter[:strategy_id]
    scope = scope.where(direction: @filter[:direction]) if @filter[:direction]
    scope = scope.where(closed_at: @filter[:from].beginning_of_day..) if @filter[:from]
    scope = scope.where(closed_at: ..@filter[:to].end_of_day) if @filter[:to]
    scope
  end
end
