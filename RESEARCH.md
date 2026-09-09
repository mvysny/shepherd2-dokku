# RESEARCH.md — what we know about Dokku

Everything this project has established about **Dokku**, the upstream product it is built on. This is
the reference: when a design argument needs "does Dokku do X?", the answer belongs here and gets cited
from wherever it is used, rather than re-derived.

**Why a separate file.** Dokku is a dependency we do not own, so its behaviour is neither a decision of
ours (`DECISIONS.md`) nor an operator instruction (`README.md`) nor a scratchpad note (`ideas/`). Facts
about it need one durable home that survives the idea that prompted the lookup — see `D_research_md`.

**How to read it.** Every claim is either **[docs]** (stated in Dokku's own documentation), **[src]**
(read out of a repository), or **[unverified]** (inferred, or reported by a third party, and *not yet
run on a box*). Treat `[unverified]` as a hypothesis: the whole point of marking it is that the
first thing the box does is turn those into facts. Checked **2026-09-09** against Dokku **v0.38.27**
unless noted; re-check before relying on a version-sensitive claim.

---

## Versions, platform, install

- **Current line: v0.38.x**, latest v0.38.27 (2026-08-12). MIT licence, ~32.1k GitHub stars. **[docs]**
- **Supported OS:** Ubuntu 22.04 / 24.04, or Debian 11+, on amd64 or arm64. **[docs]**
- **Minimum memory:** 1 GB for the Docker scheduler (2 GB per node for the k3s scheduler, which we do
  not use). No documented disk minimum. **[docs]**
- **Install is two commands**, as root: **[docs]**

  ```bash
  wget -NP . https://dokku.com/install/v0.38.27/bootstrap.sh
  sudo DOKKU_TAG=v0.38.27 bash bootstrap.sh
  ```

  Takes 5–10 minutes. It installs Docker itself if missing. **The version is pinned in two places** —
  the URL path and `DOKKU_TAG` — so an upgrade means editing both. **[docs]**
- **Post-install, two steps:** authorise an admin SSH key and set the global domain. **[docs]**

  ```bash
  cat ~/.ssh/authorized_keys | sudo dokku ssh-keys:add admin
  dokku domains:set-global dokku.me
  ```

- **Docker version:** not documented as a hard requirement. Relevant anyway because BuildKit is the
  default only from Docker Engine 24+ (below). **[docs]**
- **Security floor: 0.38.2 or later.** 0.38.2 bundled four security fixes — app-name restriction against
  command injection, archive-extraction symlink hardening, 0600 on the `.netrc`, and openresty include
  sanitisation — and all 0.38.x users are told to upgrade. Never pin below it. **[docs]**
- **0.38.0 was a migration release:** a batch of `DOKKU_*` config environment variables became
  namespaced plugin properties (auto-migrated on first run, originals unset), and the global/per-app ENV
  file paths moved to a consolidated config path. Anything written against pre-0.38 docs or blog posts
  may name variables that no longer exist. **[docs]**

## Deploying: builders and git

### The Dockerfile builder

- **Auto-detected** when a `Dockerfile` exists at the repo root — but only if `herokuish` and `pack`
  builders do not claim the app first. **[docs]**
- **Dockerfile path is settable**, relative only: **[docs]**

  ```bash
  dokku builder-dockerfile:set node-js-app dockerfile-path .dokku/Dockerfile
  ```

- **BuildKit** is on by default on Docker Engine 24+. Below that, enable it in `/etc/default/dokku`:
  **[docs]**

  ```bash
  echo "export DOCKER_BUILDKIT=1" | sudo tee -a /etc/default/dokku
  echo "export BUILDKIT_PROGRESS=plain" | sudo tee -a /etc/default/dokku
  ```

- **Cache mounts are documented and supported** ("BuildKit directory caching"), with a worked example.
  Dokku's own example is apt, and it names `$HOME/.m2` as the Maven path. **[docs]**
- **Build args** go through `docker-options`, and the documented form passes the *name only*, taking the
  value from the environment the build runs in: **[docs]**

  ```bash
  dokku docker-options:add node-js-app build '--build-arg NODE_ENV'
  ```

  An explicit `--build-arg NAME=value` in the same position is the obvious way to pin a value (this is
  how a per-project secret like a Vaadin offline key would be passed), but Dokku's docs do not show that
  form. **[unverified]**

### `docker-options` and its sharp edge

Three phases — `build`, `deploy`, `run`: **[docs]**

```bash
dokku docker-options:add    [--process PROC...] <app> <phase(s)> OPTION
dokku docker-options:remove [--process PROC...] <app> <phase(s)> OPTION
dokku docker-options:clear  [--process PROC...] <app> [<phase(s)>...]
dokku docker-options:report [<app>] [<flag>] [--format json|stdout]
```

Two caveats that matter, quoted:

- **`build` options are *container* options for the builder, not `docker build` flags.** "A given builder
  may strip out or ignore options that are unsupported by the builder in question — as an example, the
  `dockerfile` builder does not support mounted volumes." So this is **not** a way to reach
  `--cache-to` / `--cache-from`. **[docs]**
- **`run` is not `docker run`.** "The `run` phase does *not* correspond 1-to-1 to `docker run` … Specifying
  a container option at the `run` phase will only be invoked on containers created by the `run` plugin
  and cron tasks." Deployed processes take `deploy`. **[docs]**

### `git:sync` — the SCM poll

The command that replaces Jenkins. **[docs]**

```bash
dokku git:sync [--build|--build-if-changes] [--skip-deploy-branch] <app> <repository> [<git-ref>]
dokku git:sync node-js-app https://github.com/heroku/node-js-getting-started.git main
```

- Clones or fetches from a remote URL; takes an optional branch, tag or commit SHA.
- `--build` always builds; **`--build-if-changes` builds only when the fetch moved the ref** — exactly
  the poll-SCM semantics.
- The app must already exist (`apps:create`).

Related git commands: **[docs]**

```bash
dokku git:set [--global] <app> <key> <value>   # deploy-branch (default master), keep-git-dir,
                                               # rev-env-var (default GIT_REV), archive-max-files/-size
dokku git:report [<app>] [<flag>|--format json]
dokku git:initialize <app>                     # create the pre-receive hook
dokku git:from-image [--build-dir DIR] <app> <docker-image> [user] [email]
dokku git:from-archive [--archive-type TYPE] <app> <archive-url> [user] [email]
dokku git:allow-host <host>                    # add to known_hosts
dokku git:generate-deploy-key                  # ed25519 keypair
dokku git:public-key                           # print it, to install as a deploy key upstream
dokku git:auth <host> [<username> <password>]  # netrc auth; password can come from stdin
dokku git:auth-status <host> [...]             # since 0.38.0; exit 0 match / 1 none / 2 mismatch
```

**Private repos** are handled either by an SSH key in `/home/dokku/.ssh/` installed as a deploy key
upstream, or by a `.netrc` entry via `git:auth`; Dokku recommends a personal access token on a bot
user. `git:auth` writes credentials **per host, not per app** — one GitHub token for the whole box —
which is a coarser grain than one credential per project. **[docs]**

### There is no built-in scheduler for rebuilds

Dokku's `cron` plugin (`app.json` `cron` array) runs commands **inside the app's existing image** in a
one-off `run` container: **[docs]**

```json
{ "cron": [ { "command": "npm run send-email", "schedule": "@daily" } ] }
```

```bash
dokku cron:list <app>       dokku cron:report [<app>]     dokku cron:run <app> <cron_id>
dokku cron:suspend/resume <app> <cron_id>                 dokku cron:set ...
```

It **cannot trigger a build** — it executes the deployed image, so it is useless for periodic rebuild.
Also: only `PATH` and `SHELL` are set in the cron template, the command is exec'd directly so `;`,
`&&`, `|` and `>` are *not* interpreted, tasks are reaped at 24 h, and schedules run in the host
timezone (usually UTC). **[docs]**

**Consequence: periodic rebuild is a host crontab line calling `dokku git:sync --build-if-changes`.**
Not an in-product feature.

## Ports — the `EXPOSE` trap

```bash
dokku ports:list <app>
dokku ports:add   <app> <scheme>:<host-port>:<container-port>
dokku ports:set   <app> <scheme>:<host-port>:<container-port>   # replaces all mappings
dokku ports:remove <app> <host-port>
dokku ports:clear <app>
dokku ports:report [<app>]
```

Schemes: `http`, `https`, `grpc`, `grpcs` (nginx). **[docs]**

- **Default for buildpack apps and Dockerfile apps with no `EXPOSE`:** a listener on 80 (and 443 with
  SSL) proxying to container port **5000**. **[docs]**
- **With `EXPOSE` in the Dockerfile, Dokku creates listeners on the *exposed* ports**, proxying to the
  matching container port. So a `Dockerfile` with `EXPOSE 8080` — Shepherd's contract — lands the app on
  **`app.domain:8080`**, not on 443. **[docs]**
- Fix, once per app: **[docs, syntax]**

  ```bash
  dokku ports:set myapp http:80:8080 https:443:8080
  ```

- **The default is computed once and never revisited:** "this default behavior **will not** be
  automatically changed on subsequent pushes". And don't set `PORT` by hand — port mappings manage it.
  **[docs]**
- The Traefik plugin **only supports `http:80` and `https:443` mappings**, so under Traefik the fix-up
  above is not optional. **[docs]**

## Proxies

```bash
dokku proxy:set --global type nginx|caddy|haproxy|traefik|openresty
dokku proxy:set <app> type <impl>            # per-app override; computed-type is the effective one
dokku proxy:build-config [--parallel count] [--all|<app>]
dokku proxy:enable|disable [--parallel count] [--all|<app>]
dokku proxy:clear-config <app>|--all         # since 0.27.0
dokku proxy:report [<app>] [<flag>]
```

Five first-party implementations; **nginx is the default**. Properties: `type`, `proxy-port`,
`proxy-ssl-port` (app + global), `disabled` (app only); app beats global. "Changing the proxy does not
stop or start any given proxy implementation" — each has its own start procedure. Custom proxy plugins
must be named `*-vhosts` for the scheduler integration to work. **[docs]**

### nginx (the default) — and why it is architecturally different

- **nginx runs on the host as a system service installed by apt, not in a container.** **[docs]**
- It reaches app containers via **`.DOKKU_APP_<PROCESS_TYPE>_LISTENERS`** — "a list of IP:PORT pairs for
  the respective app containers" — i.e. it dials the container's IP directly. **[docs]**
- **Therefore nginx does not need to share an app's Docker network.** This deletes shepherd-traefik's
  network-sharing gotcha outright (a host process can route into any bridge network the daemon created),
  which is the single biggest architectural difference between the two designs. **[docs, inference —
  the docs never state the negative, but a host-side proxy dialling container IPs cannot need an
  attachment]**
- **`dokku-event-listener` runs in the background**, watches container state and rebuilds proxy config
  when a web process's IP changes. That is the in-product equivalent of
  `shepherd-traefik-connect-networks`. **[docs]**
- **Per-app ingress tuning is first-class** — `nginx:set`, app or global scope, app beating global then
  Dokku's default: **[docs]**

  | Property | Default |
  |---|---|
  | `client-max-body-size` | `1m` |
  | `proxy-read-timeout` | `60s` |
  | `x-forwarded-for-value` | `$remote_addr` |
  | `x-forwarded-port-value` | `$server_port` |
  | `x-forwarded-proto-value` | `$scheme` |
  | `x-forwarded-ssl` | (empty; `on`/`off`) |
  | `hsts` | `true` |
  | `hsts-include-subdomains` | `true` |
  | `hsts-max-age` | `15724800` |
  | `hsts-preload` | `false` |
  | `bind-address-ipv4` | `0.0.0.0` |
  | `bind-address-ipv6` | `[::]` |

- Escape hatch: a per-app **`nginx.conf.sigil`** template, with `{{ .APP }}`, `{{ .PROXY_PORT }}`,
  `{{ .APP_SSL_PATH }}` and the listener variables. `nginx:show-config` and `nginx:validate-config`
  inspect and check the generated file. **[docs]**
- **Since 0.38.0, an undeployed app still gets a minimal nginx config returning 502** — so its domain
  resolves and monitoring sees a non-200 rather than a connection failure. Replaced by the real config
  on first successful deploy. **[docs]**

### Traefik (official plugin)

Label-driven, exactly like shepherd-traefik — so existing Traefik knowledge transfers. **[docs]**

```bash
dokku proxy:set node-js-app type traefik
dokku ps:rebuild node-js-app

dokku traefik:set --global letsencrypt-email automated@dokku.sh
dokku traefik:set --global challenge-mode dns            # dns | http | tls (default tls)
dokku traefik:set --global dns-provider cloudflare
dokku traefik:set --global dns-provider-cf_api_email user@example.com

dokku traefik:labels:add    node-js-app traefik.directive value
dokku traefik:labels:remove node-js-app traefik.directive
dokku traefik:labels:show   node-js-app
dokku traefik:show-config <app>
dokku traefik:start | traefik:stop | traefik:report [app] | traefik:logs [--num N] [--tail]
```

Other global properties: `image`, `log-level`, `api-enabled`, `dashboard-enabled`,
`basic-auth-username`, `basic-auth-password`, `http-entry-point`, `https-entry-point`. **All
`traefik:set` properties are global-only** — there is no per-app Traefik setting, so per-app ingress
tuning has to go through `traefik:labels:add`. **[docs]**

Three restrictions, quoted: **[docs]**

- "Only `web` containers have Traefik labels injected by the plugin".
- "The traefik plugin only supports automatic ssl certificates from it's letsencrypt integration.
  Managed certificates provided by the `certs` plugin are ignored" — **this rules out `dokku-global-cert`
  and the `certs` plugin entirely under Traefik.**
- Only `http:80` and `https:443` port mappings are supported.

DNS-01 mode is documented as being "for wildcard certificates or when port 443 is not accessible" —
but nothing in the plugin declares a wildcard SAN, so per-app ACME *orders* remain unless `tls.domains`
labels are added by hand with `traefik:labels:add`. **[docs for the mode; unverified for the wildcard
workaround]**

## TLS: three routes to a wildcard certificate

### Route 1 — nginx + `dokku-global-cert` (community)

The exact model shepherd-traefik uses: **one** cert for the whole box. **[docs]**

```bash
dokku plugin:install https://github.com/josegonzalez/dokku-global-cert.git global-cert

global-cert:set [--force] CRT KEY      # add / update are aliases
global-cert:apply <app>...             # overwrite an app's own cert with the global one
global-cert:remove
global-cert:generate                   # key + CSR + self-signed cert
global-cert:show <crt|key|csr>
global-cert:report [<app>|--global] [<flag>]
```

"Allows setting a global certificate, which is imported for all new applications and applied to every
existing application that does not already have its own certificate." On update it re-applies to every
app currently using it, so a renewal propagates. Apps with their own cert are left alone unless
`--force`. **[docs]**

Caveats: the README declares support for **Dokku 0.7.0+ / Docker 1.12.x** and the install URL still
points at `josegonzalez/`, while the live repo is `dokku-community/dokku-global-cert` (20★, MIT, last
active 2026-07-20) — a low-profile plugin, genuinely maintained but thin. **We would own the renewal
cron** (lego/certbot DNS-01 → `global-cert:set`). **[docs + repo metadata]**

There is also a rawer official variant: drop `server.crt` / `server.key` into `/home/dokku/tls` and
uncomment the `ssl_certificate` lines in `/etc/nginx/conf.d/dokku.conf`. **[docs]**

### Route 2 — nginx + `dokku-letsencrypt` (official plugin)

```bash
sudo dokku plugin:install https://github.com/dokku/dokku-letsencrypt.git
sudo dokku letsencrypt:cron-job --add

dokku letsencrypt:set --global email admin@example.com
dokku letsencrypt:set --global dns-provider namecheap
dokku letsencrypt:set --global dns-provider-NAMECHEAP_API_USER user
dokku letsencrypt:set --global dns-provider-NAMECHEAP_API_KEY key
dokku letsencrypt:enable <app>
dokku letsencrypt:disable <app>   letsencrypt:list   letsencrypt:revoke <app>
dokku letsencrypt:cron-job --add|--remove
```

- 1118★, MIT, active (2026-09-01). Email is **mandatory** for ACME registration; set it `--global` to
  avoid repeating. **[docs]**
- Provider credentials are lego env var names under the `dns-provider-*` property prefix, global or
  per-app. **[docs]**
- **Renewal is solved:** `letsencrypt:auto-renew` runs daily (06:24 via Dokku's cron plugin, or `@daily`
  from the user crontab), with a 30-day-before-expiry grace period. **[docs]**
- A single ACME account is shared: "the plugin stores a single ACME account in
  `${DOKKU_LIB_ROOT}/data/letsencrypt/--global/accounts`" for apps with the same email and server config.
  **[docs]**
- **But issuance is per app** (`letsencrypt:enable <app>`), so every new app performs its own ACME
  order — the "https works" half of the requirement, not the "no per-app round-trip" half. **[docs]**
- **Wildcard status is muddier than the README suggests.** The README says DNS-01 "is the only way to
  obtain wildcard certificates", while issue #189 carries the note: *"As of 0.12.0, dokku-letsencrypt
  will be in a position to add dns-01 challenge support. That said, it'll still need work to enable the
  environment variable support needed. Until someone volunteers or sponsors the work, wildcard support
  is not officially supported by this plugin."* Whether a `*.domain` cert can be requested **and shared
  across apps** on a current version is **[unverified]** and is a box question.

### Route 3 — Traefik plugin with `challenge-mode dns`

See *Traefik* above. Renewal is Traefik's problem (as today), at the cost of per-app ACME orders and
losing the `certs` / `global-cert` plugins.

## Networking and app isolation

```bash
dokku network:create <network>          # attachable bridge network
dokku network:destroy <network>
dokku network:list [--format text|json] [--dokku-managed]
dokku network:exists <network>          # exit 0 if it does
dokku network:info <network> [--format text|json]
dokku network:set [--global] <app> <key> (<value>)
dokku network:report [<app>] [<flag>]
dokku network:rebuild <app>   dokku network:rebuildall
```

`network:set` properties: **[docs]**

| Property | Meaning |
|---|---|
| `initial-network` | "Network attached at container creation time." |
| `attach-post-create` | "Networks attached to a container immediately after creation, before the deploy phase." |
| `attach-post-deploy` | "Networks attached to a container after it passes healthchecks." |
| `bind-all-interfaces` | default `false`; binds to `0.0.0.0` instead of the Docker network address |
| `static-web-listener` | app-only; static `host:port` override for proxy templates when nothing is running |
| `tld` | custom TLD appended to network aliases |

**The default is not isolated.** "Apps will default to being associated with the default bridge network
or a network specified by the `initial-network` network property" — so out of the box **every Dokku app
shares Docker's default bridge and can reach every other app**. Getting shepherd-traefik's
one-network-per-app property means creating a network per app and setting `initial-network` on it.
**[docs + third-party corroboration; the per-app recipe is unverified]**

Containers on a non-default network get automatic aliases `APP.PROC_TYPE`, e.g.
`http://node-js-app.web:5000`. **[docs]**

**Carried over from shepherd-traefik regardless:** one Docker network per app on one daemon still hits
Docker's default address pools at ~29 networks, so `/etc/docker/daemon.json` still needs enlarged
`default-address-pools`. Dokku's bootstrap is not documented as writing that file. **[unverified —
whether bootstrap.sh touches daemon.json needs reading or a box]**

## Resource limits

```bash
dokku resource:limit   [--process-type PROC] [--cpu N] [--memory N] [--memory-swap N] \
                       [--network N] [--network-ingress N] [--network-egress N] [--nvidia-gpu N] <app>
dokku resource:reserve  [same flags] <app>
dokku resource:limit-clear <app>      dokku resource:reserve-clear <app>
dokku resource:report [<app>]

dokku resource:limit --memory 100 node-js-app
dokku resource:limit --memory 4g --process-type build node-js-app
dokku resource:limit --cpu clear node-js-app
```

Mapping to Docker flags (docker-local scheduler): `cpu` → `--cpus`, `memory` → `--memory` (b/k/m/g
suffixes), `memory-swap` → `--memory-swap`, `nvidia-gpus` → `--gpus`; reservations: `memory` →
`--memory-reservation`. **[docs]**

**Build-time limits exist but are builder-dependent** — the special `build` process type, added in
0.38.0, applied via the `docker-args-process-build` trigger, and "only limits explicitly set against the
`build` process type are applied at build time": **[docs]**

| Builder | cpu | memory | memory-swap | nvidia-gpu |
|---|---|---|---|---|
| herokuish | ✓ | ✓ | ✓ | ✓ |
| **dockerfile** | **✗** | **✓** | **✓** | ✗ |
| pack, nixpacks, railpack, lambda | ✗ | ✗ | ✗ | ✗ |

**So with the Dockerfile builder, build *memory* can be capped and build *CPU* cannot.** That is a
direct, documented regression against shepherd-traefik, which limits both.

## Processes, restarts and reboot

```bash
dokku ps:report [<app>]      dokku ps:inspect <app>
dokku ps:scale node-js-app web=1 worker=1   [--skip-deploy|--replace|--clear|--format stdout|json]
dokku ps:start|ps:stop|ps:restart [<app>|--all] [--parallel N]
dokku ps:rebuild [<app>|--all] [--parallel N]      # rebuild from source
dokku ps:restore                                   # start previously-running apps, e.g. after reboot
dokku ps:set [--global] <app> <key> <value>
```

- **`restart-policy` defaults to `on-failure:10`**; allowed values `always`, `no`, `unless-stopped`,
  `on-failure`, `on-failure:N`. To match shepherd-traefik's `restart: always`:
  `dokku ps:set --global restart-policy always`. **[docs]**
- **Reboot:** `ps:restore` runs automatically from the init service after a Docker daemon restart — it
  starts linked services, clears generated proxy config, and restarts each app unless it was manually
  stopped. Per-app opt-out: `dokku ps:set node-js-app restore false`. **[docs]**
- The docker-local scheduler injects an init process (`--init`) by default, disableable via
  `scheduler-docker-local:set`. `parallel-schedule-count` (default 1) controls how many *process types*
  deploy in parallel, web first — this is about deploys, **not** about concurrent builds. **[docs]**
- **Container naming is not documented** on the scheduler page. shepherd-traefik's naming contract has
  no counterpart here; whatever Dokku names containers is Dokku's business, which is the point of
  retiring the contract. **[unverified]**

## Config, env vars and app metadata

```bash
dokku config:show  (<app>|--global)
dokku config:get   (<app>|--global) KEY
dokku config:set   [--encoded] [--no-restart] (<app>|--global) KEY=VALUE [KEY2=VALUE2 ...]
dokku config:unset [--no-restart] (<app>|--global) KEY [KEY2 ...]
dokku config:export (<app>|--global) [--format <format>]
dokku config:clear (<app>|--global)
dokku config:keys  (<app>|--global) [--merged]
dokku config:bundle (<app>|--global) [--merged]
```

- Global vars are sourced before app vars, so **app beats global**. **[docs]**
- `--encoded` takes base64, for values with newlines. `--no-restart` avoids the restart, for scripting.
  **[docs]**
- **For Dockerfile deploys, config vars are runtime-only** — "variables available *only* during runtime",
  deliberately, per Docker's own recommendation. Build-time values must go through build args. (Buildpack
  apps get them at both build and run time.) **[docs]**

App/domain management: **[docs]**

```bash
dokku apps:create <app>      dokku apps:destroy <app>     dokku apps:rename <old> <new>
dokku apps:clone <old> <new> dokku apps:list [--format stdout|json]
dokku apps:report [<app>] [<flag>]                dokku apps:exists <app>
dokku apps:lock <app> | apps:unlock <app> | apps:locked <app>
dokku apps:set [--global] <app> <key> (<value>)   # incl. disable-autocreation

dokku domains:set-global <domain> [<domain> ...]
dokku domains:add <app> <domain> [...]   dokku domains:set <app> <domain> [...]
dokku domains:clear <app>                dokku domains:enable|disable <app>
dokku domains:report [<app>|--global] [<flag>]
```

- Default app hostname is `subdomain.domain.tld`, subdomain inferred from the app name, TLD from the
  global domain — i.e. `PROJECTID.<domain>` comes for free. **[docs]**
- **An app named as an FQDN takes that FQDN**: "the global virtualhost will be ignored and the resulting
  vhost URL for that application will be `dokku.org`" — the mechanism for publishing one project on the
  apex domain. **[docs]**
- Whether a **wildcard** app domain (`domains:add app '*.example.com'`) is accepted is not documented.
  **[unverified]**
- `apps:set --global disable-autocreation` requires an explicit `apps:create` before a deploy can land —
  worth having on a box that hosts other people's repos. **[docs]**

## Services: Postgres

```bash
sudo dokku plugin:install https://github.com/dokku/dokku-postgres.git --name postgres

dokku postgres:create <service> [--create-flags...]   # image version, env, memory limit
dokku postgres:link   <service> <app> [--link-flags...]
dokku postgres:unlink <service> <app>
dokku postgres:info   <service> [--single-info-flag]
dokku postgres:export <service>   dokku postgres:import <service>
dokku postgres:backup-auth <service> <aws-access-key-id> ...
dokku postgres:backup <service> <bucket-name> [--use-iam]
dokku postgres:backup-schedule <service> <schedule> <bucket-name>
dokku postgres:upgrade <service> [--upgrade-flags...]
```

`postgres:link` sets **`DATABASE_URL`** on the app and restarts it; the DSN looks like
`postgres://lollipop:SOME_PASSWORD@dokku-postgres-lollipop:5432/lollipop`, reachable only from inside
containers unless `expose`d. Major-version upgrades are export → new service → import. Scheduled S3
backups are built in. **[docs]**

This is strictly more than shepherd-traefik has today (a README TODO) and more than shepherd-java's
fixed `postgres-service` with a hardcoded password.

## Observability

- **Logs are first-class:** **[docs]**

  ```bash
  dokku logs <app> [-t|--tail] [-n|--num N] [-q|--quiet] [-p|--ps process]
  dokku logs node-js-app -t -p web
  dokku logs:failed <app>|--all      # last failed deploy only
  dokku logs:report [<app>]
  dokku logs:set [--global|<app>] max-size 20m     # default 10m
  ```

  `logs:failed` under the docker-local scheduler keeps logs "only until the next deploy or garbage
  collection". **[docs]**
- **Log shipping via Vector** is an option, not a requirement: `logs:vector-start` / `-stop` /
  `-logs`, sinks as `SINK_TYPE://?SINK_OPTIONS` (`console://`, `http://`, `file://`, `loki://`).
  **[docs]**
- **No metrics, by design.** Dokku does not manage monitoring. Because apps are plain Docker
  containers with stable names, `docker stats`, `lazydocker` (52.8k★, MIT) or `ctop` (17.8k★, MIT)
  cover it for zero code. **[docs for the stance]**
- **Event log:** Dokku writes events to `/var/log/syslog` and `/var/log/dokku/events.log`, with
  `dokku events [-t]`, `events:list`, `events:on`, `events:off`. (A separate third-party
  `alessio/dokku-events` logs to `/var/log/dokku.log` — don't confuse the two.) **[docs]**
- **No build history.** "Deploy history with Git SHAs isn't tracked by Dokku at the moment, though it
  was considered as part of a builds plugin effort that has stalled" — the events log notes the SHA
  attempted/deployed, and that is all. So the per-project build list + retained build log that Jenkins
  provides today has **no Dokku counterpart**. **[docs/discussion #5114]**

## Admin interface

- **The CLI is the primary and only official interface, and it is remote over SSH.** Users authenticate
  as the `dokku` system user; `ssh dokku@host <command>` is the sanctioned remote form. **[docs]**

  ```bash
  dokku ssh-keys:add <name> [/path/to/key]     # or by pipe
  dokku ssh-keys:list [--format text|json]
  dokku ssh-keys:remove <name>|--fingerprint <fp>
  cat ~/.ssh/id_rsa.pub | ssh root@dokku.me dokku ssh-keys:add KEY_NAME
  ```

  **A key name containing `admin` grants the right to add further keys remotely.** Keys are stored with
  `no-agent-forwarding,no-user-rc,no-X11-forwarding,no-port-forwarding`. **[docs]**
- **There is no HTTP API.** **[docs, by absence]**
- **Reports are machine-readable**, which makes command-and-parse a structured interface rather than
  screen-scraping: `--format json` on `*:report`, `apps:list`, `network:list`, `ps:scale`; and
  single-value flags return one bare value, e.g. `dokku docker-options:report node-js-app
  --docker-options-build`. **[docs]**
- **The official web UI is Dokku Pro: proprietary, paid.** Debian/RPM packages, a JWT-authenticated JSON
  API, HTTPS git-push endpoints, and a web UI for apps, datastores and SSH keys; licence validated
  against the public internet (offline support by enquiry). No open-source version. **[docs]**
- **Third-party web UIs have a demonstrated death rate.** `palfrey/wharf` (262★, AGPL-3.0, active
  2026-09-03) is the one live option and is single-maintainer; `ledokku` (642★, MIT — and the one Dokku
  itself endorsed in 2021) died 2023-10, `cywio/atlas` 2022-01, `HarborJS` 2018-05. Pruvon advertises
  AGPLv3 but no public repo was locatable on 2026-09-09. **[repo metadata]**

## What Dokku does *not* do

The honest gap list, for the feature discussion:

| Missing | Detail |
|---|---|
| **Per-project build cache isolation** | No per-app `--cache-to`/`--cache-from`; `docker-options … build` is container options, not build flags. Cache mounts are shared box-wide and unkeyed. |
| **Build CPU limit (Dockerfile builder)** | Documented `✗`. Memory yes, CPU no. |
| **Periodic rebuild** | `app.json` cron runs the deployed image, never a build. Host crontab required. |
| **Build history / build logs** | Not tracked; `logs:failed` keeps the last failed deploy only. |
| **Box-wide resource quota** | `resource:limit` is per app. Nothing sums them or refuses an over-committing app. |
| **App isolation by default** | Default bridge is shared; isolation is opt-in per app. |
| **Wildcard-cert-once-for-all-apps** | Every route has a caveat; see *TLS* above. |
| **Metrics** | Explicitly out of scope for the project. |
| **A single declarative project descriptor** | Project state is spread over `apps`/`config`/`resource`/`domains`/`ports`/`network`/`git`/`builder-dockerfile` properties. |
| **Open-source web UI** | Pro is paid; third-party is a graveyard with one survivor. |
| **HTTP API** | None. SSH is the transport. |
| **Graceful "safe to reboot"** | No equivalent of shepherd-cli's `shutdown`. |
| **Per-project git credentials** | `git:auth` is per host, not per app. |

## Questions only a box can answer

The `[unverified]` claims above, plus the ones that decide the design. This is the punch list for the
first throwaway VPS:

1. Does `--build-arg NAME=value` work in `docker-options:add <app> build`, or only the pass-through
   `NAME` form?
2. Does `network:create` + `network:set <app> initial-network` actually isolate apps *and* leave
   host-nginx routing intact?
3. Does `bootstrap.sh` write `/etc/docker/daemon.json`, and does it survive our enlarged
   `default-address-pools`?
4. Can `dokku-letsencrypt` on a current version issue a `*.domain` cert, and can that one cert serve
   every app — or is `dokku-global-cert` + our own renewal cron the only way?
5. Are cache mounts actually preserved across `git:sync --build` runs, and for how long, given
   buildkitd's own GC (reported to evict unused entries after ~48 h)?
6. **The two-build timing drill** from `COMPARISON.md`'s *How to settle it*: install, deploy one real
   Vaadin-Boot app, commit trivially, redeploy — timed. Then deploy a second app sharing Maven
   coordinates with the first and check whether it resolves the first one's `1.0-SNAPSHOT` jar.
7. What does Dokku name app containers, and do `lazydocker` / `ctop` show them usefully?
8. Does `EXPOSE 8080` + `ports:set http:80:8080 https:443:8080` behave as documented, and does it
   survive a rebuild?

## Sources

Dokku documentation (dokku.com, read 2026-09-09):
[Installation](https://dokku.com/docs/getting-started/installation/) ·
[Git deployment](https://dokku.com/docs/deployment/methods/git/) ·
[Dockerfile builder](https://dokku.com/docs/deployment/builders/dockerfiles/) ·
[docker-options](https://dokku.com/docs/advanced-usage/docker-options/) ·
[Port management](https://dokku.com/docs/networking/port-management/) ·
[Proxy management](https://dokku.com/docs/networking/proxy-management/) ·
[nginx proxy](https://dokku.com/docs/networking/proxies/nginx/) ·
[Traefik proxy](https://dokku.com/docs/networking/proxies/traefik/) ·
[Network management](https://dokku.com/docs/networking/network/) ·
[Resource management](https://dokku.com/docs/advanced-usage/resource-management/) ·
[Process management](https://dokku.com/docs/processes/process-management/) ·
[Scheduled cron tasks](https://dokku.com/docs/processes/scheduled-cron-tasks/) ·
[docker-local scheduler](https://dokku.com/docs/deployment/schedulers/docker-local/) ·
[Application management](https://dokku.com/docs/deployment/application-management/) ·
[Domains](https://dokku.com/docs/configuration/domains/) ·
[Environment variables](https://dokku.com/docs/configuration/environment-variables/) ·
[Log management](https://dokku.com/docs/deployment/logs/) ·
[Event logs](https://dokku.com/docs/advanced-usage/event-logs/) ·
[User management / ssh-keys](https://dokku.com/docs/deployment/user-management/) ·
[SSL configuration](http://dokku.viewdocs.io/dokku/configuration/ssl/) ·
[Dokku Pro](https://github.com/dokku/dokku/blob/master/docs/enterprise/pro.md) ·
[0.38.0 release notes](https://dokku.com/blog/2026/dokku-0.38.0/).

Plugins: [dokku-letsencrypt](https://github.com/dokku/dokku-letsencrypt) (and
[issue #189](https://github.com/dokku/dokku-letsencrypt/issues/189)) ·
[dokku-global-cert](https://github.com/dokku-community/dokku-global-cert) ·
[dokku-postgres](https://github.com/dokku/dokku-postgres).

Gaps and third parties: [no deploy history — discussion #5114](https://github.com/dokku/dokku/discussions/5114) ·
[monitoring stance — discussion #5681](https://github.com/dokku/dokku/discussions/5681) ·
[wharf](https://github.com/palfrey/wharf) · [ledokku](https://github.com/ledokku/ledokku) ·
[lazydocker](https://github.com/jesseduffield/lazydocker) · [ctop](https://github.com/bcicen/ctop).

Build-cache background (carried over, not re-verified here):
[buildx mount caches vs per-project `type=local`](https://mvysny.github.io/docker-build-cache/) ·
[BuildKit `RUN --mount=type=cache` reference](https://docs.docker.com/reference/dockerfile/#run---mounttypecache) ·
[buildkitd's own GC evicting unused entries](https://www.loopwerk.io/articles/2026/docker-buildkit-cache-coolify/).

The product survey that chose Dokku over Coolify, Dokploy and CapRover is
[`COMPARISON.md` in shepherd-traefik](https://github.com/mvysny/shepherd-traefik/blob/main/COMPARISON.md);
`D_dokku` in `DECISIONS.md` links to it rather than restating it.
