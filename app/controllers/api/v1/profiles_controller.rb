module Api
  module V1
    class ProfilesController < BaseController
      def show
        render json: UserSerializer.new(current_user).as_json
      end
    end
  end
end
