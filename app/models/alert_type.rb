# The catalogue of things worth telling a user about.
#
# Two rules decide what belongs here:
#
#   1. The user must be able to act on it. An alert nobody can do anything
#      about is noise, and noise trains people to ignore the alerts that
#      matter.
#   2. Silence must be meaningful. If a condition would go unnoticed until
#      someone happened to open the dashboard, it belongs here.
class AlertType
  ALL = {
    "terminal_stale" => {
      title: "Terminal stopped reporting",
      description: "Your MT5 terminal stopped sending updates while a strategy was running.",
      severity: "critical",
      # Cannot be switched off. A running strategy whose terminal has gone
      # silent is the single most dangerous state this platform can observe,
      # and the user may have open positions nobody is watching.
      mandatory: true
    },
    "terminal_recovered" => {
      title: "Terminal reporting again",
      description: "Your MT5 terminal resumed sending updates.",
      severity: "info",
      mandatory: false
    },
    "drawdown_threshold" => {
      title: "Drawdown threshold reached",
      description: "Account drawdown reached the limit configured on a running strategy.",
      severity: "critical",
      mandatory: false
    },
    "margin_low" => {
      title: "Margin level low",
      description: "Margin level fell below the minimum configured on a running strategy.",
      severity: "critical",
      mandatory: false
    },
    "basket_closed" => {
      title: "Basket closed",
      description: "A basket of positions was closed.",
      severity: "info",
      mandatory: false
    },
    "security" => {
      title: "Security activity",
      description: "Sign-ins from new devices, API tokens issued, two-factor changes.",
      severity: "warning",
      mandatory: false
    }
  }.freeze

  CHANNELS = %w[email push].freeze

  class << self
    def keys = ALL.keys

    def find(key) = ALL[key.to_s]

    def exists?(key) = ALL.key?(key.to_s)

    def mandatory?(key) = ALL.dig(key.to_s, :mandatory) || false

    def severity(key) = ALL.dig(key.to_s, :severity) || "info"

    def title(key) = ALL.dig(key.to_s, :title) || key.to_s.humanize

    # Everything on by default. A user who has not thought about notifications
    # should still be told their bot stopped reporting.
    def default_preferences
      keys.index_with { CHANNELS.index_with { true } }
    end
  end
end
