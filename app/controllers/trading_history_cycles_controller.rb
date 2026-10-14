# One closed cycle: the positions closed together, with the account as it was
# when the cycle started and as it was when it ended.
class TradingHistoryCyclesController < ApplicationController
  def show
    # Found through the signed-in user's strategies only, so an id from another
    # account is simply not found.
    position = Position.where(strategy: current_user.strategies).closed.find(params[:position_id])
    @strategy = position.strategy
    @cycle = @strategy.closed_cycle_containing(position)
    return head :not_found if @cycle.nil?

    members = @cycle.members
    @started_at = members.map(&:opened_at).min
    @lots = members.sum(&:volume)
    @exposure = members.sum { |m| m.volume * m.open_price * 100 }
    @reached = @strategy.basket_take_profit.present? && @cycle.net >= @strategy.basket_take_profit
    @before = account_at(@started_at)
    @after = account_after(@cycle.closed_at)
  end

  private

  # The last account sample at or before the moment. Samples are taken about
  # once a minute, so this is the account as it stood within that minute.
  def account_at(time)
    AccountSnapshot.where(user: current_user).where(recorded_at: ..time).latest_first.first
  end

  # The first sample at or after the moment: the balance once the cycle has
  # closed, which the balance before the close does not show.
  def account_after(time)
    AccountSnapshot.where(user: current_user).where(recorded_at: time..).order(:recorded_at).first
  end
end
