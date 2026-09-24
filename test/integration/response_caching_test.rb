require "test_helper"

# What may be stored in a cache.
#
# An account page carries balances, positions, an email address and IP history.
# Rails' default "private, must-revalidate" still permits a cache to keep a
# copy — including the service worker and the back-forward cache — which would
# outlive the session and be readable by whoever holds the device next.
class ResponseCachingTest < ActionDispatch::IntegrationTest
  PASSWORD = "a-long-test-password".freeze

  ACCOUNT_PAGES = %w[/dashboard /settings /profile /activity /history
                     /notifications /settings/api-tokens /settings/notifications].freeze

  setup do
    @user = users(:verified)
    post login_path, params: { email_address: @user.email_address, password: PASSWORD }
  end

  test "every account page forbids storage" do
    ACCOUNT_PAGES.each do |path|
      get path

      assert_response :success, "#{path} did not render"
      assert_includes response.headers["Cache-Control"].to_s, "no-store",
        "#{path} may be stored in a cache while it renders account data"
    end
  end

  test "a signed-out visitor's public pages are not marked no-store" do
    delete logout_path

    get root_path

    assert_response :success
    assert_not_includes response.headers["Cache-Control"].to_s, "no-store",
      "the public landing page is cacheable and should stay so"
  end

  test "the login page is cacheable before a session exists" do
    delete logout_path

    get login_path

    assert_not_includes response.headers["Cache-Control"].to_s, "no-store"
  end

  test "API responses for a token holder also forbid storage" do
    token = ApiToken.issue(user: @user, name: "MT5").plaintext_token

    get "/api/v1/profile", headers: { "Authorization" => "Bearer #{token}" }

    assert_response :success
    # ActionController::API sets no caching directives of its own; an
    # intermediary must not be free to keep account JSON.
    assert_no_match(/public/, response.headers["Cache-Control"].to_s)
  end
end

# The service worker decides what is written to Cache Storage on the device.
class ServiceWorkerCachingTest < ActionDispatch::IntegrationTest
  setup { get pwa_service_worker_path(format: :js) }

  test "only explicitly public pages may be cached" do
    assert_match(/CACHEABLE_PAGES/, response.body)

    allowlist = response.body[/const CACHEABLE_PAGES = \[(.*?)\]/m, 1].to_s

    %w[dashboard settings history activity notifications api-tokens].each do |path|
      assert_no_match(/#{path}/, allowlist, "#{path} renders account data and must not be cacheable")
    end
  end

  test "a no-store response is never written to the cache" do
    assert_match(/no-store/, response.body,
      "the worker must honour no-store so a page that becomes account-specific is never stored")
  end

  test "API responses are never cached" do
    assert_match(%r{url\.pathname\.startsWith\("/api/"\)}, response.body)
  end
end
