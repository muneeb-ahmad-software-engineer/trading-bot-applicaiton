# One user's MT5 terminal.
#
# This row is the boundary between the control plane and the execution layer.
# Rails writes `desired_state`; the execution layer reports what actually
# happened and the reconciler moves `state` towards the desire. Nothing else in
# the application is allowed to assume a terminal is running because someone
# pressed a button — only because this row says a heartbeat arrived.
#
# The distinction matters after a crash. A VPS reboot, a Rails deploy and an MT5
# segfault all look identical from here: `state` says running, the process is
# gone. Recovery is therefore not special-cased per cause — the reconciler
# compares observed facts to desired state and acts, which makes it correct
# after failures nobody predicted.
class Mt5Instance < ApplicationRecord
  # An instance must have been heard from this recently to count as running.
  # Matched to the EA's reporting contract (5–15s) with room for one missed
  # report, and to TerminalConnection::STALE_AFTER so the dashboard and the
  # execution manager never disagree about whether a terminal is alive.
  HEARTBEAT_TIMEOUT = 90.seconds

  # How long a terminal may sit in `starting` or `connecting` before the attempt
  # is called a failure. MT5 under Wine is slow to boot; a broker login adds
  # more. Too short and a healthy start is killed, too long and a user watches a
  # spinner for minutes.
  START_TIMEOUT = 90.seconds
  CONNECT_TIMEOUT = 180.seconds

  # How long a graceful shutdown is given before the process is killed. MT5
  # flushes its own state on exit and cutting that short can corrupt a terminal
  # profile, so this is generous.
  STOP_TIMEOUT = 30.seconds

  # A crash loop is worse than being down: it burns the VPS and floods the user
  # with alerts. Restarts back off, and stop entirely at the limit.
  MAX_CONSECUTIVE_FAILURES = 5
  RESTART_BACKOFF = [ 10.seconds, 30.seconds, 2.minutes, 5.minutes, 15.minutes ].freeze

  # MT5 magic numbers must not collide across terminals. This base keeps them
  # clear of anything a user has attached by hand.
  MAGIC_NUMBER_BASE = 7_700_000

  belongs_to :user
  belongs_to :worker_node
  belongs_to :strategy, optional: true
  belongs_to :api_token, optional: true

  has_many :events, class_name: "Mt5InstanceEvent", dependent: :delete_all

  # ------------------------------------------------------------------ States

  STATES = %w[provisioning starting connecting running stopping stopped failed terminated].freeze
  DESIRED_STATES = %w[running stopped absent].freeze

  # The only transitions that may happen. Anything else is a bug in a caller,
  # and is refused loudly rather than quietly corrupting the lifecycle.
  TRANSITIONS = {
    "provisioning" => %w[stopped starting failed terminated],
    "starting"     => %w[connecting running stopping stopped failed],
    "connecting"   => %w[running stopping stopped failed],
    "running"      => %w[stopping stopped failed connecting],
    "stopping"     => %w[stopped failed],
    "stopped"      => %w[starting terminated failed],
    # A failed instance may still have a live process: a stop that fails records
    # a failure while the terminal is very much still running. Halting must
    # therefore be reachable from here, or a crashed terminal could never be
    # cleaned up — and the user could never get rid of one that will not die.
    "failed"       => %w[starting stopping stopped terminated],
    "terminated"   => []
  }.freeze

  # States in which a process is expected to exist on the worker node.
  LIVE_STATES = %w[starting connecting running stopping].freeze

  enum :state, STATES.index_with(&:itself), validate: true
  enum :desired_state, DESIRED_STATES.index_with(&:itself), prefix: :wants, validate: true

  validates :uuid, presence: true, uniqueness: true
  validates :instance_dir, presence: true
  validates :magic_number, presence: true, uniqueness: true

  scope :live, -> { where(state: LIVE_STATES) }
  scope :not_terminated, -> { where.not(state: "terminated") }
  scope :due_for_restart, -> { where(desired_state: "running").where(state: %w[stopped failed]) }

  before_validation :assign_identity, on: :create

  # ------------------------------------------------------------- Predicates

  def process_expected? = LIVE_STATES.include?(state)

  def heartbeat_fresh? = last_heartbeat_at.present? && last_heartbeat_at > HEARTBEAT_TIMEOUT.ago

  def healthy? = running? && heartbeat_fresh?

  def terminal? = TRANSITIONS.fetch(state, []).empty?

  def may_transition_to?(next_state) = TRANSITIONS.fetch(state, []).include?(next_state.to_s)

  # A start attempt that has been "starting" for longer than the terminal takes
  # to boot is not slow, it is stuck.
  def start_timed_out?
    return false unless starting?

    last_transition_at.present? && last_transition_at < START_TIMEOUT.ago
  end

  # Up, but the EA has never called in. Usually a bad token, a missing WebRequest
  # whitelist entry, or a broker refusing the login.
  def connect_timed_out?
    return false unless connecting?

    last_transition_at.present? && last_transition_at < CONNECT_TIMEOUT.ago
  end

  def stop_timed_out?
    return false unless stopping?

    last_transition_at.present? && last_transition_at < STOP_TIMEOUT.ago
  end

  def crash_looping? = consecutive_failures >= MAX_CONSECUTIVE_FAILURES

  def restart_allowed_now?
    return false if crash_looping?

    next_restart_at.blank? || next_restart_at <= Time.current
  end

  def backoff_for(failures)
    RESTART_BACKOFF[[ failures - 1, RESTART_BACKOFF.length - 1 ].min.clamp(0, RESTART_BACKOFF.length - 1)]
  end

  # ------------------------------------------------------------ Transitions

  # The single way `state` may change.
  #
  # Every transition is audited in the same statement that performs it, so the
  # history can never disagree with the row: either both land or neither does.
  # Callers pass `reason` because "why did this stop?" is the first question
  # anyone asks, and reconstructing it from timestamps is guesswork.
  def transition_to!(next_state, action:, reason: nil, source: "system", actor: nil, metadata: {})
    next_state = next_state.to_s

    unless may_transition_to?(next_state)
      raise InvalidTransition, "#{uuid}: #{state} → #{next_state} is not a valid transition"
    end

    previous = state

    transaction do
      assign_attributes(state: next_state, last_transition_at: Time.current)
      assign_attributes(timestamp_for(next_state) => Time.current) if timestamp_for(next_state)
      save!

      events.create!(
        action:, from_state: previous, to_state: next_state, reason:, source:,
        user: actor, metadata:, occurred_at: Time.current
      )
    end

    self
  end

  # Records a failure and schedules the next attempt. Kept separate from the
  # transition so that "we failed" and "when we may try again" cannot drift.
  def record_failure!(code:, message:, source: "system", metadata: {})
    failures = consecutive_failures + 1

    transaction do
      update!(
        consecutive_failures: failures,
        next_restart_at: Time.current + backoff_for(failures),
        last_error_code: code,
        last_error_message: message.to_s.truncate(1000)
      )

      transition_to!("failed", action: "instance.failed", reason: message.to_s.truncate(500),
                     source:, metadata: metadata.merge(error_code: code, consecutive_failures: failures))
    end
  end

  def clear_failures!
    update!(consecutive_failures: 0, next_restart_at: nil, last_error_code: nil, last_error_message: nil)
  end

  def record_heartbeat!
    # update_columns: a heartbeat arrives every few seconds per instance and
    # must not burn validations, callbacks or a timestamp bump on each one.
    update_columns(last_heartbeat_at: Time.current, updated_at: Time.current)
  end

  # ---------------------------------------------------------------- Paths
  #
  # Every path an instance touches hangs off one directory, so isolation is a
  # property of the layout rather than a rule each call site has to remember.

  def config_dir = File.join(instance_dir, "config")
  def data_dir = File.join(instance_dir, "data")
  def log_dir = File.join(instance_dir, "logs")
  def run_dir = File.join(instance_dir, "run")
  def pid_file = File.join(run_dir, "terminal.pid")
  def token_file = File.join(run_dir, "process.token")

  # MetaTrader's own tree, one per instance.
  #
  # It exists because MT5 run with /portable keeps everything — settings, the
  # expert's inputs, logs, downloaded history — in the folder its executable
  # sits in. Pointed at one shared installation, every user's terminal would
  # read and write the same MQL5/Presets/GoldGrid.set, which is to say every
  # user would be trading the strategy of whoever provisioned last. Giving each
  # instance its own tree is what makes /portable an isolation mechanism rather
  # than a collision.
  def terminal_dir = File.join(instance_dir, "terminal")
  def terminal_binary = File.join(terminal_dir, "terminal64.exe")
  def terminal_config_dir = File.join(terminal_dir, "config")
  def startup_ini = File.join(terminal_config_dir, "goldgrid.ini")
  def mql5_dir = File.join(terminal_dir, "MQL5")
  def presets_dir = File.join(mql5_dir, "Presets")
  def ea_preset = File.join(presets_dir, "GoldGrid.set")

  # Safe to log. Deliberately excludes the API token, the broker password and
  # anything else that would turn a log aggregator into a credential store.
  def to_log
    {
      instance: uuid, user_id:, node: worker_node&.name, state:, desired_state:,
      pid:, display: display_number, magic: magic_number,
      heartbeat_age: last_heartbeat_at && (Time.current - last_heartbeat_at).round
    }
  end

  class InvalidTransition < StandardError; end

  private

  def timestamp_for(next_state)
    {
      "starting" => :started_at, "connecting" => :connected_at, "stopped" => :stopped_at,
      "failed" => :failed_at, "terminated" => :terminated_at
    }[next_state]
  end

  def assign_identity
    self.uuid ||= "mt5-#{SecureRandom.uuid}"
    self.magic_number ||= self.class.next_magic_number
    self.instance_dir ||= File.join(Mt5.config.instances_root, uuid)
  end

  def self.next_magic_number
    # A gap-tolerant sequence. Reusing a freed number would let a new terminal
    # adopt a dead one's positions at the broker.
    (maximum(:magic_number) || MAGIC_NUMBER_BASE) + 1
  end
end
