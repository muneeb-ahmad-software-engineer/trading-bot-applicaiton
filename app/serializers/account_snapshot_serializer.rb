class AccountSnapshotSerializer < ApplicationSerializer
  def as_json(*)
    {
      currency: object.currency,
      balance: money(object.balance),
      equity: money(object.equity),
      margin: money(object.margin),
      free_margin: money(object.free_margin),
      margin_level_percent: percent(object.margin_level_percent),
      recorded_at: timestamp(object.recorded_at)
    }
  end
end
