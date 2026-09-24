# MT5 execution architecture

How many users share one VPS, each with their own isolated MetaTrader terminal,
without any of them being able to affect another — and how the platform keeps
that true across crashes, reboots and deploys.

**Status: the foundation is built and tested; MetaTrader is not installed yet.**
Everything below runs today against the *simulated* runtime, which builds the
same directories, writes the same configuration and obeys the same state
machine — it just does not spawn `terminal64.exe`. §9 is the exact procedure for
switching it on.

No trading, order or grid logic lives in any of this. That stays where
[`MT5_INTEGRATION.md`](MT5_INTEGRATION.md) puts it: inside the EA.

---

## 1. The split

| | Control plane (Rails) | Execution layer (MT5 + EA) |
|---|---|---|
| Decides | *which* terminals should run, for whom, where | *what to trade* |
| Owns | lifecycle, placement, recovery, audit | the broker connection |
| State | Postgres | the terminal's own data directory |
| Never does | place an order, hold a broker session | decide whether it should exist |

Rails does not trade and MT5 does not schedule. That line is what lets the
control plane be audited, tested and restarted without touching anything that
holds a position.

```
┌──────────────────────── Rails (control plane) ─────────────────────────┐
│                                                                        │
│  Mt5::Provision ─ Start ─ Stop ─ Restart ─ Deprovision                  │
│         │                                                              │
│         ├── Mt5::Placement ······ which node, which display            │
│         ├── Mt5::Reconcile ······ observed vs desired  (every minute)  │
│         ├── Mt5::ReapIdle ······· release unused capacity (every 5 m)  │
│         └── Mt5::RecordHeartbeat  called from the ingestion path       │
│                          │                                             │
│                  Mt5::Runtime (interface)                              │
│                    ├── Simulated  ← today, and in CI forever           │
│                    ├── Local      ← one VPS: spawns processes here     │
│                    └── Remote     ← many VPSs: HTTP to a node agent    │
└────────────────────────────────┬───────────────────────────────────────┘
                                 │  spawn / signal / inspect
┌────────────────────────────────▼───────────────────────────────────────┐
│  Worker node (VPS)                                                     │
│    /opt/goldgrid/instances/mt5-<uuid>/                                 │
│        config/  terminal.ini, GoldGrid.set   (0600)                    │
│        data/    the terminal's portable data directory                 │
│        logs/    terminal.out.log, terminal.err.log                     │
│        run/     terminal.pid, process.token                            │
│        wine/    an isolated WINEPREFIX                                 │
└────────────────────────────────┬───────────────────────────────────────┘
                                 │  HTTPS, bearer token
                                 ▼
                 POST /api/v1/trading/report   ← also the heartbeat
                 GET  /api/v1/strategies/:id   ← configuration
```

---

## 2. Desired state versus observed state

Every instance row carries two fields, and the difference between them is the
entire design:

* **`desired_state`** — what the control plane wants: `running`, `stopped`,
  `absent`. Written the instant a user presses a button, *before* anything is
  attempted.
* **`state`** — what the execution layer was last observed doing.

Nothing assumes a terminal is running because someone asked for it. `state`
only becomes `running` when the EA actually reports in. This matters because a
dashboard that says "connected" when the process died ten minutes ago is worse
than one that says nothing.

Writing intent first is also what makes the system recoverable: if Rails is
deployed mid-start, the intent is already durable, and the reconciler finishes
the job on its next pass.

---

## 3. The state machine

```
                    ┌──────────────┐
                    │ provisioning │  directories, config, token
                    └──────┬───────┘
                           ▼
    ┌──────────────► ┌──────────┐ ◄──────────────────┐
    │                │ stopped  │                    │
    │                └────┬─────┘                    │
    │                     ▼                          │
    │                ┌──────────┐  process spawned   │
    │                │ starting │                    │
    │                └────┬─────┘                    │
    │                     ▼                          │
    │              ┌────────────┐ up, but silent     │
    │      ┌──────►│ connecting │                    │
    │      │       └─────┬──────┘                    │
    │      │             ▼  first heartbeat          │
    │      │        ┌─────────┐                      │
    │      └────────┤ running │                      │
    │  heartbeat    └────┬────┘                      │
    │  lost              ▼                           │
    │               ┌──────────┐                     │
    │               │ stopping │─────────────────────┘
    │               └──────────┘
    │                     
    │               ┌────────┐         ┌────────────┐
    └───────────────┤ failed │────────►│ terminated │  (final)
      backoff       └────────┘         └────────────┘
```

Transitions are declared in `Mt5Instance::TRANSITIONS` and anything undeclared
raises `Mt5Instance::InvalidTransition`. A transition and its audit row are
written in one database transaction, so the history can never disagree with the
row.

Two states earn their keep:

* **`connecting`** — the process exists but the EA has not called in. Almost
  always a bad token, a broker refusing the login, or the platform URL missing
  from MetaTrader's WebRequest whitelist. Separating it from `running` is what
  stops the interface showing green for a terminal that is not actually talking
  to anything.
* **`failed`** — reachable from `running`, and can *still hold a live process*:
  a stop that fails records a failure while the terminal keeps going. Halting is
  therefore reachable from `failed`, or a crashed terminal could never be
  cleaned up.

---

## 4. Isolation

Isolation is structural, not conventional — nothing depends on a call site
remembering to scope itself.

| Resource | Per instance | Enforced by |
|---|---|---|
| Directory tree | `<root>/mt5-<uuid>/` | every path derives from `instance_dir` |
| File permissions | `0700` dirs, `0600` files | `Mt5::Runtime::Local` |
| Wine prefix | `<instance>/wine` | `WINEPREFIX` in the child environment |
| X display | one number | partial unique index on `(worker_node_id, display_number)` |
| MT5 magic number | one, never reused | unique index; `next_magic_number` only ever increments |
| API token | one per instance | `ApiToken.issue` per provision |
| Logs | `<instance>/logs/` | `Process.spawn` `out:`/`err:` |
| Broker credentials | per user, encrypted | `BrokerCredential`, `encrypts :password` |
| Process group | one per terminal | `pgroup: true`, signals sent to `-pid` |

Two further guarantees:

* **The child environment is built from nothing** (`unsetenv_others: true`).
  Inheriting Rails' environment would hand every user's terminal the database
  URL and the Rails master key.
* **One live instance per user**, enforced by a partial unique index rather than
  a Ruby check. Two concurrent provisions would both pass a check and both spawn
  a terminal against the same broker account — two EAs fighting over the same
  positions.

Magic numbers are never reused even after an instance is terminated: a fresh
terminal adopting a dead one's number would treat its leftover positions at the
broker as its own.

---

## 5. Recovery

`Mt5::Reconcile` runs every minute against every instance. It is deliberately
**not** written as handlers for particular failures — a VPS reboot, a Rails
deploy interrupted mid-start, an MT5 segfault and an operator killing a process
by hand all look identical from here: the row says one thing, the kernel says
another. Comparing observed facts to desired state, rather than trying to work
out *why* they diverged, is what makes it correct after failures nobody
anticipated.

It settles facts before acting on intent. Acting on desired state while the row
still disagrees with the machine would mean acting on a fiction.

| Observed | Meaning | Action |
|---|---|---|
| `stopping`, process gone | the stop finished unobserved | → `stopped` |
| process expected, absent | **a crash** | → `failed`, count it, schedule a retry |
| process not expected, present | **an orphan** | kill it; it would keep trading against a config nothing believes in |
| `starting` too long | stuck boot | stop, → `failed` |
| `connecting` too long | never called in | stop, → `failed`, with a message naming the three usual causes |
| `stopping` too long | graceful stop hung | `SIGKILL`, → `stopped` |
| `running`, heartbeat stale | quiet, but alive | → `connecting` (demoted, not destroyed) |

Then, and only then, it converges towards `desired_state`.

**Restart backoff** is 10s → 30s → 2m → 5m → 15m, and after
`MAX_CONSECUTIVE_FAILURES` (5) the instance stops being retried at all. A crash
loop is worse than being down: it burns the node and floods the user with
alerts. Recovery is only complete when a heartbeat arrives, which clears the
failure counter.

**After a VPS reboot**, every instance row says `running` and no process exists.
The reconciler sees a crash on each, and restarts the ones whose
`desired_state` is `running`. No special boot path, because a reboot is not a
special case.

---

## 6. Idle reaping — how one VPS serves many users

`Mt5::ReapIdle` runs every 5 minutes and **stops** (never deprovisions) any
terminal whose user has no running strategy and no recent activity. The
directory, token and broker configuration all survive, so coming back is a spawn
of a few seconds rather than a setup flow.

This is what makes the economics work: an MT5 terminal under Wine costs roughly
400 MB of RSS at rest, so with a 15-minute idle window a node's capacity is set
by *concurrently active* users, not registered ones.

---

## 7. Observability

**Structured logs.** One line per decision, prefixed `mt5.`, carrying the whole
instance context rather than an id somebody has to look up:

```
mt5.crash_detected {"instance":"mt5-71ab…","user_id":42,"node":"vps-1","state":"running","pid":31337,"heartbeat_age":94,"previous_state":"running"}
```

`Mt5Instance#to_log` is the only thing that builds these, and it is tested to
contain no token, password or secret.

**Audit trail.** `mt5_instance_events` is append-only and read-only after write
(`readonly?`), recording every transition with its reason, source and actor.
Separate from `events`, which audits what a *user* did — most of what happens to
a terminal happens with nobody in the room.

**Health.** `Mt5Instance#healthy?` is `running? && heartbeat_fresh?` — never a
stored boolean. `WorkerNode#heartbeat_fresh?` is the same idea one level up: a
crashed VPS does not get to update a column saying it crashed.

**Operator tasks.** `mt5:status`, `mt5:reconcile`, `mt5:register_node`,
`mt5:drain`, `mt5:quiesce`.

---

## 8. Security

* Broker passwords are encrypted at rest (`encrypts :password`) and have **no
  rendering at all** — `BrokerCredential#inspect` is overridden so an accidental
  interpolation into a log line cannot leak one.
* The API token exists on disk in exactly one place, `config/GoldGrid.set`, mode
  `0600` in a `0700` directory.
* A token per instance, so revoking one terminal does not sign out a user's
  phone, and a leaked token is traceable to one terminal.
* `Runtime#destroy` refuses any path that is not demonstrably inside the
  configured instances root — the guard that stops a bug in path construction
  becoming `rm -rf /`. It is tested against `/etc`.
* Provisioning requires a verified email address. Stopping never requires
  anything: a user must always be able to halt a program trading their money.
* Deleting an account deprovisions terminals first. It never *blocks* deletion
  (a legal obligation), but a terminal it cannot stop is reported to
  `Rails.error` for an operator, because a stranded MT5 process is worse than a
  slow delete.

---

## 9. Turning MetaTrader on

Everything below is the whole change. No application code is modified.

> **Running this on a laptop instead?** §9.7 does all of the below in a
> container, which is the practical route on macOS — the Mac build of
> MetaTrader cannot serve as the execution layer (§9.6).

### 9.1 Prepare the VPS

```bash
# Wine and a headless X server. MT5 is a Windows program.
sudo dpkg --add-architecture i386 && sudo apt update
sudo apt install -y wine64 wine32 xvfb xauth

# One display per instance, from MT5_DISPLAY_BASE upwards.
Xvfb :100 -screen 0 1024x768x16 &   # supervise these properly; see 9.5

sudo mkdir -p /opt/goldgrid/instances
sudo chown goldgrid:goldgrid /opt/goldgrid/instances
sudo chmod 700 /opt/goldgrid/instances
```

Install MetaTrader 5 once, as a **template**. Every instance is built from it,
and provisioning refuses with `no_template` until it is ready.

`/portable` makes MetaTrader keep its state — settings, expert inputs, logs,
downloaded history — in the folder its executable sits in. Pointed at one shared
installation that would mean every user reading and writing the same
`MQL5/Presets/GoldGrid.set`, which is to say every user trading whichever
strategy was provisioned last. So each instance gets its own tree, built at
provision time: everything a terminal only reads is linked from the template,
and the handful of paths it writes are real directories of its own
(`Mt5::Runtime::Local::SHARED_PATHS` and `PRIVATE_PATHS`). `terminal64.exe` is
hard-linked rather than symlinked, because `/portable` resolves the data
directory from the path the executable was invoked by.

Three things have to be true of the template:

1. **The EA is compiled into it.** `MQL5/Experts/GoldGrid.ex5` must exist — see
   [`mt5/README.md`](../mt5/README.md). Provisioning checks for it by name.

2. **The platform URL is in the WebRequest whitelist.** *Tools → Options →
   Experts → "Allow WebRequest for listed URL"*, then quit MetaTrader cleanly so
   it saves. This cannot be automated: MetaTrader stores the list **encrypted**
   in `config/common.ini` (`WebRequest=1` and an opaque `WebRequestUrl=` blob),
   so there is no plaintext to write. Each instance inherits that file, which is
   why it must be set on the template once. Without it every call the EA makes
   fails and terminals sit in `connecting` until they time out.

3. **It is not running while instances are.** MetaTrader writes `config/` only
   on a clean exit, so an open template can overwrite what was configured in it.

### 9.2 Configure Rails

```bash
MT5_RUNTIME=local                       # the only switch that matters
MT5_INSTANCES_ROOT=/opt/goldgrid/instances
MT5_TERMINAL_BINARY=/opt/mt5/drive_c/Program Files/MetaTrader 5/terminal64.exe
MT5_TEMPLATE_DIR=/opt/mt5/drive_c/Program Files/MetaTrader 5   # defaults to the binary's directory
MT5_WINE_BINARY=/usr/bin/wine
MT5_DISPLAY_BASE=100
MT5_NODE_NAME=vps-1
MT5_MAX_INSTANCES=10
MT5_IDLE_TIMEOUT_SECONDS=900
PRODUCT_BASE_URL=https://your-domain    # written into every EA config
```

`MT5_RUNTIME` defaults to `simulated` deliberately: a half-configured production
box should fail to start terminals loudly, not spawn processes against a broker
with half a configuration.

### 9.3 Register the node

```bash
bin/rails mt5:register_node
bin/rails mt5:status
```

### 9.4 First terminal

1. User adds broker credentials (`BrokerCredential`) and verifies their email.
2. `Mt5::Provision.call(user:, strategy:)` — directories, config, token.
3. `Mt5::Start.call(instance:)` → `starting` → `connecting`.
4. The EA boots, reads `GoldGrid.set`, and posts to `/api/v1/trading/report`.
5. `Mt5::RecordHeartbeat` (already wired into the ingestion path) promotes it to
   `running`.

**Start with `InpAllowTrading=false`** — pass `allow_trading: false` (the
default) to `Provision`. The terminal connects, fetches configuration and
reports state without placing a single order. Confirm the dashboard populates
before enabling trading for anyone.

### 9.5 Sizing and supervision

* Budget **~400 MB RSS + ~0.1 core** per idle terminal. `MT5_MAX_INSTANCES`
  should be roughly `(RAM_GB × 1024 × 0.7) / 400`.
* Xvfb displays must be supervised (systemd template unit, one per display) —
  the current design assumes the display exists; a dead Xvfb presents as a
  terminal that starts and never connects.
* Set `LimitNOFILE` and a memory cap per instance if you run near capacity.

---

## 9.6 Local development on macOS (what is installed today)

MetaTrader 5 is installed on the development Mac as the official
`/Applications/MetaTrader 5.app`, which bundles its own Wine:

| | Path |
|---|---|
| Wine | `/Applications/MetaTrader 5.app/Contents/SharedSupport/wine/bin/wine` |
| Prefix | `~/Library/Application Support/net.metaquotes.wine.metatrader5` |
| Terminal | `<prefix>/drive_c/Program Files/MetaTrader 5/terminal64.exe` |
| MetaEditor | `<prefix>/drive_c/Program Files/MetaTrader 5/MetaEditor64.exe` |

**This machine is for compiling and for testing one terminal — it is not the
execution layer.** The Mac build uses a single fixed Wine prefix shared by every
terminal it runs, which is the opposite of the per-instance isolation the
`Local` runtime depends on. Multi-user isolation is a Linux-VPS property and
has to be verified there.

`bin/mt5_compile` builds the EA. One thing worth knowing if you ever call
MetaEditor by hand: **its `/compile:` flag silently does nothing when the path
contains a space**, and the terminal lives under `Program Files`. The script
works around it by running from the `MQL5` directory and passing a relative
path. A compile that "succeeds" with no `.ex5` and no log is this bug.

---

## 9.7 Running the execution layer in Docker

Docker is how you run the managed path (Option A) without a VPS. It supplies
the two things macOS cannot: `/usr/bin/wine` and `/usr/bin/Xvfb`.

### One container, not two

`Mt5::Runtime::Local` starts terminals with `Process.spawn`, **on the machine
Rails is running on**. Putting Rails in one container and the terminals in
another would need `Mt5::Runtime::Remote`, which §10 describes and which does
not exist. So the image holds both. When `Remote` is built, this splits; until
then, it does not.

### Architecture is not a detail

Wine executes Windows x86_64 binaries. On an **x86_64** host that is native
execution and MetaTrader behaves normally. On **arm64** (Apple Silicon) every
instruction is emulated, and MetaTrader under emulated Wine is slow and
unreliable enough that it is not something to trade on — not even on a demo
account, because what you would be testing is the emulator.

Check before starting: `uname -m`.

### Setup

```bash
docker compose build
docker compose run --rm app bin/rails db:prepare

# ONCE, interactively — see below.
docker compose run --rm -e MT5_VNC=1 -p 5901:5901 app \
  docker/mt5-worker/prepare-template.sh

docker compose up
docker compose exec app bin/rails mt5:register_node
```

Then add broker credentials in the interface and press **Start strategy**. The
platform provisions a terminal, signs it in and runs it — no chart, no dragging,
no API token to copy.

### What Docker does not solve

**The WebRequest whitelist still has to be typed in by hand, once.**

MetaTrader stores it encrypted in `config/common.ini` — `WebRequest=1` and an
opaque `WebRequestUrl=` blob. There is no plaintext, so no Dockerfile, script or
environment variable can write it. Every instance inherits that file from the
template, which is why the template is a volume rather than an image layer: it
holds a value that cannot be rebuilt from source.

`prepare-template.sh` installs MetaTrader and compiles the EA, then stops and
tells you to do the rest over VNC:

1. `wine "<template>/terminal64.exe"`
2. Tools → Options → Expert Advisors → tick **Allow WebRequest for listed URL**
3. Add `http://127.0.0.1:3000` — **not** `localhost`. The whitelist silently
   refuses a host name with no dot in it, which is a trap that costs an evening.
4. Quit MetaTrader **cleanly**. It writes `config/` only on a clean exit, so
   killing it discards the whitelist you just typed.

Connect with a VNC viewer at `localhost:5901` (on macOS, Finder → Go → Connect
to Server → `vnc://localhost:5901`). The viewer is off unless `MT5_VNC=1`,
because it is a window onto a session holding a broker login.

### Status

**The container definition has not been built or run.** It is written from the
requirements in §9.1–9.3 and from how `Mt5::Runtime::Local` actually behaves,
but MetaTrader's installer is interactive and its Wine behaviour varies by
version — expect to iterate on `docker/mt5-worker/Dockerfile` the first time.
Everything above `docker compose up` is the part most likely to need work.

---

## 10. Growing past one VPS

The interface is already the seam. Adding a second node is:

1. Implement `Mt5::Runtime::Remote < Base` — the same six methods
   (`prepare`, `start`, `stop`, `alive?`, `destroy`, `resource_usage`) over HTTP
   to a small agent on each node.
2. Return it from `Mt5::Runtime.for(worker_node)` based on the node row.
3. `INSERT` the node and run `mt5:register_node` there.

Nothing above the runtime changes. `Placement` already asks "which node?" and
picks the least-loaded schedulable one; `Reconcile` already goes through
`instance.worker_node.runtime`; capacity, displays and directories are already
per node.

The two things that will need attention when that day comes:

* **Node heartbeats become first-hand.** Today `Mt5::Monitor` heartbeats the
  node it is running on, which is honest only while Rails and MT5 share a
  machine. A remote agent must post its own.
* **Reconciliation should shard by node**, so one unreachable VPS does not slow
  the pass for every other.

---

## 11. What is deliberately not built

* **Any trading logic.** No orders, no grid, no risk enforcement. That is the
  EA's job and the boundary is not moving.
* **A user interface.** No controllers or views for terminals yet — the services
  are the API, and they are what a controller will call.
* **Automatic provisioning on strategy start.** Deliberate: the first terminal a
  user gets should be an explicit act while this is new.
* **The remote runtime.** §10 is a design, not code.
* **Broker credential verification.** `last_verified_at` exists; nothing writes
  it. A wrong password currently presents as a connect timeout, which is
  correct but slow and unhelpful.
* **Per-instance resource limits** (cgroups, `ulimit`). `resource_usage` reports;
  nothing enforces.
