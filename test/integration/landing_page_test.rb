require "test_helper"

class LandingPageTest < ActionDispatch::IntegrationTest
  setup { get root_path }

  test "renders successfully with every required section" do
    assert_response :success

    %w[how-it-works features risk-management faq].each do |section|
      assert_select "section##{section}", count: 1, message: "missing ##{section} section"
    end

    assert_select "h1", /Automate your XAUUSD strategy/i
  end

  test "navigation links resolve to real routes" do
    assert_select "a[href=?]", login_path
    assert_select "a[href=?]", signup_path

    # Anchor targets in the nav must exist on the page.
    css_select("nav a[href^='#']").each do |link|
      id = link[:href].delete_prefix("#")
      assert_select "##{id}", count: 1, message: "nav links to ##{id} but no such element exists"
    end
  end

  test "carries SEO and social metadata" do
    assert_select "title", /GoldGrid/
    assert_select "link[rel=canonical][href=?]", root_url
    assert_select "meta[property='og:title']"
    assert_select "meta[property='og:image']"
    assert_select "meta[name='twitter:card'][content=?]", "summary_large_image"

    description = css_select("meta[name=description]").first[:content]
    assert description.length.between?(50, 320), "meta description length #{description.length} is outside the useful range"
  end

  test "has one h1 and a landmark structure" do
    assert_select "h1", count: 1
    assert_select "main#main", count: 1
    assert_select "header.navbar", count: 1
    assert_select "footer", count: 1
    assert_select "a.skip-link[href='#main']", count: 1
  end

  test "mobile menu toggle is wired to the panel it controls" do
    toggle = css_select("button.nav-toggle").first

    assert_equal "false", toggle[:"aria-expanded"]
    assert_equal "mobile-menu", toggle[:"aria-controls"]
    assert_select "##{toggle[:'aria-controls']}", count: 1
  end

  test "every image and svg is either labelled or explicitly decorative" do
    css_select("main img, header img, footer img").each do |img|
      labelled = img[:alt].present? || img[:"aria-hidden"] == "true"
      assert labelled, "image #{img[:src]} has neither alt text nor aria-hidden"
    end
  end
end
