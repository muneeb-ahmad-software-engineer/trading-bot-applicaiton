require "test_helper"

# Deleting an account.
#
# This is a legal obligation, and it breaks in a specific, easy-to-miss way:
# Rails destroys associations in the order they are declared, so a foreign key
# pointing at a table destroyed earlier aborts the whole deletion. It has
# happened twice in this codebase — once for terminal_connections referencing
# api_tokens, once for account_states referencing strategies.
#
# This test populates every association, so a new table with a foreign key
# cannot quietly reintroduce it.
class AccountDeletionTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email_address: "deleteme@example.com", password: "a-long-test-password")
    @user.verify!

    @strategy = @user.strategies.create!(
      name: "XAUUSD grid", grid_spacing_points: 150, grid_buy_orders: 5, grid_sell_orders: 5, basket_take_profit: 2,
      initial_lot: 0.01, max_positions: 10, max_exposure_lots: 0.5
    )
    @strategy.start!

    token = ApiToken.issue(user: @user, name: "MT5")
    TerminalConnection.create!(user: @user, api_token: token, strategy: @strategy, symbol: "XAUUSD",
                              last_report_at: Time.current)

    attributes = { strategy_id: @strategy.id, currency: "USD", balance: 10_000,
                   equity: 10_100, recorded_at: Time.current }
    AccountState.record(user: @user, attributes:)
    AccountSnapshot.create!(attributes.merge(user: @user))

    @strategy.positions.create!(ticket: "1", direction: "buy", volume: 0.01,
                               open_price: 2300, opened_at: Time.current)
    @strategy.orders.create!(ticket: "o1", order_type: "buy_limit", volume: 0.01,
                            price: 2280, placed_at: Time.current)

    @user.sessions.create!(ip_address: "1.1.1.1", user_agent: "test")
    @user.prepare_otp_secret!
    @user.enable_otp!
    RecoveryCode.regenerate_for(@user)
    Event.record("session.started", user: @user, subject: @strategy)
    Notification.create!(user: @user, alert_type: "terminal_stale", title: "t", body: "b",
                        dedup_key: "k", severity: "critical")
    PushSubscription.subscribe(user: @user, endpoint: "https://push.example/x",
                              p256dh_key: "k", auth_key: "a")
  end

  test "a fully populated account can be deleted" do
    assert_nothing_raised { @user.destroy! }
    assert_not User.exists?(@user.id)
  end

  test "deletion leaves nothing behind in any table" do
    id = @user.id
    @user.destroy!

    leftovers = {
      "sessions" => Session.where(user_id: id).count,
      "api_tokens" => ApiToken.where(user_id: id).count,
      "strategies" => Strategy.where(user_id: id).count,
      "terminal_connections" => TerminalConnection.where(user_id: id).count,
      "account_states" => AccountState.where(user_id: id).count,
      "account_snapshots" => AccountSnapshot.where(user_id: id).count,
      "recovery_codes" => RecoveryCode.where(user_id: id).count,
      "events" => Event.where(user_id: id).count,
      "notifications" => Notification.where(user_id: id).count,
      "push_subscriptions" => PushSubscription.where(user_id: id).count,
      "positions" => Position.where(strategy_id: @strategy.id).count,
      "orders" => Order.where(strategy_id: @strategy.id).count
    }

    assert_empty leftovers.reject { |_, count| count.zero? },
      "these rows outlived the account they belonged to"
  end

  test "every foreign key into a user-owned table is covered by an association" do
    # Catches a new table added with a foreign key but no dependent: option.
    connection = ActiveRecord::Base.connection
    owned = %w[users strategies api_tokens]

    unhandled = connection.tables.flat_map do |table|
      next [] if table.start_with?("solid_", "ar_internal", "schema_")

      connection.foreign_keys(table).filter_map do |fk|
        next unless owned.include?(fk.to_table)
        model = table.classify.safe_constantize
        next if model.nil?

        parent = fk.to_table.classify.safe_constantize
        next if parent.nil?

        covered = parent.reflect_on_all_associations.any? do |a|
          a.klass == model && a.options[:dependent].present?
        rescue StandardError
          false
        end

        "#{table}.#{fk.column} -> #{fk.to_table}" unless covered
      end
    end

    assert_empty unhandled,
      "these foreign keys have no association with a dependent: option, so deletion will fail:\n" +
      unhandled.join("\n")
  end
end
