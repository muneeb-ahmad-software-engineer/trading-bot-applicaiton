module TradingHelper
  # Profit and loss figures.
  #
  # The sign is always shown, including the "+" on a gain. This is an
  # accessibility requirement, not a stylistic one: the profit green (#34D399)
  # and loss red (#F87171) sit at ΔE 6.5 under deuteranopia, which is below the
  # threshold at which colour alone is a safe encoding. Roughly one man in
  # twelve has red-green colour vision deficiency, and "am I up or down?" is not
  # a question this interface may answer in colour only.
  #
  # The sign carries the meaning; the colour reinforces it.
  def signed_money(value, precision: 2)
    return "—" if value.nil?

    amount = value.to_d
    sign = amount.negative? ? "−" : "+"   # U+2212 minus, which aligns with digits

    "#{sign}#{number_with_precision(amount.abs, precision:, delimiter: ',')}"
  end

  # Tone token for a P/L figure. Always paired with signed_money, never used to
  # convey the sign on its own.
  def profit_tone(value)
    return "figure-flat" if value.nil? || value.to_d.zero?

    value.to_d.positive? ? "figure-profit" : "figure-loss"
  end

  # A screen-reader-only word so the direction is spoken, not just punctuated.
  def profit_label(value)
    return "no change" if value.nil? || value.to_d.zero?

    value.to_d.positive? ? "profit" : "loss"
  end

  # Points restated as the dollar distance the user was thinking in.
  #
  # Every price distance on a strategy is stored in points because that is what
  # the terminal works in, but nobody sets a "200 point" loss margin — they set
  # a $2 one. Showing both removes an arithmetic step the user would otherwise
  # do in their head, wrongly, once.
  def points_as_price_hint(points)
    price = Strategy.points_to_price(points)
    return "" if price.nil?

    "That is $#{number_with_precision(price, precision: 2)} on gold."
  end

  # Utilisation of a configured limit, as a percentage capped at 100.
  def utilisation_percent(used, limit)
    return 0 if limit.nil? || limit.to_d <= 0

    ((used.to_d / limit.to_d) * 100).clamp(0, 100).to_f.round(1)
  end

  # Status of a limit, as a token *and* a word. Status is never conveyed by
  # colour alone — the word is always rendered beside the meter.
  def utilisation_status(percent)
    case percent
    when 0...70  then { tone: "success", label: "Within limit" }
    when 70...90 then { tone: "warning", label: "Approaching limit" }
    else              { tone: "danger",  label: "At limit" }
    end
  end
end
