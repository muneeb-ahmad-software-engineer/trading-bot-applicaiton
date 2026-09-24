# Execution manager configuration.
#
# The runtime defaults to :simulated everywhere except a host that has actually
# been prepared with MetaTrader. That default is deliberate: a misconfigured
# production box should fail to start terminals loudly, not spawn processes
# against a broker with half a configuration.
Rails.application.config.to_prepare do
  Mt5.config = Mt5::Config.new(
    runtime: ENV.fetch("MT5_RUNTIME", "simulated").to_sym,
    instances_root: ENV.fetch("MT5_INSTANCES_ROOT", Rails.root.join("tmp/mt5/instances").to_s),
    terminal_binary: ENV["MT5_TERMINAL_BINARY"],
    # The installation instances are built from: the EA compiled into it and
    # the platform URL whitelisted, once, by hand. Defaults to the directory
    # holding terminal64.exe, which is what a normal MT5 install looks like.
    template_dir: ENV["MT5_TEMPLATE_DIR"].presence || ENV["MT5_TERMINAL_BINARY"].presence&.then { File.dirname(_1) },
    wine_binary: ENV.fetch("MT5_WINE_BINARY", "/usr/bin/wine"),
    xvfb_binary: ENV.fetch("MT5_XVFB_BINARY", "/usr/bin/Xvfb"),
    display_base: Integer(ENV.fetch("MT5_DISPLAY_BASE", "100")),
    node_name: ENV.fetch("MT5_NODE_NAME", "local"),
    max_instances: Integer(ENV.fetch("MT5_MAX_INSTANCES", "10")),
    report_seconds: Integer(ENV.fetch("MT5_REPORT_SECONDS", "10")),
    idle_timeout: Integer(ENV.fetch("MT5_IDLE_TIMEOUT_SECONDS", "900")).seconds
  )
end
