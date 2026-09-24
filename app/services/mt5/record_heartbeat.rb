module Mt5
  # A terminal calling in.
  #
  # This is the only thing that moves an instance to `running`. Not the spawn
  # succeeding, not the process existing — the EA actually reaching the platform
  # and identifying itself. Everything upstream of that is an assumption, and on
  # a trading platform "assumed connected" and "connected" must never be the
  # same colour on a dashboard.
  #
  # Called from the ingestion path on every report, so it is deliberately cheap:
  # one indexed lookup and one narrow UPDATE in the common case.
  class RecordHeartbeat < ApplicationService
    def initialize(api_token:)
      @api_token = api_token
    end

    def call
      return success(nil) if api_token.nil?

      instance = Mt5Instance.not_terminated.find_by(api_token_id: api_token.id)
      return success(nil) if instance.nil?

      instance.record_heartbeat!
      promote(instance) unless instance.running?
      confirm_credential(instance)

      success(instance)
    end

    private

    attr_reader :api_token

    # A terminal that reports in has signed in to the broker, because it cannot
    # do the first without the second. That makes an arriving report the only
    # first-hand evidence this application ever gets that a user's broker
    # details are correct — so it is recorded here rather than guessed at from
    # a settings form that has no way to check.
    #
    # Rate-limited inside the model: reports arrive every ten seconds and this
    # must not become a write per report.
    def confirm_credential(instance)
      instance.user.broker_credential&.record_verification!
    end

    # A report from a terminal the control plane believes is starting or
    # connecting is the proof that it arrived.
    def promote(instance)
      return unless instance.may_transition_to?("running")

      instance.with_lock do
        return unless instance.may_transition_to?("running")

        instance.transition_to!("running", action: "instance.connected", source: "api")
        instance.clear_failures!
      end

      Rails.logger.info("mt5.connected #{instance.to_log.to_json}")
    end
  end
end
