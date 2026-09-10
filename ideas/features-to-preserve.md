# Which features must Shepherd2 preserve?

**This is the agreement document.** `D_dokku` decided *that* we rebuild on Dokku; nothing else about
Shepherd2 is decided until this list is agreed. Nothing here is a decision — argue with it, cut from it,
add to it. Once it's settled, the surviving `F_` set graduates into `README.md` (what the box does),
`DECISIONS.md` (the forks we resolved along the way) and whatever code it implies, and this file is
deleted.

**Where the inventory came from.** `COMPARISON.md`'s `R_` boxes in shepherd-traefik were the starting
point, but they are *requirements for choosing a product*, not a feature list — they were written to
discriminate between Coolify and Dokku, so they compress or omit anything all four candidates did
equally. Reading shepherd-traefik's scripts and shepherd-java-client's README/CLAUDE.md turned up **11
features with no `R_` box at all** (marked ⁿᵉʷ below), most of them in shepherd-java, which is exactly
the component being deleted. That is the point of doing this before writing code.

**Verdicts.** ✅ Dokku does it · 🔧 glue we write · 🕳️ gap, no answer yet · ✂️ propose dropping.
Every Dokku claim below is sourced in `RESEARCH.md`; nothing is restated here beyond the one-line
answer, and `[unverified]` there means it is a hypothesis, not a plan.

---

## A. Build

| `F_` | Feature | Today | Dokku answer | |
|---|---|---|---|---|
| ~~`F_build_dockerfile`~~ | ~~Build from the `Dockerfile` at the repo root, on the box~~ | Jenkins → `shepherd-build` → `docker build` | **Dropped — `D_builder`.** The Dockerfile builder is prohibited box-wide; apps are built by the herokuish buildpack builder | ✂️ |
| `F_poll_rebuild` | Rebuild **on a schedule**, not on push — we host repos we don't own | Jenkins poll-SCM job per project | `dokku git:sync --build-if-changes <app> <url> <ref>` from a **host crontab** — `app.json` cron runs the deployed image and cannot build | 🔧 |
| `F_build_mem_limit` | Cap build memory | `shepherd-build` `--memory` | `resource:limit --process-type build --memory N` | ✅ |
| `F_build_cpu_limit` | Cap build CPU | `shepherd-build` `--cpu-quota` | **Probably no longer a gap under `D_builder`**: the documented `✗` and the missing `--cpus` are *Dockerfile-builder* facts, and on the herokuish path build options go to `docker container create` unfiltered `[src]`. Punch-list 17 | ❓ |
| `F_build_args` ⁿᵉʷ | Per-project build args — the Vaadin offline key needs to exist at *build* time | `build.buildArgs` in the project JSON | **Simpler under `D_builder`**: plain `dokku config:set`, since herokuish bundles config vars into the build's ENV_DIR `[src]`. (The `--build-arg` route was a Dockerfile-builder workaround) | ✅ |
| ~~`F_custom_dockerfile`~~ ⁿᵉʷ | ~~Per-project Dockerfile path (`vherd.Dockerfile`)~~ | `build.dockerFile` | **Dropped with `F_build_dockerfile` — `D_builder`.** The nearest equivalent is `builder:set <app> build-dir` for a monorepo subdirectory | ✂️ |
| `F_build_cache` | The Maven/Gradle dependency tree must not be re-downloaded on every scheduled rebuild | per-project buildx `type=local` dir + cache mounts | **`cache-$APP` volume, and the Heroku Java buildpack puts `maven.repo.local` inside it** `[src]`. Maven half solved; the Vaadin *frontend* half is open — punch-list 13–16 | 🔧 |
| `F_cache_isolation` | …and that cache must be **per project** — one project must not reach another's artifacts | `--cache-to/--cache-from` per project id, enforced on the build command | **Closed, and now enforced rather than conventional** — Dokku names the volume, the app has no Dockerfile in which to name another. `repo:purge-cache <app>` purges exactly one. See `D_builder` | ✅ |
| `F_build_serial` ⁿᵉʷ | Never two builds at once (`concurrentJenkinsBuilders: 1`) — the corruption half of the cache problem | Jenkins executor count | Free if the poll is one serial cron loop; `parallel-schedule-count` is about deploys, not builds | 🔧 |
| `F_build_history` ⁿᵉʷ | The list of past builds, and each one's build log | Jenkins; `shepherd-cli builds` / `buildlog` | Core `builds` plugin since 0.38.0: `builds:list` / `builds:output`, a record + log file per deploy, 20 per app. `git:sync` is captured like a push. No git SHA in the record | ✅ |
| `F_private_repos` ⁿᵉʷ | Build private repos, with a credential per project | Jenkins credentials store, `gitRepo.credentialsID` | `git:auth <host> <user> <token>` (netrc) or a deploy key — but **per host, not per project** | 🕳️ |

**Section A was settled by `D_builder` on 2026-09-10, and it cost a feature.** The Dockerfile builder
is prohibited box-wide (`builder:set --global selected herokuish`) and apps are built by Heroku v2a
buildpacks, because that is the only way to make `F_cache_isolation` *enforced* rather than a
convention the app could break. `F_build_dockerfile` and `F_custom_dockerfile` are dropped — the first
features this migration deletes rather than preserves. Read `D_builder` before re-arguing any row
above; the five positions this file used to list under `F_cache_isolation` are gone with it, and so is
`ideas/build-cache.md`, which existed to choose between them.

Two loose ends survive into `ideas/vaadin-build-under-herokuish.md`: the frontend half of a Vaadin
build (`F_build_cache`), and whether `F_build_cpu_limit` was ever really a gap.

**One number still isn't written down anywhere, and `F_poll_rebuild` depends on it: the poll
interval.** Under the Dockerfile builder it was load-bearing (BuildKit evicts mount caches after
~48 h, so a weekly poll meant a permanently cold cache); under `D_builder` the cache volume has no TTL,
so the stakes are lower — but the housekeeping cron still must not wipe a cache the poll is about to
use, and `builds:set --global retention 20` was sized for "a weekly poll" in `Q_build_history`. Look up
the predecessor's Jenkins poll cadence rather than assuming.

---

**`F_cache_isolation` was the scariest row here and it has shrunk — corrected 2026-09-09.** *(Kept for
the correction it records; superseded in substance by `D_builder`.)* The earlier
reading ("no per-app `--cache-to`; `docker-options … build` is container options") was wrong, and it was
wrong in the direction that mattered: the docs' container-options warning describes the *herokuish*
builder, while the *Dockerfile* builder allowlists the option and appends it to `docker image build`.
`RESEARCH.md` → *Build caching* has the allowlist and the source it was read from. So **the layer-cache
half of today's setup migrates verbatim**, one `docker-options:add` per app, still enforced by us rather
than by the app.

What is left is exactly the gap that exists *today* — `D_no_shared_cache` in shepherd-traefik files it
under *Known gap*: an app's own `RUN --mount=type=cache` names its own id, defaulting to the mount
target, so unkeyed mounts share one directory box-wide. Worth re-reading that entry before hand-waving
it; its short form is that **corruption** (concurrent writers) is fixed by serial builds, but
**pollution** is not, and the path that bites is not malice but `mvn install` — a demo farm is full of
forks of the same starter, so two projects legitimately share `com.example:my-app:1.0-SNAPSHOT` and the
second silently resolves the first one's jar with a green build.

**Resolved 2026-09-10 by `D_builder`, which took position 4** — the one this file called "almost
certainly not worth it". Two requirements the operator stated as hard (a warm Maven cache, and
per-project isolation that is *enforced*) made it the only option satisfying both, once it was clear
that nothing available to the Dockerfile builder can remap a cache mount. Positions 1, 2, 3 and 5 are
recorded as roads not taken in that entry; don't re-list them here.

**`F_build_history` flipped from 🕳️ to ✅ — corrected 2026-09-09.** The earlier reading came from
discussion #5114, where the builds-plugin effort is described as stalled; it landed in **0.38.0**, which
is below our pin. Dokku now writes a JSON record and a log file per deploy under
`/var/lib/dokku/data/builds/<app>/`, keeps 20 per app (`builds:set … retention N`), and exposes
`builds:list` / `builds:info` / `builds:output` with `--format json`. The part that matters for us is
that the capture is **trigger-independent** — the whole deploy is redirected, and `git:sync` goes
through the same path — so the poll cron gets its build log without teeing anything, and `Q_build_history`
is closed rather than answered. `RESEARCH.md` → *Build tracking* has the commands and the two sharp
edges (`builds:output <app>` with no id reads the deploy lock, not the last build; the record carries no
git SHA).

## B. Run

| `F_` | Feature | Today | Dokku answer | |
|---|---|---|---|---|
| `F_run_limits` | Runtime memory + CPU quota per app | `docker run -m … --cpus …` by shepherd-java | `resource:limit --memory N --cpu N` | ✅ |
| `F_keep_alive` | Restart on crash and after a host reboot | Docker restart policy | `ps:set --global restart-policy always` (default is `on-failure:10`) + `ps:restore` from the init service | ✅ |
| `F_runtime_env` ⁿᵉʷ | Per-project runtime env vars | `runtime.envVars` | `config:set` | ✅ |
| `F_network_isolation` | Apps can't reach another app's non-public ports (was: "…or the admin plane" — there is no longer an admin plane) | one bridge network per app (`D_network_per_project`) | **Not the default** — every app shares Docker's default bridge. Opted into per project: `network:create` + `network:set <app> initial-network`, and `postgres:create --initial-network` for the app's database. **Decided — `D_isolation`** | 🔧 |
| `F_postgres` | Optional per-project Postgres | a README TODO in *both* predecessors; shepherd-java has a fixed `postgres-service` with a hardcoded password | `dokku-postgres`: `postgres:create` + `postgres:link` → `DATABASE_URL`, plus S3 backup schedules | ✅ |
| `F_restart` | Restart one app on demand | `shepherd-cli restart` | `ps:restart <app>` | ✅ |

**`F_network_isolation` — decided 2026-09-10, see `D_isolation`.** One Dokku-managed bridge network per
project (`network:create` + `network:set <app> initial-network`, and `postgres:create --initial-network`
for the project's database), which is `D_network_per_project` carried forward. The argument, the two
rejected rungs and the consequences are in that entry; the mechanics are in `RESEARCH.md`
(*Networking and app isolation*). The three things worth knowing from here:

- **It got cheaper, and that is why it survived the move.** `shepherd-traefik-connect-networks` has no
  successor: membership is managed state Dokku re-applies at every container creation, and a host-side
  nginx needs no membership at all. That was the entire cost of the isolation before.
- **It is contingent on `D_proxy`** — the Traefik plugin has no network-attachment logic, so under
  Traefik this feature costs either itself or a reconciler cron.
- **What it does *not* cover** is app-to-host and egress, since every container keeps a route to its
  bridge gateway no matter which network it is on. That axis is deferred to
  `ideas/harden-container-egress.md` and is where the old `int_jenkins` / `int_shepherd` admin-plane
  concern now lands.

## C. Publish

| `F_` | Feature | Today | Dokku answer | |
|---|---|---|---|---|
| `F_subdomain` | App reachable at `PROJECTID.<domain>` | Traefik host rule from a label | `domains:set-global <domain>` and the app name becomes the subdomain | ✅ |
| `F_port_contract` | ~~`EXPOSE 8080` is the whole app contract~~ → **listen on `$PORT`** | Traefik routes to 8080 | **Free under `D_builder`** — the buildpack builders end the build with `ports-set-detected http:<proxy-port>:5000` `[src]` and the app reads `$PORT`. The `EXPOSE`/`ports:set` dance was Dockerfile-only | ✅ |
| `F_wildcard_https` | **One** wildcard Let's Encrypt cert via DNS-01 — a new app is on https immediately, with no per-app ACME round-trip | Traefik, DNS challenge, one wildcard cert | lego (`--dns godaddy`) on the host + a root cron line, pushed into every app by `dokku-global-cert`. **Decided — `D_cert`** | 🔧 |
| `F_custom_domains` ⁿᵉʷ | Extra domains per project, with https on them | `publication.additionalDomains` | `domains:add <app> …` — but the wildcard cert covers no foreign domain, so https on one needs `dokku-letsencrypt` on that app. **Deferred to v2** (`D_cert`); never used in practice | ✂️ |
| `F_apex_domain` ⁿᵉʷ | One project can own the apex domain | `publication.publishOnMainDomain` | Name the app as an FQDN and the global vhost is ignored; or `domains:set`. The wildcard cert does not cover the apex, so it is one more `-d` on the lego command. **Deferred to v2** (`D_cert`) — nothing to run there | ✂️ |
| `F_ingress_tuning` ⁿᵉʷ | Per-project max body size and proxy read timeout | `publication.ingressConfig` | `nginx:set <app> client-max-body-size` / `proxy-read-timeout`, app-scoped, first-class | ✅ |

**`F_wildcard_https` — decided 2026-09-10, see `D_cert`.** One `*.mydomain.me` cert, issued and renewed
on the host by lego against GoDaddy (the same library and credentials Traefik uses today), pushed into
every app by `dokku-global-cert` from a `--renew-hook`. The argument, the five rejected routes and the
consequences are in that entry; the mechanics are in `RESEARCH.md` (*TLS*). The three things worth
knowing from here:

- **It turned on the requirement, not on the tooling.** Per-app ACME (`dokku-letsencrypt`) would have won
  had `F_custom_domains` stayed, because a wildcard covers no foreign domain. Every app ever hosted was a
  demo under the wildcard record, so the two rows above are deferred and "one cert" is the whole story.
- **Nothing per app.** `create-app` does no TLS work at all; the plugin imports the cert at app creation.
  The requirement's *"no per-app round-trip"* half is met literally.
- **The DNS API token lives on the box, root-only**, which is one more reason `D_single_operator` holds.

## D. Project lifecycle and configuration

| `F_` | Feature | Today | Dokku answer | |
|---|---|---|---|---|
| `F_project_descriptor` ⁿᵉʷ | **One JSON file per project is the source of truth**; create / update / delete a project from it | `/etc/shepherd/java/projects/<id>.json` + `shepherd-cli create/update/delete` | **Dokku's own state is the truth instead** — `D_dokku_is_truth`. Every fact is reportable as `--format json`; the two Dokku has no slot for (`SHEPHERD_GIT_URL`, `SHEPHERD_OWNER`) are config vars. Creation is `shepherd2 create-app`, everything after is `dokku` | ✂️ |
| `F_smart_update` ⁿᵉʷ | An update rebuilds only when *build* inputs changed; otherwise just re-applies config | `SimpleJenkinsClient.needsProjectRebuild` — rebuild iff `buildArgs`/`dockerFile` changed | With no descriptor there is no "update": a build-arg change is `docker-options:remove` + `add` + `ps:rebuild`, a runbook line. Source changes are `git:sync --build-if-changes` | ✂️ |
| `F_memory_quota` ⁿᵉʷ | **Box-wide** memory quota — refuse to create a project whose runtime + build memory overflows what the box has | `memoryQuotaMb` + `ShepherdClient.validate` | `create-app` sums `resource:report --format json` over `apps:list` and refuses. **Creation-time only** — a later hand `resource:limit` is unchecked | 🔧 |
| `F_reserved_ids` ⁿᵉʷ | Refuse project ids that collide with the admin plane (`admin`, `*-admin`) | `validate()` | Moot as written — there is no admin plane to collide with. Dokku 0.38 restricts app names for its own security reasons | ✂️ |
| `F_project_owner` ⁿᵉʷ | Record who owns each project (name, email) | `owner` in the project JSON | `config:set --no-restart <app> SHEPHERD_OWNER=…`, set by `create-app`. Leaks into the container env; not a secret | 🔧 |

**`F_project_descriptor` — decided 2026-09-10, see `D_dokku_is_truth`.** It was the design fork of the
whole project and it went the way the ideas file's own instinct did *not*: no descriptor, no converger,
Dokku's state is the truth. The argument, the five rejected shapes and the consequences are in the entry;
the three things worth knowing from here:

- **The fork was never "software or guide".** Creation is ~ten commands, three non-idempotent, and earns a
  script either way; every day-N action is one `dokku` command and earns nothing. So the repo is
  `create-app` / `destroy-app` / `poll` / `rebuild` plus the box crons, and a `README.md` cheat sheet from
  `F_` row to `dokku` command for everything else. **Shepherd2 never wraps a command Dokku already has.**
- **What killed the descriptor was not size but conflict.** An authoritative file makes every other edit
  path (a hand `dokku config:set`, wharf) into drift needing a policy; with Dokku as truth there is no
  drift to police. The descriptor was shepherd-java's answer to plain Docker having no per-app state store,
  and Dokku *is* one.
- **The config vars beat inferring from Dokku's records on one edge.** `git:sync` does record its URL
  (`apps:report --app-deploy-source-metadata`) but only after a build that succeeded — and first builds
  usually fail a couple of times. An app with no recorded URL would be invisible to a derived poll and
  never healed by the upstream fix. `SHEPHERD_GIT_URL` is written before the first build.

What remains in this section is only confirming the `F_reserved_ids` drop.

## E. Observability and administration

| `F_` | Feature | Today | Dokku answer | |
|---|---|---|---|---|
| `F_app_logs` | Per-app runtime logs | Web Admin / `shepherd-cli logs` | `dokku logs <app> -t -p web`, plus optional Vector shipping | ✅ |
| `F_app_stats` | Per-app CPU / memory | Web Admin / `shepherd-cli stats`, from `docker` | Dokku won't do monitoring by design — but apps are plain containers, so `docker stats` / `lazydocker` / `ctop`, zero code | ✅ |
| `F_admin_iface` | Create, deploy, restart, inspect | Web Admin + `shepherd-cli` | Dokku's CLI over SSH; `*:report --format json` makes it a structured interface, not screen-scraping | ✅ |
| `F_web_admin` | A **browser** UI | shepherd-web (Vaadin) | Dokku Pro (paid, proprietary); third-party UIs are a graveyard with one survivor | ✂️ |
| `F_multi_user` ⁿᵉʷ | **An admin adds users; each user sees, creates, edits and deletes only their own projects** | `UserRoles.USER`/`ADMIN`; the project list filters on `owner.email` unless you're admin | **Nothing in core** — an authorised SSH key may do anything to any app. Buildable on the `user-auth` trigger; `dokku-acl` is the stale community attempt. **Deferred to v2 — `D_single_operator`** | 🕳️ |
| `F_user_login` ⁿᵉʷ | **Log in with a password or Google SSO**, SSO self-provisioning a user whose email ends with an allowed domain | `webadmin-users.json` + hashed passwords; `googleSSOClientId`, `ssoOnlyAllowEmailsEndingWith` | **Nothing** — no password, no SSO, no OIDC, and no HTTP API to attach one to. SSH keys are the sole authentication | ✂️ |

`F_web_admin` is decided in principle by `D_retire_shepherd_java`, but that entry's `Status:` says the
*shape* is still open — and the two rows under it are what dropping the UI actually costs, which is why
they now have slugs of their own rather than living inside `F_web_admin`'s parenthesis. See `Q_web_admin`
and `Q_multi_user`.

**`D_retire_shepherd_java` says "access control becomes SSH keys". That understates it** — SSH keys are
not access control. In core Dokku the *only* privilege distinction is the substring `admin` in a key
name (which grants adding further keys); every other key may run every command against every app,
`apps:destroy` on someone else's project included. Dokku's maintainer states this is by design: the
product assumes a personal or fully-trusted-team box, and anyone with real SSH access bypasses added
restrictions anyway. So today a regular Shepherd user gets a scoped view of their own projects; the
naive Dokku successor gives every keyholder the whole box. `RESEARCH.md` → *Users and access control*
has the detail.

`F_user_login` is proposed as a straight drop rather than a gap, because nothing short of Dokku Pro
(paid, and its reverse-proxy auth) could ever provide it and there is no browser UI left to log in to —
unless v2 takes `Q_web_admin`'s option 3, the reworked Vaadin admin, which is the one route that brings
Google SSO back. `F_multi_user` is a real fork, with four positions; **position 1 is v1, decided
2026-09-10 as `D_single_operator`**, and the other three are the v2 candidates:

1. **Single-operator box.** Only the operator holds a key. User management evaporates; `F_project_owner`
   is a contact field (`SHEPHERD_OWNER`), not an ACL. Cheapest, and the honest reading of "no web
   admin". The one thing v1 must get right for v2's sake is storing the owner in a form a `user-auth`
   hook can match against `$SSH_NAME` — see the entry's *Consequences*.
2. **Our own `user-auth` hook.** `SHEPHERD_OWNER` already names an owner per app (`D_dokku_is_truth`),
   so the check is "is `$SSH_NAME` the app's owner" — one `config:get`, a small Bash hook, no third-party
   dependency, and squarely "the answer is a wrapper script". Buys per-user push / restart / logs;
   still no self-service and no SSO, and we would own a security-critical hook.
3. **`dokku-acl`.** More features than we'd write, but: last commit 2024-01, written against 0.32 (six
   minors behind our pin), self-described as not security-audited — and that last commit was *adapting
   to a trigger rename*, i.e. the failure mode when Dokku moves is that the hook stops being invoked at
   all and enforcement silently disappears. That is the `D_retire_shepherd_java`
   death-rate argument again, except in the authorization path. It also does not give Shepherd's model
   without glue: ACLs cannot be edited over SSH, creating an app does not add the creator to its ACL,
   and `apps:create` is all-users-or-none.
4. **Dokku Pro.** Teams, `users:create`, reverse-proxy SSO — the only real mirror of Shepherd, and
   already rejected in `D_retire_shepherd_java` for being paid and proprietary.

## F. Host operations

| `F_` | Feature | Today | Dokku answer | |
|---|---|---|---|---|
| `F_install` | Reproducible one-shot host provisioning | `install` | Dokku's `bootstrap.sh` is two commands; **everything on top of it is ours** — daemon address pools, plugins, global properties, the poll cron, the prune cron, TLS | 🔧 |
| `F_uninstall` ⁿᵉʷ | Tear the box down, symmetrically with what `install` created | `uninstall` | Nothing; ours. Worth keeping the old invariant that install/uninstall stay symmetric | 🔧 |
| `F_housekeeping` | Periodic prune of images and build caches | `shepherd-clearcache`, weekly cron | Ours: `docker buildx prune` + `docker system prune`, **weekly not nightly** (the purge cadence is the cache's real lifetime) | 🔧 |
| `F_safe_reboot` ⁿᵉʷ | Graceful "wait until it's safe" before a host reboot, so a reboot never lands mid-build | `shepherd-cli shutdown` — blocks until Jenkins is idle | Half of it is upstream: `builds:list` with no app lists every running build box-wide. Blocking until it's empty (or until our poll's lock file is free) is ours | 🔧 |

## Proposed drops

Say so if any of these is wrong:

- **`F_web_admin`** — the browser UI.
- **`F_user_login`** — password and Google SSO login, and the email-domain allowlist. Nothing outside
  Dokku Pro can provide it, and with the UI gone there is nothing to log in to. (`F_multi_user` is *not*
  on this list — it is an open fork, see `Q_multi_user`.)
- **`F_reserved_ids`** — there is no admin plane left to collide with.
- **`F_custom_domains` and `F_apex_domain`** — *deferred to v2*, not dropped (`D_cert`). Neither was ever
  used: every app has been a demo at `PROJECTID.<domain>`, and there is nothing to publish on the apex
  when a visitor cannot ask for an app. v2 is `dokku-letsencrypt` on the affected apps only, which
  coexists with the global cert.
- **The naming contract** — `shepherd_PROJECTID` / `shepherd/PROJECTID` / `PROJECTID.shepherd`. It
  existed because there was no scheduler or registry, so the name *was* the lookup. Dokku owns naming.
- **`shepherd-java-api` on Maven Central** — no successor library; published versions stay published.
- **Jenkins, and everything downstream of it**: the `jenkins-admin.<domain>` vhost, the Jenkins
  credentials store as our secret store, the `admin.int` network, `docker-compose.yaml`.
- **`F_build_dockerfile` and `F_custom_dockerfile`** — by choice, as of `D_builder`: the Dockerfile is
  what made per-project cache isolation unenforceable. Apps carry a `Procfile` instead.
- ~~**`F_build_cpu_limit`** — not by choice; the Dockerfile builder can't.~~ Probably back on the menu
  under `D_builder`, since the herokuish path passes build options to `docker container create`
  unfiltered. Build *memory* caps either way, which is the one that actually protects the box from a
  runaway JVM build.

## Open questions — these decide the shape

Roughly in the order they need answering; each becomes a `D_` entry once settled.

- ~~**`Q_descriptor`**~~ — **answered 2026-09-10: no descriptor; Dokku's state is the truth. See
  `D_dokku_is_truth`.** The two facts Dokku cannot hold are `SHEPHERD_GIT_URL` / `SHEPHERD_OWNER` config
  vars; Shepherd2 is `create-app` / `destroy-app` / `poll` / `rebuild` and the box crons, and wraps
  nothing Dokku already has. `F_smart_update` is dropped with it; `F_memory_quota` survives at creation
  time only. *(Section D.)*
- ~~**`Q_proxy`**~~ — **answered 2026-09-10: nginx, Dokku's default. See `D_proxy`.** It was not close in
  the end: Traefik is global-only for ingress properties (costing `F_ingress_tuning`), ignores the
  `certs` plugin (costing `Q_cert` routes 1 and 2), and has no network-attachment logic at all (costing
  `F_network_isolation`, or a reconciler cron). Familiarity was its whole case.
- ~~**`Q_cert`**~~ — **answered 2026-09-10: one wildcard cert, lego DNS-01 against GoDaddy on the host,
  `dokku-global-cert` for propagation. See `D_cert`.** Relaxing the requirement to per-app ACME was
  argued and lost: it only paid off with custom domains, which no app has ever used, so
  `F_custom_domains` and `F_apex_domain` are deferred to v2 instead. *(Section C.)*
- **`Q_cache`** — which of the five positions on `F_cache_isolation`? **Downgraded 2026-09-09**: the
  per-app `--cache-to` carries over, so this is no longer a regression to absorb but a pre-existing gap
  (the app's own cache mounts) to close or accept. `D_no_shared_cache` deserves re-reading before we
  pick. **Reframed 2026-09-10, not decided — see `ideas/build-cache.md`**: the five positions collapse
  to a two-way fork (convention vs. prune mounts between builds), and two things this file treats as
  settled are open there too — whether the per-project `--cache-to` dirs are wanted at all, and the
  poll interval every cadence answer hangs on.
- ~~**`Q_isolation`**~~ — **answered 2026-09-10: one bridge network per project. See `D_isolation`.** The
  shared default bridge and the `enable_icc=false` variant are recorded there as roads not taken. What
  remains open is only the axis that was never this question's — app-to-host and egress, now
  `ideas/harden-container-egress.md`.
- **`Q_multi_user`** — **answered for v1 2026-09-10: single operator, see `D_single_operator`.** Stays
  open as the **v2** question: how does per-user project ownership come back? Really the question *who
  else gets an SSH key*, because in core Dokku a key is unrestricted: there is no ownership to scope it
  with. The candidates are a `user-auth` hook of our own (cheap — `SHEPHERD_OWNER` exists per
  `D_dokku_is_truth`, and matching it against `$SSH_NAME` is the whole hook), `dokku-acl` in the
  authorization path, or Dokku Pro. Whether `F_user_login` returns with it depends on `Q_web_admin`'s
  option 3. *(Section E.)*
- **`Q_web_admin`** — **answered for the first version 2026-09-10: no UI.** The admin interface is an
  SSH login to the box and `dokku` / `shepherd2` commands issued by hand, with `README.md` documenting
  every common scenario (build log, runtime log, restart, config change, extra domain, build-arg change,
  …) as the exact command. That is `D_dokku_is_truth`'s cheat sheet, and it is the whole of v1. One
  practical note for that README: the operator logs in as an admin user and runs both `dokku …` and
  `shepherd2 …` from one shell; the `ssh dokku@host <cmd>` remote form is for *other* keyholders and
  reaches only `dokku`, so it belongs to `Q_multi_user`, not to v1.

  **Kept open for later, none decided** — every one of them is a *client* of Dokku's state, which is the
  property `D_dokku_is_truth` requires of any UI:
  1. **A read-only status page** generated by cron from `dokku *:report --format json`, served as static
     files. No auth to get wrong, no framework, and it covers "is everything up" without covering
     "administer the box".
  2. **wharf**, adopted as a pure client — day-N edits and logs in a browser, nothing to lose if it dies
     (`D_dokku_is_truth` *Consequences*). Single admin password, so single-operator only.
  3. **Re-programme shepherd-java-client as a Dokku client**, once `create-app`'s command set has
     solidified: stop storing `/etc/shepherd/java/projects/*.json`, read `*:report --format json` for
     the project list, and edit by emitting `dokku` / `shepherd2` commands. The existing Vaadin Web Admin
     then drives a shepherd2-dokku box unchanged on the surface. This is the first road-not-taken in
     `D_retire_shepherd_java` reopened, and it is the only option here that gives back `F_multi_user` and
     `F_user_login` (Google SSO, per-owner project lists) without Dokku Pro. The flavour that keeps the
     JSON files as truth is *not* on the table — it is the descriptor through the back door.
  4. **A TUI in Ruby on [Tuile](https://github.com/mvysny/tuile).** Same client shape as 3 with no
     browser, no auth of its own and no JVM: it runs in the operator's SSH session and shells out to
     `dokku` / `shepherd2`, so it is v1's cheat sheet made interactive. Prior art for the shape is the
     Ruby `dokku-cli` gem. Cheapest of the four to build and the one that adds no new surface to the box.
- ~~**`Q_build_history`**~~ — **closed 2026-09-09, not answered**: Dokku's `builds` plugin already does
  it (see section A). The tee-to-`/var/log/shepherd2` sketch this question proposed is dead — writing it
  would duplicate `/var/lib/dokku/data/builds/` with a worse retention story. The only thing left to
  decide is whether the default retention of 20 is right for a weekly poll, which is one
  `builds:set --global retention N` in the installer, not a fork in the design.
- **`Q_quota`** — keep `F_memory_quota`? It has never been Dokku's job and never will be. Summing
  `resource:report --format json` across apps and refusing an over-commit is maybe 20 lines in
  `create-app` — but only *there*: under `D_dokku_is_truth` a later hand `resource:limit` bypasses it.
  Is creation-time-only enforcement worth the 20 lines?
- **`Q_credentials`** — `git:auth` is per *host*, not per project, so one GitHub token would cover the
  whole box. Is per-project git credentials still a requirement, or was it an artifact of Jenkins having
  a credentials store? (Deploy keys per project may still work; `[unverified]`.)
- **`Q_language`** — what is the glue written in? Bash matches both predecessors and adds no runtime.
  Its main input is gone: with `D_dokku_is_truth` there is no descriptor to parse, only `--format json`
  reports to read, which is `jq`. Bash + `jq` is the default; the remaining case for anything richer is
  `create-app`'s argument list (a dozen flags) — decide when writing it.

## A concrete sketch, to argue against

With nginx settled by `D_proxy`, per-project networks by `D_isolation`, no descriptor by
`D_dokku_is_truth` and one wildcard cert by `D_cert`, the whole repo is roughly:

```
shepherd2 create-app ID URL [REF] [--mem M --cpu C --build-mem B --postgres --owner EMAIL
                             #   --buildpack BP --build-dir PATH --domain D…]
                             #   quota check, then: apps:create, config:set SHEPHERD_GIT_URL/_OWNER
                             #   + any build-time vars (--no-restart), resource:limit,
                             #   network:create + network:set, postgres:create -N + link if asked,
                             #   buildpacks:set if --buildpack given (else the repo's own
                             #   .buildpacks names it — D_builder), then git:sync --build
shepherd2 destroy-app ID     # the inverse, symmetric: apps:destroy, postgres:destroy, network:destroy
shepherd2 rebuild ID         # git:sync --build with the app's SHEPHERD_GIT_URL — the forced variant,
                             #   and the retry after a failed build
shepherd2 poll               # cron: for every app with SHEPHERD_GIT_URL, git:sync --build-if-changes,
                             #   serially under a lock file (Dokku records the build logs itself)
shepherd2-clearcache         # weekly: docker system prune. NOT a blanket volume prune — under
                             #   D_builder the per-app cache-$APP volumes are the build cache;
                             #   the per-app lever is dokku repo:purge-cache ID
shepherd2-install            # dokku bootstrap.sh + daemon address pools + plugins + globals + crons,
                             #   lego + global-cert + first issuance (D_cert)
shepherd2-uninstall
```

Plus one root cron line that is not a script: `lego renew --days 30 --renew-hook '<two lines calling
dokku global-cert:set>'` (`D_cert`). One CLI with four verbs plus three box scripts, and no data
directory, against today's Jenkins + Traefik + compose + five scripts + a Kotlin/Vaadin repo. **`shepherd2 poll` is the whole of Jenkins**, and
`F_safe_reboot` is `flock` on the lock file it already holds. Whether the four verbs are one script or
four is `Q_language`'s leftover.

Everything else the `F_` tables preserve is a `dokku` command and belongs in a `README.md` cheat sheet,
not here: `logs -t`, `builds:list` / `builds:output`, `ps:restart`, `config:set`, `domains:add`,
`nginx:set`, `resource:limit`, and the three-command build-arg change.

Worth noting what is *not* in the list: no network reconciler. The Dokploy sibling needs an eighth
script on a short cron to re-attach its proxy to every per-app network after Dokploy re-creates the
Traefik container; a host-side nginx dialling container IPs cannot have that failure mode, and
`network:rebuild` covers the rest. See `ideas/app-network-isolation.md`.

Where this sketch is weakest: `create-app` is a dozen flags, and a project whose creation fails halfway
(the first build usually does) must be re-runnable without tripping over the three non-idempotent
commands — `apps:exists` / `network:exists` / `postgres:exists` guards, or a `destroy-app` first.
`Q_cache` is *mostly* handled — `create-app` emits `docker-options:add … build '--cache-to …'` per
project, so the layer cache is enforced the way `shepherd-build` enforces it today; what the sketch
still cannot do is scope an app's own `RUN --mount=type=cache`, which stays convention
(`--build-arg CACHE_ID=PROJECTID` plus a documented `id=`, cooperation rather than enforcement).
