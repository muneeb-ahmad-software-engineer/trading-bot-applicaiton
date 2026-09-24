require "test_helper"

# P/L presentation.
#
# The rule under test: profit and loss must be distinguishable without colour.
# The profit green and loss red measure ΔE 6.5 under deuteranopia — below the
# threshold at which colour alone is a safe encoding — so the sign carries the
# meaning and the colour only reinforces it.
class TradingHelperTest < ActionView::TestCase
  include TradingHelper

  test "a gain is signed, not just coloured" do
    assert_equal "+82.50", signed_money(BigDecimal("82.50"))
  end

  test "a loss is signed with a true minus sign" do
    # U+2212, which aligns with digits in tabular figures.
    assert_equal "−9.15", signed_money(BigDecimal("-9.15"))
  end

  test "zero reads as neither profit nor loss" do
    assert_equal "+0.00", signed_money(BigDecimal("0"))
    assert_equal "figure-flat", profit_tone(BigDecimal("0"))
    assert_equal "no change", profit_label(BigDecimal("0"))
  end

  test "missing data is not rendered as zero" do
    # "no data" and "flat" are different facts about money.
    assert_equal "—", signed_money(nil)
  end

  test "large values keep thousands separators" do
    assert_equal "+1,234.56", signed_money(BigDecimal("1234.56"))
  end

  test "tone and spoken label agree with the sign" do
    assert_equal "figure-profit", profit_tone(BigDecimal("1"))
    assert_equal "profit", profit_label(BigDecimal("1"))
    assert_equal "figure-loss", profit_tone(BigDecimal("-1"))
    assert_equal "loss", profit_label(BigDecimal("-1"))
  end

  test "utilisation is a percentage of the limit, capped at 100" do
    assert_equal 50.0, utilisation_percent(5, 10)
    assert_equal 100.0, utilisation_percent(15, 10), "over-limit must not overflow the meter"
    assert_equal 0, utilisation_percent(5, 0), "an absent limit is not a division"
    assert_equal 0, utilisation_percent(5, nil)
  end

  test "every utilisation status carries a word, not only a colour" do
    [ 0, 50, 69.9, 70, 89.9, 90, 100 ].each do |percent|
      status = utilisation_status(percent)

      assert status[:label].present?, "#{percent}% produced no status word"
      assert_includes %w[success warning danger], status[:tone]
    end

    assert_equal "Within limit", utilisation_status(50)[:label]
    assert_equal "Approaching limit", utilisation_status(75)[:label]
    assert_equal "At limit", utilisation_status(95)[:label]
  end
end
