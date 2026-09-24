#!/usr/bin/env bash
# Brings up the X displays the terminals need, then hands over to the command.
#
# Mt5::Runtime::Local gives each instance its own display number, counting up
# from MT5_DISPLAY_BASE, and expects a server to already be listening on it.
# Wine needs a display even for a terminal nobody is looking at.
set -euo pipefail

BASE="${MT5_DISPLAY_BASE:-100}"
COUNT="${MT5_MAX_INSTANCES:-10}"

for ((i = 0; i < COUNT; i++)); do
  display=$((BASE + i))
  # -nolisten tcp: these displays exist for Wine inside this container and have
  # no business being reachable from outside it.
  Xvfb ":${display}" -screen 0 1280x1024x24 -nolisten tcp >/dev/null 2>&1 &
done

# One window manager per display. Wine maps a dialog but never paints it when
# nothing is managing the screen, so without this MetaTrader's Options window
# is a black rectangle and the WebRequest whitelist cannot be typed into it.
for ((i = 0; i < COUNT; i++)); do
  DISPLAY=":$((BASE + i))" openbox >/dev/null 2>&1 &
done

# Give the servers a moment to create their sockets. A terminal that starts
# against a display that is not listening yet fails in a way that looks like a
# MetaTrader problem rather than a race.
for ((i = 0; i < 50; i++)); do
  [ -e "/tmp/.X11-unix/X${BASE}" ] && break
  sleep 0.1
done

# A server.pid left behind by a container that was killed rather than stopped.
#
# The source tree is bind-mounted, so tmp/ survives the container that wrote
# it. Puma finds the file, believes a server it cannot see is already running,
# and exits — which presents as a container that starts and immediately dies
# for no stated reason. Nothing else can be holding this pid: it is the
# container's own pid 1.
rm -f /rails/tmp/pids/server.pid

# Optional window onto the first display, for preparing the template or seeing
# why a terminal will not sign in. Off unless asked for: it is a view of a
# session holding a broker login.
if [ "${MT5_VNC:-0}" = "1" ]; then
  echo "entrypoint: VNC on :5901 (display :${BASE}) — view only, no password"
  x11vnc -display ":${BASE}" -rfbport 5901 -forever -shared -nopw -quiet >/dev/null 2>&1 &
fi

exec "$@"
