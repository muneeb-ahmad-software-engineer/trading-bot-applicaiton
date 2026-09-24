module Mt5
  # Scheduled reconciliation of every terminal.
  #
  # Idempotent by construction: it compares observed facts to desired state, so
  # running it twice in a row produces the same result as running it once. That
  # property is what makes it safe to run every minute and safe to run by hand
  # during an incident.
  class ReconcileInstancesJob < ApplicationJob
    queue_as :default

    def perform = Monitor.call
  end
end
