class CreateApiTokens < ActiveRecord::Migration[8.0]
  def change
    create_table :api_tokens do |t|
      t.references :user, null: false, foreign_key: true

      # A user-supplied label, e.g. "MT5 terminal" or "iPhone", so a token can
      # be recognised and revoked without guesswork.
      t.string :name, null: false

      # Only the SHA-256 digest is stored. The plaintext token is shown to the
      # user exactly once, at creation, and is not recoverable from the database.
      t.string :token_digest, null: false

      t.datetime :last_used_at
      t.datetime :expires_at
      t.datetime :revoked_at

      t.timestamps
    end

    add_index :api_tokens, :token_digest, unique: true
  end
end
