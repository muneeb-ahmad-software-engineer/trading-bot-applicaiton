# A position held with the broker, as reported by the terminal.
#
# This platform never creates positions — it only records what the Expert
# Advisor says exists. Nothing here should ever be treated as an instruction to
# trade.
class Position < ApplicationRecord
  DIRECTIONS = %w[buy sell].freeze

  belongs_to :strategy

  validates :ticket, presence: true, uniqueness: { scope: :strategy_id }
  validates :direction, inclusion: { in: DIRECTIONS }
  validates :volume, numericality: { greater_than: 0 }
  validates :open_price, numericality: { greater_than: 0 }
  validates :opened_at, presence: true

  scope :open, -> { where(closed_at: nil) }
  scope :closed, -> { where.not(closed_at: nil) }
  scope :recent_first, -> { order(opened_at: :desc) }

  def open? = closed_at.nil?

  # Profit including carrying costs. Swap and commission are frequently the
  # difference between a basket that is actually up and one that only looks it,
  # so net is what the interface shows.
  def net_profit
    [ profit, swap, commission ].compact.sum
  end
end
