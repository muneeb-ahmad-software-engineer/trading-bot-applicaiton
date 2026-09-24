class AddVerificationToUsers < ActiveRecord::Migration[8.0]
  def change
    # Null until the user clicks the link in their verification email. Actions
    # that can move real money check this rather than a boolean flag, so the
    # moment of verification is auditable.
    add_column :users, :verified_at, :datetime
  end
end
