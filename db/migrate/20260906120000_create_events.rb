class CreateEvents < ActiveRecord::Migration[8.0]
  def change
    # An append-only record of things that happened to an account.
    #
    # This is the extension point the application was missing: alerts,
    # notifications, webhooks and compliance reporting all need to know "what
    # happened, to what, when, and who did it". Writing that once here means
    # those features subscribe to events rather than each re-deriving state.
    create_table :events do |t|
      t.references :user, null: false, foreign_key: true

      # What happened, e.g. "strategy.started". Namespaced so subscribers can
      # match on a prefix.
      t.string :action, null: false

      # What it happened to. Polymorphic and nullable, because some events
      # (a sign-in) have no subject.
      t.references :subject, polymorphic: true, null: true

      # Structured detail. JSONB rather than a text blob so events stay
      # queryable — "every strategy started with over 0.5 lots of exposure" is
      # a question worth being able to ask.
      t.jsonb :metadata, null: false, default: {}

      # Where the action came from: "web", "api", or "system" for anything the
      # platform did on its own.
      t.string :source, null: false, default: "web"
      t.string :ip_address

      t.datetime :occurred_at, null: false

      t.timestamps
    end

    add_index :events, %i[user_id occurred_at]
    add_index :events, %i[action occurred_at]
    add_index :events, :metadata, using: :gin
  end
end
