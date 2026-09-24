# The current state of a user's broker account, as last reported.
#
# One row per user, updated in place. This is deliberately not a time series:
# the dashboard and the API only ever ask "what is it now?", and answering that
# from an ever-growing history table was costing 8,640 inserts per user per day
# to serve reads that only ever touched the newest row.
#
# History lives in AccountSnapshot, written far less often and pruned.
class AccountState < ApplicationRecord
  belongs_to :user
  belongs_to :strategy, optional: true

  validates :balance, :equity, :recorded_at, presence: true

  # A single statement, so concurrent reports from the same terminal cannot
  # interleave into a lost update.
  def self.record(user:, attributes:)
    upsert(
      attributes.merge(user_id: user.id, created_at: Time.current, updated_at: Time.current),
      unique_by: :index_account_states_on_user_id
    )
  end
end
