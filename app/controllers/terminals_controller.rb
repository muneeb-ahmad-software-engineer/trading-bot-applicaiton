# The user's managed MT5 terminal.
#
# One action: try again. After repeated failures the reconciler stops
# restarting a terminal on its own (see Mt5Instance::MAX_CONSECUTIVE_FAILURES),
# because a crash loop is worse than being down. Once the user has fixed
# whatever was wrong — a password, a server name — they need a way to lift that
# and start over, rather than waiting out a backoff or asking support.
class TerminalsController < ApplicationController
  def restart
    instance = current_user.mt5_instances.not_terminated.first
    return redirect_back_or_to(strategies_path, alert: "You don't have a managed terminal yet.") if instance.nil?

    # A terminal exists to run a strategy. Bringing one up with nothing to run
    # would sign in to the broker for no reason and be reaped as idle.
    unless current_user.strategies.running.exists?
      return redirect_back_or_to(strategies_path, alert: "Start a strategy to bring your terminal up.")
    end

    # The user asking again is the signal the crash-loop cap waits for.
    instance.clear_failures!

    result = if instance.process_expected?
      Mt5::Restart.call(instance:, actor: current_user, source: "web", reason: "retried by user")
    else
      Mt5::Start.call(instance:, actor: current_user, source: "web")
    end

    Event.record("terminal.retried", user: current_user, ip_address: request.remote_ip,
                 metadata: { instance: instance.uuid, ok: result.success?, error: result.error_code })

    if result.success?
      redirect_back_or_to strategies_path,
                          notice: "Reconnecting your terminal. Signing in to the broker usually takes a minute or two."
    else
      redirect_back_or_to strategies_path, alert: "Could not restart your terminal: #{result.error_message}"
    end
  end
end
