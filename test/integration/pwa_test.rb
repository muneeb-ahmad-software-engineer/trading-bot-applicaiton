require "test_helper"

class PwaTest < ActionDispatch::IntegrationTest
  test "serves the web app manifest as JSON" do
    get pwa_manifest_path(format: :json)

    assert_response :success
    assert_equal "application/json", response.media_type

    manifest = JSON.parse(response.body)
    product = Rails.application.config.x.product

    assert_equal product.name, manifest["short_name"]
    assert_equal "standalone", manifest["display"]
    assert_equal "/", manifest["start_url"]
    assert_equal product.theme_color, manifest["theme_color"]
  end

  test "manifest advertises both a regular and a maskable icon" do
    get pwa_manifest_path(format: :json)

    purposes = JSON.parse(response.body).fetch("icons").map { |icon| icon["purpose"] }

    assert_includes purposes, "any"
    assert_includes purposes, "maskable"
  end

  test "every icon referenced by the manifest exists on disk" do
    get pwa_manifest_path(format: :json)

    JSON.parse(response.body).fetch("icons").each do |icon|
      path = Rails.public_path.join(icon.fetch("src").delete_prefix("/"))
      assert path.exist?, "manifest references missing icon #{icon['src']}"
    end
  end

  test "serves the service worker as JavaScript" do
    get pwa_service_worker_path(format: :js)

    assert_response :success
    assert_equal "text/javascript", response.media_type
  end

  test "service worker never caches API responses" do
    get pwa_service_worker_path(format: :js)

    assert_match %r{url\.pathname\.startsWith\("/api/"\)}, response.body,
      "the service worker must bypass the cache for /api/ so stale trading data is never shown"
  end

  test "offline page renders standalone and states that trading needs a connection" do
    get offline_path

    assert_response :success
    assert_select "title", /Offline/
    assert_select "h1", "You are offline"
    assert_match(/live internet connection/i, response.body)
  end

  test "offline page is excluded from search indexing" do
    get offline_path

    assert_select "meta[name=robots][content=noindex]", count: 1
  end
end
