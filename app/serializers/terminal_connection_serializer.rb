class TerminalConnectionSerializer < ApplicationSerializer
  # A nil connection is a real state — "no terminal has ever reported" — and is
  # different from a connected terminal with nothing to say.
  def self.for(connection)
    return { status: "never_connected" } if connection.nil?

    new(connection).as_json
  end

  def as_json(*)
    {
      status: object.status,
      symbol: object.symbol,
      broker: object.broker,
      ea_version: object.ea_version,
      bid: price(object.bid),
      ask: price(object.ask),
      spread_points: object.spread_points_or_derived,
      last_report_at: timestamp(object.last_report_at)
    }
  end
end
