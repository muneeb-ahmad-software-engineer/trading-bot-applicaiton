# Renders error responses.
#
# Wired up as `config.exceptions_app` so errors raised in middleware — a
# malformed JSON body, an unrecognised route — are rendered by the application
# rather than by Rails' static HTML pages.
#
# The reason that matters: without this, a client posting bad JSON to /api/v1
# receives an HTML error page. A mobile app calling JSON.parse on that response
# crashes with a parse error instead of reading a status code. Everything under
# /api must answer in JSON, including its failures.
class ErrorsController < ActionController::Base
  # Errors must render even when the failure was an authentication problem, so
  # this controller deliberately does not include Authentication.
  layout "application"

  STATUSES = {
    400 => [ "bad_request", "The request could not be understood." ],
    404 => [ "not_found", "That page could not be found." ],
    406 => [ "not_acceptable", "That format is not supported." ],
    422 => [ "unprocessable_entity", "That change could not be saved." ],
    500 => [ "internal_error", "Something went wrong on our end." ]
  }.freeze

  def show
    status = extracted_status
    code, message = STATUSES.fetch(status, STATUSES[500])

    # Branch on the path, not on content negotiation. A client sending
    # `Accept: */*` — which both curl and the MT5 terminal do — would otherwise
    # be handed whichever format happens to be listed first, and that decision
    # must not be left to header ordering.
    if api_request?
      render json: { error: { code:, message: } }, status:
    else
      render :show, status:, formats: [ :html ], locals: { status:, message: }
    end
  end

  private

  def extracted_status
    exception = request.env["action_dispatch.exception"]
    fallback = request.path_info[1..].to_i
    fallback = 500 unless STATUSES.key?(fallback)

    return fallback if exception.nil?

    ActionDispatch::ExceptionWrapper.new(request.env["action_dispatch.backtrace_cleaner"], exception)
                                    .status_code
  end

  # Anything under /api answers in JSON, as does a request that explicitly asks
  # for JSON. Everything else gets the styled HTML page.
  def api_request?
    original = request.env["action_dispatch.original_path"] || request.path

    original.start_with?("/api/") || request.format.json?
  end
end
