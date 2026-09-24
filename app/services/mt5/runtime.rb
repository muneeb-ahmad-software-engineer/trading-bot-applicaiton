module Mt5
  # The seam between the control plane and whatever actually runs a terminal.
  #
  # Every operation the execution manager performs on a process goes through a
  # runtime, and the services above it never learn which one they got. That is
  # the whole reason a second VPS is not a rewrite: a remote runtime that speaks
  # HTTP to a node agent implements the same six methods, and `for` returns it
  # based on the node.
  module Runtime
    # What a runtime reports back. Deliberately not a boolean — "did it start?"
    # has three interesting answers (yes / no, here is why / it was already up)
    # and callers branch on all three.
    Result = Struct.new(:ok, :pid, :process_token, :error_code, :error_message, :details, keyword_init: true) do
      def ok? = ok
      def failed? = !ok
    end

    def self.for(worker_node)
      case Mt5.config.runtime.to_sym
      when :local then Local.new(worker_node)
      when :simulated then Simulated.new(worker_node)
      else raise ArgumentError, "unknown MT5 runtime #{Mt5.config.runtime.inspect}"
      end
    end
  end
end
