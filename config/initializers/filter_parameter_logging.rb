# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc,

  # :code covers two-factor and recovery codes. A recovery code is single-use
  # but stays valid until spent, so one sitting in a log file is a usable
  # credential for anyone who can read that file.
  :code,

  # A Web Push endpoint URL embeds a per-device secret; whoever holds it can
  # push notifications to that device.
  :endpoint
]
