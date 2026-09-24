module Api
  module V1
    # Unauthenticated readiness probe.
    #
    # Deliberately public and deliberately empty of account data: it exists so a
    # client can confirm connectivity and API version before it holds a token.
    class StatusController < BaseController
      allow_unauthenticated_api_access

      def show
        render json: {
          service: Rails.application.config.x.product.name,
          api_version: "v1",
          status: "ok",
          time: Time.current.utc.iso8601
        }
      end
    end
  end
end
