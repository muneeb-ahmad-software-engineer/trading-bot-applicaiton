# A user's XAUUSD strategy configuration.
#
# This model holds configuration and lifecycle state only. It places no orders:
# execution is the MT5 Expert Advisor's job, and it reads this configuration
# through the API. Keeping the boundary strict is what lets the platform be
# audited independently of anything that touches a broker.
class Strategy < ApplicationRecord
  SYMBOLS = %w[XAUUSD].freeze

  # One point on XAUUSD, used only to show a points figure back to the user as
  # the dollar distance they were thinking in. Nothing decides anything on this
  # number — the EA reads the broker's own _Point at runtime.
  POINT_VALUE = BigDecimal("0.01")

  # Without a minimum step, a trailing stop asks the broker to modify the
  # position on every tick that moves a fraction in its favour. Brokers throttle
  # or reject that. A distance is never stored without one.
  TRAILING_STEP_DEFAULT_POINTS = 10

  # Above this, a theoretical lot total is reported as "more than" rather than
  # printed in full. The exposure ceiling itself maxes out at 1,000 lots, so any
  # figure past this point is only ever telling the user "far too much".
  DISPLAY_LOT_CEILING = 1_000_000

  belongs_to :user
  has_many :api_tokens, through: :user
  has_many :positions, dependent: :destroy
  has_many :orders, dependent: :destroy
  has_many :account_snapshots, dependent: :nullify
  # Nullify, not destroy: account state belongs to the account, and survives a
  # strategy being deleted. Declared here so destroying a user cannot trip the
  # foreign key depending on which association happens to be listed first.
  has_one :account_state, dependent: :nullify
  # One row per API token that has reported for this strategy, and a managed
  # terminal is issued a new token every time it is pointed at a strategy — so
  # a strategy started more than once has several. All of them are detached on
  # delete; the one that answers "is anything reporting?" is the most recent.
  # Unordered, has_one handed back whichever row Postgres found first, which
  # was usually a long-dead token while a live one reported every ten seconds.
  has_many :terminal_connections, dependent: :nullify
  has_one :terminal_connection, -> { order(Arel.sql("last_report_at DESC NULLS LAST"), id: :desc) }
  # A terminal outlives the strategy it happened to be running: the process is
  # still there and still has to be stopped deliberately.
  has_many :mt5_instances, dependent: :nullify

  enum :status, { draft: "draft", running: "running", stopped: "stopped" }, validate: true
  enum :direction, { both: "both", buy: "buy", sell: "sell" }, prefix: :direction, validate: true
  enum :lot_mode, { fixed: "fixed", multiplier: "multiplier" }, prefix: :lot_mode, validate: true

  # What the strategy does with the market, as opposed to how it exits.
  #
  # Prefixed on purpose. `trailing?` would read as "is this strategy trailing",
  # which is a different question with a different answer: a grid strategy can
  # have a trailing stop too. Asking for the category has to look like asking
  # for the category.
  #
  # A reversal strategy is always in the market on exactly one side. The
  # position's stop and a pending order for the opposite side sit at the same
  # price and trail together, so when price turns far enough the stop closes
  # the position and the pending order opens its replacement, both on the
  # broker's side.
  enum :category, { grid: "grid", trailing: "trailing", reversal: "reversal" },
       prefix: :category, validate: true

  validates :name, presence: true, length: { maximum: 80 }
  validates :symbol, inclusion: { in: SYMBOLS }

  # ------------------------------------------------------------- Grid setup

  # Only a grid strategy has a grid. A trailing strategy opens a single
  # position per direction and manages it with its stop, so requiring a spacing
  # and a level count from it would be asking for numbers that decide nothing.
  with_options if: :category_grid? do
    validates :grid_spacing_points, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: 100_000 }
    validates :grid_levels, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: 200 }
  end

  validates :initial_lot, numericality: { greater_than: 0, less_than_or_equal_to: 100 }

  # Only meaningful in multiplier mode, and must actually scale up when present.
  validates :lot_multiplier,
            numericality: { greater_than_or_equal_to: 1, less_than_or_equal_to: 10 },
            if: -> { category_grid? && lot_mode_multiplier? }

  # --------------------------------------------------------- Trailing stop

  # The loss margin the user is willing to give back from the best price seen.
  # Required for a trailing strategy, optional on a grid, where it is an extra
  # exit layered on top of the basket targets. For a reversal strategy it is
  # the reversal distance: how far the opposite order trails behind price.
  validates :trailing_stop_points, presence: true, unless: :category_grid?
  validates :trailing_stop_points,
            numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: 100_000 },
            allow_nil: true
  validates :trailing_activation_points,
            numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: 100_000 },
            allow_nil: true
  validates :trailing_step_points,
            numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: 100_000 },
            allow_nil: true

  # Reversal only: how far from the market the flat Buy Stop / Sell Stop
  # bracket rests. Blank means the trailing distance. Ignored by the other
  # categories rather than refused, so switching category on the form does not
  # strand the user on an error about a field they can no longer see.
  validates :entry_distance_points,
            numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: 100_000 },
            allow_nil: true

  before_validation :default_the_trailing_step

  validate :trailing_settings_need_a_distance
  validate :trailing_step_fits_inside_the_distance
  validate :reversal_trails_both_sides_from_the_start

  # ---------------------------------------------------------- Risk controls

  validates :max_positions, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: 500 }
  validates :max_exposure_lots, numericality: { greater_than: 0, less_than_or_equal_to: 1_000 }
  validates :basket_take_profit, numericality: { greater_than: 0 }, allow_nil: true
  validates :basket_stop_loss, numericality: { greater_than: 0 }, allow_nil: true
  validates :max_drawdown_percent, numericality: { greater_than: 0, less_than_or_equal_to: 100 }, allow_nil: true
  validates :min_margin_level_percent, numericality: { greater_than: 0 }, allow_nil: true
  validates :max_spread_points, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  # Realised plus floating loss for the broker's trading day, in account
  # currency. Enforced by the EA, which closes this strategy's positions when
  # it is reached and opens nothing more until the next day.
  validates :max_daily_loss, numericality: { greater_than: 0, less_than_or_equal_to: 10_000_000 }, allow_nil: true

  validate :grid_levels_within_max_positions
  validate :exposure_can_accommodate_the_strategy
  validate :category_unchanged_while_running

  scope :ordered, -> { order(created_at: :desc) }

  # Configuration may be edited at any time: the EA re-fetches as soon as the
  # config_version in a report response changes. Only the strategy type is
  # fixed while running, because switching it would hand the open positions
  # to logic that never opened them.
  def category_locked? = running?

  # Whether the EA will trail stops for this strategy at all. True for every
  # trailing strategy, and for a grid that opted into the exit.
  def trailing_enabled? = trailing_stop_points.present?

  # A points distance as the dollar figure the user entered it as.
  def self.points_to_price(points)
    return nil if points.blank?

    (points.to_d * POINT_VALUE).round(2)
  end

  def trailing_stop_price       = self.class.points_to_price(trailing_stop_points)
  def trailing_activation_price = self.class.points_to_price(trailing_activation_points)
  def trailing_step_price       = self.class.points_to_price(trailing_step_points)

  # The distance the EA actually brackets the market at. Only a reversal
  # strategy places a bracket, so every other category has none.
  def effective_entry_distance_points
    return unless category_reversal?

    entry_distance_points || trailing_stop_points
  end

  def entry_distance_price = self.class.points_to_price(effective_entry_distance_points)

  def start!
    raise NotVerified unless user.may_trade?
    # Starting something already running is not a no-op: it would move
    # started_at forward and lose the moment the strategy actually went live,
    # which is the timestamp the audit trail and the P/L window are read
    # against. The partial unique index cannot catch this, because a row does
    # not conflict with itself.
    raise AlreadyRunning if running?

    # Starting again is the explicit acknowledgement that ends an emergency
    # stop. Nothing else clears it.
    update!(status: :running, started_at: Time.current, stopped_at: nil, emergency_stopped_at: nil)
  rescue ActiveRecord::RecordNotUnique
    # The partial unique index rejected a second concurrent start.
    raise AlreadyRunning
  end

  def stop!
    halt!(stopped_at: Time.current)
  end

  # Stopping, and more: the EA closes every position and pending order of this
  # strategy and opens nothing until it is started again. Allowed on a strategy
  # that is already stopped, because that is exactly when a user discovers
  # positions they want gone.
  def emergency_stop!
    now = Time.current
    halt!(stopped_at: running? ? now : (stopped_at || now), emergency_stopped_at: now)
  end

  def emergency_stopped? = emergency_stopped_at.present?

  # Identifies this exact configuration. The EA re-fetches when the value in a
  # report response differs from the one it holds.
  def config_version = updated_at&.utc&.iso8601(6)

  # The number of baskets this strategy can run at once. A both-directions
  # grid can hold a buy side and a sell side simultaneously. Trailing and
  # reversal strategies hold one position in total, whatever the direction —
  # the EA refuses a second one.
  def concurrent_directions = direction_both? && category_grid? ? 2 : 1

  # Whether the strategy's positions are opened one at a time and exited only
  # by their stop, rather than averaged into a grid.
  def single_position? = !category_grid?

  # The largest total volume this configuration could ever open, used to warn a
  # user before their exposure ceiling silently truncates the strategy.
  def maximum_theoretical_lots
    # A trailing strategy holds one position at a time, and re-enters only
    # once the previous one has closed. Its ceiling is the entry size itself.
    return (initial_lot.to_d * concurrent_directions).round(2) if single_position?

    if lot_mode_multiplier? && lot_multiplier.to_d > 1
      # Geometric series: a(rⁿ − 1) / (r − 1)
      r = lot_multiplier.to_d
      (initial_lot.to_d * ((r**grid_levels) - 1) / (r - 1)).round(2)
    else
      (initial_lot.to_d * grid_levels).round(2)
    end
  end

  class NotVerified < StandardError; end
  class AlreadyRunning < StandardError; end

  private

  # Halting writes its columns directly, WITHOUT validations. Stopping must
  # never be refused because some unrelated setting no longer passes a rule
  # added after it was saved — a refused stop leaves the EA trading. updated_at
  # is written with them, so config_version changes and the EA re-fetches.
  def halt!(**attributes)
    now = Time.current
    update_columns(status: "stopped", updated_at: now, **attributes)
    self
  end

  def default_the_trailing_step
    return if trailing_stop_points.blank? || trailing_step_points.present?

    # Clamped, so a distance tighter than the default step still moves.
    self.trailing_step_points = [ TRAILING_STEP_DEFAULT_POINTS, trailing_stop_points ].min
  end

  # An activation or a step with nothing to trail is a setting that does
  # nothing, which is worse than an error: the user believes they configured an
  # exit and did not.
  def trailing_settings_need_a_distance
    return if trailing_stop_points.present?

    if trailing_activation_points.present?
      errors.add(:trailing_activation_points, "needs a trailing distance to activate")
    end
    if trailing_step_points.present?
      errors.add(:trailing_step_points, "needs a trailing distance to step through")
    end
  end

  # A step wider than the distance itself can never be satisfied, so the stop
  # would be placed once and then never move again — a fixed stop wearing a
  # trailing stop's label.
  def trailing_step_fits_inside_the_distance
    return if trailing_step_points.blank? || trailing_stop_points.blank?
    return if trailing_step_points <= trailing_stop_points

    errors.add(:trailing_step_points,
      "cannot exceed the trailing distance (#{trailing_stop_points} points) — the stop would never move")
  end

  # The opposite order has to be trailing from the moment a position opens, or
  # a reversal strategy is just an unprotected position waiting to activate.
  # And a reversal alternates between buy and sell by definition, so limiting
  # it to one side would describe a different strategy.
  def reversal_trails_both_sides_from_the_start
    return unless category_reversal?

    if trailing_activation_points.present?
      errors.add(:trailing_activation_points,
        "must be blank for a reversal strategy — the opposite order trails from the moment a position opens")
    end
    unless direction_both?
      errors.add(:direction, "must be both directions for a reversal strategy — it alternates between buy and sell")
    end
  end

  def grid_levels_within_max_positions
    return unless category_grid?
    return if grid_levels.blank? || max_positions.blank?
    return if grid_levels <= max_positions

    errors.add(:grid_levels,
      "cannot exceed maximum positions (#{max_positions}) — the grid would be cut short before its last level")
  end

  def exposure_can_accommodate_the_strategy
    return if initial_lot.blank? || max_exposure_lots.blank?
    return if category_grid? && grid_levels.blank?
    return if category_grid? && lot_mode_multiplier? && lot_multiplier.blank?
    return if maximum_theoretical_lots <= max_exposure_lots.to_d

    errors.add(:max_exposure_lots, exposure_shortfall_message)
  end

  def exposure_shortfall_message
    if single_position?
      "is below what this strategy can open (#{readable_maximum_lots} lots). " \
      "Raise the ceiling or lower the entry lot size."
    else
      "is below what this grid can open (#{readable_maximum_lots} lots). " \
      "Raise the ceiling, reduce levels, or lower the initial lot size."
    end
  end

  # A compounding grid grows geometrically, so a careless multiplier produces a
  # figure with dozens of digits. Printing that verbatim gives the user a wall
  # of numerals where they needed a readable quantity, and the message is
  # already telling them the answer is "far more than your ceiling". Past the
  # point where the exact total stops meaning anything, say that instead.
  def readable_maximum_lots
    total = maximum_theoretical_lots

    if total > DISPLAY_LOT_CEILING
      "more than #{ActiveSupport::NumberHelper.number_to_delimited(DISPLAY_LOT_CEILING)}"
    else
      ActiveSupport::NumberHelper.number_to_delimited(total)
    end
  end

  def category_unchanged_while_running
    return unless running? && category_changed? && !status_changed?

    errors.add(:category, "cannot change while the strategy is running. Stop it first")
  end
end
