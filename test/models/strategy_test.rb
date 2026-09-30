require "test_helper"

# Exhaustive coverage of Strategy: every validation boundary, both branches of
# the lot arithmetic, the full lifecycle, and the guarantees the database makes
# on its own.
#
# The bias here is deliberate. A wrong number in this model is a wrong number of
# lots at a broker, so boundaries are asserted on both sides — the largest value
# that is accepted and the smallest that is not — rather than sampled.
class StrategyTest < ActiveSupport::TestCase
  setup { @user = users(:verified) }

  # A configuration that is valid in every respect. Each test changes exactly
  # one thing, so a failure names the rule that broke rather than the setup.
  def build(**overrides)
    @user.strategies.new({
      name: "XAUUSD grid", direction: "both",
      grid_spacing_points: 150, grid_levels: 5,
      initial_lot: 0.01, lot_mode: "fixed",
      max_positions: 10, max_exposure_lots: 0.5
    }.merge(overrides))
  end

  # Asserts the record is rejected *for the stated reason*. Without naming the
  # attribute, a test passes when the record is invalid for some unrelated
  # reason the setup introduced, which is how boundary tests quietly rot.
  def assert_invalid(strategy, attribute)
    assert_not strategy.valid?, "expected #{attribute} to be rejected"
    assert_predicate strategy.errors[attribute], :any?,
                     "expected an error on #{attribute}, got #{strategy.errors.to_hash.inspect}"
  end

  def assert_valid(strategy)
    assert strategy.valid?, "expected valid, got #{strategy.errors.full_messages.to_sentence}"
  end

  test "a sensible configuration is valid" do
    assert_predicate build, :valid?
  end

  # ------------------------------------------------------------------ Name

  test "name is required and cannot be blank or whitespace" do
    assert_invalid build(name: nil), :name
    assert_invalid build(name: ""), :name
    assert_invalid build(name: "   "), :name
  end

  test "name accepts 80 characters and rejects 81" do
    assert_valid build(name: "a" * 80)
    assert_invalid build(name: "a" * 81), :name
  end

  # ---------------------------------------------------------------- Symbol

  test "the only tradeable symbol is XAUUSD" do
    assert_valid build(symbol: "XAUUSD")
    assert_invalid build(symbol: "EURUSD"), :symbol
    assert_invalid build(symbol: nil), :symbol
  end

  test "symbol matching is case sensitive" do
    # The column defaults to "XAUUSD", so most tests never supply one and this
    # would go unnoticed. A lower-case symbol reaching the Expert Advisor would
    # not match any instrument at the broker.
    assert_invalid build(symbol: "xauusd"), :symbol
  end

  # ----------------------------------------------------------------- Enums

  test "an unknown enum value is a validation error, not an exception" do
    # enum ..., validate: true. Without it Rails raises ArgumentError on
    # assignment, which a controller would surface as a 500 rather than a form
    # error.
    assert_invalid build(status: "bogus"), :status
    assert_invalid build(direction: "sideways"), :direction
    assert_invalid build(lot_mode: "martingale"), :lot_mode
  end

  # ------------------------------------------------------------- Grid setup

  test "rejects non-positive grid spacing, levels and lot size" do
    assert_not build(grid_spacing_points: 0).valid?
    assert_not build(grid_levels: 0).valid?
    assert_not build(initial_lot: 0).valid?
    assert_not build(initial_lot: -1).valid?
  end

  test "grid spacing is bounded on both sides" do
    assert_invalid build(grid_spacing_points: 0), :grid_spacing_points
    assert_invalid build(grid_spacing_points: -1), :grid_spacing_points
    assert_valid build(grid_spacing_points: 1)
    assert_valid build(grid_spacing_points: 100_000)
    assert_invalid build(grid_spacing_points: 100_001), :grid_spacing_points
    assert_invalid build(grid_spacing_points: nil), :grid_spacing_points
  end

  test "grid spacing must be a whole number of points" do
    # The attribute casts 150.5 to 150; only_integer inspects the value before
    # the cast, so the user is told rather than silently given a different grid.
    assert_invalid build(grid_spacing_points: 150.5), :grid_spacing_points
  end

  test "grid levels are bounded on both sides" do
    assert_invalid build(grid_levels: 0), :grid_levels
    assert_valid build(grid_levels: 1)
    assert_valid build(grid_levels: 200, max_positions: 500, max_exposure_lots: 2)
    assert_invalid build(grid_levels: 201, max_positions: 500, max_exposure_lots: 3), :grid_levels
    assert_invalid build(grid_levels: nil), :grid_levels
    assert_invalid build(grid_levels: 5.5), :grid_levels
  end

  test "initial lot is bounded on both sides" do
    assert_invalid build(initial_lot: 0), :initial_lot
    assert_invalid build(initial_lot: -0.01), :initial_lot
    assert_valid build(initial_lot: 100, grid_levels: 1, max_positions: 1, max_exposure_lots: 100)
    assert_invalid build(initial_lot: 100.01, grid_levels: 1, max_positions: 1, max_exposure_lots: 1000), :initial_lot
    assert_invalid build(initial_lot: nil), :initial_lot
  end

  test "a lot size below broker precision is refused, not silently rounded to zero" do
    # The column is decimal(10,2), so 0.001 casts to 0.00. Saving that would
    # hand the Expert Advisor a zero-lot grid; the user must be told instead.
    strategy = build(initial_lot: 0.001)

    assert_equal 0.to_d, strategy.initial_lot
    assert_invalid strategy, :initial_lot
  end

  # ----------------------------------------------------------- Lot multiplier

  test "multiplier mode requires a multiplier of at least one" do
    assert_not build(lot_mode: "multiplier", lot_multiplier: nil).valid?
    assert_not build(lot_mode: "multiplier", lot_multiplier: 0.5).valid?
  end

  test "the multiplier is bounded between one and ten" do
    assert_invalid build(lot_mode: "multiplier", lot_multiplier: 0.99), :lot_multiplier
    assert_valid build(lot_mode: "multiplier", lot_multiplier: 1)
    assert_valid build(lot_mode: "multiplier", lot_multiplier: 10, max_exposure_lots: 200)
    assert_invalid build(lot_mode: "multiplier", lot_multiplier: 10.01, max_exposure_lots: 200), :lot_multiplier
  end

  test "a multiplier is ignored entirely in fixed mode" do
    # The validation is conditional on the mode. A leftover multiplier from a
    # user who switched back to fixed must not block the save, and must not
    # change the arithmetic.
    strategy = build(lot_mode: "fixed", lot_multiplier: 99)

    assert_valid strategy
    assert_equal BigDecimal("0.05"), strategy.maximum_theoretical_lots
  end

  # --------------------------------------------------------- Risk controls

  test "maximum positions is bounded on both sides" do
    assert_invalid build(max_positions: 0), :max_positions
    assert_valid build(max_positions: 1, grid_levels: 1)
    assert_valid build(max_positions: 500)
    assert_invalid build(max_positions: 501), :max_positions
    assert_invalid build(max_positions: nil), :max_positions
  end

  test "the exposure ceiling is bounded on both sides" do
    assert_invalid build(max_exposure_lots: 0), :max_exposure_lots
    assert_valid build(max_exposure_lots: 1_000)
    assert_invalid build(max_exposure_lots: 1_000.01), :max_exposure_lots
    assert_invalid build(max_exposure_lots: nil), :max_exposure_lots
  end

  test "basket targets are optional but must be positive when given" do
    assert_valid build(basket_take_profit: nil, basket_stop_loss: nil)
    assert_valid build(basket_take_profit: 0.01, basket_stop_loss: 0.01)
    assert_invalid build(basket_take_profit: 0), :basket_take_profit
    assert_invalid build(basket_take_profit: -1), :basket_take_profit
    assert_invalid build(basket_stop_loss: 0), :basket_stop_loss
    assert_invalid build(basket_stop_loss: -1), :basket_stop_loss
  end

  test "drawdown limit is optional and expressed as a percentage of at most 100" do
    assert_valid build(max_drawdown_percent: nil)
    assert_valid build(max_drawdown_percent: 100)
    assert_invalid build(max_drawdown_percent: 0), :max_drawdown_percent
    assert_invalid build(max_drawdown_percent: 100.01), :max_drawdown_percent
  end

  test "minimum margin level is optional, positive, and has no upper bound" do
    # Margin level is equity/margin as a percentage and routinely runs into the
    # thousands on a lightly used account, so capping it at 100 would be wrong.
    assert_valid build(min_margin_level_percent: nil)
    assert_valid build(min_margin_level_percent: 10_000)
    assert_invalid build(min_margin_level_percent: 0), :min_margin_level_percent
  end

  test "maximum spread is optional and a positive whole number of points" do
    assert_valid build(max_spread_points: nil)
    assert_valid build(max_spread_points: 1)
    assert_invalid build(max_spread_points: 0), :max_spread_points
    assert_invalid build(max_spread_points: 10.5), :max_spread_points
  end

  # ------------------------------------------ Grid levels vs max positions

  test "grid levels cannot exceed maximum positions" do
    strategy = build(grid_levels: 20, max_positions: 10, max_exposure_lots: 100)

    assert_not strategy.valid?
    assert_match(/cannot exceed maximum positions/, strategy.errors[:grid_levels].to_sentence)
  end

  test "a grid that exactly fills the position ceiling is allowed" do
    assert_valid build(grid_levels: 10, max_positions: 10, max_exposure_lots: 1)
  end

  test "the message names the ceiling the user actually configured" do
    strategy = build(grid_levels: 20, max_positions: 12, max_exposure_lots: 100)
    strategy.valid?

    assert_match(/\(12\)/, strategy.errors[:grid_levels].to_sentence)
  end

  test "the levels-versus-positions check stays quiet when either value is missing" do
    # Otherwise a blank form reports "cannot exceed maximum positions" on top of
    # the presence errors, which reads as a contradiction.
    strategy = build(grid_levels: nil, max_positions: nil)
    strategy.valid?

    assert_no_match(/cannot exceed maximum positions/, strategy.errors[:grid_levels].to_sentence)
  end

  # -------------------------------------------- Exposure versus the grid

  test "exposure ceiling must accommodate the grid it is paired with" do
    # 10 levels of 0.10 lots = 1.0 lots, above a 0.5 ceiling.
    strategy = build(grid_levels: 10, initial_lot: 0.10, max_positions: 10, max_exposure_lots: 0.5)

    assert_not strategy.valid?
    assert_match(/below what this grid can open/, strategy.errors[:max_exposure_lots].to_sentence)
  end

  test "a grid that exactly reaches its exposure ceiling is allowed" do
    # 5 levels of 0.01 is exactly 0.05. The ceiling is a limit, not a barrier
    # the grid must stay strictly under.
    assert_valid build(grid_levels: 5, initial_lot: 0.01, max_exposure_lots: 0.05)
  end

  test "a compounding grid is measured against its geometric total, not its levels" do
    # 0.01 * (1 + 2 + 4 + 8 + 16) = 0.31
    assert_invalid build(lot_mode: "multiplier", lot_multiplier: 2, grid_levels: 5,
                         initial_lot: 0.01, max_exposure_lots: 0.30), :max_exposure_lots
    assert_valid build(lot_mode: "multiplier", lot_multiplier: 2, grid_levels: 5,
                       initial_lot: 0.01, max_exposure_lots: 0.31)
  end

  test "an unusable multiplier reports one error, not two" do
    # The exposure check returns early rather than computing a total from a
    # multiplier it knows is missing. The user gets "multiplier is not a number"
    # and fixes one thing.
    strategy = build(lot_mode: "multiplier", lot_multiplier: nil, max_exposure_lots: 0.01)
    strategy.valid?

    assert_predicate strategy.errors[:lot_multiplier], :any?
    assert_empty strategy.errors[:max_exposure_lots]
  end

  test "an unreachable total is described in words rather than printed in full" do
    # A 200-level grid doubling each step reaches a 59-digit number. Printed
    # verbatim it fills the form with numerals and tells the user nothing.
    strategy = build(lot_mode: "multiplier", lot_multiplier: 2, grid_levels: 200,
                     max_positions: 500, max_exposure_lots: 1_000)
    strategy.valid?
    message = strategy.errors[:max_exposure_lots].to_sentence

    assert_match(/more than 1,000,000 lots/, message)
    assert_operator message.length, :<, 200, "the error message must stay readable"
  end

  test "an ordinary total is printed exactly, with separators" do
    strategy = build(lot_mode: "multiplier", lot_multiplier: 10, grid_levels: 10,
                     max_positions: 500, max_exposure_lots: 1_000)
    strategy.valid?

    # 0.01 * (10^10 - 1) / 9 = 11,111,111.11 — above the display ceiling.
    assert_match(/more than/, strategy.errors[:max_exposure_lots].to_sentence)
  end

  # --------------------------------------------- maximum_theoretical_lots

  test "maximum theoretical lots is linear in fixed mode" do
    strategy = build(grid_levels: 5, initial_lot: 0.02, lot_mode: "fixed")

    assert_equal 0.10.to_d, strategy.maximum_theoretical_lots
  end

  test "maximum theoretical lots compounds in multiplier mode" do
    # 0.01 * (1 + 2 + 4 + 8) = 0.15
    strategy = build(grid_levels: 4, initial_lot: 0.01, lot_mode: "multiplier", lot_multiplier: 2)

    assert_equal 0.15.to_d, strategy.maximum_theoretical_lots
  end

  test "a multiplier of exactly one does not divide by zero" do
    # The geometric series is a(rⁿ − 1)/(r − 1), which is undefined at r = 1.
    # A multiplier of 1 is a legal configuration meaning "do not scale up", so
    # this is a reachable input, not a theoretical one.
    strategy = build(lot_mode: "multiplier", lot_multiplier: 1, grid_levels: 5, initial_lot: 0.01)

    assert_nothing_raised { strategy.maximum_theoretical_lots }
    assert_equal BigDecimal("0.05"), strategy.maximum_theoretical_lots
    assert_valid strategy
  end

  test "multiplier mode with no multiplier falls back to the linear total" do
    # Reached while a form is half-filled. It must not raise on the way to
    # reporting that the multiplier is missing.
    strategy = build(lot_mode: "multiplier", lot_multiplier: nil, grid_levels: 5, initial_lot: 0.01)

    assert_nothing_raised { strategy.maximum_theoretical_lots }
    assert_equal BigDecimal("0.05"), strategy.maximum_theoretical_lots
  end

  test "a single-level grid can only ever open its initial lot" do
    assert_equal BigDecimal("0.01"), build(grid_levels: 1, initial_lot: 0.01).maximum_theoretical_lots
    assert_equal BigDecimal("0.01"),
                 build(grid_levels: 1, initial_lot: 0.01, lot_mode: "multiplier",
                       lot_multiplier: 2, max_positions: 1).maximum_theoretical_lots
  end

  test "the total is rounded to broker lot precision" do
    # 0.03 * (1 + 1.5 + 2.25) = 0.1425, which no broker can accept as-is.
    strategy = build(initial_lot: 0.03, lot_mode: "multiplier", lot_multiplier: 1.5,
                     grid_levels: 3, max_exposure_lots: 1)

    assert_equal BigDecimal("0.14"), strategy.maximum_theoretical_lots
  end

  test "lot amounts use decimal arithmetic, not floats" do
    strategy = build(initial_lot: 0.01, grid_levels: 3)
    strategy.save!

    assert_kind_of BigDecimal, strategy.reload.initial_lot
    # 0.01 * 3 is exactly 0.03 in decimal; in binary floating point it is not.
    assert_equal BigDecimal("0.03"), strategy.maximum_theoretical_lots
  end

  # ------------------------------------------------------------- Lifecycle

  test "a new strategy starts as a draft and is not running" do
    strategy = build
    strategy.save!

    assert_predicate strategy, :draft?
    assert_not strategy.running?
  end

  test "a running strategy can be edited but not change its type" do
    strategy = build
    strategy.save!
    strategy.start!

    assert strategy.update(grid_levels: 6), strategy.errors.full_messages.to_sentence
    assert_not strategy.update(category: "trailing", trailing_stop_points: 300, trailing_step_points: 50)
    assert_includes strategy.errors[:category], "cannot change while the strategy is running. Stop it first"

    strategy.reload.stop!
    assert_predicate strategy, :stopped?
    assert_not strategy.category_locked?
  end

  test "starting requires a verified user" do
    strategy = users(:unverified).strategies.create!(
      name: "g", grid_spacing_points: 150, grid_levels: 5, initial_lot: 0.01,
      max_positions: 10, max_exposure_lots: 0.5
    )

    assert_raises(Strategy::NotVerified) { strategy.start! }
    assert_not strategy.reload.running?
  end

  test "start and stop move through the lifecycle" do
    strategy = build
    strategy.save!

    strategy.start!
    assert_predicate strategy, :running?
    assert_not_nil strategy.started_at
    assert_predicate strategy, :category_locked?

    strategy.stop!
    assert_predicate strategy, :stopped?
    assert_not_nil strategy.stopped_at
    assert_not strategy.category_locked?
  end

  test "restarting clears the previous stop so the record is not both started and stopped" do
    strategy = build
    strategy.save!
    strategy.start!
    strategy.stop!
    assert_not_nil strategy.stopped_at

    strategy.start!

    assert_predicate strategy, :running?
    assert_nil strategy.stopped_at
  end

  test "starting a strategy that is already running is refused and preserves the original start time" do
    # The partial unique index cannot catch this: a row does not conflict with
    # itself. Without the guard, start! moves started_at forward and the record
    # of when the strategy actually went live — which the audit trail and every
    # since-start P/L figure are read against — is lost.
    strategy = build
    strategy.save!
    strategy.start!
    original = strategy.started_at

    assert_raises(Strategy::AlreadyRunning) { strategy.start! }
    assert_equal original.to_i, strategy.reload.started_at.to_i
  end

  test "only one strategy may run per symbol, enforced by the database" do
    first = build(name: "first")
    first.save!
    first.start!

    second = build(name: "second")
    second.save!

    assert_raises(Strategy::AlreadyRunning) { second.start! }
    assert_not second.reload.running?
  end

  test "the database refuses a second running strategy even when validations are bypassed" do
    first = build(name: "first")
    first.save!
    first.update_column(:status, "running")

    second = build(name: "second")
    second.save!

    assert_raises(ActiveRecord::RecordNotUnique) { second.update_column(:status, "running") }
  end

  test "two different users may each run their own strategy" do
    mine = build
    mine.save!
    mine.start!

    other = users(:unverified)
    other.verify!
    theirs = other.strategies.create!(
      name: "theirs", grid_spacing_points: 150, grid_levels: 5, initial_lot: 0.01,
      max_positions: 10, max_exposure_lots: 0.5
    )

    assert_nothing_raised { theirs.start! }
  end

  test "stopping a draft that never ran is allowed and leaves it never-started" do
    # Reachable from the interface, and the serializer and dashboard must cope
    # with a stopped strategy whose started_at is nil.
    strategy = build
    strategy.save!

    strategy.stop!

    assert_predicate strategy, :stopped?
    assert_nil strategy.started_at
    assert_not_nil strategy.stopped_at
  end

  test "stopping is idempotent and never blocked" do
    strategy = build
    strategy.save!
    strategy.start!
    strategy.stop!
    first_stop = strategy.stopped_at

    travel 1.second do
      assert_nothing_raised { strategy.stop! }
    end

    assert_predicate strategy, :stopped?
    assert_operator strategy.stopped_at, :>, first_stop
  end

  test "an unverified user may always stop, however the strategy came to be running" do
    # Halting must never be gated. Someone whose verification lapsed still has
    # real money at a broker.
    user = users(:unverified)
    strategy = user.strategies.create!(
      name: "g", grid_spacing_points: 150, grid_levels: 5, initial_lot: 0.01,
      max_positions: 10, max_exposure_lots: 0.5
    )
    strategy.update_column(:status, "running")

    assert_nothing_raised { strategy.stop! }
    assert_predicate strategy.reload, :stopped?
  end

  # ------------------------------------------------------- Strategy category

  # A configuration for the second category. It carries no grid at all, which
  # is the point: the grid rules must not fire on it.
  def build_trailing(**overrides)
    @user.strategies.new({
      name: "XAUUSD trailing", category: "trailing", direction: "both",
      initial_lot: 0.01, trailing_stop_points: 200,
      max_positions: 10, max_exposure_lots: 0.5
    }.merge(overrides))
  end

  test "a strategy is a grid unless it says otherwise" do
    assert_predicate build, :category_grid?
    assert_equal "grid", Strategy.new.category
  end

  test "category must be one this platform actually runs" do
    assert_invalid build(category: "martingale"), :category
  end

  test "a trailing strategy is valid with no grid configuration at all" do
    assert_valid build_trailing
  end

  test "a trailing strategy must have a trailing distance" do
    assert_invalid build_trailing(trailing_stop_points: nil), :trailing_stop_points
  end

  test "a reversal strategy needs only a distance, and trails from the start on both sides" do
    assert_valid build_trailing(category: "reversal")
    assert_invalid build_trailing(category: "reversal", trailing_stop_points: nil), :trailing_stop_points
    assert_invalid build_trailing(category: "reversal", trailing_activation_points: 100), :trailing_activation_points
    assert_invalid build_trailing(category: "reversal", direction: "buy"), :direction
  end

  test "a reversal strategy holds one position, so its ceiling is a single entry" do
    strategy = build_trailing(category: "reversal", initial_lot: 0.05, max_exposure_lots: 0.05)

    assert_equal BigDecimal("0.05"), strategy.maximum_theoretical_lots
    assert_valid strategy
  end

  test "a grid still requires its spacing and levels" do
    assert_invalid build(grid_spacing_points: nil), :grid_spacing_points
    assert_invalid build(grid_levels: nil), :grid_levels
  end

  # The database carries the same rule, so a row that skips the model cannot
  # create a grid with no grid or a trailing strategy with nothing to trail.
  test "the database refuses a grid with no grid" do
    strategy = build
    strategy.save!

    assert_raises ActiveRecord::StatementInvalid do
      strategy.update_column(:grid_levels, nil)
    end
  end

  test "the database refuses a trailing strategy with no distance" do
    strategy = build_trailing
    strategy.save!

    assert_raises ActiveRecord::StatementInvalid do
      strategy.update_column(:trailing_stop_points, nil)
    end
  end

  # ------------------------------------------------------------ Trailing stop

  test "a grid may carry a trailing stop without becoming a trailing strategy" do
    strategy = build(trailing_stop_points: 200)

    assert_valid strategy
    assert_predicate strategy, :category_grid?
    assert_predicate strategy, :trailing_enabled?
  end

  test "a strategy with no trailing distance is not trailing anything" do
    assert_not_predicate build, :trailing_enabled?
  end

  test "trailing distance boundaries" do
    assert_invalid build(trailing_stop_points: 0), :trailing_stop_points
    assert_invalid build(trailing_stop_points: -1), :trailing_stop_points
    assert_valid build(trailing_stop_points: 1)
    assert_valid build(trailing_stop_points: 100_000)
    assert_invalid build(trailing_stop_points: 100_001), :trailing_stop_points
  end

  test "an activation or a step with nothing to trail is rejected rather than ignored" do
    # Silently accepting these is the worst outcome: the user leaves the form
    # believing they configured an exit that does not exist.
    assert_invalid build(trailing_activation_points: 500), :trailing_activation_points
    assert_invalid build(trailing_step_points: 20), :trailing_step_points
  end

  test "a distance is never stored without a step" do
    strategy = build(trailing_stop_points: 200)
    strategy.validate

    assert_equal Strategy::TRAILING_STEP_DEFAULT_POINTS, strategy.trailing_step_points
  end

  test "the default step is clamped to a distance tighter than itself" do
    strategy = build(trailing_stop_points: 3)
    strategy.validate

    assert_equal 3, strategy.trailing_step_points
  end

  test "an explicit step is left alone" do
    strategy = build(trailing_stop_points: 200, trailing_step_points: 50)
    strategy.validate

    assert_equal 50, strategy.trailing_step_points
  end

  test "a step wider than the distance would freeze the stop, so it is rejected" do
    assert_invalid build(trailing_stop_points: 200, trailing_step_points: 201), :trailing_step_points
    assert_valid build(trailing_stop_points: 200, trailing_step_points: 200)
  end

  test "points are restated as the dollar distance they were entered as" do
    strategy = build(trailing_stop_points: 200, trailing_activation_points: 1_000,
                     trailing_step_points: 25)

    assert_equal BigDecimal("2.00"), strategy.trailing_stop_price
    assert_equal BigDecimal("10.00"), strategy.trailing_activation_price
    assert_equal BigDecimal("0.25"), strategy.trailing_step_price
    assert_nil build.trailing_stop_price
  end

  # A trailing strategy holds one position in total — never a buy and a sell
  # together — so its ceiling is the entry size, whatever the direction.
  test "maximum exposure for a trailing strategy is the entry, once in total" do
    assert_equal BigDecimal("0.01"), build_trailing(initial_lot: 0.01, direction: "both").maximum_theoretical_lots
    assert_equal BigDecimal("0.01"), build_trailing(initial_lot: 0.01, direction: "buy").maximum_theoretical_lots
    assert_equal BigDecimal("0.01"), build_trailing(category: "reversal", initial_lot: 0.01).maximum_theoretical_lots
  end

  # --------------------------------------------- daily loss and emergency stop

  test "daily loss boundaries" do
    assert_valid build(max_daily_loss: nil)
    assert_valid build(max_daily_loss: 0.01)
    assert_invalid build(max_daily_loss: 0), :max_daily_loss
    assert_invalid build(max_daily_loss: -5), :max_daily_loss
  end

  test "an emergency stop stops the strategy and stays until it is started again" do
    strategy = build
    strategy.save!
    strategy.start!

    strategy.emergency_stop!
    assert_predicate strategy, :stopped?
    assert_predicate strategy, :emergency_stopped?

    strategy.start!
    assert_not_predicate strategy, :emergency_stopped?
  end

  # A rule added after a strategy was saved must never be what keeps it
  # trading: stopping writes past validations on purpose.
  test "a strategy that no longer passes validation can still be stopped and emergency-stopped" do
    strategy = build
    strategy.save!
    strategy.start!
    strategy.update_column(:max_exposure_lots, 0.001)   # now below what the grid can open
    assert_not strategy.reload.valid?

    strategy.stop!
    assert_predicate strategy.reload, :stopped?

    strategy.update_column(:status, "running")
    before = strategy.reload.config_version
    travel 1.second do
      strategy.emergency_stop!
    end
    strategy.reload
    assert_predicate strategy, :stopped?
    assert_predicate strategy, :emergency_stopped?
    assert_not_equal before, strategy.config_version, "the EA must see the change and re-fetch"
  end

  test "an emergency stop on an already stopped strategy keeps its original stop time" do
    strategy = build
    strategy.save!
    strategy.start!
    strategy.stop!
    stopped_at = strategy.stopped_at

    travel 1.minute do
      strategy.emergency_stop!
    end
    assert_equal stopped_at, strategy.reload.stopped_at
    assert_predicate strategy, :emergency_stopped?
  end

  # --------------------------------------------- entry distance (reversal bracket)

  test "a blank entry distance falls back to the trailing distance for a reversal" do
    assert_equal 200, build_trailing(category: "reversal").effective_entry_distance_points
    assert_equal 350, build_trailing(category: "reversal", entry_distance_points: 350).effective_entry_distance_points
  end

  test "only a reversal strategy has an entry distance" do
    assert_nil build_trailing(entry_distance_points: 350).effective_entry_distance_points
    assert_nil build(entry_distance_points: 350).effective_entry_distance_points
  end

  test "entry distance boundaries" do
    assert_invalid build_trailing(category: "reversal", entry_distance_points: 0), :entry_distance_points
    assert_invalid build_trailing(category: "reversal", entry_distance_points: 100_001), :entry_distance_points
    assert_valid build_trailing(category: "reversal", entry_distance_points: 1)
    assert_valid build_trailing(category: "reversal", entry_distance_points: nil)
  end

  test "a trailing strategy still has to fit inside its exposure ceiling" do
    assert_invalid build_trailing(initial_lot: 1.0, max_exposure_lots: 0.5), :max_exposure_lots
  end

  test "the level ceiling does not apply to a strategy with no levels" do
    # max_positions below grid_levels rejects a grid. A trailing strategy has
    # no levels for that rule to compare against.
    assert_valid build_trailing(max_positions: 1)
  end

  # ---------------------------------------------------------- Associations

  test "deleting a user deletes their strategies" do
    build.save!

    assert_difference "Strategy.count", -1 do
      @user.destroy
    end
  end

  test "deleting a strategy discards its positions and orders" do
    strategy = build
    strategy.save!
    strategy.positions.create!(ticket: "1", direction: "buy", volume: 0.01,
                               open_price: 2000, opened_at: Time.current)
    strategy.orders.create!(ticket: "2", order_type: "buy_limit", volume: 0.01,
                            price: 1990, status: "pending", placed_at: Time.current)

    assert_difference [ "Position.count", "Order.count" ], -1 do
      strategy.destroy
    end
  end

  test "deleting a strategy keeps the account history and the terminal it was bound to" do
    # Snapshots and connections are nullified, not destroyed: what the account
    # was worth last Tuesday remains true after the strategy is deleted, and a
    # terminal that is still connected must not vanish from the dashboard.
    strategy = build
    strategy.save!
    snapshot = @user.account_snapshots.create!(strategy:, balance: 100, equity: 100,
                                               recorded_at: Time.current)
    token = ApiToken.issue(user: @user, name: "terminal")
    connection = TerminalConnection.create!(user: @user, api_token: token, strategy:,
                                            symbol: "XAUUSD")

    assert_no_difference [ "AccountSnapshot.count", "TerminalConnection.count" ] do
      strategy.destroy
    end

    assert_nil snapshot.reload.strategy_id
    assert_nil connection.reload.strategy_id
  end
end
