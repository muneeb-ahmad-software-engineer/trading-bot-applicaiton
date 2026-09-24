module Mt5
  # Decides which node a new instance goes on, and which display it gets there.
  #
  # Trivial with one node. It exists as its own object anyway, because "where
  # does this run?" is precisely the decision that has to change when a second
  # VPS appears, and having it in one place is the difference between adding a
  # node and auditing every call site.
  class Placement < ApplicationService
    def initialize(user:)
      @user = user
    end

    def call
      node = choose_node
      return failure("no_capacity", "No worker node has capacity for a new terminal.") if node.nil?

      display = allocate_display(node)
      return failure("no_display", "No X display is free on #{node.name}.") if display.nil?

      success(node:, display_number: display)
    end

    private

    attr_reader :user

    # Least-loaded first, so instances spread rather than piling onto whichever
    # node sorts first. With one node this is a no-op; with three it is the
    # difference between balanced and not.
    def choose_node
      WorkerNode.schedulable.select(&:schedulable?).min_by(&:used_capacity)
    end

    # Lowest free display at or above the configured base. Reusing a freed
    # number is safe — the directory it belonged to is gone by then — and keeps
    # the range small enough to reason about.
    def allocate_display(node)
      taken = node.live_instances.where.not(display_number: nil).pluck(:display_number).to_set
      base = Mt5.config.display_base

      (base...(base + node.max_instances + 1)).find { |n| !taken.include?(n) }
    end
  end
end
