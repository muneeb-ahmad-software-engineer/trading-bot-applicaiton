# Project Handover: Deploy My GoldGrid Rails Trading Application to Dokku

> Last updated: 2026-10-12, after a read-only analysis of the local project
> (Docker setup, Rails production config, MT5 runtime, project docs).

## 0. Summary — what we are doing

Deploy GoldGrid (Rails 8 + Solid Queue + MetaTrader 5 terminals running under
Wine) as a **new, completely separate Dokku app** on the existing Contabo
server, with its own PostgreSQL service, subdomain, HTTPS, persistent MT5
storage and a GitHub Actions deploy workflow — **without touching the
FlexTools apps**. The main engineering work is turning the development-only
MT5 image into a production image, and making redeploys safe for terminals
that hold live positions.

---

## 1. Main Objective

I have a full-stack Ruby on Rails trading application running locally on my Mac. I want to deploy it to my existing Ubuntu server using Dokku and configure automated deployments through GitHub Actions.

The application is called **GoldGrid / Trading Project**. It uses PostgreSQL and includes MetaTrader 5 (MT5) terminal management through Wine.

I already host my FlexTools SaaS website on this server. The new trading application must be deployed as a completely separate application with its own:

* Dokku application
* PostgreSQL service and database(s)
* Domain or subdomain
* Environment variables and secrets
* GitHub Actions deployment workflow
* Persistent storage for application data and MT5 files

**The most important requirement is to protect the existing FlexTools production applications. Do not disrupt them.**

---

## 2. Existing Production Server Configuration

### Server details

* Operating system: Ubuntu 24.04
* Dokku version: 0.37.2
* Server IP: `158.220.108.180`
* SSH port: `52345`
* Global Dokku domain: `vmi2873256.contaboserver.net`
* Approximate resources reported during earlier checks:

  * Free disk space: 181 GB
  * Available RAM: 10 GiB

**Verified 2026-10-12 (read-only check on the server):**

* CPU architecture: `x86_64` (required for Wine/MT5 — §4.3)
* CPU: 6 cores
* RAM: 11 GiB total, 1.5 GiB used, **10 GiB available**, **no swap**
* Disk: 193 GB, 13 GB used, **181 GB free**
* Dokku plugins: `postgres` 1.44.0, `letsencrypt` 0.20.4, `builder-dockerfile`,
  `docker-options`, `storage`, `ports`, `checks`, `ssh-keys`, `cron`,
  `scheduler-docker-local`, `scheduler-k3s`, `ps`, `enter`, `shell` — all enabled
* Proxy: **nginx** (global and per-app, for both `flextools` and
  `frontendflextools`). The other vhost plugins are installed but not in use.
  The new app must also use nginx (`dokku proxy:set <app> nginx` if it is not
  the default).
* Minor: `builder-railpack` is 0.36.7 while core is 0.37.2 — not used by this
  plan (we use the Dockerfile builder), but noted.
* **Re-checked 2026-10-12 (read-only commands run by the owner on the server and
  pasted into the session):** Dokku apps are `flextools` and `frontendflextools` only.
  `goldgrid` does not exist yet. The `goldgrid` report commands returned
  "App does not exist" as expected. Nothing has been created on the server.
* FlexTools restart policy is `on-failure:10`. Our app should use
  `unless-stopped` (matches the local compose file), set with `dokku ps:set`.
* Memory used by all containers: 1.4 GiB (was 1.04 GiB for the FlexTools
  containers alone earlier, so this is roughly the same load).
* **FlexTools resource use (snapshot, 2026-10-12):**

  | Container | CPU | Memory |
  |---|---|---|
  | `frontendflextools.web.1` | 0.00% | 298.5 MiB |
  | `flextools.web.1` | 0.11% | 694.7 MiB |
  | `dokku.postgres.flextools-db` | 0.01% | 51.1 MiB |

  Total ≈ **1.04 GiB** of 11.68 GiB. FlexTools has **no memory limit set**
  (the "limit" shown is the whole host), so it can grow to take any free memory.
  Our app must get its own memory limit so the two cannot starve each other.

### Existing Dokku applications

| Application         | Technology                  | Public domains                                                     |
| ------------------- | --------------------------- | ------------------------------------------------------------------ |
| `frontendflextools` | Next.js frontend            | `flextools.io`, `www.flextools.io`                                 |
| `flextools`         | Ruby on Rails backend/admin | `backend-apis.flextools.io`, `super-admin-management.flextools.io` |

Previously observed port configuration:

* Rails backend: container port `3001`, host port `3101`
* Next.js frontend: container port `3000`, host port `3002`

Do not change them. The new app's port mapping is determined independently (§9).

### Existing PostgreSQL service

* Dokku PostgreSQL service: `flextools-db` (PostgreSQL `17.5`)
* Existing database: `flextools_db`, linked to Dokku app `flextools`
* Not publicly exposed.

**Never reuse `flextools-db` or `flextools_db` for the trading application.**

### Existing backend database configuration

The FlexTools Rails app uses `ENV['DATABASE_URL']`; it also carries
`DATABASE_NAME=tools_production`, which did not appear in the database list.
That discrepancy belongs to FlexTools and must not be modified here.

---

## 3. Local Trading Project — verified facts

### Project path and machine

* Path: `/Users/macbook/Desktop/learning/trading-project/full-stack`
* Git remote: `github.com/muneeb-ahmad-software-engineer/trading-bot-applicaiton`
* Current branch: `deployement-phase`
* Mac: macOS, Intel **x86_64** (so the local Docker image runs Wine natively)

### Versions

* Ruby `3.4.10` (`.ruby-version`, both Dockerfiles)
* Rails `8.0.5.1` (Gemfile.lock)
* Asset stack: Propshaft + importmap + `tailwindcss-rails`; Thruster gem present
* Jobs/cache/cable: `solid_queue`, `solid_cache`, `solid_cable`

### Relevant files

| Path | What it is |
|---|---|
| `Dockerfile` | Stock Rails production image — **no Wine/Xvfb, cannot run MT5** |
| `docker/mt5-worker/Dockerfile` | The image actually used locally — Rails + Wine + Xvfb |
| `docker/mt5-worker/entrypoint.sh` | Starts Xvfb + Openbox per display, optional VNC, then `exec`s the command |
| `docker/mt5-worker/prepare-template.sh` | One-time MT5 install + EA compile into the template volume |
| `compose.yaml` | Local stack: `db` (postgres:16) + `app` |
| `config/database.yml` | Dev/test single DB; **production = 4 databases** |
| `config/environments/production.rb` | Hard-required env vars (§8) |
| `config/puma.rb` | `PORT` (default 3000); Solid Queue inside Puma when `SOLID_QUEUE_IN_PUMA` set |
| `config/recurring.yml` | Production recurring jobs (MT5 reconcile, monitor, reap, prune) |
| `config/initializers/mt5.rb`, `product.rb` | MT5 runtime + `PRODUCT_BASE_URL` |
| `lib/tasks/mt5.rake` | `mt5:register_node`, `mt5:status`, `mt5:drain`, … |
| `doc/EXECUTION_ARCHITECTURE.md` | Authoritative design for the MT5 execution layer (§4–§10) |
| `.github/workflows/ci.yml` | CI only (brakeman, importmap audit, rubocop, tests) — **no deploy workflow yet** |
| `.kamal/`, `config/deploy.yml` | Unused Kamal scaffolding from `rails new` — not part of this plan |
| `config/master.key` | Present locally, git-ignored, docker-ignored — needed as a production secret |

---

## 4. How the local environment works (analysis)

### 4.1 Local stack (`compose.yaml`)

```
Mac (x86_64, Docker Desktop)
└── compose project "goldgrid"
    ├── db   postgres:16  (goldgrid/goldgrid, gold_grid_development, volume pgdata)
    └── app  built from docker/mt5-worker/Dockerfile, init: true
          entrypoint.sh → Xvfb :100..:103 + openbox each → (optional x11vnc :5901)
          CMD → bin/rails server -b 0.0.0.0 -p 3000   (RAILS_ENV=development)
             ├── Puma (web)
             ├── Solid Queue supervisor inside Puma (SOLID_QUEUE_IN_PUMA=1)
             │     └── recurring: mt5_reconcile (1 min), monitor_terminals (1 min), reap_idle (5 min)
             ├── tailwind watcher inside Puma (TAILWINDCSS_IN_PUMA=1)
             └── MT5 terminals, spawned by Mt5::Runtime::Local via Process.spawn
                   one per user, each with its own Wine prefix + X display,
                   under /opt/goldgrid/instances/mt5-<uuid>/
          volumes: mt5template:/opt/mt5   mt5instances:/opt/goldgrid/instances
                   .:/rails (live source)  bundle:/usr/local/bundle
          ports:   3000:3000, 5901:5901
```

The EA inside each terminal calls the platform back at
`PRODUCT_BASE_URL=http://127.0.0.1:3000` (loopback inside the same container),
which must match the URL typed into the template's WebRequest whitelist
**character for character**.

### 4.2 Why Rails and the terminals must share one container

`Mt5::Runtime::Local` starts terminals with `Process.spawn` on the machine Rails
runs on. `Mt5::Runtime::Remote` (for a separate worker) is designed but **does
not exist**. Therefore in production: **one Dokku `web` process, one container,
containing Puma + Solid Queue + Xvfb + all MT5 terminals.** No separate `worker`
process type, and the app must **never be scaled above 1 container**.

### 4.3 MT5 worker image (`docker/mt5-worker/Dockerfile`) — full contents verified

* Base: `ruby:3.4.10-slim-bookworm` (Debian 12)
* WineHQ **stable** from `dl.winehq.org` (Debian's Wine 8.0 is rejected by MT5
  build 6205; Wine ≥ 10 required), `i386` architecture enabled
* `xvfb xauth x11vnc cabextract winbind build-essential git libpq-dev postgresql-client procps`
* `openbox xdotool x11-apps x11-utils imagemagick`
* Wine symlinks in `/usr/bin`; user `goldgrid`; `WORKDIR /rails`
* `bundle install` then `COPY . .`; dirs `/opt/goldgrid/instances`, `/opt/mt5`
* `USER goldgrid`, `EXPOSE 3000 5901`, entrypoint `/usr/local/bin/entrypoint`
* `CMD bin/rails server -b 0.0.0.0 -p 3000`
* Uses BuildKit cache mounts (`RUN --mount=type=cache`) — Dokku's Dockerfile
  builder must have BuildKit enabled (verify on server).
* **x86_64 only.** Wine on arm64 is emulation and not safe for trading.

**It is a development image.** Gaps for production:

| Gap | Effect in production |
|---|---|
| No `RAILS_ENV=production` / `BUNDLE_WITHOUT=development` | Would boot in dev mode with dev gems |
| No `assets:precompile` (Tailwind build) | `.dockerignore` excludes `app/assets/builds/*` → no CSS |
| No `bootsnap precompile` | Slower boot |
| No `db:prepare` on boot (root image's `bin/docker-entrypoint` does this) | Migrations must run some other way |
| `EXPOSE 5901` | Dokku may auto-map it → **unauthenticated VNC exposure risk** |
| No jemalloc | More memory per Puma process |
| `build-essential` etc. left in final image | Larger image; acceptable but not ideal |

### 4.4 Root `Dockerfile`

Standard Rails 8 production image (multi-stage, `RAILS_ENV=production`, asset
precompile with `SECRET_KEY_BASE_DUMMY=1`, user `rails` UID 1000,
`bin/docker-entrypoint` runs `db:prepare`, Thruster on port 80). **It has no
Wine, no Xvfb and no entrypoint for displays**, so MT5 cannot run in it.

### 4.5 Entrypoint (`docker/mt5-worker/entrypoint.sh`)

* Starts `MT5_MAX_INSTANCES` Xvfb displays from `MT5_DISPLAY_BASE`
  (`1280x1024x24`, `-nolisten tcp`), one Openbox each, waits for `:BASE` socket.
* Removes stale `/tmp/.X*-lock`, `/rails/tmp/pids/server.pid`.
* `MT5_VNC=1` → `x11vnc -forever -shared -nopw` on 5901 (**no password**).
* `exec "$@"` → the CMD becomes PID 1 unless an init is injected.
* Xvfb processes are **not supervised**: if one dies, terminals on that display
  fail (a dead Xvfb looks like an MT5 update/network failure).

### 4.6 MT5 template (`prepare-template.sh`)

One-time, in the running container:

1. Install MT5 into a Wine prefix at `/opt/mt5` (downloads ~300 MB).
2. First `/portable` run to create `MQL5/` and `Config/common.ini`.
3. Compile `mt5/GoldGrid.mq5` → `MQL5/Experts/GoldGrid.ex5`.
4. **By hand over VNC:** Tools → Options → Expert Advisors → whitelist
   `PRODUCT_BASE_URL`, then quit MT5 cleanly.

The whitelist is stored **encrypted** and is keyed to the Wine prefix's registry
identity — it cannot be built from source or copied into a fresh prefix. That
is why `/opt/mt5` is a volume, not an image layer, and why it must be
**backed up** (losing it means redoing the VNC step).

### 4.7 Recurring jobs (`config/recurring.yml`, production section)

`monitor_terminals` (1 min), `mt5_reconcile` (1 min — also keeps the worker
node heartbeat fresh; without it Start fails with `no_capacity` ~2 min after
boot), `mt5_reap_idle` (5 min), `prune_old_records` (daily 03:20),
`clear_solid_queue_finished_jobs` (hourly). These only run if Solid Queue runs,
so `SOLID_QUEUE_IN_PUMA=1` is required in production.

---

## 4A. Local runtime findings (2026-10-12)

Checked read-only on the running local stack, plus one rebuild and recreate.

* **Stack:** `goldgrid-app-1` (`goldgrid-app` image) and `goldgrid-db-1`
  (`postgres:16`, healthy). Volumes: `goldgrid_pgdata`, `goldgrid_mt5template`,
  `goldgrid_mt5instances`, `goldgrid_bundle`.
* **Init was missing.** The container predated `init: true` in `compose.yaml`,
  and Docker only applies that at container creation. Fixed by
  `docker compose build app` then `docker compose up -d app`. Verified:
  `docker inspect … Init=true`, and PID 1 is now `/sbin/docker-init`.
  Without it, MT5 terminals left zombie processes (`wineboot`, `main`).
* **One zombie remains:** a `[sh]` child of the Tailwind watcher (PID 128).
  That watcher runs only because `TAILWINDCSS_IN_PUMA=1`. Development only.
  **Never set `TAILWINDCSS_IN_PUMA` in production.**
* **Postgres healthcheck noise:** `pg_isready -U goldgrid` connects to a
  database called `goldgrid`, which doesn't exist, so it logs a FATAL every 5 s.
  Add `-d gold_grid_development` to the check. The container still reports healthy.
* **Restart on boot:** when the app starts, `Mt5::ReconcileInstancesJob`
  restarts any terminal whose `desired_state` is `running`. So stopping the app
  does not stop trading for good; the next start resumes it. Production deploys
  must go flat first (§11).
* **Stopping a strategy does not stop its terminal.** After stopping strategy 8
  and closing its trades (2026-10-12), the terminal stayed `running` with
  `desired_state=running` and a fresh heartbeat. It is only stopped later by the
  idle reaper (`mt5_reap_idle`, 15 min idle in production). Expect this when
  checking that a deploy is safe.
* **Verified recovery after a full restart (2026-10-12).** `docker compose up -d app`
  brought the app back with init active. The reconciler moved the terminal
  `failed` → `connecting` (new PID) → `running` in about two minutes, with a
  fresh heartbeat. The container stayed up with 0 restarts for 15+ minutes.
  Earlier, after a forced recreate, the terminal stayed `connecting` with the
  old PID and no new process for about three minutes. That was not reproduced
  after the clean start. **Likely cause:** `Mt5::Runtime::Local#tracked_pid_alive?`
  accepted any live process at the recorded pid, so after a container recreate
  (PIDs restart from scratch) a reused pid looked like the terminal and the
  reconciler never restarted it. **Fix (2026-10-12):** a recorded pid now counts
  only if its `/proc/<pid>/cmdline` contains the instance uuid
  (`owned_by_instance?` in `app/services/mt5/runtime/local.rb`). Regression tests
  in `test/services/mt5/local_runtime_test.rb`: a stranger's pid is not the
  terminal; a pid that names the instance is. Results: MT5 tests 92/92, full
  suite 614/614, rubocop clean.
  **Live proof (2026-10-12):** three forced recreates (`docker compose up -d
  --force-recreate app`), each with 0 container restarts and init active. Each
  time the terminal went `failed` (~1 min after recreate) → `starting` → `connecting`
  (new process) → `running` with a heartbeat newer than the recreate, about 3–4
  minutes in total. The stuck `connecting` state did not recur.
  **Production deploys must still check that a terminal reaches `running` after
  each deploy, not just that the app responds to `/up`.**
* **App exit at 07:00:04 UTC, cause unknown.** The container exited with code 0 after a
  graceful Puma shutdown. Docker recorded no stop or kill event. Likely
  outside Docker (Docker Desktop, Mac sleep). Not reproduced.
* **Restart policy added locally (2026-10-12):** `restart: unless-stopped` on
  the `app` service. Docker brings the app back after an unexpected exit or a
  Docker Desktop restart, but not after a deliberate `docker compose stop`.
  Verified after recreate: `restartPolicy=unless-stopped`, terminal back to
  `running` in about three minutes. This is a local setting only. **For
  production, check Dokku's own restart policy on the server before relying on
  it.** Do not assume it matches this one.
* **Template volume holds backup builds:** `GoldGrid.ex5` plus `.previous`,
  `.pre-opposite-stop`, `.pre-refactor` and `.pre-spread-fix`. Prune the old ones
  before the template backup in §10.
* **Local sizes:** `tmp/` 3.7 GB, `log/` 384 MB. Neither is copied into an image.
* **Never run `docker compose down -v`.** It deletes `goldgrid_mt5template`
  (the encrypted whitelist can't be rebuilt) and `goldgrid_pgdata`.

---

## 5. Deployment image decision (proposed — needs approval)

**Recommendation:** create a production MT5 image, e.g.
`docker/mt5-worker/Dockerfile.production` (or a `production` target in the
existing file), that keeps the Wine/Xvfb layers and adds what the root
Dockerfile does: `RAILS_ENV=production`, `BUNDLE_DEPLOYMENT=1`,
`BUNDLE_WITHOUT=development:test`, `bootsnap precompile`,
`SECRET_KEY_BASE_DUMMY=1 bin/rails assets:precompile`, jemalloc, and
`EXPOSE 3000` only (no 5901). Point Dokku at it with
`dokku builder-dockerfile:set <app> dockerfile-path <path>`.

Keep the local `docker/mt5-worker/Dockerfile` unchanged so the dev stack keeps working.

Migrations: run via a Dokku `app.json` `scripts.dokku.predeploy`
(`bin/rails db:prepare`) rather than in the entrypoint.

**Approved and built 2026-10-12.** File: `docker/mt5-worker/Dockerfile.production`.
Test results (local, x86_64, throwaway Postgres with all 4 databases):

* Build succeeds (about 15 min first time, Wine layers cached after). Image 1.05 GB.
* Runs as `goldgrid` (UID/GID 1000); `wine-11.0`; `RAILS_ENV=production`;
  only port 3000 exposed; no `master.key`, `.git`, `.claude`, `.idea`, `.DS_Store`
  in the image; no development or test gems.
* `bin/rails db:prepare` works against the 4 database URLs.
* Puma starts and `/up` returns 200. Solid Queue supervisor, dispatcher,
  worker, and scheduler start inside Puma.
* Xvfb displays `:100` to `:109` start; no VNC process and no listening 5901.
* `assume_ssl = true` makes Rails treat every request as HTTPS, so Rails does
  **not** redirect plain HTTP. `/` returns 200 over HTTP inside the container.
  The HTTP → HTTPS redirect has to be handled by Dokku's nginx on the server
  (verify when setting up the app), not by Rails. `/up` works over HTTP without
  any change.
* Not yet tested: the terminals themselves in this image (needs the MT5
  template, which is prepared on the server or in the dev stack).

Changes made while testing: `.dockerignore` now excludes `.claude`, `.idea`,
and `.DS_Store`. (The temporary `/up` redirect exclusion was reverted: not needed.)

---

## 6. MT5 Entrypoint and Security

* VNC stays **disabled** in production (`MT5_VNC` unset). Port 5901 is never
  published.
* The one-time template whitelist step needs a GUI. Proposed approach: run a
  one-off container with `MT5_VNC=1` whose 5901 is bound to **127.0.0.1 on the
  server only**, and reach it from the Mac through an **SSH tunnel**
  (`ssh -p 52345 -L 5901:127.0.0.1:5901 …`). Never bind it to the public IP.
  Exact Dokku command to be designed and approved before use.
* Only the web port is routed through Dokku's nginx. PostgreSQL, VNC and X
  displays are never exposed (`-nolisten tcp` already set on Xvfb).
* Terminals get a clean environment (`unsetenv_others: true`), so the database
  URL / master key are not inherited by MT5 processes.

---

## 7. GitHub Actions and Deployment

The repo currently has only `.github/workflows/ci.yml` (no deploy).

The FlexTools workflows use `DOKKU_DEPLOY_KEY`, `158.220.108.180:52345` and
`ssh-keyscan`. The FlexTools backend workflow stops/destroys its container
before pushing — **never copy that pattern.**

**Written 2026-10-12, not yet run or committed:** `.github/workflows/deploy.yml`.
Trigger: automatically after the `CI` workflow succeeds on `main` (so a merge into
`main` deploys), plus a manual run that must type `deploy-goldgrid`. This was
changed on the owner's request on 2026-10-12, from manual-only. It reuses the
existing `DOKKU_DEPLOY_KEY` secret and pushes only to `goldgrid`. The workflow
only starts once its file is on `main`. The gate is `mt5:deploy_gate` (`lib/tasks/mt5.rake`,
tested in `test/tasks/mt5_deploy_gate_test.rb`): it blocks only on terminals in
`starting`, `connecting`, `stopping`, or `failed`. Open positions do not block.
Known gaps: host key is pinned with `ssh-keyscan` (trust on first use, same as
FlexTools); the health check needs the HTTPS domain (step 6) before it can pass;
the post-deploy "terminals back to running within 10 min" check is not written yet,
because no terminal runs until the MT5 template exists.

Original plan (kept for reference):

1. Trigger on push to the chosen branch (and/or manual `workflow_dispatch`).
2. Checkout with full history (`fetch-depth: 0`) — Dokku needs it for git push.
3. SSH with a **dedicated** deploy key (new GitHub secret, e.g.
   `GOLDGRID_DOKKU_DEPLOY_KEY`), added to Dokku with `ssh-keys:add`.
4. `git push dokku@158.220.108.180:<new-app>` over port 52345 — new app only.
5. **Pre-deploy safety gate** (see §11): refuse if any strategy is running
   with open positions, unless explicitly overridden.
6. Post-deploy: `curl -fsS https://<domain>/up` health check.
7. Never stops, destroys or reconfigures any other app.

Secrets are set once on the server with `dokku config:set`, not in the workflow
and not in the repo.

---

## 8. Production Environment Variables and Database

### 8.1 Database — production needs FOUR databases

`config/database.yml` production section:

| Role | Database name (default) | URL variable | Migrations |
|---|---|---|---|
| primary | `DATABASE_NAME` → `gold_grid_production` | `DATABASE_URL` | `db/migrate`, `db/schema.rb` |
| cache | `<name>_cache` | `CACHE_DATABASE_URL` | `db/cache_schema.rb` |
| queue | `<name>_queue` | `QUEUE_DATABASE_URL` | `db/queue_schema.rb` |
| cable | `<name>_cable` | `CABLE_DATABASE_URL` | `db/cable_schema.rb` |

`dokku postgres:link` only sets `DATABASE_URL`. If the other three are not set,
those connections fall back to `localhost` and the `$USER` username and fail.

**Proposed:** one new Dokku Postgres service (e.g. `goldgrid-db`), linked to the
new app, plus `CACHE_/QUEUE_/CABLE_DATABASE_URL` set to the **same service with
`_cache`, `_queue`, `_cable` database names**. `db:prepare` creates and loads
all four (the Dokku service user can create databases — verify).

Note: in development, Solid Queue tables live in the primary DB (migration
`20260925090000_install_solid_queue_tables.rb`); production uses the separate
queue database via `config.solid_queue.connects_to`. Both are valid; just be
aware they differ.

PostgreSQL version: local is 16, server has 17.5 for FlexTools. Either is fine
for Rails 8; pick one explicitly when creating the service.

### 8.2 Required environment variables (from the code, not guessed)

**Boot fails without these** (`production.rb` uses `ENV.fetch` without default):

| Variable | Purpose |
|---|---|
| `APP_HOST` | Host for mailer links (the new subdomain) |
| `SMTP_ADDRESS` | SMTP server — production sends real email (verification, alerts) |

**Required for a working app:**

| Variable | Value / note |
|---|---|
| `RAILS_ENV` | `production` |
| `RAILS_MASTER_KEY` | from local `config/master.key` (decrypts credentials, incl. Active Record encryption for broker passwords) — **set on server, never commit or paste** |
| `SECRET_KEY_BASE` | only if not coming from credentials — verify |
| `DATABASE_URL` | set by `postgres:link` |
| `CACHE_DATABASE_URL`, `QUEUE_DATABASE_URL`, `CABLE_DATABASE_URL` | §8.1 |
| `SMTP_PORT` (587), `SMTP_USER_NAME`, `SMTP_PASSWORD`, `MAILER_FROM` | SMTP provider to be chosen |

**Email is deferred until after the first deploy (decided 2026-10-12). Use these placeholders for now:**

| Variable | Placeholder | Why |
|---|---|---|
| `SMTP_ADDRESS` | `smtp.invalid` | Required to boot. `.invalid` never resolves, so nothing is sent by mistake. |
| `SMTP_PORT` | `587` | Default, fine as is. |
| `SMTP_USER_NAME` / `SMTP_PASSWORD` | left unset | No provider yet. |
| `MAILER_FROM` | `no-reply@flextools.io` | Not yet verified with a provider, so mail will not be delivered. |
| `APP_HOST` | `trading.flextools.io` | Used in email links. |

What the placeholders mean in practice, verified in the code:
- All mail is sent with `deliver_later`, so it runs as a background job. Signup
  still succeeds, but the verification email never arrives, so new users can't
  verify their accounts.
- Alert emails fail as separate background jobs. The monitoring job itself
  isn't affected, but failed mail jobs will pile up and should be checked.
- The owner's account should be created from the Rails console and marked
  verified (one-off data step, to be run with you).
- Don't invite other users until a real provider is set up and tested.
| `SOLID_QUEUE_IN_PUMA` | `1` (mandatory — recurring MT5 jobs) |
| `PORT` | `3000` (Puma) — verify what Dokku sets for Dockerfile apps |
| `RAILS_MAX_THREADS`, `WEB_CONCURRENCY`, `JOB_CONCURRENCY`, `RAILS_LOG_LEVEL` | optional tuning |

**MT5:**

| Variable | Production value (proposed) |
|---|---|
| `MT5_RUNTIME` | `local` (default `simulated` = nothing real runs) |
| `MT5_INSTANCES_ROOT` | `/opt/goldgrid/instances` |
| `MT5_TEMPLATE_DIR` | `/opt/mt5/drive_c/Program Files/MetaTrader 5` |
| `MT5_TERMINAL_BINARY` | `/opt/mt5/drive_c/Program Files/MetaTrader 5/terminal64.exe` |
| `MT5_WINE_BINARY` | `/usr/bin/wine` |
| `MT5_XVFB_BINARY` | `/usr/bin/Xvfb` |
| `MT5_DISPLAY_BASE` | `100` |
| `MT5_MAX_INSTANCES` | sized from RAM: `(RAM_GB × 1024 × 0.7) / 400`, but leave headroom for FlexTools — start with `4` |
| `MT5_NODE_NAME` | e.g. `contabo-1` |
| `MT5_NODE_HOSTNAME` | set explicitly (container hostname changes every deploy) |
| `MT5_IDLE_TIMEOUT_SECONDS`, `MT5_REPORT_SECONDS`, `MT5_NODE_REGION` | optional |
| `PRODUCT_BASE_URL` | **decision needed:** `http://127.0.0.1:3000` (loopback, as locally — EA traffic never leaves the container) vs. `https://<domain>`. Whatever is chosen must be typed into the template whitelist exactly. Loopback is recommended. |

Must **not** be set in production: `TAILWINDCSS_IN_PUMA`, `MT5_VNC`,
`SECRET_KEY_BASE_DUMMY`.

### 8.3 After first deploy

`bin/rails mt5:register_node` once (it is an upsert, safe to re-run), then
`bin/rails mt5:status`.

---

## 9. Domain, HTTPS, and Networking

* **Chosen subdomain: `trading.flextools.io`** (decided 2026-10-12). DNS A record →
  `158.220.108.180`.
* **DNS check (2026-10-12):** `trading.flextools.io` has no A or CNAME record, so
  the name is free. `flextools.io` and `www.flextools.io` resolve to Cloudflare
  addresses (`172.67.190.109`, `104.21.19.225`), so the zone is probably behind
  Cloudflare. **Create the new record as DNS only (grey cloud), not proxied.**
  Let's Encrypt's HTTP check must reach the server directly. Confirm the proxy
  setting of the existing FlexTools records in Cloudflare before copying it.
  `backend-apis.flextools.io` and `super-admin-management.flextools.io` returned no
  public record from this lookup, so their setup is unknown.
* Port mapping: **only** `http:80:3000` and `https:443:3000`. Explicitly set
  with `dokku ports:set` so the `EXPOSE 5901` in the image is never mapped.
* HTTPS via `dokku letsencrypt:enable <new-app>` only.
* `production.rb` has `assume_ssl` and `force_ssl` enabled → the app must sit
  behind HTTPS; `/up` is the health endpoint (silenced in logs).
* Postgres stays internal (no `postgres:expose`).
* FlexTools certificates were reported valid until 2026-11-24 / 2026-12-22;
  renewal not independently confirmed — recheck, but do not modify.

---

## 10. Persistence, Backups, and Recovery

### Persistent storage (Dokku `storage:mount`)

| Host path (proposed) | Container path | Contents | Loss impact |
|---|---|---|---|
| `/var/lib/dokku/data/storage/goldgrid/mt5` | `/opt/mt5` | MT5 template + encrypted whitelist | Must redo VNC step |
| `/var/lib/dokku/data/storage/goldgrid/instances` | `/opt/goldgrid/instances` | Per-user terminals, Wine prefixes, logs, API tokens | Terminals reprovisioned |
| `/var/lib/dokku/data/storage/goldgrid/storage` | `/rails/storage` | Active Storage (`:local`) | Uploaded files |

Ownership must match the container user (`goldgrid`, UID to be checked) and
instance dirs are `0700`.

### Backups (none confirmed yet)

* Postgres: `dokku postgres:backup` / schedule to off-server storage, all 4
  databases; test a restore.
* MT5 template directory: tar snapshot after the whitelist step, stored
  off-server.
* Do not assume a backup exists because a command was attempted.

---

## 11. Trading-specific deployment risks (new)

1. **A redeploy kills every running terminal.** Terminals are child processes
   of the container. **Decided 2026-10-12: deploys may run with open trades**
   (option 2). Broker-side stop-loss and take-profit keep protecting open
   positions, but nothing reverses or adjusts them until the terminal is back.
   Expected unmanaged window: about 3–4 minutes (measured in the recreate
   tests). Rules that follow from this:
   - Pre-deploy gate in the workflow: refuse only if the node or a terminal is
     in an unknown state (for example, a terminal stuck in `connecting` or
     `failed` before the deploy starts). Open positions do not block.
   - Post-deploy gate: every instance that was `running` before the deploy must
     reach `running` with a fresh heartbeat within 10 minutes. If one does not,
     the deploy is marked failed.
   - Strategies are never restarted by the deploy. Restart manually from the UI
     after the post-deploy gate passes.
   - Before the first live deploy, confirm each strategy's stop-loss/take-profit
     is set broker-side. Without it, an open position has no protection during
     the gap.
2. **Zero-downtime overlap.** Dokku starts the new container before retiring
   the old one. Both would see the same `/opt/goldgrid/instances` volume; the
   new container's reconciler can start a second terminal for the same broker
   account while the old one is still alive → **two EAs on one account**.
   **Decided 2026-10-12: option 1, no overlap.** Turn off zero-downtime for
   this app so the old container fully stops before the new one starts.
   Terminals return in about 3–4 minutes, the same gap accepted in §11.1.
   Set via `checks:disable` (or equivalent retire-immediately setting), to be
   verified on the server before the first deploy.
   Test before the first real deploy: with a demo-account terminal running,
   deploy once and confirm only one `terminal64.exe` process exists during the
   swap, and that the instance returns to `running`.
   Rejected for now: draining terminals first (more code, more failure points)
   and a database lock (most code, easiest to get wrong).
3. **Zombie processes.** Without an init as PID 1 dead terminals become
   zombies that look alive. Locally `init: true` fixes this; on Dokku verify
   that `--init` is injected (`scheduler-docker-local` init-process, or
   `docker-options:add … --init`).
4. **Resource contention with FlexTools.** ~400 MB RAM + 0.1 core per idle
   terminal, more when trading. Set a Dokku memory limit on the new app so it
   can never starve FlexTools.
5. **Single container only.** Never `ps:scale web=2`.
6. **Start with `allow_trading: false`** on the first production terminal.

---

## 12. Required Working Style and Safety Rules

1. Give me **one command or one step at a time**.
2. Explain what the command does and why it is necessary.
3. Wait for my output before moving to the next step.
4. Prefer read-only inspection before changing anything.
5. Do not run Docker commands unless I explicitly request them.
6. Do not edit files, create Dokku resources, change configuration, push code, or deploy without my explicit approval.
7. Never stop, restart, destroy, unlink, delete, or reconfigure the existing `flextools` or `frontendflextools` apps or their PostgreSQL service.
8. Never reuse the existing FlexTools database or its credentials.
9. Never ask me to paste passwords, tokens, private SSH keys, or unredacted database connection strings.
10. Remind me to redact sensitive values before sharing command output.
11. Do not assume that configuration from local development is suitable for production.
12. Do not assume a deployment is safe until the image, database, ports, environment variables, persistence, backups, domain, HTTPS, and GitHub workflow have been reviewed.
13. If a configuration detail is unknown, inspect it or ask me rather than guessing.
14. Keep instructions clear and beginner-friendly.
15. Never deploy or restart the trading app while a strategy has open positions (§11).

---

## 13. Progress Checklist

### Done

- [x] Server details, Dokku version, existing apps, domains, ports
- [x] Existing `flextools-db` identified (not to be reused)
- [x] Existing FlexTools workflows reviewed (stop/destroy pattern to avoid)
- [x] Local Ruby / Rails versions
- [x] Root `Dockerfile` (cannot run MT5)
- [x] Full `docker/mt5-worker/Dockerfile` (bookworm + WineHQ, dev-only)
- [x] `entrypoint.sh` and `prepare-template.sh`
- [x] `compose.yaml` and how the local stack works (§4)
- [x] `config/database.yml` — production needs 4 databases
- [x] Production env vars derived from code (§8.2)
- [x] Process model: one container, Solid Queue in Puma, no separate worker
- [x] Health endpoint `/up`; Puma `PORT`
- [x] Local machine is x86_64
- [x] Local stack inspected: containers, volumes, logs, template contents, DB state (§4A)
- [x] Init confirmed active locally (`Init=true`, PID 1 = docker-init) (§4A)
- [x] Fix Postgres healthcheck in `compose.yaml` (`-d gold_grid_development`), applied and verified healthy (§4A)
- [ ] Prune old `GoldGrid.ex5` backups from the template before backing it up (§4A, §10)
- [ ] Production: confirm init is injected on Dokku (`--init` via docker-options or equivalent) and zombies stay at zero (§11.3)

### To do (in order)

- [x] Server read-only checks: `x86_64`, 6 CPU, 10 GiB RAM free, 181 GB disk, Dokku plugins (postgres 1.44.0, letsencrypt 0.20.4, builder-dockerfile, docker-options, storage, ports)
- [x] Confirm active Dokku proxy: nginx
- [x] Measure FlexTools' RAM/CPU: ~1.04 GiB total, near-zero CPU, no memory limits set
- [ ] Set a memory limit on the new app (`dokku resource:limit --memory …`) so it cannot starve FlexTools
- [x] Decide subdomain: `trading.flextools.io`
- [x] Create DNS A record `trading.flextools.io` → `158.220.108.180`, DNS only (not proxied). Verified 2026-10-12 via 1.1.1.1, 8.8.8.8 and 9.9.9.9; the local resolver still caches an empty answer.
- [~] SMTP provider deferred until after first deploy; placeholders in §8.2 (`SMTP_ADDRESS=smtp.invalid`). Before inviting other users: pick a provider, verify the domain, test, and check failed mail jobs.
- [ ] Decide `PRODUCT_BASE_URL` (loopback recommended)
- [x] Decide redeploy strategy for live terminals: deploys allowed with open trades, post-deploy gate (§11.1)
- [x] Decide zero-downtime overlap handling: option 1, no overlap (§11.2)
- [ ] Verify on the server that zero-downtime is off for the app, and test one demo-terminal deploy (§11.2)
- [x] Approve and write production MT5 Dockerfile (§5); build-tested locally, boot-tested with Postgres
- [x] Write `app.json` predeploy (`bin/rails db:prepare`); tested twice on a fresh database, both exit 0
  - Dokku runs predeploy before the new container starts, and the old version is still running then (§11.2 turns off overlap, not this step). Every migration must therefore work with the previous version of the code still running. Drop or rename columns in two deploys, not one.
- [x] Create Dokku app `goldgrid`: memory 4g, restart `unless-stopped`, `--init` on deploy/run, zero-downtime off (verified 2026-10-12, §2)
- [x] Set dockerfile-path, port mapping (80 → 3000) (2026-10-12; "detected 5000" is Dokku's guess before the first deploy, our explicit mapping wins; recheck after deploy)
- [x] Create `goldgrid-db` Postgres 16 service and link `DATABASE_URL` (2026-10-12). The password was pasted into the chat: rotate it before go-live.
- [ ] Set the 3 extra DB URLs (`goldgrid_db_cache`, `_queue`, `_cable`)
- [x] Set all env vars / secrets with `dokku config:set` (names verified with `config:keys`; RAILS_MASTER_KEY length checked as 33)
- [x] Create storage directories and `storage:mount` (owned 1000:1000)
- [ ] First deploy (manual `git push`), `db:prepare`, `/up` check
- [ ] Let's Encrypt for the new app
- [ ] `mt5:register_node`; prepare MT5 template via SSH-tunnelled VNC; back up template
- [ ] First terminal with `allow_trading: false`
- [ ] Postgres + template backups, off-server, restore tested
- [ ] Dedicated deploy key + `.github/workflows/deploy.yml` with safety gate and health check
- [ ] Confirm FlexTools apps unaffected after every step

---

## 14. Exact Next Step

Local analysis and the basic server check are done (§2). Server is `x86_64`,
has enough free RAM and disk, and has the Dokku plugins we need.

The read-only checks are complete: proxy is nginx, and FlexTools uses about
1.04 GiB with no memory limits. Nothing else needs checking on the server.

The decisions needed before any change are, in order:
1. Subdomain (and DNS A record → `158.220.108.180`)
2. SMTP provider (`SMTP_*`, `MAILER_FROM`)
3. `PRODUCT_BASE_URL` (loopback recommended)
4. Redeploy strategy for live terminals (§11.2)
5. Approval of the production MT5 Dockerfile (§5)
