# Scheduled retention. Idempotent: a second run finds nothing left to delete.
class PruneOldRecordsJob < ApplicationJob
  queue_as :default

  def perform
    Maintenance::PruneOldRecords.call
  end
end
