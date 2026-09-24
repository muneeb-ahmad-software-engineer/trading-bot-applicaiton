require "tmpdir"

# Shared setup for execution-manager tests.
#
# Every test runs against a real directory tree in a temporary root and the
# simulated runtime, so provisioning, isolation and cleanup are exercised for
# real — only the last inch, spawning MetaTrader itself, is stood in for.
module Mt5Helpers
  def with_mt5_sandbox(**overrides)
    root = Dir.mktmpdir("mt5-test")
    Mt5::Runtime::Simulated.clear!

    Mt5.with_config(runtime: :simulated, instances_root: root, display_base: 100,
                    node_name: "test-node", max_instances: 10, report_seconds: 10,
                    idle_timeout: 15.minutes, **overrides) { yield root }
  ensure
    FileUtils.rm_rf(root)
    Mt5::Runtime::Simulated.clear!
  end

  def worker_node(**overrides)
    WorkerNode.create!({ name: "test-node", hostname: "127.0.0.1", status: "online",
                         max_instances: 10, last_heartbeat_at: Time.current }.merge(overrides))
  end

  def broker_credential_for(user)
    user.broker_credential || BrokerCredential.create!(
      user:, server: "Demo-Server", login: "500123", password: "s3cret-broker-password", demo: true
    )
  end

  def provision!(user, **options)
    broker_credential_for(user)
    result = Mt5::Provision.call(user:, **options)
    raise "provision failed: #{result.error_code} #{result.error_message}" if result.failure?

    result.payload
  end

  # Fails every prepare for the duration of the block. Injected by replacing the
  # method rather than by uuid, because the instance whose provision is meant to
  # fail does not exist until the provision that must fail has created it.
  def with_prepare_failing
    original = Mt5::Runtime::Simulated.instance_method(:prepare)
    Mt5::Runtime::Simulated.define_method(:prepare) do |instance, _context|
      failure("prepare_failed", "Injected prepare failure for #{instance.uuid}")
    end
    yield
  ensure
    Mt5::Runtime::Simulated.define_method(:prepare, original)
  end

  # Provisioned, started, and having reported in — the state a healthy terminal
  # spends almost all of its life in.
  def running_instance(user, **options)
    instance = provision!(user, **options)
    Mt5::Start.call(instance:)
    Mt5::RecordHeartbeat.call(api_token: instance.reload.api_token)
    instance.reload
  end
end
