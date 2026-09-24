module NavigationHelper
  # The authenticated navigation, defined once and rendered by the sidebar, the
  # mobile tab bar and the overflow sheet. Keeping it as data means those three
  # cannot list different destinations.
  def app_navigation
    [
      { label: "Overview", items: [
        { name: "Dashboard", path: dashboard_path, icon: :dashboard, primary: true }
      ] },
      { label: "Trading", items: [
        { name: "Strategies", path: strategies_path, icon: :strategies, primary: true },
        { name: "History", path: trading_history_path, icon: :history, primary: true }
      ] },
      { label: "Account", items: [
        { name: "Alerts", path: notifications_path, icon: :alerts, primary: true,
          badge: unread_alert_count },
        { name: "Activity", path: activity_path, icon: :activity },
        { name: "Settings", path: settings_path, icon: :settings },
        { name: "Profile", path: profile_path, icon: :profile }
      ] }
    ]
  end

  # The four destinations that earn a place in the mobile tab bar; the rest live
  # behind "More".
  def primary_navigation = app_navigation.flat_map { _1[:items] }.select { _1[:primary] }

  def secondary_navigation = app_navigation.flat_map { _1[:items] }.reject { _1[:primary] }

  # A section is current when the request is anywhere beneath it, so
  # /strategies/3/edit still highlights Strategies.
  def nav_current?(path)
    return request.path == path if path == "/"

    request.path == path || request.path.start_with?("#{path}/")
  end

  def unread_alert_count
    return 0 unless respond_to?(:current_user) && current_user

    @unread_alert_count ||= current_user.notifications.unread.count
  end

  # Inline SVG, so navigation needs no icon font and no extra request.
  def nav_icon(name, css_class: "sidebar-icon")
    paths = {
      dashboard: '<path d="M3.75 6A2.25 2.25 0 016 3.75h2.25A2.25 2.25 0 0110.5 6v2.25a2.25 2.25 0 01-2.25 2.25H6a2.25 2.25 0 01-2.25-2.25V6zM3.75 15.75A2.25 2.25 0 016 13.5h2.25a2.25 2.25 0 012.25 2.25V18a2.25 2.25 0 01-2.25 2.25H6A2.25 2.25 0 013.75 18v-2.25zM13.5 6a2.25 2.25 0 012.25-2.25H18A2.25 2.25 0 0120.25 6v2.25A2.25 2.25 0 0118 10.5h-2.25a2.25 2.25 0 01-2.25-2.25V6zM13.5 15.75a2.25 2.25 0 012.25-2.25H18a2.25 2.25 0 012.25 2.25V18A2.25 2.25 0 0118 20.25h-2.25A2.25 2.25 0 0113.5 18v-2.25z"/>',
      strategies: '<path d="M3.75 6.75h16.5M3.75 12h16.5m-16.5 5.25h16.5"/><circle cx="8" cy="6.75" r="2"/><circle cx="15" cy="12" r="2"/><circle cx="9" cy="17.25" r="2"/>',
      history: '<path d="M12 6v6l4 2"/><path d="M3.05 11a9 9 0 105.9-8.4"/><path d="M3 3v5h5"/>',
      alerts: '<path d="M14.857 17.082a23.848 23.848 0 005.454-1.31A8.967 8.967 0 0118 9.75V9A6 6 0 006 9v.75a8.967 8.967 0 01-2.312 6.022c1.733.64 3.56 1.085 5.455 1.31m5.714 0a24.255 24.255 0 01-5.714 0m5.714 0a3 3 0 11-5.714 0"/>',
      activity: '<path d="M3 12h4l3 8 4-16 3 8h4"/>',
      settings: '<circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.65 1.65 0 00.33 1.82l.06.06a2 2 0 11-2.83 2.83l-.06-.06a1.65 1.65 0 00-1.82-.33 1.65 1.65 0 00-1 1.51V21a2 2 0 11-4 0v-.09A1.65 1.65 0 009 19.4a1.65 1.65 0 00-1.82.33l-.06.06a2 2 0 11-2.83-2.83l.06-.06a1.65 1.65 0 00.33-1.82 1.65 1.65 0 00-1.51-1H3a2 2 0 110-4h.09A1.65 1.65 0 004.6 9a1.65 1.65 0 00-.33-1.82l-.06-.06a2 2 0 112.83-2.83l.06.06A1.65 1.65 0 009 4.6a1.65 1.65 0 001-1.51V3a2 2 0 114 0v.09a1.65 1.65 0 001 1.51 1.65 1.65 0 001.82-.33l.06-.06a2 2 0 112.83 2.83l-.06.06A1.65 1.65 0 0019.4 9c.14.36.4.67.75.87"/>',
      profile: '<path d="M15.75 6a3.75 3.75 0 11-7.5 0 3.75 3.75 0 017.5 0zM4.5 20.25a7.5 7.5 0 0115 0"/>',
      more: '<circle cx="5" cy="12" r="1.5"/><circle cx="12" cy="12" r="1.5"/><circle cx="19" cy="12" r="1.5"/>'
    }

    tag.svg(
      raw(paths.fetch(name, paths[:dashboard])),
      class: css_class, fill: "none", stroke: "currentColor",
      "stroke-width": 1.75, "stroke-linecap": "round", "stroke-linejoin": "round",
      viewBox: "0 0 24 24", "aria-hidden": true
    )
  end
end
