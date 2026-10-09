#!/usr/bin/env bash
# Builds the MetaTrader template the Local runtime provisions every instance
# from. Run ONCE, inside the container.
#
#   docker compose stop app
#   docker compose run --rm --service-ports -e MT5_VNC=1 app \
#     docker/mt5-worker/prepare-template.sh
#
# `docker compose stop app` first, and `--service-ports` rather than
# `-p 5901:5901`: the app service already publishes 3000 and 5901, so a second
# container asking for 5901 while it is up fails with "port is already
# allocated".
#
# Four things must be true of the finished template. Provisioning refuses with
# `no_template` until the first three are, and terminals sit in `connecting`
# until the fourth is:
#
#   1. terminal64.exe exists — installed by this script.
#   2. MQL5/Experts/GoldGrid.ex5 exists — compiled from mt5/.
#   3. Config/common.ini exists — written by MetaTrader, not by us.
#   4. The platform URL is in the WebRequest whitelist.
#   5. MetaTrader is not running when instances are.
#
# Only step 4 is manual. MetaTrader stores the whitelist ENCRYPTED in
# Config/common.ini — `WebRequest=1` and an opaque `WebRequestUrl=` blob — so
# there is no plaintext for a script to write. It has to be typed into the GUI
# once, which is what the VNC session is for.
set -euo pipefail

TEMPLATE="${MT5_TEMPLATE_DIR:-/opt/mt5/drive_c/Program Files/MetaTrader 5}"
PREFIX="${WINEPREFIX:-/opt/mt5}"
DISPLAY_NUM="${MT5_DISPLAY_BASE:-100}"
BASE_URL="${PRODUCT_BASE_URL:-http://127.0.0.1:3000}"
export WINEPREFIX="$PREFIX"
export DISPLAY=":${DISPLAY_NUM}"
export WINEDEBUG=-all
# Wine offers to download Mono and Gecko the first time it builds a prefix,
# modally. MetaTrader needs neither, and the prompt blocks an unattended run.
export WINEDLLOVERRIDES="mscoree,mshtml="

# MetaTrader refuses to run properly on Wine older than 10.0 — it starts and it
# trades, but its dialogs map without ever painting, so Tools > Options is a
# black rectangle and the whitelist below cannot be typed in. Checked here
# rather than left to be discovered over VNC.
wine_version="$(wine --version 2>/dev/null || echo unknown)"
echo "Wine: ${wine_version}"
case "$wine_version" in
  wine-[1-9].*) echo "WARNING: MetaTrader needs Wine 10.0 or later. Options will not render." >&2 ;;
esac

# ---------------------------------------------------------------- 1. Install

if [ -f "$TEMPLATE/terminal64.exe" ]; then
  echo "A MetaTrader installation already exists at: $TEMPLATE"
else
  echo "Initialising the Wine prefix at $PREFIX …"
  wineboot --init
  wineserver -w

  echo "Downloading the MetaTrader installer …"
  curl -fsSL -o /tmp/mt5setup.exe https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe

  # /auto installs without a single click. The installer still downloads the
  # terminal itself afterwards, so this takes a few minutes and looks idle.
  echo "Installing MetaTrader (unattended) — this downloads ~300 MB …"
  wine /tmp/mt5setup.exe /auto || true
  wineserver -w

  [ -f "$TEMPLATE/terminal64.exe" ] || { echo "✗ Install failed: no terminal64.exe" >&2; exit 1; }
fi

# ------------------------------------------------------------- 2. Bootstrap

# The installer lays down the executables and nothing else. MQL5/ — which is
# where the Expert Advisor has to be compiled to — and Config/common.ini are
# created by the terminal on its first run, so there has to be one.
#
# /portable is what makes that first run build the tree inside the installation
# directory. Without it MetaTrader puts MQL5/ under AppData instead, the
# compile below has nowhere to write, and every instance inherits a template
# with no expert in it.
if [ -d "$TEMPLATE/MQL5/Experts" ] && [ -f "$TEMPLATE/Config/common.ini" ]; then
  echo "MQL5 tree already present."
else
  echo "First run of the terminal, to create the MQL5 tree …"
  ( cd "$TEMPLATE" && wine ./terminal64.exe /portable >/dev/null 2>&1 & )

  for _ in $(seq 1 60); do
    [ -d "$TEMPLATE/MQL5/Experts" ] && [ -f "$TEMPLATE/Config/common.ini" ] && break
    sleep 2
  done

  # Shut it down again: the compile wants the tree, not a running terminal, and
  # the whitelist pass below starts its own.
  wineserver -k || true
  sleep 2

  [ -d "$TEMPLATE/MQL5/Experts" ] || { echo "✗ MQL5 tree was never created." >&2; exit 1; }
fi

# --------------------------------------------------------------- 3. Compile

echo "Copying the Expert Advisor sources in …"
mkdir -p "$TEMPLATE/MQL5/Experts/Include/GoldGrid"
cp /rails/mt5/GoldGrid.mq5 "$TEMPLATE/MQL5/Experts/"
cp /rails/mt5/Include/GoldGrid/*.mqh "$TEMPLATE/MQL5/Experts/Include/GoldGrid/"

echo "Compiling GoldGrid.ex5 …"
# The build being replaced is kept beside the new one, so a template that
# turns out to misbehave can be put back without a recompile:
#   mv GoldGrid.ex5.previous GoldGrid.ex5
if [ -f "$TEMPLATE/MQL5/Experts/GoldGrid.ex5" ]; then
  cp -f "$TEMPLATE/MQL5/Experts/GoldGrid.ex5" "$TEMPLATE/MQL5/Experts/GoldGrid.ex5.previous"
  echo "Previous build kept as GoldGrid.ex5.previous"
fi
rm -f "$TEMPLATE/MQL5/Experts/GoldGrid.ex5" "$TEMPLATE/MQL5/Experts/GoldGrid.log"
# MetaEditor's /compile: flag silently does nothing when the path contains a
# space, and the terminal lives under "Program Files". Run from MQL5 and pass
# a relative path, the same workaround bin/mt5_compile uses.
( cd "$TEMPLATE/MQL5" && wine "$TEMPLATE/MetaEditor64.exe" /compile:"Experts\\GoldGrid.mq5" /log >/dev/null 2>&1 || true )
wineserver -w

if [ -f "$TEMPLATE/MQL5/Experts/GoldGrid.log" ]; then
  # MetaEditor writes its log as UTF-16.
  iconv -f UTF-16LE -t UTF-8 "$TEMPLATE/MQL5/Experts/GoldGrid.log" 2>/dev/null | tail -3 || true
fi

echo
if [ -f "$TEMPLATE/MQL5/Experts/GoldGrid.ex5" ]; then
  echo "✓ GoldGrid.ex5 is in the template."
else
  echo "✗ GoldGrid.ex5 is MISSING. Provisioning will refuse with no_template."
  exit 1
fi

# ------------------------------------------------------------- 4. Whitelist

cat <<NEXT

STILL TO DO, BY HAND, OVER VNC — this is the one step no script can perform.

Connect a viewer to localhost:5901 first.
  macOS: Finder > Go > Connect to Server > vnc://localhost:5901

  1. Start MetaTrader, from a second shell into this same container:
       docker compose exec app bash -lc \\
         'cd "$TEMPLATE" && WINEPREFIX=$PREFIX DISPLAY=:$DISPLAY_NUM wine ./terminal64.exe /portable'
  2. Tools > Options > Expert Advisors
     tick "Allow WebRequest for listed URL"
     add:  $BASE_URL
     NOT "localhost" — the whitelist silently refuses a host name with no dot
     in it, and the terminal then fails every call with no message worth
     reading.
  3. QUIT MetaTrader cleanly (File > Exit). It writes Config/ only on a clean
     exit, so killing it loses the whitelist you just typed.

The template is then ready, and must stay closed while instances run.
NEXT
