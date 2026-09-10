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

  The explicit `--build-arg NAME=value` form works as well, though the docs never show it: the builder
  allowlists the `--build-arg` *flag* and appends it together with its value to `docker image build`
  without inspecting either (see the allowlist under *`docker-options`*, below). That is how a
  per-project secret like a Vaadin offline key gets to a build. **[src]**
- **`DOKKU_GLOBAL_BUILD_ARGS` is appended to every app's build options**, after the per-app ones — a
  box-wide escape hatch, and a thing to check when a build behaves unexpectedly. **[src]**

### `docker-options` and its sharp edges

Three phases — `build`, `deploy`, `run`: **[docs]**

```bash
dokku docker-options:add    [--process PROC...] <app> <phase(s)> OPTION
dokku docker-options:remove [--process PROC...] <app> <phase(s)> OPTION
dokku docker-options:clear  [--process PROC...] <app> [<phase(s)>...]
dokku docker-options:report [<app>] [<flag>] [--format json|stdout]
```

- **`run` is not `docker run`.** "The `run` phase does *not* correspond 1-to-1 to `docker run` … Specifying
  a container option at the `run` phase will only be invoked on containers created by the `run` plugin
  and cron tasks." Deployed processes take `deploy`. **[docs]**
- **What the `build` phase means depends on the builder** — and the docs' blanket warning that "`build`
  options are container options … the `dockerfile` builder does not support mounted volumes" describes
  the *herokuish* path, not the Dockerfile one. Both builders read the same `docker-args-build`
  trigger and then use its output completely differently. Read at **v0.38.27**: **[src]**
  - `plugins/builder-dockerfile/builder-build` concatenates the `docker-args-build` and
    `docker-args-process-build` trigger output with `DOKKU_GLOBAL_BUILD_ARGS`, splits it through
    `fn-docker-args-split`, filters it against a **flag allowlist**, and appends the survivors to
    `docker image build`. Value-taking flags keep their value (`DOCKERFILE_ARGS+=("--cache-to");
    DOCKERFILE_ARGS+=("$2"); shift 2`); anything off the list is silently dropped, with no warning.
  - `plugins/builder-herokuish/builder-build` hands the same options to `docker container create`
    instead. *There* they are genuinely container options — which is what the doc note is about.
- **The allowlist, verbatim at v0.38.27:** `--add-host`, `--allow`, `--annotation`, `--attest`,
  `--build-arg`, `--builder`, `--cache-from`, **`--cache-to`**, `--call`, `--cgroup-parent`, `--label`,
  `--memory`/`-m`, `--memory-swap`, `--network`, `--platform`, `--progress`, `--provenance`, `--sbom`,
  `--secret`, `--shm-size`, `--ssh`, `--tag`, `--target`, `--ulimit`, `--check`, `-D`/`--debug`,
  `--no-cache`. **[src]**

  Two things follow from reading it. `--cache-to`/`--cache-from` are on it, so a per-project build
  cache *is* reachable per app — see *Build caching*. And there is **no `--cpus`/`--cpu-quota` on it
  while `--memory` is**, which is the mechanism behind the documented `✗` for build CPU limits: the
  flag would be dropped on the floor rather than rejected.

### Build caching

Two independent mechanisms, and Dokku exposes both. The short version: **Dokku is the one product in
the survey that lets the *platform* name a per-app build cache**, so shepherd-traefik's per-project
`type=local` cache directory migrates rather than being lost.

- **Cache mounts** — `RUN --mount=type=cache,target=…` in the app's own Dockerfile, documented by Dokku
  under *BuildKit directory caching*. Zero glue, and it survives changes that invalidate every layer.
  But the mount's `id` defaults to its `target`, so unkeyed mounts from every app on the box resolve to
  the same directory: shared and unkeyed unless each Dockerfile opts into an `id=`. Since the app writes
  its own Dockerfile, that is cooperation, never a boundary — the argument is `D_no_shared_cache` in
  shepherd-traefik. **[docs]**
- **Per-app `--cache-to` / `--cache-from`** — both are on the Dockerfile builder's allowlist (above), so
  they reach `docker image build` as one `docker-options:add` per app: **[src]**

  ```bash
  dokku docker-options:add myapp build '--cache-to type=local,dest=/var/cache/shepherd2/myapp,mode=max'
  dokku docker-options:add myapp build '--cache-from type=local,src=/var/cache/shepherd2/myapp'
  ```

  The flag sits on the *build command*, not in the repo, so the app cannot name another project's
  cache. This is the same mechanism `shepherd-build` uses today, and it covers the **layer** cache
  only — the `RUN --mount` half above stays the app's business.
- **The hinge is `docker image build` routing to buildx**, which is where `type=local` export comes
  from. That holds on Docker Engine 23+, but it is a property of the *engine*, not of Dokku, and it has
  not been run on our box. **[unverified]**
- **The buildpack builders solve it a different way, and completely.** `builder-herokuish` runs
  `docker volume create cache-$APP`, mounts it with `-v "cache-$APP:/cache"` and sets
  `--env=CACHE_PATH=/cache`, so the app never learns the cache's name and cannot address another's;
  `dokku repo:purge-cache <app>` clears exactly that one, and the docs scope that command to buildpack
  builds. The price is that with a buildpack there is no Dockerfile, which is the whole build contract.
  **[src]** / **[docs]**
- **buildkitd runs its own GC**, independently of Dokku and of any prune cron of ours; the defaults are
  reported to evict unused entries after roughly 48 h. A cache mount is therefore not a durable store,
  and an explicit buildkitd GC policy belongs in the install guide. **[unverified]**

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
- **Its output is captured** like any other deploy — a build record plus a log file per run, no
  redirection needed in the crontab line. See *Build tracking*.

**What `git:sync` persists** — it remembers more than the command's shape suggests, which matters for
`D_dokku_is_truth`:

- **The remote URL lands in `apps:report <app> --app-deploy-source-metadata`**, alongside
  `--app-deploy-source` = `git-sync`. The flags are documented, the metadata described as "free-form
  (commit sha, image ref, URL)". **[docs]** For `git:sync` the value is `<url>#<sha>` — the ref resolved
  to a commit, not the branch name — written by the `deploy-source-set` trigger. **[src]**
- **…but only after a build that got as far as `receive-app`.** The trigger fires *after* the build,
  so a first `git:sync --build` whose build fails leaves the deploy source empty; the app has a cloned
  repo and no recorded URL. **[src]** This is the edge that rules out deriving the poll list from it.
- **The branch persists separately**, as `git:report --git-deploy-branch`: syncing a branch ref sets
  `deploy-branch` to it unless `--skip-deploy-branch`. **[docs]** A later `git:sync` with no ref fetches
  the deploy branch. **[src]** So a poll never needs to carry the ref, only the URL.
- `--build-if-changes` compares the deploy branch's commit before and after the fetch and builds only if
  it moved — so **a failed build is not retried until upstream has a new commit**, same as Jenkins
  poll-SCM. **[src]**
- The bare repo under `~dokku/<app>` also keeps `origin` (from the first clone) and a `remote` remote
  (re-added on every fetch) pointing at the URL. **[src]** Readable with `git remote get-url`, but that
  is reaching around Dokku; the report flag is the sanctioned reader.

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

A fourth restriction, not quoted because the docs never mention it: **the plugin does nothing about
Docker networks.** `plugins/traefik-vhosts/internal-functions` templates a compose file and reads global
properties; there is no `docker network connect`, no `--network`, and no read of the app's
`initial-network` / `attach-*` properties (read 2026-09-10). Since Traefik here *is* a container, an app
isolated on its own network is plausibly unreachable by it. See *Nobody has to re-attach anything* under
*Networking and app isolation*. This is one of the reasons `D_proxy` chose nginx, and it is why
`D_isolation` depends on that choice. **[src for the absence; unverified for the 502]**

DNS-01 mode is documented as being "for wildcard certificates or when port 443 is not accessible" —
but nothing in the plugin declares a wildcard SAN, so per-app ACME *orders* remain unless `tls.domains`
labels are added by hand with `traefik:labels:add`. **[docs for the mode; unverified for the wildcard
workaround]**

## TLS: three routes to a wildcard certificate

`D_cert` takes route 1. Two facts about Let's Encrypt itself frame all three routes: **a wildcard
certificate can only be issued over the DNS-01 challenge** — HTTP-01 and TLS-ALPN-01 "cannot be used to
issue wildcard certificates" **[docs]** — and a `*.example.com` certificate does **not** cover the apex
`example.com`, which has to be requested as a second name on the same certificate. **[docs]**

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
existing application that does not already have its own certificate." On update: "re-applies it to every
application that currently uses it, so renewals (for example a rotated wildcard certificate) propagate to
existing applications and are served immediately." Apps with their own cert are "left untouched unless
`--force` is passed". **[docs]**

Caveats: the README declares support for **Dokku 0.7.0+ / Docker 1.12.x** and the install URL still
points at `josegonzalez/`, while the live repo is `dokku-community/dokku-global-cert` (20★, MIT, last
active 2026-07-20) — a low-profile plugin, genuinely maintained but thin. **We own issuance and renewal**
(an ACME client on the host → `global-cert:set`). **[docs + repo metadata]**

There is also a rawer official variant: drop `server.crt` / `server.key` into `/home/dokku/tls` and
uncomment the `ssl_certificate` lines in `/etc/nginx/conf.d/dokku.conf`. **[docs]** Whether that covers
app vhosts or only the default server was not investigated.

**The ACME client on the host — lego vs certbot.** Read 2026-09-10 for `D_cert`:

- **Traefik "relies internally on Lego for ACME"**, and its DNS-provider list *is* lego's. So a `lego`
  command on the host with the same provider credentials is the same code path that renews
  shepherd-traefik's certificate today. **[docs — Traefik]**
- **lego's `godaddy` provider** takes `GODADDY_API_KEY` / `GODADDY_API_SECRET`; the documented example is
  literally our case: `lego run --dns godaddy -d '*.example.com' -d example.com`. Its page carries the
  provider's own warning: "GoDaddy has recently (2024-04) updated the account requirements … Management
  and DNS APIs: Limited to accounts with 10 or more domains and/or an active Discount Domain Club plan."
  **[docs — lego]**
- **`lego renew`** takes `--days N` (renew when fewer than N days remain) and `--renew-hook CMD`, and "the
  hook is executed only when the certificates are effectively renewed"; the hook sees `LEGO_CERT_DOMAIN`,
  `LEGO_CERT_PATH`, `LEGO_CERT_KEY_PATH` (and `LEGO_ISSUER_CERT_PATH`, `LEGO_CERT_PEM_PATH`,
  `LEGO_CERT_PFX_PATH`). Certificates land under `.lego/certificates/`, a wildcard as `_.example.com.crt`
  / `.key`. A `--dynamic` renewal window (⅓ of lifetime) exists in 4.x and is the default from v5.
  **[src — `cmd/cmd_run_renew.go`, `cmd/hook.go`; docs for the file layout]**
- **lego ships no timer**; the daily `lego renew` is the operator's cron line. **[docs]**
- **Ubuntu packages lego in universe: 4.1.3 on 22.04, 4.9.1 on 24.04**, against upstream **v5.4.1** — a
  major version behind. **[docs — packages.ubuntu.com, GitHub releases, 2026-09-10]**
- **certbot** ships a renewal timer with the distro package and a `--deploy-hook` (run after a successful
  renewal, with `$RENEWED_LINEAGE`), but its **first-party DNS plugins are thirteen** — Cloudflare,
  DigitalOcean, DNSimple, DNS Made Easy, Gehirn, Google, Linode, LuaDNS, NS1, OVH, RFC 2136, Route53,
  Sakura Cloud — and **GoDaddy is not among them**; `certbot-dns-godaddy` is a third-party pip package.
  **[docs — certbot]**

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
- **And the app must exist on the wire first:** "The app needs to already be deployed and reachable on
  the public internet over HTTP before a certificate can be issued." An app whose first builds fail has no
  certificate until `enable` is re-run after a green build. **[docs]**
- **The challenge type is per app.** `dns-provider` is settable globally or per app; a per-app value
  overrides the global one, and `none` forces HTTP-01 for that app. This is what would let it coexist
  with a global cert in v2: enabled only on apps carrying a foreign domain. **[docs]**
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

**The plugin owns membership, Docker does the enforcing.** `network:create` is a thin wrapper: it
shells out to `docker network create --attachable --label dokku.network.name=<name> <name>` and accepts
**no other arguments** — no `--driver`, no `-o/--opt`, no `--subnet`, no extra labels. **[src]** So
Dokku contributes no isolation primitive of its own (no ACLs, no per-port policy, no egress rules); it
contributes *which* network a container joins and *when*, and the boundary is whatever a Docker bridge
network gives you. Everything below follows from that split.

`network:set` properties: **[docs]**

| Property | Meaning |
|---|---|
| `initial-network` | "Network attached at container creation time." |
| `attach-post-create` | "Networks attached to a container immediately after creation, before the deploy phase." |
| `attach-post-deploy` | "Networks attached to a container after it passes healthchecks." |
| `bind-all-interfaces` | default `false`; binds to `0.0.0.0` instead of the Docker network address |
| `static-web-listener` | app-only; static `host:port` override for proxy templates when nothing is running |
| `tld` | custom TLD appended to network aliases |

**The three attachment phases are not interchangeable, and only one of them isolates.** **[docs]**

| Property | Container state | Phases it applies to | What it is for |
|---|---|---|---|
| `initial-network` | `created` | build, deploy, run | **isolation** — the app is *only* ever on this network |
| `attach-post-create` | `created` | build, deploy, run | joining an *additional* shared network the app needs at boot; the inter-app-communication tutorial's recommended property |
| `attach-post-deploy` | `running` | deploy only | joining an additional network once healthchecks pass, "when other containers need to access this one" |

`attach-post-deploy` carries a documented warning: *"If the attachment fails during the `running`
container state, this may result in your application failing to respond to proxied requests."* **[docs]**
The `attach-*` properties **add** networks, so an app with only an `attach-*` set is still on the
default bridge — they cannot deliver isolation, only reachability. Isolation is `initial-network`.

**The default is not isolated.** "Apps will default to being associated with the default bridge network
or a network specified by the `initial-network` network property" — so out of the box **every Dokku app
shares Docker's default bridge and can reach every other app**. Getting shepherd-traefik's
one-network-per-app property means creating a network per app and setting `initial-network` on it.
**[docs + third-party corroboration; the per-app recipe is unverified]**

The one mitigation on the shared default bridge is weak and worth naming so nobody mistakes it for a
boundary: *"Containers on the default bridge network can only access each other by IP addresses, unless
you use the `--link` option, which is considered legacy"* — so app-to-app there needs a container IP
rather than a name, while on any non-default network containers get automatic aliases `APP.PROC_TYPE`
(`http://node-js-app.web:5000`), optionally suffixed by the `tld` property. Discovery is harder on the
shared bridge; reachability is unchanged. **[docs]**

**Datastore plugins take the same three phases, which is what makes per-app isolation usable.**
`dokku-postgres` exposes `-N|--initial-network`, `-P|--post-create-network` and
`-S|--post-start-network` on `postgres:create` (comma-separated lists for the latter two), and the same
values are settable afterwards with e.g. `dokku postgres:set <service> post-create-network <net>`.
**[docs]** So an app and its own Postgres can share one per-project network with no raw-Docker escape
hatch — see *Services: Postgres*. Note `postgres:link` "will use native docker links via the
docker-options plugin", i.e. it adds a `--link`, which is a *legacy default-bridge* mechanism; what the
link flag does to a container whose `initial-network` is a user-defined bridge is **[unverified]**.

`network:rebuild <app>` / `network:rebuildall` re-apply network config to running containers — a
first-party re-assert, so keeping isolation true after drift does not need a tool of ours. **[docs]**

### What a Docker bridge network does and does not buy

Load-bearing for the isolation design, and it is Docker's behaviour rather than Dokku's:

- **Bridge membership is a real boundary.** *"Using a user-defined network provides a scoped network in
  which only containers attached to that network are able to communicate"*; containers on two different
  user-defined bridges have no route to each other. **[docs]**
- **But unlike a Swarm overlay, the host's firewall can see this traffic.** A bridge lives in the root
  network namespace, so container-to-container packets traverse the host's `FORWARD` chain — which is
  how Docker implements both inter-network isolation (`DOCKER-ISOLATION-STAGE-1/2`) and the `icc`
  setting in the first place. **Consequence: "one shared network plus a firewall rule" is a shape that
  can exist here**, and it is the rung that Swarm structurally denies the Dokploy sibling (there,
  intra-overlay traffic never reaches host netfilter). **[docs for the chains and the `enable_icc`
  driver option; the claim that an `icc=false` bridge plus links is a *workable* Shepherd2 topology is
  `[unverified]`; we chose per-app networks over it — see `D_isolation`]**
- **We cannot ask Dokku for a non-default bridge, though.** `enable_icc=false`, `--internal` and an
  explicit `--subnet` are all `docker network create` driver options, and `network:create` passes none
  of them **[src]**. A hand-made `docker network create -o …` referenced by name may work — the
  `network:list --dokku-managed` *filter* implies unmanaged networks are visible to the plugin — but
  that network then becomes ours to create and maintain. **[unverified]**
- **`--internal` would break builds anyway**, if anyone reaches for it: `initial-network` applies to the
  build phase too, so an egress-less initial network takes the build's package downloads with it.
  **[docs + inference]**
- **Per-app networks do not hide the host.** Every container keeps a route to its bridge gateway, so an
  app can reach anything bound on the box (sshd included) no matter which network it is on. That is a
  `DOCKER-USER` rule, not a membership question, and it is the whole of what the Dokploy sibling's
  "app → admin plane" axis becomes here — Dokku's control plane is a host binary and a git remote, with
  no dashboard container and no control-plane database to move off the wire. **[inference from the
  bridge model; unverified on a box]**

**The address-pool ceiling is an install-time line, not a design constraint.** Per-app networks are
*bridge* networks, i.e. Docker's **local**-scope pool: `172.17.0.0/12` at size 16 plus `192.168.0.0/16`
at size 20, so ~31 networks total, minus `docker0` — call it **~30 apps** on a stock daemon before
allocation fails. Enlarging `default-address-pools` in `/etc/docker/daemon.json` lifts it, and
shepherd-traefik already does exactly this, so it is precedent rather than a new cost: one stanza in
`shepherd2-install` and a `README.md` requirement. The only property worth remembering is *when* — it
needs a daemon restart, so it belongs in the install, not in a later fix. Dokku's bootstrap is not
documented as writing `daemon.json`. **[docs for the pools; unverified — whether bootstrap.sh touches
daemon.json needs reading or a box]**

(For the record, since the number moved twice: the `~29` that used to sit in this file was this same
local pool, miscounted with a `docker_gwbridge` that a non-Swarm box does not have. Swarm's
*global*-scope overlay pool, which shepherd2-dokploy draws on, is a different pool entirely —
`10.0.0.0/8` at mask 24, 65 536 subnets — so that repo has no equivalent line to write.)

### Nobody has to re-attach anything — and why that is two facts, not one

The predecessor's `shepherd-traefik-connect-networks` existed for one reason (a *proxy container* had to
join every app network and lost those attachments whenever it was re-created) and was made worse by
another (nothing re-asserted the app side either). Both halves are answered here, but by different
mechanisms, and they have different futures:

- **The app side is managed state.** `initial-network` is a persisted app property, not a one-shot
  `docker network connect`: Dokku re-applies it every time it creates a container, so it survives
  deploys, `ps:restart`, rebuilds and a host reboot. `network:rebuild` / `network:rebuildall` re-apply
  it on demand. Nothing outside Dokku has to re-assert it. **[docs]**
- **The proxy side needs nothing at all — but only because the default proxy is not a container.**
  nginx is a host process dialling `IP:PORT` (see *nginx — and why it is architecturally different*), so
  there is no proxy membership to maintain, and `dokku-event-listener` rewrites the config when a
  container IP changes.

**The second half is a property of the proxy choice, not of Dokku.** Under the Traefik plugin the proxy is a
container again, and the plugin's code contains no network-attachment logic — no `docker network
connect`, no read of the app's network properties (`plugins/traefik-vhosts/internal-functions`,
read 2026-09-10) **[src]**. So a per-app `initial-network` plausibly leaves Traefik unable to reach the
app at all, and repairing that is `shepherd-traefik-connect-networks` returning, this time as ours.
**Traefik would therefore cost either `F_network_isolation` or a reconciler script** — which is one of
the reasons `D_proxy` chose nginx, and why `D_isolation` names `D_proxy` as a dependency rather than a
neighbour. **[src for the absence; unverified — whether Traefik + `initial-network` actually 502s needs
a box]**

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
dokku apps:set [--global] <app> <key> (<value>)   # ONLY disable-autocreation, global-only — see below

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
- **There is no user-settable per-app metadata slot.** `apps:set` accepts exactly one key,
  `disable-autocreation`, and only globally; every other `apps:report` field (`deploy-source`,
  `deploy-source-metadata`, `created-at`, …) is read-only and system-written. **[docs + src]** Anything
  of ours that must live *in* Dokku per app therefore goes through `config:set` — with the price that a
  config var is injected into the container's environment (`--no-restart` avoids the restart on write).
  This is what `D_dokku_is_truth` relies on.
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

**The service container takes the same network properties an app does** — `postgres:create -N|--initial-network`,
`-P|--post-create-network`, `-S|--post-start-network`, and `postgres:set <service> post-create-network`
after the fact. That is what lets a project's app and its own database share one isolated network; see
*Networking and app isolation* for the isolation design and for the `--link` caveat that `postgres:link`
drags in. **[docs]**

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
- **Build history is first-class** — see *Build tracking* below. Discussion #5114 ("deploy history with
  Git SHAs isn't tracked … it was considered as part of a builds plugin effort that has stalled") is
  **superseded**: the effort landed in 0.38.0. Only its git-SHA half still holds.

### Build tracking — the `builds` plugin

**New as of 0.38.0**, core (nothing to install), and present in every 0.38.x tag including our pinned
v0.38.27. **Every deploy is recorded**, whatever triggered it: `git push`, `ps:rebuild`, `ps:restart`,
`ps:start`, `config:set`, `deploy`, and `git:sync` / `git:from-archive` / `git:from-image` /
`git:load-image`. **[docs]**

```bash
dokku builds:list [<app>] [--format json] [--kind build|deploy] [--status <status>]
dokku builds:info <app> <build-id> [--format json]
dokku builds:output <app> [<build-id>|current]   # tail -f while live, cat once finished
dokku builds:cancel <app>                        # SIGQUIT to the deploy's process group
dokku builds:prune <app> [--all-apps]
dokku builds:report [<app>] [<flag>]
dokku builds:set [--global|<app>] retention <N>  # `retention` is the only property
```

- **On disk, per build:** `/var/lib/dokku/data/builds/<app>/<build-id>.json` (the record) and
  `<build-id>.log` (the captured stdout+stderr). The output is *also* tagged into syslog as
  `dokku-<build-id>`, but the file is the durable copy — `builds:output` falls back to
  `journalctl -t dokku-<build-id>` only when the file is missing. **[docs]**
- **The record** is `id, app, kind, pid, started_at, finished_at, status, source, exit_code`; `--format
  json` adds a computed `display_status`, `duration` and `log_path`. `kind` is `build` (paths that
  produce an image) or `deploy` (paths that re-deploy one); `source` names the originating command,
  `git:sync` among them; `status` is `running|succeeded|failed|canceled` on disk, plus a display-only
  `abandoned` computed for a `running` record whose PID is dead. **[src]**
- **Retention is by count, not age: 20 records per app** by default (minimum 1), a per-app override
  cascading to a `--global` one. Pruning removes the record *and* its log, runs at the end of every
  deploy, and never touches a live build. Deleting the app deletes its build data; renaming moves it.
  **[src]**
- **No git SHA in the record.** "Which commit was that build?" is still answerable only from the events
  log. That is the half of discussion #5114 that survives. **[src]**
- `builds:list` **with no app** lists the builds running box-wide — which is a cheaper
  "is it safe to reboot?" than watching a lock file. **[docs]**

**The capture is trigger-independent by construction**, which is the property that matters here:
`dokku_setup_build_capture` in `plugins/common/functions` generates the id, writes the record, and then
redirects the *entire* deploy — **[src]**

```bash
exec &> >(tee -a "$LOG" >(logger -i -t "dokku-${DOKKU_BUILD_ID}"))
```

`plugins/git/internal-functions` calls it with source `git:sync`, so **the rebuild cron gets its build
log for free**: no redirection of our own in the crontab line, and no glue to write.

**Sharp edge: bare `builds:output <app>` does not mean "the last build".** Given no build id (or the
literal `current`) it resolves one from the app's `.deploy.lock`, so on an idle app it prints
`App not currently deploying` rather than the failure you came for. `builds:list` is sorted
newest-first and emits `id`, so the two-step scripts: **[src]**

```bash
dokku builds:output myapp "$(dokku builds:list myapp --status failed --format json | jq -r '.[0].id')"
```

## Admin interface

- **The CLI is the primary and only official interface, and it is remote over SSH.** Users authenticate
  as the `dokku` system user by SSH public key; `ssh dokku@host <command>` is the sanctioned remote
  form. Who may run what is *Users and access control* below. **[docs]**
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
  itself endorsed in 2021) died 2023-10, `cywio/atlas` 2022-01, `HarborJS` 2018-05, `intercity-next`
  2019-04. Pruvon advertises AGPLv3 but no public repo was locatable on 2026-09-09. **[repo metadata]**
- **wharf's scope is day-to-day, not provisioning.** Its README claims "most features you'll need
  day-to-day": apps, env vars, domains, Postgres/Redis links, deploy and sync, runtime logs, build
  output. Nothing for resource limits, `docker-options` or networks. It is a pure client — talks to
  Dokku over SSH with a key of its own (optionally the `dokku-daemon` socket) and authenticates its own
  users with a single `ADMIN_PASSWORD` — so adopting it costs nothing if it dies: no server-side state
  lives in it. **[docs]** (its README, read 2026-09-10)
- **Other clients Dokku lists** (*Community contributions* on the clients page): `dokku-toolbelt`
  (Node), `dokku-cli` (Ruby gem, 184★, updated 2026-04, "makes your Dokku even more Heroku") and
  `Dockland` (Ruby). All are sugar over the SSH commands. **No Dokku TUI was found** on the GitHub topic
  page or the clients page. **[repo metadata]** (web search was unavailable on 2026-09-10; the topic
  page and Dokku's clients page were read directly)

## Users and access control

The one-line version: **an SSH key is the whole identity model, and every key is effectively root over
every app.** There is no user registry, no password, no OAuth, and nothing to log in *to*.

- **A "user" is a named public key** in `~dokku/.ssh/authorized_keys`. The key name reaches plugin hooks
  as `$NAME` / `$SSH_NAME`; the system user is always `dokku`. **[docs]**

  ```bash
  dokku ssh-keys:add <name> [/path/to/key]     # or by pipe
  dokku ssh-keys:list [--format text|json]
  dokku ssh-keys:remove <name>|--fingerprint <fp>
  cat ~/.ssh/id_rsa.pub | ssh root@dokku.me dokku ssh-keys:add KEY_NAME
  ```

  Keys are stored with `no-agent-forwarding,no-user-rc,no-X11-forwarding,no-port-forwarding`. **[docs]**
- **The only privilege distinction in core is the substring `admin` in a key name**, which grants the
  right to add further keys remotely. **[docs]**
- **There is no app ownership and no per-user authorization.** Any authorised key may run any command
  against any app, `apps:destroy` on someone else's project included. **[docs, by absence]** The
  maintainer's stated position is that this is by design: Dokku assumes a personal or fully-trusted-team
  box, granular team access "is not part of Dokku's core offering", and anyone with real SSH access to
  the host bypasses restrictions anyway. **[docs]** (discussion #4927)
- **No password, no SSO, no OIDC**, in any form — a consequence of there being no HTTP API to attach a
  provider to. **[docs, by absence]**
- **The extension point is the `user-auth` plugin trigger**, called with `$SSH_USER $SSH_NAME $COMMAND
  $ARGS`; a non-zero exit denies the command. `user-auth-app` is the per-app variant. The docs
  recommend `user-auth` over `git-pre-pull` for authentication because it also covers
  `git-upload-archive`. **[docs]** This is what any multi-user story here has to be built on.

### `dokku-acl` — the community multi-tenancy plugin

[dokku-acl](https://github.com/dokku-community/dokku-acl) (MIT, 66★) implements per-app and per-service
ACLs on the `user-auth` trigger. It is the only open-source answer, and it is **stale**: last commit
**2024-01-16**, README still claiming "dokku 0.32.0+, docker 1.8.x", and its own README says it *"has not
been extensively audited for security"*. The staleness is not cosmetic — that final commit is
`fix: adapt to new trigger naming`, so a Dokku trigger rename makes it stop enforcing. **[src]**

```bash
acl:add <app> <user>      acl:remove <app> <user>      acl:list <app>      acl:allowed <user>
acl:add-service <type> <service> <user>                # …and the service-scoped equivalents
```

Global knobs live in `~dokku/.dokkurc/acl`: `DOKKU_SUPER_USER` (always allowed; when set, nobody else
may push to an app with an empty ACL), `DOKKU_ACL_ALLOW_COMMAND_LINE`, and four command whitelists —
`DOKKU_ACL_USER_COMMANDS` (any user, any time), `DOKKU_ACL_PER_APP_COMMANDS`,
`DOKKU_ACL_PER_SERVICE_COMMANDS`, `DOKKU_ACL_LINK_COMMANDS`. With none set, the plugin is inert and all
users can run everything. **[src]**

Four behaviours matter more than the command list, because they are what a Shepherd-shaped model would
run into: **[src]**

1. **ACLs cannot be edited over SSH.** `fn-acl-check-app` fails with *"You can only modify ACL using
   local dokku command on target host"* whenever `$NAME` is set. Every grant is the operator, on the box.
2. **Creating an app does not add the creator to its ACL.** There is no auto-ownership hook; a
   user-created app is owned by nobody until someone runs `acl:add` locally.
3. **`apps:create` takes no app argument**, so it can only sit in `DOKKU_ACL_USER_COMMANDS` — all users
   or none, with no per-user scope or quota. `apps:destroy` does take an app, so per-app delete works.
4. **Repos are readable by default.** Any user can `git clone` any app unless `git-upload-pack` and
   `git-upload-archive` are added to the per-app whitelist.

### Dokku Pro

The paid product is where the team model lives, and it is the only thing in the Dokku world resembling a
user registry with logins: **[docs]**

- **Teams** grant members a whitelisted set of commands against a set of apps (`*` allowed) and
  services; **Admins** is a special team with full access; **Owners** administer membership without
  inheriting it. Nothing is permitted until whitelisted, and some commands are admin-only.
- `users:create <username> [password]` — with no password, a reset URL is printed for the user to set
  their own. Users are automatically mapped to the matching key from `ssh-keys:add`.
- **Reverse-proxy authentication since Pro 1.4.0**: a trusted identity-aware proxy (oauth2-proxy,
  Tailscale Serve) sets a configured header naming the user and Pro issues a session with no login form.
  This is the only route to Google SSO anywhere in the Dokku ecosystem. Fails closed; must be scoped to
  trusted proxies.
- Pricing seen 2026-09-09: **$849 lifetime**, 1 production + 2 pre-production servers. **[unverified]**
  (vendor marketing, not read off an invoice)

## What Dokku does *not* do

The honest gap list, for the feature discussion:

| Missing | Detail |
|---|---|
| **Isolation of *cache mounts*** | The per-app **layer** cache is fine — `--cache-to`/`--cache-from` go through per app (*Build caching*). What no builder can scope is a `RUN --mount=type=cache` written by the app: its `id` defaults to `target`, so unkeyed mounts share one directory box-wide. |
| **Build CPU limit (Dockerfile builder)** | Documented `✗`. Memory yes, CPU no. |
| **Periodic rebuild** | `app.json` cron runs the deployed image, never a build. Host crontab required. |
| **A git SHA per build** | Build history itself is covered (*Build tracking*), but the record has no commit field — only the events log notes the SHA attempted/deployed. |
| **Box-wide resource quota** | `resource:limit` is per app. Nothing sums them or refuses an over-committing app. |
| **App isolation by default** | Default bridge is shared; isolation is opt-in per app, via `initial-network`. |
| **Any isolation primitive finer than membership** | No per-port ACLs, no egress policy. And `network:create` passes no driver options, so `enable_icc=false` / `--internal` / an explicit subnet are not reachable through Dokku at all. |
| **Wildcard-cert-once-for-all-apps** | Not in core. `dokku-global-cert` does the *propagation*; issuance and renewal need an ACME client on the host and a cron line of ours (`D_cert`). See *TLS* above. |
| **Metrics** | Explicitly out of scope for the project. |
| **A single declarative project descriptor** | Project state is spread over `apps`/`config`/`resource`/`domains`/`ports`/`network`/`git`/`builder-dockerfile` properties — but it is all *there*, reportable as `--format json`, and `git:sync` even records its URL (*`git:sync`* above). The genuinely missing pieces are a per-app **metadata slot** (`apps:set` takes one global key) and a URL that survives a failed first build; `config:set` stands in for both. |
| **A one-shot "create a project" command** | `apps:create` makes an empty app. Limits, ports, network, build options, database and the first `git:sync` are each their own command; `apps:create`, `network:create` and `postgres:create` are not idempotent. |
| **Open-source web UI** | Pro is paid; third-party is a graveyard with one survivor. |
| **HTTP API** | None. SSH is the transport. |
| **App ownership / per-user access** | An authorised key may do anything to any app. Buildable on the `user-auth` trigger; `dokku-acl` is the stale community attempt, teams are a Pro feature. |
| **Any login that is not an SSH key** | No password, no SSO, no OIDC. Pro's reverse-proxy auth is the only door. |
| **Graceful "safe to reboot"** | No equivalent of shepherd-cli's `shutdown`. |
| **Per-project git credentials** | `git:auth` is per host, not per app. |

## Questions only a box can answer

The `[unverified]` claims above, plus the ones that decide the design. This is the punch list for the
first throwaway VPS:

1. Does the box's Docker route `docker image build` to buildx, so that a `--cache-to type=local` passed
   through `docker-options` actually *exports* a cache rather than being accepted and ignored? The
   allowlist gets the flag to the build command (`[src]`); the engine decides whether it means anything.
2. Does `network:create` + `network:set <app> initial-network` actually isolate apps *and* leave
   host-nginx routing intact? Concretely, from inside app A's container: can it reach app B's
   unpublished port by container IP before the change, and not after; and does `curl` through nginx
   still work for both apps after it.
3. Does `bootstrap.sh` write `/etc/docker/daemon.json`, and does it survive our enlarged
   `default-address-pools`?
   - And confirm the wall it protects against: `network:create` ~30 times on a stock box and watch for
     the allocation failure, so we know the real number rather than the arithmetic.
4. **The `D_cert` chain, end to end:** `lego run --dns godaddy` succeeds with the current GoDaddy key
   and secret on Ubuntu's packaged 4.9.1; `global-cert:set` with the result serves https on an existing
   app; a *renewal* (`lego renew --days 3650 --renew-hook …` to force one) re-applies to every app and
   reloads nginx without dropped connections; and an app created but never deployed serves the global
   cert on its first successful deploy. (The earlier question here — whether `dokku-letsencrypt` can
   issue and share a wildcard — is moot for v1 and only matters if `F_custom_domains` returns.)
5. Are cache mounts, and a per-app `type=local` cache directory, actually preserved across
   `git:sync --build` runs, and for how long, given buildkitd's own GC (reported to evict unused
   entries after ~48 h)?
6. **The two-build timing drill** from `COMPARISON.md`'s *How to settle it*: install, deploy one real
   Vaadin-Boot app, commit trivially, redeploy — timed. Then deploy a second app sharing Maven
   coordinates with the first and check whether it resolves the first one's `1.0-SNAPSHOT` jar.
7. What does Dokku name app containers, and do `lazydocker` / `ctop` show them usefully?
8. Does `EXPOSE 8080` + `ports:set http:80:8080 https:443:8080` behave as documented, and does it
   survive a rebuild?
9. **Does `postgres:link` still work when the app is on a per-app network?** The link is a legacy
   default-bridge `--link`; on a user-defined bridge the app resolves the service by DNS name
   (`dokku-postgres-<svc>`), so it plausibly works *because* both sit on the per-app network rather than
   because of the link. Check that `postgres:create -N app-<id>` + `postgres:link` leaves `DATABASE_URL`
   connectable, and whether the `--link` flag errors, warns, or is silently inert.
10. **Can `initial-network` point at a network Dokku did not create** — one made with
    `docker network create -o com.docker.network.bridge.enable_icc=false` — and does the app still
    deploy and route? Only matters if `D_isolation` is ever revisited — it decides whether that entry's
    rejected shared-network-plus-firewall rung is reachable through Dokku at all. Lowest priority here.
11. **What can an app reach on the host?** From inside a container, on both a shared and a per-app
    network: `curl http://<gateway-ip>:22`, and nginx by gateway IP with a `Host:` header for another
    app. Sizes the `DOCKER-USER` rule that is all that is left of the sibling's "unpublish :3000" axis.
12. **Does `proxy:set <app> type traefik` still route an app whose `initial-network` is its own
    network?** The plugin has no attachment logic `[src]`, so the expectation is a 502. Worth ten
    minutes on the same box as item 2, because it is the evidence under `D_proxy`'s strongest reason and
    the thing to re-check if anyone ever proposes switching proxies.

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
[Repository management](https://dokku.com/docs/advanced-usage/repository-management/) ·
[Application management](https://dokku.com/docs/deployment/application-management/) (`apps:report` flags, `apps:set` keys) ·
[Community clients](https://dokku.com/docs/community/clients/) ·
[Log management](https://dokku.com/docs/deployment/logs/) ·
[Build tracking](https://dokku.com/docs/advanced-usage/builds/) ·
[Event logs](https://dokku.com/docs/advanced-usage/event-logs/) ·
[User management / ssh-keys](https://dokku.com/docs/deployment/user-management/) ·
[Plugin triggers](https://dokku.com/docs/development/plugin-triggers/) (`user-auth`, `user-auth-app`) ·
[Pro: team management](https://pro.dokku.com/docs/features/team-management/) ·
[Pro: user management](https://pro.dokku.com/docs/features/user-management/) ·
[Pro 1.4.0 — reverse-proxy auth](https://dokku.com/blog/2026/pro-release-1.4.0/) ·
[SSL configuration](http://dokku.viewdocs.io/dokku/configuration/ssl/) ·
[Dokku Pro](https://github.com/dokku/dokku/blob/master/docs/enterprise/pro.md) ·
[0.38.0 release notes](https://dokku.com/blog/2026/dokku-0.38.0/).

Plugins: [dokku-letsencrypt](https://github.com/dokku/dokku-letsencrypt) (and
[issue #189](https://github.com/dokku/dokku-letsencrypt/issues/189); README re-read 2026-09-10 for the
deployed-first requirement and per-app `dns-provider`) ·
[dokku-global-cert](https://github.com/dokku-community/dokku-global-cert) (README re-read 2026-09-10) ·
[dokku-postgres](https://github.com/dokku/dokku-postgres).

TLS tooling, read 2026-09-10 for `D_cert`:
[Let's Encrypt challenge types](https://letsencrypt.org/docs/challenge-types/) ·
[Traefik ACME reference](https://doc.traefik.io/traefik/reference/install-configuration/tls/certificate-resolvers/acme/) ("relies internally on Lego") ·
[lego GoDaddy provider](https://go-acme.github.io/lego/dns/godaddy/) ·
[lego — obtain a certificate](https://go-acme.github.io/lego/obtain/) (file layout) ·
[`cmd/cmd_run_renew.go`](https://github.com/go-acme/lego/blob/master/cmd/cmd_run_renew.go) and
[`cmd/hook.go`](https://github.com/go-acme/lego/blob/master/cmd/hook.go) (renew flags, hook semantics, hook env) ·
[lego on packages.ubuntu.com](https://packages.ubuntu.com/search?keywords=lego&searchon=names&exact=1&suite=all&section=all) ·
[certbot user guide](https://eff-certbot.readthedocs.io/en/stable/using.html) (DNS plugin table, `--deploy-hook`, timers).

Gaps and third parties: [deploy history — discussion #5114](https://github.com/dokku/dokku/discussions/5114),
**superseded by the `builds` plugin in 0.38.0 except for its git-SHA half** ·
[monitoring stance — discussion #5681](https://github.com/dokku/dokku/discussions/5681) ·
[security model / multi-tenancy — discussion #4927](https://github.com/dokku/dokku/discussions/4927) ·
[dokku-acl](https://github.com/dokku-community/dokku-acl) (`README.md`, `user-auth` and
`internal-functions` read on 2026-09-09; repo metadata for the last-commit date) ·
[wharf](https://github.com/palfrey/wharf) · [ledokku](https://github.com/ledokku/ledokku) ·
[lazydocker](https://github.com/jesseduffield/lazydocker) · [ctop](https://github.com/bcicen/ctop).

Dokku source, read at **v0.38.27** on 2026-09-09 (the `[src]` claims about the build-option allowlist,
the per-app buildpack cache volume, and build tracking):
[`plugins/builder-dockerfile/builder-build`](https://github.com/dokku/dokku/blob/v0.38.27/plugins/builder-dockerfile/builder-build) ·
[`plugins/builder-herokuish/builder-build`](https://github.com/dokku/dokku/blob/v0.38.27/plugins/builder-herokuish/builder-build) ·
[`plugins/builds/builds.go`](https://github.com/dokku/dokku/blob/v0.38.27/plugins/builds/builds.go) (retention, record schema, pruning) ·
[`plugins/builds/subcommands.go`](https://github.com/dokku/dokku/blob/v0.38.27/plugins/builds/subcommands.go) (the `builds:output` deploy-lock resolution) ·
[`plugins/common/functions`](https://github.com/dokku/dokku/blob/v0.38.27/plugins/common/functions) (`dokku_setup_build_capture`) ·
[`plugins/git/internal-functions`](https://github.com/dokku/dokku/blob/v0.38.27/plugins/git/internal-functions) (`git:sync` calls it; re-read 2026-09-10 for `cmd-git-sync`, `fn-git-clone`, `fn-git-fetch` — what the sync persists) ·
[`plugins/git/deploy-source-set`](https://github.com/dokku/dokku/blob/v0.38.27/plugins/git/deploy-source-set) and
[`plugins/apps/triggers.go`](https://github.com/dokku/dokku/blob/v0.38.27/plugins/apps/triggers.go) (`TriggerDeploySourceSet` writes `deploy-source` / `deploy-source-metadata`) ·
[`plugins/apps/subcommands.go`](https://github.com/dokku/dokku/blob/v0.38.27/plugins/apps/subcommands.go) (`CommandSet`: `disable-autocreation` is the only key) ·
[`plugins/git/subcommands/set`](https://github.com/dokku/dokku/blob/v0.38.27/plugins/git/subcommands/set) (`git:set` valid keys) ·
[`plugins/network/subcommands.go`](https://github.com/dokku/dokku/blob/master/plugins/network/subcommands.go)
(read on 2026-09-10: `network:create` takes a name and nothing else) ·
[`plugins/traefik-vhosts/internal-functions`](https://github.com/dokku/dokku/blob/master/plugins/traefik-vhosts/internal-functions)
(read on 2026-09-10: no network attachment logic anywhere in it).

Networking, read 2026-09-10 (*Network management* above re-read the same day for the three attachment
phases):
[Inter-app communication tutorial](https://dokku.com/tutorials/network/inter-app-communication/) ·
[dokku-postgres README](https://github.com/dokku/dokku-postgres/blob/master/README.md) (`--initial-network`,
`post-create-network`, `post-start-network`, "native docker links") ·
[Docker bridge driver](https://docs.docker.com/engine/network/drivers/bridge/) (scoped networks,
default-bridge IP-only access, the `com.docker.network.bridge.enable_icc` option) ·
[Docker packet filtering and firewalls](https://docs.docker.com/engine/network/packet-filtering-firewalls/) ·
[legacy container links](https://docs.docker.com/engine/network/links/).

Build-cache background (carried over, not re-verified here):
[buildx mount caches vs per-project `type=local`](https://mvysny.github.io/docker-build-cache/) ·
[BuildKit `RUN --mount=type=cache` reference](https://docs.docker.com/reference/dockerfile/#run---mounttypecache) ·
[buildkitd's own GC evicting unused entries](https://www.loopwerk.io/articles/2026/docker-buildkit-cache-coolify/).

The product survey that chose Dokku over Coolify, Dokploy and CapRover is
[`COMPARISON.md` in shepherd-traefik](https://github.com/mvysny/shepherd-traefik/blob/main/COMPARISON.md);
`D_dokku` in `DECISIONS.md` links to it rather than restating it.
