module Mt5
  # Releases MT5 resources held by users who are not trading.
  class ReapIdleInstancesJob < ApplicationJob
    queue_as :default

    def perform = ReapIdle.call
  end
end
