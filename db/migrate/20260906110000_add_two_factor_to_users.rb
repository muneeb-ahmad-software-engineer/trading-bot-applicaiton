class AddTwoFactorToUsers < ActiveRecord::Migration[8.0]
  def change
    # Encrypted at the application layer, so the shared secret is not readable
    # from a database dump or a backup. Text, not string: the ciphertext payload
    # is far longer than the 32-character base32 secret it holds.
    add_column :users, :otp_secret, :text

    # Null until enrolment is *confirmed* with a working code. A secret that has
    # been generated but never verified must not lock anyone out.
    add_column :users, :otp_enabled_at, :datetime

    # The last TOTP time-step consumed. A one-time password must be exactly
    # that: without this, a code observed over someone's shoulder (or captured
    # in transit) can be replayed for the rest of its 30-second window.
    add_column :users, :otp_last_used_step, :bigint

    create_table :recovery_codes do |t|
      t.references :user, null: false, foreign_key: true

      # Only a digest is stored, exactly as for passwords and API tokens.
      t.string :code_digest, null: false
      t.datetime :used_at

      t.timestamps
    end

    add_index :recovery_codes, %i[user_id code_digest], unique: true
  end
end
