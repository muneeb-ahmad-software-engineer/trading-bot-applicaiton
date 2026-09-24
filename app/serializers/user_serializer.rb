class UserSerializer < ApplicationSerializer
  def as_json(*)
    {
      id: object.id,
      email_address: object.email_address,
      verified: object.verified?,
      two_factor_enabled: object.otp_enabled?,
      # Tells a client whether trading actions will be accepted, so it can
      # prompt for verification rather than failing at the point of use.
      may_trade: object.may_trade?,
      created_at: timestamp(object.created_at)
    }
  end
end
