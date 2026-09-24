class CreateNotifications < ActiveRecord::Migration[8.0]
  def change
    # A delivered (or suppressed) alert.
    #
    # Persisted rather than fire-and-forget for one reason above all:
    # deduplication. A terminal that stops reporting stays stopped, and the
    # monitor runs every minute. Without a record of what was already sent, the
    # user gets an alert every minute until they give up and mute everything —
    # at which point the alerting system is worse than none.
    create_table :notifications do |t|
      t.references :user, null: false, foreign_key: true

      t.string :alert_type, null: false
      t.string :title, null: false
      t.text   :body, null: false
      t.string :severity, null: false, default: "info"

      # Identifies the *situation*, not the message: e.g.
      # "terminal_stale:14". Repeat alerts for the same ongoing situation are
      # suppressed while it remains unresolved.
      t.string :dedup_key, null: false

      # Where it points when opened.
      t.string :url

      t.references :subject, polymorphic: true, null: true
      t.jsonb :metadata, null: false, default: {}

      # Delivery outcome per channel, so a failure is visible rather than
      # silently lost.
      t.datetime :emailed_at
      t.datetime :pushed_at
      t.datetime :read_at

      # When the underlying situation ended. A resolved alert allows the same
      # dedup_key to fire again later.
      t.datetime :resolved_at

      t.timestamps
    end

    add_index :notifications, %i[user_id created_at]
    # The lookup the dedup check makes on every detection pass.
    add_index :notifications, %i[user_id dedup_key resolved_at]

    # A browser or installed PWA that has granted permission to receive push.
    create_table :push_subscriptions do |t|
      t.references :user, null: false, foreign_key: true

      # The push service endpoint. Unique: re-subscribing the same browser must
      # update the existing row rather than accumulate duplicates that would
      # each deliver the same alert.
      t.string :endpoint, null: false
      t.string :p256dh_key, null: false
      t.string :auth_key, null: false

      t.string :user_agent
      t.datetime :last_used_at
      t.datetime :failed_at
      t.integer :failure_count, null: false, default: 0

      t.timestamps
    end

    add_index :push_subscriptions, :endpoint, unique: true

    # Per-user channel and alert-type preferences. JSONB rather than a row per
    # combination: it is a settings document, read whole, never queried across
    # users.
    add_column :users, :notification_preferences, :jsonb, null: false, default: {}
  end
end
