# Strategy configuration.
#
# Every lookup is scoped through current_user, so a strategy belonging to
# another account is a 404 rather than a permission error — the existence of
# someone else's record is not disclosed.
class StrategiesController < ApplicationController
  before_action :set_strategy, only: %i[show edit update destroy start stop emergency_stop]

  def index
    @strategies = current_user.strategies.ordered.includes(:terminal_connection)
    @instance = current_user.mt5_instances.not_terminated.first
  end

  def show
    @positions = @strategy.positions.open.recent_first
    @orders = @strategy.orders.pending.order(:price)
    @basket_profit = @positions.sum(&:net_profit)
    # Scoped to THIS strategy. A terminal reporting for a different strategy is
    # not evidence that anything is executing this one, and the positions and
    # figures on this page all come from the strategy — so a connection that
    # does not belong to it would vouch for numbers it never sent.
    @connection = @strategy.terminal_connection
    @closed_count = @strategy.positions.closed.count
    # What is executing this, if anything. Loaded on the page that asks the
    # question rather than left to the settings screen.
    @instance = current_user.mt5_instances.not_terminated.first
    @credential = current_user.broker_credential
    # Read from the terminal's own logs, so only when there is something to
    # explain.
    @diagnostics = @instance && !@instance.healthy? ? @instance.worker_node.runtime.diagnostics(@instance) : []
  end

  def new
    @strategy = current_user.strategies.new(defaults)
  end

  def create
    @strategy = current_user.strategies.new(strategy_params)

    if @strategy.save
      Event.record("strategy.created", user: current_user, subject: @strategy,
                   ip_address: request.remote_ip, metadata: { name: @strategy.name })
      redirect_to @strategy, notice: "Strategy saved as a draft. Nothing is trading yet."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    return if @strategy.editable?

    redirect_to @strategy, alert: "Stop the strategy before editing its configuration."
  end

  def update
    return redirect_to(@strategy, alert: "Stop the strategy before editing its configuration.") unless @strategy.editable?

    if @strategy.update(strategy_params)
      Event.record("strategy.updated", user: current_user, subject: @strategy,
                   ip_address: request.remote_ip,
                   metadata: { name: @strategy.name, changed: @strategy.previous_changes.keys - %w[updated_at] })
      redirect_to @strategy, notice: "Strategy updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    return redirect_to(@strategy, alert: "Stop the strategy before deleting it.") if @strategy.running?

    name = @strategy.name
    @strategy.destroy
    Event.record("strategy.deleted", user: current_user, ip_address: request.remote_ip,
                 metadata: { name: })
    redirect_to strategies_path, notice: "Strategy deleted."
  end

  def start
    result = Strategies::Start.call(strategy: @strategy, actor: current_user,
                                    source: "web", ip_address: request.remote_ip)

    if result.success?
      redirect_to @strategy, notice: "Strategy started. Your Expert Advisor will pick up this configuration."
    else
      redirect_to @strategy, alert: result.error_message
    end
  end

  def stop
    Strategies::Stop.call(strategy: @strategy, actor: current_user,
                          source: "web", ip_address: request.remote_ip)

    redirect_to @strategy,
                notice: "Strategy stopped. No new orders will be placed. Positions already open with your broker are not closed by this action."
  end

  def emergency_stop
    result = Strategies::EmergencyStop.call(strategy: @strategy, actor: current_user,
                                            source: "web", ip_address: request.remote_ip)

    if result.success?
      redirect_to @strategy,
                  notice: "Emergency stop sent. Your Expert Advisor will close every position and pending order " \
                          "of this strategy at market as soon as it next reports — normally within seconds."
    else
      redirect_to @strategy, alert: result.error_message
    end
  end

  private

  def set_strategy
    @strategy = current_user.strategies.find(params[:id])
  end

  # Deliberately conservative starting values. They are a valid configuration to
  # edit from, not a recommendation — no default is profitable by design.
  def defaults
    {
      name: "XAUUSD grid",
      category: "grid",
      direction: "both",
      grid_spacing_points: 150,
      grid_levels: 5,
      initial_lot: 0.01,
      lot_mode: "fixed",
      max_positions: 10,
      max_exposure_lots: 0.5,
      max_drawdown_percent: 20,
      min_margin_level_percent: 200,
      max_spread_points: 50
    }
  end

  def strategy_params
    params.expect(strategy: %i[
      name category direction grid_spacing_points grid_levels initial_lot lot_mode
      lot_multiplier trailing_stop_points trailing_activation_points
      trailing_step_points entry_distance_points basket_take_profit basket_stop_loss max_positions
      max_exposure_lots max_drawdown_percent min_margin_level_percent max_spread_points max_daily_loss
    ])
  end
end
