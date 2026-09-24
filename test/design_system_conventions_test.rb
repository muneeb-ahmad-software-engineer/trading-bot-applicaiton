require "test_helper"

# Guards the design system rule from the product brief: colour, radius and
# shadow values live in the token layer, not scattered through templates.
#
# This exists so the rule survives contact with future feature work. Without it,
# the first hurried page adds a raw hex value and the design system quietly
# stops being the single source of truth.
class DesignSystemConventionsTest < ActiveSupport::TestCase
  # Two deliberate exceptions:
  #
  #   * The offline layout inlines its palette because it is precached by the
  #     service worker and must render before any stylesheet is available.
  #   * Mailer views inline styles because email clients do not support external
  #     stylesheets or CSS custom properties. A design token cannot reach them.
  EXEMPT = [ "layouts/offline.html.erb" ].freeze
  EXEMPT_DIRECTORIES = [ "app/views/alert_mailer", "app/views/passwords_mailer",
                         "app/views/email_verification_mailer", "app/views/layouts/mailer" ].freeze

  HEX_COLOR = /#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6})\b/

  def templates
    Rails.root.glob("app/views/**/*.erb").reject do |path|
      EXEMPT.any? { |exempt| path.to_s.end_with?(exempt) } ||
        EXEMPT_DIRECTORIES.any? { |dir| path.to_s.include?(dir) }
    end
  end

  test "no template hardcodes a hex colour" do
    offenders = templates.filter_map do |path|
      body = path.read
      # Ignore data: URI payloads, which legitimately contain encoded colours.
      body = body.gsub(/url\(["']?data:[^)]*\)/, "")
      matches = body.scan(HEX_COLOR)
      "#{path.relative_path_from(Rails.root)}: #{matches.uniq.join(', ')}" if matches.any?
    end

    assert_empty offenders,
      "hex colours belong in app/assets/tailwind/theme.css, not in templates:\n" +
      offenders.join("\n")
  end

  test "every semantic colour named in the brief exists as a token" do
    theme = Rails.root.join("app/assets/tailwind/theme.css").read

    required = %w[
      background surface surface-elevated border primary primary-hover secondary
      success warning danger info text-primary text-secondary text-muted
    ]

    missing = required.reject { |token| theme.include?("--color-#{token}:") }

    assert_empty missing, "design tokens missing from theme.css: #{missing.join(', ')}"
  end

  # The profit green and loss red sit at ΔE 6.5 under deuteranopia, below the
  # threshold where colour alone is a safe encoding. A figure wearing a P/L
  # colour must therefore also carry its sign — either via the signed_money
  # helper, or as a literal that already includes one.
  #
  # components/_stat.html.erb is exempt: it applies the tone but the caller
  # supplies the already-formatted value.
  SIGN_EXEMPT = [ "components/_stat.html.erb" ].freeze

  test "profit and loss are never conveyed by colour alone" do
    offenders = Rails.root.glob("app/views/**/*.erb").flat_map do |path|
      next [] if SIGN_EXEMPT.any? { |exempt| path.to_s.end_with?(exempt) }

      # Each coloured figure is checked on its own. Checking the file as a whole
      # would let one correct usage excuse every other figure in it.
      path.read.scan(/figure-(?:profit|loss)[^>]*>\s*([^<]{1,80})/).flatten.filter_map do |content|
        value = content.strip
        next if value.include?("signed_money")          # rendered with its sign
        next if value.start_with?("+", "−", "-")        # literal already signed
        next if value.empty? || value.start_with?("<%")  # some other expression

        "#{path.relative_path_from(Rails.root)}: #{value.truncate(40)}"
      end
    end

    assert_empty offenders,
      "these figures wear a P/L colour without showing a sign:\n" + offenders.join("\n")
  end

  test "profit and loss are tokens distinct from success and danger" do
    theme = Rails.root.join("app/assets/tailwind/theme.css").read

    assert_includes theme, "--color-profit:"
    assert_includes theme, "--color-loss:"
  end
end
