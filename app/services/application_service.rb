# Base class for service objects.
#
# Services hold business logic that does not belong to a single model and must
# behave identically however it is reached — the web interface and the API both
# start strategies, and the rules for whether that is allowed must not be
# written twice.
#
# They return a Result rather than raising, so callers translate one outcome
# into a redirect and the other into JSON without rescuing control flow.
class ApplicationService
  Result = Struct.new(:success, :error_code, :error_message, :payload, keyword_init: true) do
    def success? = success
    def failure? = !success
  end

  def self.call(...) = new(...).call

  private

  def success(payload = nil)
    Result.new(success: true, payload:)
  end

  # error_code is a stable machine-readable string for API clients;
  # error_message is for humans.
  def failure(code, message)
    Result.new(success: false, error_code: code, error_message: message)
  end
end
