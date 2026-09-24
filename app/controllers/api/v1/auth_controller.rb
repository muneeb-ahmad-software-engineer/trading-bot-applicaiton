module Api
  module V1
    # Exchanges credentials for a bearer token.
    #
    # This is how a native mobile application signs in: POST credentials, store
    # the returned token in the device keychain, send it as
    # `Authorization: Bearer <token>` from then on.
    #
    # The MT5 Expert Advisor does not use this endpoint. Its token is issued
    # from the web interface and pasted into the terminal, so the EA never
    # handles a password.
    class AuthController < BaseController
      allow_unauthenticated_api_access only: :create

      # Throttled by client IP, since an API client has no session to key on.
      rate_limit to: 10, within: 3.minutes, only: :create,
                 with: -> { render json: { error: { code: "rate_limited", message: "Too many attempts." } }, status: :too_many_requests }

      def create
        user = User.authenticate_by(
          email_address: params[:email_address].to_s,
          password: params[:password].to_s
        )

        # Identical response for an unknown address and a wrong password, so the
        # endpoint cannot be used to enumerate accounts.
        return render_error("invalid_credentials", "Incorrect email address or password.", :unauthorized) unless user

        # A second factor is enforced on the API exactly as in the browser,
        # otherwise the API would be a way to bypass it entirely. A client that
        # gets `otp_required` should prompt for a code and repeat the request
        # with `otp_code` included.
        if user.otp_enabled?
          if params[:otp_code].blank?
            return render_error("otp_required", "A two-factor code is required for this account.", :unauthorized)
          end

          unless user.verify_second_factor(params[:otp_code])
            return render_error("invalid_otp", "That two-factor code is not valid.", :unauthorized)
          end
        end

        token = ApiToken.issue(user:, name: device_name)

        render json: {
          token: token.plaintext_token,
          token_id: token.id,
          user: UserSerializer.new(user).as_json
        }, status: :created
      end

      def destroy
        current_api_token.revoke!
        head :no_content
      end

      private

      def device_name
        params[:device_name].presence&.to_s&.truncate(60) || "Mobile device"
      end
    end
  end
end
