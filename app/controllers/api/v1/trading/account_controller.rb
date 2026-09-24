module Api
  module V1
    module Trading
      class AccountController < BaseController
        def show
          state = current_user.account_state
          connection = current_user.terminal_connections.order(last_report_at: :desc).first

          render json: {
            connection: TerminalConnectionSerializer.for(connection),
            account: state ? AccountStateSerializer.new(state).as_json : nil
          }
        end
      end
    end
  end
end
