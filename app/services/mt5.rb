# The execution manager.
#
# Rails is the control plane: it decides which users should have a terminal
# running and records what happened. MT5 is the execution layer: it holds the
# broker connection and places orders. Everything in this namespace is about
# getting a terminal into the state the control plane asked for, and telling the
# truth about it when that fails.
#
# Nothing here knows what a grid is.
module Mt5
  # Runtime configuration, assembled once at boot (config/initializers/mt5.rb).
  # Read through this rather than ENV so a test can substitute a whole config
  # and so every knob is discoverable in one place.
  Config = Struct.new(
    :runtime,             # :simulated | :local
    :instances_root,      # where per-instance directories live
    :terminal_binary,     # path to terminal64.exe
    :template_dir,        # a prepared MT5 installation each instance is built from
    :wine_binary,
    :xvfb_binary,
    :display_base,        # X displays are allocated from here upwards
    :node_name,           # which worker node this Rails process is running on
    :max_instances,
    :report_seconds,
    :idle_timeout,        # a terminal with no running strategy is reaped after this
    keyword_init: true
  ) do
    def simulated? = runtime.to_sym == :simulated
    def local? = runtime.to_sym == :local
  end

  class << self
    attr_writer :config

    def config = @config ||= Config.new(runtime: :simulated, instances_root: "/tmp/goldgrid/instances")

    # Swaps configuration for the duration of a block. Used by tests, which must
    # never touch a real instances root or spawn a real terminal.
    def with_config(**overrides)
      previous = config
      self.config = Config.new(**previous.to_h.merge(overrides))
      yield
    ensure
      self.config = previous
    end
  end
end
