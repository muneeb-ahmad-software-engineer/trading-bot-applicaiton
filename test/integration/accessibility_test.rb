require "test_helper"

# Structural accessibility.
#
# These are the rules that break silently: a heading level skipped, a label
# pointing at an id that does not exist, an aria-describedby referencing nothing.
# Nothing looks wrong on screen, and the page becomes hard to navigate for
# anyone using a screen reader.
class AccessibilityTest < ActionDispatch::IntegrationTest
  PASSWORD = "a-long-test-password".freeze

  VALID = {
    name: "XAUUSD grid", direction: "both", grid_spacing_points: 150, grid_buy_orders: 5, grid_sell_orders: 5, basket_take_profit: 2,
    initial_lot: 0.01, max_positions: 10, max_exposure_lots: 0.5
  }.freeze

  setup do
    @user = users(:verified)
    @strategy = @user.strategies.create!(VALID)
    post login_path, params: { email_address: @user.email_address, password: PASSWORD }
  end

  def pages
    { "dashboard" => dashboard_path, "strategies" => strategies_path,
      "new strategy" => new_strategy_path, "strategy" => strategy_path(@strategy),
      "history" => trading_history_path, "settings" => settings_path,
      "notifications" => notification_settings_path, "api tokens" => api_tokens_path,
      "alerts" => notifications_path, "activity" => activity_path, "profile" => profile_path }
  end

  test "every page has exactly one h1" do
    pages.each do |name, path|
      get path
      assert_select "h1", count: 1, message: "#{name} should have exactly one h1"
    end
  end

  test "no page skips a heading level" do
    pages.each do |name, path|
      get path

      levels = css_select("h1,h2,h3,h4,h5,h6").map { _1.name[1].to_i }
      levels.each_cons(2) do |previous, current|
        assert current <= previous + 1,
          "#{name} jumps from h#{previous} to h#{current}, which breaks the outline"
      end
    end
  end

  test "every form control has an accessible name" do
    pages.each do |name, path|
      get path

      controls = css_select("input, select, textarea").reject do |el|
        %w[hidden submit button reset].include?(el["type"])
      end

      controls.each do |control|
        labelled = control["aria-label"].present? ||
                   control["aria-labelledby"].present? ||
                   (control["id"].present? && css_select("label[for='#{control['id']}']").any?)

        assert labelled, "#{name}: #{control.name}[name=#{control['name']}] has no accessible name"
      end
    end
  end

  test "aria references always point at an element that exists" do
    pages.each do |name, path|
      get path

      css_select("[aria-labelledby], [aria-describedby]").each do |el|
        %w[aria-labelledby aria-describedby].each do |attribute|
          el[attribute].to_s.split.each do |id|
            assert css_select("##{id}").any?,
              "#{name}: #{attribute}=\"#{id}\" points at nothing"
          end
        end
      end
    end
  end

  test "no page renders a duplicate id" do
    pages.each do |name, path|
      get path

      ids = css_select("[id]").map { _1["id"] }
      duplicates = ids.tally.select { |_, count| count > 1 }.keys

      assert_empty duplicates, "#{name} renders duplicate ids: #{duplicates.join(', ')}"
    end
  end

  test "every page declares a language and a main landmark" do
    pages.each do |name, path|
      get path

      assert_select "html[lang]", count: 1, message: "#{name} has no lang attribute"
      assert_select "main#main", count: 1, message: "#{name} has no main landmark"
    end
  end

  test "images are either described or marked decorative" do
    pages.each do |name, path|
      get path

      css_select("img").each do |img|
        described = img["alt"].present? || img["aria-hidden"] == "true"
        assert described, "#{name}: image #{img['src']} is neither described nor decorative"
      end
    end
  end
end
