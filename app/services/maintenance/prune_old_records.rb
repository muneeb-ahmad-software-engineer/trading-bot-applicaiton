module Maintenance
  # Deletes records past their retention window.
  #
  # Every table here grows with time rather than with the number of users, so
  # without this the database only ever gets bigger. Account history is the
  # largest by a wide margin.
  #
  # Deletes run in batches so a long-overdue first run cannot hold a lock long
  # enough to affect terminals reporting at the same time.
  class PruneOldRecords < ApplicationService
    BATCH_SIZE = 5_000

    # Closed positions are trading history a user may legitimately want years
    # later, so they are deliberately not pruned here.
    POLICIES = [
      { model: -> { AccountSnapshot }, column: :recorded_at, retain: -> { AccountSnapshot::RETENTION } },
      { model: -> { Event }, column: :occurred_at, retain: -> { Event::RETENTION } },
      { model: -> { Notification }, column: :created_at, retain: -> { Notification::RETENTION },
        scope: -> { Notification.where.not(resolved_at: nil) } }
    ].freeze

    def call
      deleted = POLICIES.to_h do |policy|
        model = policy[:model].call
        cutoff = policy[:retain].call.ago
        scope = policy[:scope]&.call || model.all

        [ model.name, delete_in_batches(scope.where(policy[:column] => ...cutoff)) ]
      end

      Rails.logger.info("PruneOldRecords deleted #{deleted.inspect}")
      success(deleted)
    end

    private

    def delete_in_batches(scope)
      total = 0

      loop do
        count = scope.limit(BATCH_SIZE).delete_all
        total += count
        break if count < BATCH_SIZE
      end

      total
    end
  end
end
