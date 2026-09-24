require "test_helper"

# The product brief forbids profitability claims, guaranteed returns, invented
# performance figures and security claims for things that are not built.
#
# These are the rules most likely to be broken accidentally by future copy
# edits, and the ones with real consequences for a financial product, so they
# are asserted rather than left to review.
class MarketingClaimsTest < ActionDispatch::IntegrationTest
  setup do
    get root_path
    @text = css_select("body").text.gsub(/\s+/, " ")
  end

  FORBIDDEN = [
    /guaranteed (?:profit|return|income)/i,
    # Forbids asserting that trading IS risk-free, while still allowing the FAQ
    # question "Is trading risk-free?" which the brief requires us to ask.
    /risk[- ]free(?!\?)/i,
    /\bno risk\b/i,
    /can'?t lose|cannot lose/i,
    /passive income/i,
    /\bprofitable\b(?! by design)/i,
    /win rate/i,
    /\d+\s*% (?:monthly|weekly|daily|annual) (?:return|profit|gain)/i
  ].freeze

  test "makes no profitability or guaranteed-return claim" do
    offenders = FORBIDDEN.select { |pattern| @text.match?(pattern) }

    assert_empty offenders.map(&:source),
      "landing page copy matched forbidden marketing claims: #{offenders.map(&:source).join(', ')}"
  end

  test "states plainly that trading is not risk-free" do
    assert_match(/is trading risk-free\?/i, @text)
    # The answer to that question must actually be no.
    answer = @text[/is trading risk-free\?\s*(.{0,120})/i, 1]
    assert_match(/\ANo\b/i, answer.to_s.strip,
      "the risk-free FAQ answer must begin with a clear No, got: #{answer.inspect}")
  end

  test "carries a risk warning in the footer" do
    # Normalised: the copy wraps across lines, so raw text has newlines mid-phrase.
    footer = css_select("footer").text.gsub(/\s+/, " ")

    assert_match(/risk of loss/i, footer)
    assert_match(/not financial advice|nothing on this site is financial advice/i, footer)
  end

  test "risk controls are never described as removing risk" do
    assert_match(/do not eliminate risk|do not remove the risk|cannot remove market risk/i, @text)
  end

  test "dashboard preview is labelled as an interface example, not results" do
    assert_match(/interface example/i, @text)
    assert_match(/not (?:real )?trading results|not real trades/i, @text)
  end

  test "security section does not claim protections that are not implemented" do
    security = css_select("section[aria-labelledby='security-heading']").text

    # It must always disclose what is *not* built, so the section describes the
    # current state rather than an intended one.
    assert_match(/not built yet|not available yet|in development/i, security)

    # And must not assert delivered protections.
    [ /your data is (?:encrypted|secure)/i, /bank[- ]grade/i, /fully secure/i,
      /we protect your/i ].each do |claim|
      refute_match claim, security, "security section makes an unimplemented claim: #{claim.source}"
    end
  end
end
