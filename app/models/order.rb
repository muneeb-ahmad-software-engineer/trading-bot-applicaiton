# A pending order resting with the broker, as reported by the terminal.
class Order < ApplicationRecord
  TYPES = %w[buy_limit sell_limit buy_stop sell_stop].freeze
  STATUSES = %w[pending filled cancelled].freeze

  belongs_to :strategy

  validates :ticket, presence: true, uniqueness: { scope: :strategy_id }
  validates :order_type, inclusion: { in: TYPES }
  validates :status, inclusion: { in: STATUSES }
  validates :volume, numericality: { greater_than: 0 }
  validates :price, numericality: { greater_than: 0 }
  validates :placed_at, presence: true

  scope :pending, -> { where(status: "pending") }
end
