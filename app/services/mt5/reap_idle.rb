module Mt5
  # Stops terminals nobody is using.
  #
  # The point of the whole design: one VPS, many users, and only the active ones
  # holding MT5 resources. A terminal whose user has no running strategy is
  # costing ~400 MB of RSS and a Wine process to do nothing, and on a shared box
  # that is capacity another user needs.
  #
  # Stopped, never deprovisioned. The directory, the token and the broker
  # configuration all survive, so starting again is a spawn rather than a full
  # provision — seconds instead of a setup flow.
  class ReapIdle < ApplicationService
    def initialize(idle_for: nil)
      @idle_for = idle_for || Mt5.config.idle_timeout
    end

    def call
      reaped = 0

      Mt5Instance.live.includes(:user, :worker_node).find_each do |instance|
        next unless idle?(instance)

        Rails.logger.info("mt5.reaping_idle #{instance.to_log.merge(idle_for: idle_for.to_i).to_json}")
        Stop.call(instance:, source: "system", reason: "no running strategy for #{idle_for.inspect}")
        reaped += 1
      end

      success(reaped)
    end

    private

    attr_reader :idle_for

    # Idle means the user has nothing running *and* has not had anything running
    # recently. The grace period stops a terminal being reaped in the gap
    # between a user stopping one strategy and starting another.
    def idle?(instance)
      return false if instance.user.strategies.where(status: "running").exists?

      last_activity = [ instance.started_at, instance.last_heartbeat_at, instance.last_transition_at ].compact.max
      last_activity.present? && last_activity < idle_for.ago
    end
  end
end
