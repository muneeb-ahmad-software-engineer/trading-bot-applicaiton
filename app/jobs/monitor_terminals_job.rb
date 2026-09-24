# Scheduled check for situations that nothing else would notice.
#
# Idempotent by design: running it twice produces the same result, because
# Notifications::Deliver suppresses an alert for a situation already reported.
class MonitorTerminalsJob < ApplicationJob
  queue_as :default

  def perform
    Alerts::MonitorTerminals.call
  end
end
