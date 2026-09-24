module Mt5
  # Reconciles every instance, and records that this node is alive.
  #
  # Runs on a schedule rather than in response to anything, for the same reason
  # the terminal-staleness monitor does: the failures that matter most produce
  # no event. A VPS that reboots sends nothing to say so.
  class Monitor < ApplicationService
    def call
      heartbeat_node

      outcomes = Hash.new(0)

      Mt5Instance.not_terminated.includes(:worker_node).find_each do |instance|
        result = Reconcile.call(instance:)
        outcomes[result.success? ? result.payload : :error] += 1
      end

      Rails.logger.info("mt5.monitor #{outcomes.to_json}")
      success(outcomes)
    end

    private

    # This process is running on a node, so its own liveness is first-hand
    # evidence that the node is up. When workers become remote, this is replaced
    # by the agent posting its own heartbeat — the placement logic above it does
    # not change.
    def heartbeat_node
      node = WorkerNode.find_by(name: Mt5.config.node_name)

      # Not merely absent-safe: said out loud. An unregistered node is invisible
      # to placement, so every user's first start fails with "no capacity" and
      # nothing anywhere explains that the machine was never registered.
      if node.nil?
        Rails.logger.error("mt5.node_unregistered name=#{Mt5.config.node_name} — run bin/rails db:seed or rake mt5:register_node")
        return
      end

      node.record_heartbeat!(metadata: { pid: Process.pid, reconciled_at: Time.current.utc.iso8601 })
    end
  end
end
