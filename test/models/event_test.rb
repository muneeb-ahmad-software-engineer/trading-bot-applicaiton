require "test_helper"

class EventTest < ActiveSupport::TestCase
  setup { @user = users(:verified) }

  test "records an action against a user and subject" do
    strategy = @user.strategies.create!(
      name: "g", grid_spacing_points: 150, grid_levels: 5,
      initial_lot: 0.01, max_positions: 10, max_exposure_lots: 0.5
    )

    event = Event.record("strategy.started", user: @user, subject: strategy,
                         metadata: { name: "g" }, ip_address: "1.2.3.4")

    assert_equal "strategy.started", event.action
    assert_equal strategy, event.subject
    assert_equal "g", event.metadata["name"]
    assert_equal "1.2.3.4", event.ip_address
    assert_not_nil event.occurred_at
  end

  test "an event cannot be edited or deleted once written" do
    event = Event.record("session.started", user: @user)

    assert_predicate event, :readonly?
    assert_raises(ActiveRecord::ReadOnlyRecord) { event.update!(action: "tampered") }
  end

  test "a failure to audit does not break the action being audited" do
    # An invalid source would normally raise. Recording must swallow it, because
    # a broken audit row should never roll back a user stopping their strategy.
    assert_nothing_raised do
      @event = Event.record("strategy.stopped", user: @user, source: "not-a-valid-source")
    end

    assert_nil @event
  end

  test "metadata is queryable, not an opaque blob" do
    Event.record("strategy.started", user: @user, metadata: { symbol: "XAUUSD", grid_levels: 5 })
    Event.record("strategy.started", user: @user, metadata: { symbol: "EURUSD", grid_levels: 3 })

    matching = Event.where("metadata @> ?", { symbol: "XAUUSD" }.to_json)

    assert_equal 1, matching.count
  end

  test "events can be filtered by action prefix" do
    Event.record("strategy.started", user: @user)
    Event.record("strategy.stopped", user: @user)
    Event.record("api_token.issued", user: @user)

    assert_equal 2, Event.for_action("strategy.").count
  end

  test "nil metadata values are dropped rather than stored" do
    event = Event.record("strategy.started", user: @user, metadata: { name: "g", missing: nil })

    assert_equal({ "name" => "g" }, event.metadata)
  end

  test "deleting a user still deletes their events despite readonly" do
    Event.record("session.started", user: @user)

    # Readonly records cannot be destroyed one by one, so the association uses
    # delete_all. Without that, account deletion raises.
    assert_difference "Event.count", -1 do
      assert_nothing_raised { @user.destroy }
    end
  end
end
