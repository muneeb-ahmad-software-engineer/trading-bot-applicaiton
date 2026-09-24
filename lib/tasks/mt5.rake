# Operator tasks for the execution manager.
#
# Everything here is safe to run on a live node: registering is an upsert,
# reconciling is idempotent, and draining stops nothing by itself.
namespace :mt5 do
  desc "Register (or update) this machine as a worker node"
  task register_node: :environment do
    node = WorkerNode.find_or_initialize_by(name: Mt5.config.node_name)
    node.assign_attributes(
      hostname: ENV.fetch("MT5_NODE_HOSTNAME", Socket.gethostname),
      region: ENV["MT5_NODE_REGION"],
      max_instances: Mt5.config.max_instances,
      status: "online",
      last_heartbeat_at: Time.current
    )
    node.save!

    puts "registered #{node.name} (#{node.hostname}) capacity=#{node.max_instances} runtime=#{Mt5.config.runtime}"
  end

  desc "Show every terminal and what it is doing"
  task status: :environment do
    printf("%-40s %-12s %-10s %-9s %-8s %s\n", "INSTANCE", "STATE", "DESIRED", "PID", "FAILS", "HEARTBEAT")
    Mt5Instance.not_terminated.includes(:worker_node).find_each do |instance|
      age = instance.last_heartbeat_at ? "#{(Time.current - instance.last_heartbeat_at).round}s ago" : "never"
      printf("%-40s %-12s %-10s %-9s %-8s %s\n", instance.uuid, instance.state,
             instance.desired_state, instance.pid || "-", instance.consecutive_failures, age)
    end
  end

  desc "Reconcile every terminal now, instead of waiting for the schedule"
  task reconcile: :environment do
    puts Mt5::Monitor.call.payload.inspect
  end

  desc "Stop scheduling new terminals onto this node (existing ones keep running)"
  task drain: :environment do
    WorkerNode.find_by!(name: Mt5.config.node_name).update!(status: "draining")
    puts "#{Mt5.config.node_name} is draining"
  end

  desc "Stop every terminal on this node gracefully. Run before a reboot."
  task quiesce: :environment do
    node = WorkerNode.find_by!(name: Mt5.config.node_name)
    node.update!(status: "draining")

    node.mt5_instances.live.find_each do |instance|
      # preserve_desired_state: the intent that these terminals should be
      # running is not withdrawn, so once the node is registered online again
      # the reconciler starts every one of them back up without an operator
      # having to remember which were running.
      result = Mt5::Stop.call(instance:, source: "system", reason: "node quiesce",
                              preserve_desired_state: true)
      puts "#{instance.uuid} #{result.success? ? 'stopped' : "FAILED: #{result.error_message}"}"
    end
  end
end
