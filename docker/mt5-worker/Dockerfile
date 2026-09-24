# syntax=docker/dockerfile:1

# Rails AND the MetaTrader terminals, in one Linux image.
#
# Why one image and not two: Mt5::Runtime::Local starts terminals with
# Process.spawn, on the machine Rails is running on. Splitting Rails into its
# own container would need Mt5::Runtime::Remote, which is described in
# doc/EXECUTION_ARCHITECTURE.md §10 and does not exist. Until it does, the
# control plane and the execution layer share a container.
#
# Why this exists at all: the Local runtime needs /usr/bin/wine and
# /usr/bin/Xvfb. macOS has neither — the Wine inside MetaTrader 5.app draws to
# the Mac display and shares one prefix across every terminal, which is the
# opposite of the per-instance isolation this runtime is built on. A Linux
# container supplies both, on the same laptop.
#
# ARCHITECTURE MATTERS. Wine executes Windows x86_64 binaries. On an x86_64
# host that is native speed. On arm64 (Apple Silicon) it is emulation, and
# MetaTrader under emulated Wine is not something to trade on.
ARG RUBY_VERSION=3.4.10
FROM docker.io/library/ruby:${RUBY_VERSION}-slim-bookworm

# Wine comes from WineHQ, not from Debian.
#
# This is not a preference. Bookworm ships Wine 8.0, and MetaTrader build 6205
# refuses it in as many words — "unstable and unsupported Wine 8.0, please
# upgrade to Wine 10.0 or later" in the Journal. It starts and it trades, but
# its dialogs map without ever painting, so Tools > Options is a black
# rectangle and the WebRequest whitelist cannot be typed into it. Since that
# whitelist is the one thing in the template no script can write, a Wine that
# cannot show the dialog is a Wine that cannot produce a template at all.
#
# --install-recommends is WineHQ's own instruction: the recommends carry the
# 32-bit runtime and the graphics libraries, and a Wine installed without them
# fails later and less clearly.
#
# i386 as well as amd64: MetaTrader's installer is a 32-bit binary even though
# terminal64.exe is not, so a 64-bit-only Wine cannot install it.
#
# Split across three RUNs, and every apt download kept in a BuildKit cache.
# Wine pulls roughly a gigabyte over four hundred packages, and as one
# instruction a single failed DNS lookup in the last thirty seconds discards
# all of it — which is not hypothetical, it is how this was first written and
# what it cost. Separate layers mean a failure resumes from the last one that
# finished; the cache mounts mean even the failed layer's downloads survive, so
# a retry is minutes rather than half an hour. Retries cover the blips
# themselves.
RUN rm -f /etc/apt/apt.conf.d/docker-clean && \
    printf 'Binary::apt::APT::Keep-Downloaded-Packages "true";\nAcquire::Retries "5";\n' \
      > /etc/apt/apt.conf.d/99goldgrid

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    dpkg --add-architecture i386 && \
    apt-get update -qq && \
    apt-get install --no-install-recommends -y curl ca-certificates gnupg && \
    mkdir -pm755 /etc/apt/keyrings && \
    curl -fsSL --retry 5 --retry-connrefused -o /etc/apt/keyrings/winehq-archive.key \
      https://dl.winehq.org/wine-builds/winehq.key && \
    curl -fsSL --retry 5 --retry-connrefused -o /etc/apt/sources.list.d/winehq-bookworm.sources \
      https://dl.winehq.org/wine-builds/debian/dists/bookworm/winehq-bookworm.sources

# The expensive one, alone in its own layer so nothing after it can throw it away.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update -qq && \
    apt-get install --install-recommends -y winehq-stable

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get install --no-install-recommends -y \
      xvfb xauth x11vnc \
      cabextract winbind \
      build-essential git libpq-dev postgresql-client \
      procps

# Mt5.config.wine_binary defaults to /usr/bin/wine, and WineHQ installs to
# /opt/wine-stable. Linked rather than reconfigured so that the runtime, the
# compose file and prepare-template.sh all keep pointing at one path.
RUN ln -sf /opt/wine-stable/bin/wine /usr/bin/wine && \
    ln -sf /opt/wine-stable/bin/wineserver /usr/bin/wineserver && \
    ln -sf /opt/wine-stable/bin/wineboot /usr/bin/wineboot && \
    /usr/bin/wine --version

# Terminals must not run as root: each instance directory is 0700 and the
# isolation argument in §4 assumes an unprivileged owner.
RUN useradd --create-home --shell /bin/bash goldgrid

WORKDIR /rails

COPY Gemfile Gemfile.lock ./
RUN bundle install && rm -rf ~/.bundle "${BUNDLE_PATH}"/ruby/*/cache

COPY . .

# The template is a real MetaTrader installation, prepared once by hand and
# mounted as a volume — not baked in. It cannot be baked in: the WebRequest
# whitelist inside it is stored encrypted by MetaTrader, so there is no
# plaintext for a Dockerfile to write. See prepare-template.sh.
RUN mkdir -p /opt/goldgrid/instances /opt/mt5 && \
    chown -R goldgrid:goldgrid /opt/goldgrid /opt/mt5 /rails

# A window manager and the means to drive it.
#
# Wine needs a window manager for dialogs to take focus and repaint: without
# one, MetaTrader's Options window maps but never draws, which looks exactly
# like a hung terminal. xdotool drives that window over XTEST — real input
# events, which Wine honours, unlike the synthetic ones XSendEvent delivers.
# xwd and ImageMagick turn a display into a PNG, which is how you find out why
# a terminal will not sign in without sitting in front of a VNC viewer.
#
# Deliberately its own layer, after the bundle: these change far more often
# than Wine does and must not cost a ten-minute rebuild.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      openbox xdotool x11-apps x11-utils imagemagick

COPY docker/mt5-worker/entrypoint.sh /usr/local/bin/entrypoint
RUN chmod +x /usr/local/bin/entrypoint

USER goldgrid
EXPOSE 3000 5901
ENTRYPOINT ["/usr/local/bin/entrypoint"]
CMD ["bin/rails", "server", "-b", "0.0.0.0", "-p", "3000"]
