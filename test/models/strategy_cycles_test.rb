require "test_helper"

class StrategyCyclesTest < ActiveSupport::TestCase
  VALID = {
    name: "XAUUSD grid", direction: "both",
    grid_spacing_points: 150, grid_buy_orders: 5, grid_sell_orders: 5, basket_take_profit: 0.7,
    initial_lot: 0.01, max_positions: 10, max_exposure_lots: 0.5
  }.freeze

  setup do
    @strategy = users(:verified).strategies.create!(VALID)
    @ticket = 0
  end

  def close(at:, profit:, swap: 0, commission: 0)
    @ticket += 1
    @strategy.positions.create!(ticket: @ticket.to_s, direction: "buy", volume: 0.01, open_price: 2300,
                                opened_at: at - 1.hour, closed_at: at, close_price: 2301,
                                profit:, swap:, commission:)
  end

  test "positions closed within the cycle gap are one cycle, and its net includes swap and commission" do
    base = 2.hours.ago
    close(at: base, profit: 5, commission: -0.5)
    close(at: base + 2.seconds, profit: -4)
    close(at: base + 10.seconds, profit: 1, swap: -0.2)

    cycles = @strategy.closed_cycles

    assert_equal 1, cycles.size
    assert_equal 3, cycles.first.positions
    assert_in_delta 1.3, cycles.first.net, 0.001
  end

  test "a later close starts a new cycle, and the newest comes first" do
    base = 3.hours.ago
    close(at: base, profit: 2)
    close(at: base + 10.minutes, profit: -6)

    cycles = @strategy.closed_cycles

    assert_equal 2, cycles.size
    assert_in_delta(-6, cycles.first.net, 0.001)
    assert_in_delta 2, cycles.last.net, 0.001
  end

  # Real closes from the live grid, copied from the broker's history. Each list
  # is one batch that closed within seconds; profit only, as the broker showed it.
  test "the real batches from 13 and 14 October group into the cycles the broker closed" do
    oct13_1355 = [ 0.15, 1.27, 2.26, 2.45, 3.77, 4.73, 5.95, 7.20, 8.38, -17.49, -16.41, -15.20, 9.68, -13.76, 10.78 ]
    oct13_1528 = [ 2.09, 0.47, 3.53, 4.92, -11.55, 5.99, -10.42, 7.46 ]
    oct14_0851 = [ 13.42, 18.10, 16.90, 0.22, 5.02, 11.02, 14.50, 3.82, 8.62, 9.82, 1.42, 2.62, 6.22, 7.42, 12.22, 15.70,
                   -26.08, -22.48, -27.29, -21.28, -24.88, -23.68 ]

    { Time.utc(2026, 10, 13, 13, 55, 27) => oct13_1355,
      Time.utc(2026, 10, 13, 15, 28, 53) => oct13_1528,
      Time.utc(2026, 10, 14, 8, 51, 0) => oct14_0851 }.each do |start, profits|
      profits.each_with_index { |profit, i| close(at: start + i * 0.5, profit:) }
    end

    cycles = @strategy.closed_cycles(limit: 10)

    assert_equal 3, cycles.size
    # Newest first: 14 Oct 08:51 net +1.35 (the take-profit close), 13 Oct 15:28
    # net +2.49, 13 Oct 13:55 net -6.24 (closed below target, so not the take-profit rule).
    assert_equal [ 22, 8, 15 ], cycles.map(&:positions)
    assert_in_delta 1.35, cycles[0].net, 0.01
    assert_in_delta 2.49, cycles[1].net, 0.01
    assert_in_delta(-6.24, cycles[2].net, 0.01)
  end

  test "realized net sums every closed position, and open positions are left out" do
    close(at: 1.hour.ago, profit: 3, swap: -1)
    @strategy.positions.create!(ticket: "open", direction: "sell", volume: 0.01, open_price: 2300,
                                opened_at: 10.minutes.ago, profit: 50, swap: 0, commission: 0)

    assert_in_delta 2, @strategy.realized_net, 0.001
  end
end
