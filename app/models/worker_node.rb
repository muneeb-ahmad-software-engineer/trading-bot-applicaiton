# A machine that can run MT5 terminals.
#
# There is one of these today. It exists as a row rather than a constant so that
# adding a second VPS is an INSERT and a capacity number, not a refactor: every
# placement decision already asks "which node?", and every runtime call already
# goes through the node's adapter.
class WorkerNode < ApplicationRecord
  # A node must say it is alive this often to be considered usable. Longer than
  # an instance heartbeat because a node reports far less often and losing one
  # is a much bigger event than losing one terminal.
  STALE_AFTER = 2.minutes

  has_many :mt5_instances, dependent: :restrict_with_error

  enum :status, { offline: "offline", online: "online", draining: "draining" }, validate: true

  validates :name, presence: true, uniqueness: true, length: { maximum: 60 }
  validates :hostname, presence: true
  validates :max_instances, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  scope :schedulable, -> { where(status: "online") }

  # Instances that occupy capacity. A terminated instance has had its directory
  # removed and holds nothing.
  def live_instances = mt5_instances.where.not(state: "terminated")

  def used_capacity = live_instances.count

  def available_capacity = [ max_instances - used_capacity, 0 ].max

  def at_capacity? = available_capacity.zero?

  # Liveness is derived, never stored. A node that stops reporting must read as
  # stale on its own — a crashed VPS does not get to update a boolean saying it
  # crashed.
  def heartbeat_fresh? = last_heartbeat_at.present? && last_heartbeat_at > STALE_AFTER.ago

  def schedulable? = online? && heartbeat_fresh? && !at_capacity?

  def record_heartbeat!(agent_version: nil, metadata: {})
    update!(
      last_heartbeat_at: Time.current,
      status: draining? ? status : "online",
      agent_version: agent_version.presence || self.agent_version,
      metadata: self.metadata.merge(metadata)
    )
  end

  # The runtime that actually starts and stops processes on this node. Local
  # today; a remote adapter slots in here without any caller changing.
  def runtime = Mt5::Runtime.for(self)
end
