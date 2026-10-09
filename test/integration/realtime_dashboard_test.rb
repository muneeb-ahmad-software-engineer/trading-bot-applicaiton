require "test_helper"

# Live dashboard updates.
class RealtimeDashboardTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  PASSWORD = "a-long-test-password".freeze

  VALID = {
    name: "XAUUSD grid", direction: "both", grid_spacing_points: 150, grid_buy_orders: 5, grid_sell_orders: 5, basket_take_profit: 2,
    initial_lot: 0.01, max_positions: 10, max_exposure_lots: 0.5
  }.freeze

  setup do
    @user = users(:verified)
    @strategy = @user.strategies.create!(VALID)
    @strategy.start!
    @token = ApiToken.issue(user: @user, name: "MT5").plaintext_token
  end

  def report(**overrides)
    payload = {
      strategy_id: @strategy.id,
      terminal: { ea_version: "1.0", broker: "Demo", symbol: "XAUUSD" },
      tick: { bid: "2318.40", ask: "2318.45", spread_points: 5 },
      account: { currency: "USD", balance: "10000.00", equity: "10100.00" },
      positions: [ { ticket: "1", direction: "buy", volume: "0.01", open_price: "2300",
                     current_price: "2318.40", profit: "18.40", opened_at: 1.hour.ago.iso8601 } ]
    }.deep_merge(overrides)

    post "/api/v1/trading/report", params: payload,
         headers: { "Authorization" => "Bearer #{@token}" }, as: :json
  end

  test "the dashboard subscribes to a signed, account-scoped stream" do
    post login_path, params: { email_address: @user.email_address, password: PASSWORD }
    get dashboard_path

    assert_response :success
    # Turbo signs the stream name, so the raw user id must not be guessable
    # from the markup and another account cannot subscribe to this stream.
    assert_select "turbo-cable-stream-source[signed-stream-name]", count: 1

    signed = css_select("turbo-cable-stream-source").first["signed-stream-name"]

    assert_equal Turbo::StreamsChannel.signed_stream_name([ @user, :dashboard ]), signed,
      "the page must subscribe to this account's dashboard stream"

    # And crucially, not to anyone else's.
    assert_not_equal Turbo::StreamsChannel.signed_stream_name([ users(:unverified), :dashboard ]), signed
  end

  test "one account cannot subscribe to another's dashboard stream" do
    mine = Turbo::StreamsChannel.signed_stream_name([ @user, :dashboard ])
    theirs = Turbo::StreamsChannel.signed_stream_name([ users(:unverified), :dashboard ])

    # The names are signed, so a stream name cannot be forged by editing markup.
    assert_not_equal mine, theirs
    assert_nil Turbo::StreamsChannel.verified_stream_name("#{mine}-tampered")
  end

  test "a terminal report enqueues a dashboard broadcast" do
    # The dashboard's live region and the sidebar's connection badge.
    assert_enqueued_jobs 2, only: Turbo::Streams::ActionBroadcastJob do
      report
    end
  end

  test "every report refreshes the sidebar badge, so an open page does not go stale on its own" do
    perform_enqueued_jobs { report }

    html = ApplicationController.render(partial: "shared/connection_badge", locals: { user: @user })

    # The broadcast target, carrying the NEW report's time: the browser's
    # freshness timer restarts from it instead of from the page load.
    assert_match(/id="sidebar-connection-status"/, html)
    assert_match(/data-connection-freshness-last-report-value="#{Regexp.escape(@user.terminal_connections.sole.last_report_at.utc.iso8601)}"/, html)
    assert_match(/MT5 connected/, html)
  end

  test "every signed-in page subscribes to the account stream, not only the dashboard" do
    post login_path, params: { email_address: @user.email_address, password: PASSWORD }
    get strategies_path

    assert_response :success
    signed = css_select("turbo-cable-stream-source").map { |e| e["signed-stream-name"] }
    assert_includes signed, Turbo::StreamsChannel.signed_stream_name([ @user, :dashboard ])
    assert_select "#sidebar-connection-status", count: 1
  end

  test "a report refreshes its strategy's page, and that page subscribes and morphs" do
    refreshed = []
    stubbing(Turbo::StreamsChannel, :broadcast_refresh_later_to, ->(*streamables, **) { refreshed << streamables }) do
      report
    end
    assert_equal [ [ @strategy, :live ] ], refreshed

    post login_path, params: { email_address: @user.email_address, password: PASSWORD }
    get strategy_path(@strategy)

    signed = css_select("turbo-cable-stream-source").map { |e| e["signed-stream-name"] }
    assert_includes signed, Turbo::StreamsChannel.signed_stream_name([ @strategy, :live ])
    assert_select "meta[name='turbo-refresh-method'][content='morph']", count: 1
    assert_select "meta[name='turbo-refresh-scroll'][content='preserve']", count: 1
  end

  test "the broadcast targets the live region and renders current figures" do
    perform_enqueued_jobs { report }

    # Rendering the same partial the broadcast uses must reflect the new report.
    html = ApplicationController.render(partial: "dashboard/live", locals: { user: @user })

    assert_match(/dashboard-live/, html)
    assert_match(/2318.4/, html)
    assert_match(/\+18\.40/, html, "P/L must carry its sign in the broadcast too")
  end

  test "a rejected report broadcasts nothing" do
    theirs = users(:unverified).strategies.create!(VALID)

    assert_no_enqueued_jobs only: Turbo::Streams::ActionBroadcastJob do
      post "/api/v1/trading/report", params: { strategy_id: theirs.id },
           headers: { "Authorization" => "Bearer #{@token}" }, as: :json
    end
  end

  test "a broadcast failure never fails the terminal's report" do
    channel = Turbo::StreamsChannel.singleton_class
    original = Turbo::StreamsChannel.method(:broadcast_replace_later_to)
    channel.define_method(:broadcast_replace_later_to) { |*| raise "cable down" }

    begin
      report
    ensure
      channel.define_method(:broadcast_replace_later_to, original)
    end

    # Ingesting trading data must not depend on a browser being reachable.
    assert_response :accepted
    assert_equal 1, @strategy.positions.open.count
  end

  test "one failing broadcast does not stop the others" do
    refreshed = []
    stubbing(Turbo::StreamsChannel, :broadcast_replace_later_to, ->(*, **) { raise "queue down" }) do
      stubbing(Turbo::StreamsChannel, :broadcast_refresh_later_to, ->(*streamables, **) { refreshed << streamables }) do
        report
      end
    end

    assert_response :accepted
    assert_equal [ [ @strategy, :live ] ], refreshed, "the strategy page must still refresh"
  end

  test "the page carries what the browser needs to detect its own staleness" do
    post login_path, params: { email_address: @user.email_address, password: PASSWORD }
    perform_enqueued_jobs { report }
    get dashboard_path

    assert_select "[data-controller='connection-freshness']" do |elements|
      element = elements.first
      assert element["data-connection-freshness-last-report-value"].present?,
        "without a timestamp the page cannot notice that updates stopped"
      assert_equal TerminalConnection::STALE_AFTER.to_i.to_s,
                   element["data-connection-freshness-stale-after-value"]
    end
  end

  test "the controller and the broadcast render the same figures" do
    post login_path, params: { email_address: @user.email_address, password: PASSWORD }
    report
    get dashboard_path

    broadcast_html = ApplicationController.render(partial: "dashboard/live", locals: { user: @user })

    # Both go through DashboardSnapshot; if they diverged, a watched page would
    # stop matching what a reload produces.
    assert_equal broadcast_html.scan(/2318\.4/).size, response.body.scan(/2318\.4/).size
  end
end
