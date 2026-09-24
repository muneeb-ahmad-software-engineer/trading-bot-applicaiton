# The execution manager's control-plane tables.
#
# Rails decides what should be running; a worker node runs it. Everything here
# is control-plane state — desired state, observed state, and the audit of how
# one became the other. No trading data lives in these tables.
class CreateExecutionManagerTables < ActiveRecord::Migration[8.0]
  def change
    # A machine that can run MT5 terminals. Today there is one row; the schema
    # exists so that adding a second VPS is an INSERT rather than a rewrite.
    create_table :worker_nodes do |t|
      t.string :name, null: false
      t.string :hostname, null: false
      t.string :region

      # online   — accepting new instances
      # draining — keeps what it has, takes nothing new (for maintenance)
      # offline  — unreachable or deliberately withdrawn
      t.string :status, null: false, default: "offline"

      # Capacity is expressed in instances rather than CPU or memory because
      # that is the unit placement actually allocates. An MT5 terminal under
      # Wine needs roughly 400 MB of RSS and a fraction of a core at rest.
      t.integer :max_instances, null: false, default: 0

      t.string :agent_version
      t.datetime :last_heartbeat_at
      t.text :last_error
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end
    add_index :worker_nodes, :name, unique: true
    add_index :worker_nodes, :status

    # A single user's MT5 terminal: its identity, where it lives on disk, what
    # it is doing, and what it is supposed to be doing.
    create_table :mt5_instances do |t|
      t.references :user, null: false, foreign_key: true
      t.references :worker_node, null: false, foreign_key: true
      t.references :strategy, foreign_key: true

      # The token this terminal authenticates with. Nullified rather than
      # cascaded when a token is revoked, so the instance survives long enough
      # to be told to stop.
      t.references :api_token, foreign_key: { on_delete: :nullify }

      # Public identity. Appears in paths, log lines and metrics, and is safe to
      # show a user or paste into a support ticket — unlike the row id, it
      # reveals nothing about how many instances exist.
      t.string :uuid, null: false

      # What the control plane wants: running, stopped, or gone entirely.
      t.string :desired_state, null: false, default: "stopped"

      # What the execution layer was last observed to be doing.
      t.string :state, null: false, default: "provisioning"

      # ------------------------------------------------------------ Process
      t.integer :pid
      t.datetime :process_started_at

      # A PID alone cannot answer "is this still my process?" — the number is
      # reused after a reboot, and killing a stranger's PID is unforgivable on a
      # shared host. This token is written into the instance directory at boot
      # and re-read before any signal is sent.
      t.string :process_token

      # ------------------------------------------------------------ Isolation
      t.string :instance_dir, null: false

      # MT5 under Wine needs an X display. One per instance, so a crash in one
      # terminal's UI cannot take another's down with it.
      t.integer :display_number

      # Identifies this terminal's orders at the broker. Two terminals sharing a
      # magic number would each treat the other's positions as their own.
      t.bigint :magic_number, null: false

      # ------------------------------------------------------------ Liveness
      t.datetime :last_heartbeat_at
      t.datetime :last_health_check_at

      # ------------------------------------------------------------ Lifecycle
      t.datetime :provisioned_at
      t.datetime :started_at
      t.datetime :connected_at
      t.datetime :stopped_at
      t.datetime :failed_at
      t.datetime :terminated_at
      t.datetime :last_transition_at

      # ------------------------------------------------------------ Failures
      t.integer :restart_count, null: false, default: 0
      t.integer :consecutive_failures, null: false, default: 0
      t.datetime :next_restart_at
      t.string :last_error_code
      t.text :last_error_message

      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end
    add_index :mt5_instances, :uuid, unique: true
    add_index :mt5_instances, :magic_number, unique: true
    add_index :mt5_instances, %i[worker_node_id state]
    add_index :mt5_instances, :state
    add_index :mt5_instances, :next_restart_at

    # One live instance per user. Enforced by the database rather than by a
    # check in Ruby, because two simultaneous provision requests would otherwise
    # both pass the check and both spawn a terminal against the same broker
    # account — which is how an account ends up with two EAs fighting over the
    # same positions.
    add_index :mt5_instances, :user_id,
              unique: true,
              where: "state <> 'terminated'",
              name: "index_mt5_instances_one_live_per_user"

    # One display per node, for as long as an instance holds it.
    add_index :mt5_instances, %i[worker_node_id display_number],
              unique: true,
              where: "state <> 'terminated' AND display_number IS NOT NULL",
              name: "index_mt5_instances_one_display_per_node"

    # Append-only lifecycle audit. Separate from `events`, which records what a
    # *user* did: these are facts about what the execution layer did, most of it
    # with no user in the room at all.
    create_table :mt5_instance_events do |t|
      t.references :mt5_instance, null: false, foreign_key: true
      t.references :user, foreign_key: true

      t.string :action, null: false
      t.string :from_state
      t.string :to_state

      # web / api / system — who asked. "system" covers the reconciler.
      t.string :source, null: false, default: "system"
      t.text :reason
      t.jsonb :metadata, null: false, default: {}

      t.datetime :occurred_at, null: false

      t.datetime :created_at, null: false
    end
    add_index :mt5_instance_events, %i[mt5_instance_id occurred_at]
    add_index :mt5_instance_events, :action

    # The broker account a user's terminal signs in to.
    #
    # Kept out of mt5_instances: instances are disposable and get recreated,
    # credentials are entered once. The password is encrypted at rest, like
    # every other credential in this application.
    create_table :broker_credentials do |t|
      t.references :user, null: false, foreign_key: true, index: { unique: true }

      t.string :server, null: false
      t.string :login, null: false
      # Encrypted at rest by ActiveRecord encryption; never a plaintext column.
      t.text :password, null: false

      # Marks a demo account. The interface refuses to hide this: a user must
      # always know which kind of account a terminal is about to sign in to.
      t.boolean :demo, null: false, default: true

      t.datetime :last_verified_at
      t.string :last_verification_error

      t.timestamps
    end
  end
end
