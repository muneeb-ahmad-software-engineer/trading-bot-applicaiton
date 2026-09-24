# Idempotent, and run in every environment.
#
# The only thing seeded is the worker node this process is running on. It is not
# demo data: without a node row, Mt5::Placement has nowhere to put a terminal
# and every user's first strategy start fails with "no capacity" — a confusing
# error for what is really an unregistered machine. `rake mt5:register_node`
# does the same thing for an operator adding a second VPS later.
node = WorkerNode.find_or_initialize_by(name: Mt5.config.node_name)
node.assign_attributes(
  hostname: ENV.fetch("MT5_NODE_HOSTNAME", Socket.gethostname),
  region: ENV["MT5_NODE_REGION"].presence || node.region,
  max_instances: Mt5.config.max_instances,
  # Seeding runs on the node itself, so this process's own existence is
  # first-hand evidence the machine is up — the same evidence Mt5::Monitor
  # uses. Without the heartbeat the node is registered but not schedulable, and
  # a fresh install cannot start anything until the reconciler first runs. The
  # claim is self-correcting either way: liveness is derived, so if nothing
  # heartbeats here the node reads as stale two minutes from now.
  last_heartbeat_at: Time.current,
  status: node.draining? ? "draining" : "online"
)
node.save!

puts "seeded worker node #{node.name} (#{node.hostname}) capacity=#{node.max_instances} runtime=#{Mt5.config.runtime}"
