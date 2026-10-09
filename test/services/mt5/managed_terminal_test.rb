require "test_helper"

# Starting a strategy is supposed to result in something that can actually
# trade. These tests are about the join between the control plane and the
# execution layer — the part that, if it silently does nothing, leaves a user
# looking at a green "running" badge while no terminal exists anywhere.
class ManagedTerminalTest < ActiveSupport::TestCase
  VALID = {
    name: "XAUUSD grid", direction: "both",
    grid_spacing_points: 150, grid_buy_orders: 5, grid_sell_orders: 5, basket_take_profit: 2,
    initial_lot: 0.01,
    max_positions: 10, max_exposure_lots: 0.5
  }.freeze

  setup do
    @user = users(:verified)
    @other = User.create!(email_address: "second@example.com",
                          password: "another-long-test-password", verified_at: Time.current)
  end

  def strategy_for(user, **overrides)
    user.strategies.create!(VALID.merge(overrides))
  end

  # ------------------------------------------------- Starting brings a terminal up

  test "starting a strategy provisions and starts a terminal for the user" do
    with_mt5_sandbox do
      worker_node
      broker_credential_for(@user)
      strategy = strategy_for(@user)

      result = Strategies::Start.call(strategy:, actor: @user)

      assert_predicate result, :success?
      instance = @user.mt5_instances.sole
      assert_equal strategy.id, instance.strategy_id
      assert_predicate instance, :connecting?, "a started terminal waits for its EA to report in"
      assert_equal "running", instance.desired_state
    end
  end

  test "the audit trail names the terminal the strategy was started on" do
    with_mt5_sandbox do
      worker_node
      broker_credential_for(@user)

      Strategies::Start.call(strategy: strategy_for(@user), actor: @user)

      event = @user.events.where(action: "strategy.started").sole
      assert_equal @user.mt5_instances.sole.uuid, event.metadata["terminal"]
    end
  end

  # A user running MetaTrader themselves has no broker credentials here, and the
  # platform has nothing to sign in with. That must remain a supported way to
  # use the product, not an accident that happens to work.
  test "a user without broker credentials starts a strategy without a terminal" do
    with_mt5_sandbox do
      worker_node
      strategy = strategy_for(@user)

      result = Strategies::Start.call(strategy:, actor: @user)

      assert_predicate result, :success?
      assert_predicate strategy.reload, :running?
      assert_empty @user.mt5_instances
    end
  end

  # ------------------------------------------------------------ Failure to start

  test "a strategy is not left running when its terminal cannot be started" do
    with_mt5_sandbox do
      worker_node
      broker_credential_for(@user)
      strategy = strategy_for(@user)

      result = with_prepare_failing { Strategies::Start.call(strategy:, actor: @user) }

      assert_predicate result, :failure?
      assert_not strategy.reload.running?,
        "a strategy showing as running with no terminal is the worst possible outcome"
    end
  end

  test "a failed start explains itself and records nothing in the audit trail" do
    with_mt5_sandbox do
      worker_node
      broker_credential_for(@user)

      assert_no_difference -> { @user.events.where(action: "strategy.started").count } do
        result = with_prepare_failing { Strategies::Start.call(strategy: strategy_for(@user), actor: @user) }

        assert_match(/was not started/, result.error_message)
      end
    end
  end

  test "a strategy cannot be started when no node has capacity" do
    with_mt5_sandbox do
      worker_node(max_instances: 0)
      broker_credential_for(@user)
      strategy = strategy_for(@user)

      result = Strategies::Start.call(strategy:, actor: @user)

      assert_equal "no_capacity", result.error_code
      assert_not strategy.reload.running?
    end
  end

  # ------------------------------------------------------------- Reconfiguration

  # The EA reads its strategy id once, at startup. A terminal that survives from
  # one strategy to the next therefore has to be rewritten and restarted, or it
  # keeps trading the strategy the user just stopped.
  test "switching strategies repoints the existing terminal rather than building a second" do
    with_mt5_sandbox do
      worker_node
      broker_credential_for(@user)

      first = strategy_for(@user)
      Strategies::Start.call(strategy: first, actor: @user)
      instance = @user.mt5_instances.sole
      Strategies::Stop.call(strategy: first, actor: @user)

      second = strategy_for(@user, name: "Tighter grid")
      assert_predicate Strategies::Start.call(strategy: second, actor: @user), :success?

      assert_equal 1, @user.mt5_instances.count, "a second terminal would sign in to the same broker account twice"
      assert_equal second.id, instance.reload.strategy_id
      assert_match "InpStrategyId=#{second.id}",
        File.read(instance.ea_preset)
    end
  end

  test "reconfiguring issues a fresh token and revokes the one written to disk before it" do
    with_mt5_sandbox do
      worker_node
      broker_credential_for(@user)

      first = strategy_for(@user)
      Strategies::Start.call(strategy: first, actor: @user)
      instance = @user.mt5_instances.sole
      old_token = instance.api_token

      Mt5::Reconfigure.call(instance:, strategy: strategy_for(@user, name: "Other"))

      assert_not_predicate old_token.reload, :active?
      assert_not_equal old_token.id, instance.reload.api_token_id
    end
  end

  test "reconfiguring a live terminal restarts it so the EA rereads its inputs" do
    with_mt5_sandbox do
      worker_node
      broker_credential_for(@user)
      instance = running_instance(@user, strategy: strategy_for(@user))

      Mt5::Reconfigure.call(instance:, strategy: strategy_for(@user, name: "Other"))

      assert_equal 1, instance.reload.restart_count
    end
  end

  test "reconfiguring a stopped terminal leaves it stopped" do
    with_mt5_sandbox do
      worker_node
      broker_credential_for(@user)
      instance = provision!(@user, strategy: strategy_for(@user))

      Mt5::Reconfigure.call(instance:, strategy: strategy_for(@user, name: "Other"))

      assert_predicate instance.reload, :stopped?
      assert_equal 0, instance.restart_count
    end
  end

  test "reconfiguring to the same strategy changes nothing" do
    with_mt5_sandbox do
      worker_node
      broker_credential_for(@user)
      strategy = strategy_for(@user)
      instance = running_instance(@user, strategy:)
      token = instance.api_token

      Mt5::Reconfigure.call(instance:, strategy:)

      assert_equal token.id, instance.reload.api_token_id
      assert_equal 0, instance.restart_count
    end
  end

  # ------------------------------------------------------- Two users in parallel

  test "two users each get their own terminal from their own strategy" do
    with_mt5_sandbox do
      worker_node
      [ @user, @other ].each { broker_credential_for(_1) }

      [ @user, @other ].each { Strategies::Start.call(strategy: strategy_for(_1), actor: _1) }

      instances = Mt5Instance.not_terminated.to_a
      assert_equal 2, instances.size
      assert_equal 2, instances.map(&:display_number).uniq.size
      assert_equal 2, instances.map(&:magic_number).uniq.size
      assert_equal 2, instances.map(&:instance_dir).uniq.size
      assert_equal 2, instances.map(&:api_token_id).uniq.size
    end
  end

  # Placement reads which displays are free and then creates a row using one.
  # Between those two steps another user can take it, and the unique index —
  # not the Ruby above it — is what keeps the two apart. Reproduced here by
  # handing out a display that is already taken, because a real thread race
  # would pass whether or not the retry existed.
  test "a provision that loses a placement race retries instead of reporting a conflict" do
    with_mt5_sandbox do
      worker_node
      broker_credential_for(@user)
      broker_credential_for(@other)

      taken = provision!(@other)

      result = with_stale_placement(taken.display_number) { Mt5::Provision.call(user: @user) }

      assert_predicate result, :success?,
        "losing a display race is not the same as this user already having a terminal"
      assert_not_equal taken.display_number, result.payload.display_number
    end
  end

  test "a reconfigured terminal is left holding a token it can actually authenticate with" do
    with_mt5_sandbox do
      worker_node
      broker_credential_for(@user)
      instance = running_instance(@user, strategy: strategy_for(@user))

      Mt5::Reconfigure.call(instance:, strategy: strategy_for(@user, name: "Other"))

      assert_predicate instance.reload.api_token, :active?
    end
  end

  # A node rebuilt from an image, or a disk cleaned out by hand, leaves the row
  # saying a terminal exists and nothing on disk. Without a repair, every start
  # from then on fails and the only cure is deleting the row by hand.
  test "a terminal whose directory has vanished is rebuilt rather than stuck" do
    with_mt5_sandbox do
      worker_node
      broker_credential_for(@user)
      strategy = strategy_for(@user)
      Strategies::Start.call(strategy:, actor: @user)

      instance = @user.mt5_instances.sole
      FileUtils.rm_rf(instance.instance_dir)
      Mt5::Stop.call(instance:)
      Strategies::Stop.call(strategy:, actor: @user)

      result = Strategies::Start.call(strategy:, actor: @user)

      assert_predicate result, :success?, result.error_message
      assert File.exist?(instance.reload.ea_preset), "the terminal's inputs should have been written again"
    end
  end

  # --------------------------------------------------- Credential verification

  test "a terminal reporting in verifies the broker details it signed in with" do
    with_mt5_sandbox do
      worker_node
      credential = broker_credential_for(@user)
      assert_not_predicate credential, :verified?

      running_instance(@user, strategy: strategy_for(@user))

      assert_predicate credential.reload, :verified?
    end
  end

  test "a terminal that never reports in records why against the broker details" do
    with_mt5_sandbox do
      worker_node
      credential = broker_credential_for(@user)
      instance = provision!(@user, strategy: strategy_for(@user))
      Mt5::Start.call(instance:)

      # Started, but the EA never called in.
      instance.reload.update!(last_transition_at: (Mt5Instance::CONNECT_TIMEOUT + 1.minute).ago)
      Mt5::Reconcile.call(instance:)

      assert_match(/never reported back/, credential.reload.last_verification_error)
    end
  end

  private

  # Makes the next placement hand out a display that was free when Placement
  # looked and is not free any more.
  def with_stale_placement(display_number)
    original = Mt5::Placement.instance_method(:allocate_display)
    calls = 0
    Mt5::Placement.define_method(:allocate_display) do |node|
      calls += 1
      calls == 1 ? display_number : original.bind(self).call(node)
    end
    yield
  ensure
    Mt5::Placement.define_method(:allocate_display, original)
  end
end
