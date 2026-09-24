module Mt5
  # Everything a runtime needs to write a terminal's configuration.
  #
  # Extracted because two callers build it — provisioning a new terminal and
  # pointing an existing one at a different strategy — and a terminal
  # configured by one path must be indistinguishable from one configured by the
  # other. Written twice, the two would drift on the first field either one
  # gained.
  module TerminalContext
    def self.for(instance:, credential:, api_token:, strategy: nil, allow_trading: false)
      {
        broker_server: credential.server,
        broker_login: credential.login,
        broker_password: credential.password,
        symbol: strategy&.symbol || "XAUUSD",
        strategy_id: strategy&.id,
        base_url: Rails.application.config.x.product.base_url,
        api_token: api_token.plaintext_token,
        allow_trading:
      }
    end
  end
end
