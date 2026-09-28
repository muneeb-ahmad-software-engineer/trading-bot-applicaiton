module StrategiesHelper
  # An (i) button next to a strategy setting that explains it in plain words.
  #
  # The text lives in config/locales/strategy_help.en.yml so the form and the
  # strategy page can never explain the same setting two different ways.
  #
  # The explanation is attached to the button with aria-describedby, so a
  # screen reader announces it on focus without anything having to open. The
  # panel shows on hover and keyboard focus by CSS alone; a tap toggles it
  # through the info-tip controller, because touch has no hover and Safari
  # does not focus a tapped button.
  def field_info(field, label:)
    panel_id = "#{field}_info"

    tag.span(class: "info-tip", data: { controller: "info-tip" }) do
      safe_join([
        tag.button(type: "button", class: "info-tip-trigger",
                   "aria-label": "What is #{label}?",
                   "aria-describedby": panel_id,
                   "aria-expanded": "false",
                   data: { info_tip_target: "trigger", action: "info-tip#toggle" }) { info_icon },
        tag.span(t("strategy_help.#{field}"), id: panel_id, role: "tooltip", class: "info-tip-panel")
      ])
    end
  end

  # A setting's label with its (i) button beside it.
  def label_with_info(form, field, label)
    tag.div(class: "label-row") do
      safe_join([ form.label(field, label, class: "label"), field_info(field, label:) ])
    end
  end

  # Whether anything is actually executing a strategy right now: a terminal
  # reporting for it, or the user's managed terminal up and heard from.
  #
  # A strategy's status is what the user asked for; this is what is true. The
  # two diverge whenever a terminal is down, and a page that shows only the
  # first tells the user their strategy is trading when it is not.
  def terminal_executing?(connection:, instance:, strategy: nil)
    return true if connection&.live?
    return false if instance.nil?
    return false if strategy && instance.strategy_id != strategy.id

    instance.healthy?
  end

  # Until when a page waiting on the terminal should keep refreshing itself:
  # long enough for a terminal to boot and sign in after its last change of
  # state, or after its next automatic restart. Nil when nothing is going to
  # change without the user — the terminal has hit the crash-loop cap.
  def terminal_refresh_deadline(strategy:, instance:)
    return nil if instance&.crash_looping?

    since = [ strategy.started_at, instance&.last_transition_at, instance&.next_restart_at ].compact.max
    since && since + Mt5Instance::CONNECT_TIMEOUT + 1.minute
  end

  private

  def info_icon
    tag.svg(xmlns: "http://www.w3.org/2000/svg", viewBox: "0 0 20 20", fill: "currentColor",
            class: "h-4 w-4", "aria-hidden": "true", focusable: "false") do
      tag.path("fill-rule": "evenodd", "clip-rule": "evenodd",
               d: "M18 10a8 8 0 1 1-16 0 8 8 0 0 1 16 0Zm-7-4a1 1 0 1 1-2 0 1 1 0 0 1 2 0ZM9 9a.75.75 0 0 0 0 1.5h.25v2.75a.75.75 0 0 0 1.5 0V9.75A.75.75 0 0 0 10 9H9Z")
    end
  end
end
