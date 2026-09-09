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
| `F_build_dockerfile` | Build from the `Dockerfile` at the repo root, on the box | Jenkins → `shepherd-build` → `docker build` | Dockerfile builder, auto-detected | ✅ |
| `F_poll_rebuild` | Rebuild **on a schedule**, not on push — we host repos we don't own | Jenkins poll-SCM job per project | `dokku git:sync --build-if-changes <app> <url> <ref>` from a **host crontab** — `app.json` cron runs the deployed image and cannot build | 🔧 |
| `F_build_mem_limit` | Cap build memory | `shepherd-build` `--memory` | `resource:limit --process-type build --memory N` | ✅ |
| `F_build_cpu_limit` | Cap build CPU | `shepherd-build` `--cpu-quota` | **Not supported for the Dockerfile builder** (documented `✗`, and confirmed by the build-option allowlist: `--memory` is on it, no `--cpus`/`--cpu-quota` is) | 🕳️ |
| `F_build_args` ⁿᵉʷ | Per-project build args — the Vaadin offline key needs to exist at *build* time | `build.buildArgs` in the project JSON | `docker-options:add <app> build '--build-arg K=V'`; config vars are runtime-only for Dockerfile builds | 🔧 |
| `F_custom_dockerfile` ⁿᵉʷ | Per-project Dockerfile path (`vherd.Dockerfile`) | `build.dockerFile` | `builder-dockerfile:set <app> dockerfile-path …` | ✅ |
| `F_build_cache` | The Maven/Gradle dependency tree must not be re-downloaded on every scheduled rebuild | per-project buildx `type=local` dir + cache mounts | Both halves survive: cache mounts documented, and `--cache-to/--cache-from` go through per app | ✅ |
| `F_cache_isolation` | …and that cache must be **per project** — one project must not reach another's artifacts | `--cache-to/--cache-from` per project id, enforced on the build command | **Parity, not a gap** — `docker-options:add <app> build '--cache-to …'` is allowlisted through to `docker image build`. The `RUN --mount` half stays convention, as it is today | 🔧 |
| `F_build_serial` ⁿᵉʷ | Never two builds at once (`concurrentJenkinsBuilders: 1`) — the corruption half of the cache problem | Jenkins executor count | Free if the poll is one serial cron loop; `parallel-schedule-count` is about deploys, not builds | 🔧 |
| `F_build_history` ⁿᵉʷ | The list of past builds, and each one's build log | Jenkins; `shepherd-cli builds` / `buildlog` | **Nothing.** No deploy history, no git SHAs; `logs:failed` keeps the last failed deploy only | 🕳️ |
| `F_private_repos` ⁿᵉʷ | Build private repos, with a credential per project | Jenkins credentials store, `gitRepo.credentialsID` | `git:auth <host> <user> <token>` (netrc) or a deploy key — but **per host, not per project** | 🕳️ |

**`F_cache_isolation` was the scariest row here and it has shrunk — corrected 2026-09-09.** The earlier
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

Positions on that remaining half, cheapest first — the question is now "close a gap we already have?",
not "absorb a regression":

1. **Status quo: layer cache per project, mounts by convention.** `--cache-to` per app plus an
   `id=<project>` convention on the mounts we can influence. `D_no_shared_cache` already keeps `id=`
   "as a collision-avoidance convention, never as a boundary". Zero new glue; the gap stays open.
2. **Layer cache only.** Drop cache mounts entirely; rely on a `COPY pom.xml` + `mvn dependency:go-offline`
   layer, which the per-app `--cache-to` cache then protects properly. Safe and slower — a dependency
   bump re-downloads — and it only works for repos whose `Dockerfile` we can influence.
3. **A Maven repo proxy** (Nexus et al.) — the classic CI answer, sidesteps pollution entirely, and was
   rejected in `D_no_shared_cache` on cost + cooperation. Reconsider: the cost argument was "adds a
   container to a small box", and we just deleted Jenkins.
4. **Switch to a buildpack builder**, where Dokku mounts a `cache-$APP` volume the app cannot name and
   `repo:purge-cache <app>` clears exactly one project's. Fully enforced, both halves — at the price of
   `F_build_dockerfile`, since a buildpack means there is no Dockerfile. Almost certainly not worth it,
   but it is the only option that actually *closes* the gap, so it belongs on the list.
5. **Accept it and document it.** Say plainly in `README.md` that cache mounts are shared and that
   projects hosted here are not isolated at the artifact level. This is what is true today, unstated.

*Also carried over regardless of which we pick:* buildkitd runs its own GC (reported to evict unused
entries after ~48 h), so a cache mount is not a durable store — and the purge cadence is the cache's
real lifetime, so the successor to `shepherd-clearcache` must stay **weekly**, not nightly.

## B. Run

| `F_` | Feature | Today | Dokku answer | |
|---|---|---|---|---|
| `F_run_limits` | Runtime memory + CPU quota per app | `docker run -m … --cpus …` by shepherd-java | `resource:limit --memory N --cpu N` | ✅ |
| `F_keep_alive` | Restart on crash and after a host reboot | Docker restart policy | `ps:set --global restart-policy always` (default is `on-failure:10`) + `ps:restore` from the init service | ✅ |
| `F_runtime_env` ⁿᵉʷ | Per-project runtime env vars | `runtime.envVars` | `config:set` | ✅ |
| `F_network_isolation` | Apps can't reach each other, or the admin plane | one bridge network per app (`D_network_per_project`) | **Not the default** — every app shares Docker's default bridge. Opt in with `network:create` + `network:set <app> initial-network` | 🔧 |
| `F_postgres` | Optional per-project Postgres | a README TODO in *both* predecessors; shepherd-java has a fixed `postgres-service` with a hardcoded password | `dokku-postgres`: `postgres:create` + `postgres:link` → `DATABASE_URL`, plus S3 backup schedules | ✅ |
| `F_restart` | Restart one app on demand | `shepherd-cli restart` | `ps:restart <app>` | ✅ |

**`F_network_isolation` is the one to think about**, because Dokku changes its economics in both
directions at once. The *reason* for it is unchanged and still good: these are other people's example
projects and addons, mutually untrusted, all on one daemon. What changes:

- **It got cheaper.** Dokku's nginx runs on the **host** and dials container IPs, so it never needs to
  share an app's network. shepherd-traefik's whole network-sharing gotcha —
  `shepherd-traefik-connect-networks`, "prefer `docker restart` over a compose recreate", the 502s —
  simply does not exist. That was the entire cost of the isolation, and it's gone. (Under the *Traefik*
  plugin it presumably comes back, since Traefik is a container again — see `Q_proxy`.)
- **It got more manual.** It is now two commands per app instead of a property of the design, and the
  admin plane it used to protect (`int_jenkins` holding the Docker socket and the credentials,
  `int_shepherd`) **no longer exists** — so re-examine what we're isolating *from*. App-to-app is still
  a real concern; app-to-admin-container mostly isn't, since Dokku is a host binary, not a container.
- **The address-pool tax is unchanged.** One network per app still walls into Docker's default pools at
  ~29 networks, so `/etc/docker/daemon.json` still needs enlarged `default-address-pools`. Whether
  Dokku's `bootstrap.sh` writes that file is `[unverified]`.

## C. Publish

| `F_` | Feature | Today | Dokku answer | |
|---|---|---|---|---|
| `F_subdomain` | App reachable at `PROJECTID.<domain>` | Traefik host rule from a label | `domains:set-global <domain>` and the app name becomes the subdomain | ✅ |
| `F_port_contract` | `EXPOSE 8080` is the whole app contract | Traefik routes to 8080 | `EXPOSE 8080` makes Dokku publish on **:8080**; needs `ports:set <app> http:80:8080 https:443:8080` per app | 🔧 |
| `F_wildcard_https` | **One** wildcard Let's Encrypt cert via DNS-01 — a new app is on https immediately, with no per-app ACME round-trip | Traefik, DNS challenge, one wildcard cert | Three routes, all with caveats — see below | 🔧 |
| `F_custom_domains` ⁿᵉʷ | Extra domains per project, with https on them | `publication.additionalDomains` | `domains:add <app> …` | ✅ |
| `F_apex_domain` ⁿᵉʷ | One project can own the apex domain | `publication.publishOnMainDomain` | Name the app as an FQDN and the global vhost is ignored; or `domains:set` | ✅ |
| `F_ingress_tuning` ⁿᵉʷ | Per-project max body size and proxy read timeout | `publication.ingressConfig` | `nginx:set <app> client-max-body-size` / `proxy-read-timeout`, app-scoped, first-class | ✅ |

**`F_wildcard_https` is the largest chapter**, and the *"no per-app round-trip"* half is what's hard —
"https works" is easy on any route. The three routes, and what each costs:

1. **nginx + `dokku-global-cert`** — the exact current model: one cert, imported for every new app,
   re-applied to every app that has no cert of its own, re-applied on update so a renewal propagates.
   ✅ on the requirement. Costs: **we own the renewal cron** (lego/certbot DNS-01 → `global-cert:set`),
   and the plugin is thin (20★, and its README still advertises Dokku 0.7 / Docker 1.12).
2. **nginx + `dokku-letsencrypt`** (official, 1118★) — renewal is solved (`letsencrypt:cron-job --add`,
   daily, 30-day grace), DNS-01 providers are configurable globally. Costs: **issuance is per app**, so
   every new app does its own ACME order; and wildcard support is muddier than the README implies —
   issue #189 still carries *"wildcard support is not officially supported by this plugin"*.
3. **Traefik plugin + `challenge-mode dns`** — keeps our existing Traefik knowledge, renewal is
   Traefik's problem as it is today. Costs: **it ignores the `certs` plugin entirely**, so routes 1 and
   2 are off the table under it; nothing declares a wildcard SAN, so per-app orders remain unless we add
   `tls.domains` labels by hand; every `traefik:set` property is **global-only**, so `F_ingress_tuning`
   has to go through `traefik:labels:add`.

Rough read: **1 and 2 differ only in which cron we own** — our own renewal (1) versus per-app ACME
orders (2) — and 1 is what we do today. 3 trades `F_ingress_tuning` and both cert plugins for
familiarity. See `Q_proxy` and `Q_cert`.

## D. Project lifecycle and configuration

| `F_` | Feature | Today | Dokku answer | |
|---|---|---|---|---|
| `F_project_descriptor` ⁿᵉʷ | **One JSON file per project is the source of truth**; create / update / delete a project from it | `/etc/shepherd/java/projects/<id>.json` + `shepherd-cli create/update/delete` | **Nothing.** State is spread over `apps`, `config`, `resource`, `domains`, `ports`, `network`, `git`, `builder-dockerfile` properties | 🕳️ |
| `F_smart_update` ⁿᵉʷ | An update rebuilds only when *build* inputs changed; otherwise just re-applies config | `SimpleJenkinsClient.needsProjectRebuild` — rebuild iff `buildArgs`/`dockerFile` changed | Partly: `git:sync --build-if-changes` covers *source* changes; a changed build-arg is ours to notice | 🔧 |
| `F_memory_quota` ⁿᵉʷ | **Box-wide** memory quota — refuse to create a project whose runtime + build memory overflows what the box has | `memoryQuotaMb` + `ShepherdClient.validate` | **Nothing.** `resource:limit` is per app; nothing sums them or refuses an over-commit | 🕳️ |
| `F_reserved_ids` ⁿᵉʷ | Refuse project ids that collide with the admin plane (`admin`, `*-admin`) | `validate()` | Moot as written — there is no admin plane to collide with. Dokku 0.38 restricts app names for its own security reasons | ✂️ |
| `F_project_owner` ⁿᵉʷ | Record who owns each project (name, email) | `owner` in the project JSON | No metadata concept; would be a `config:set` var or a field in our own descriptor | 🔧 |

**`F_project_descriptor` is the design fork of the whole project**, more than the proxy or the cert. Two
shapes, and everything else follows from which we pick:

- **Declarative.** Keep a per-project file (`projects/PROJECTID.json` or `.yaml`) as the source of truth,
  and write **one converger script** that reads it and issues the `dokku` commands to make the box match:
  `apps:create`, `config:set`, `resource:limit`, `domains:set`, `ports:set`, `network:set`,
  `builder-dockerfile:set`, `docker-options:add … build`, and the crontab entry. Onboarding a project is
  "add a file, run the converger". This is what shepherd-java does today, minus the JVM, and it is where
  `F_memory_quota`, `F_smart_update`, `F_project_owner` and per-project cache ids all naturally live —
  they are cheap once there's a file to read and expensive otherwise.
- **Imperative.** No descriptor. `README.md` carries a runbook: "to add a project, run these eight
  `dokku` commands". Dokku's own state *is* the state. Smallest possible repo — arguably no repo at all,
  just a guide. Costs: the four 🕳️ features above stay dropped, re-creating a project after a reinstall
  is retyping eight commands per app rather than replaying files, and the box's configuration is not in
  git.

The declarative shape is a *much* smaller thing here than it was in shepherd-java, because Dokku's
commands are idempotent and its reports are `--format json` — so the converger is a loop, not a control
plane. My instinct is declarative for exactly that reason, but it is the call that decides whether this
repo is software or a guide. See `Q_descriptor`.

## E. Observability and administration

| `F_` | Feature | Today | Dokku answer | |
|---|---|---|---|---|
| `F_app_logs` | Per-app runtime logs | Web Admin / `shepherd-cli logs` | `dokku logs <app> -t -p web`, plus optional Vector shipping | ✅ |
| `F_app_stats` | Per-app CPU / memory | Web Admin / `shepherd-cli stats`, from `docker` | Dokku won't do monitoring by design — but apps are plain containers, so `docker stats` / `lazydocker` / `ctop`, zero code | ✅ |
| `F_admin_iface` | Create, deploy, restart, inspect | Web Admin + `shepherd-cli` | Dokku's CLI over SSH; `*:report --format json` makes it a structured interface, not screen-scraping | ✅ |
| `F_web_admin` | A **browser** UI | shepherd-web (Vaadin), with a user registry, Google SSO and an email-domain allowlist | Dokku Pro (paid, proprietary); third-party UIs are a graveyard with one survivor | ✂️ |

`F_web_admin` is decided in principle by `D_retire_shepherd_java` — but that entry's `Status:` says the
*shape* is still open, and dropping it takes Google SSO and the multi-user registry with it. Access
control becomes SSH keys. See `Q_web_admin`.

## F. Host operations

| `F_` | Feature | Today | Dokku answer | |
|---|---|---|---|---|
| `F_install` | Reproducible one-shot host provisioning | `install` | Dokku's `bootstrap.sh` is two commands; **everything on top of it is ours** — daemon address pools, plugins, global properties, the poll cron, the prune cron, TLS | 🔧 |
| `F_uninstall` ⁿᵉʷ | Tear the box down, symmetrically with what `install` created | `uninstall` | Nothing; ours. Worth keeping the old invariant that install/uninstall stay symmetric | 🔧 |
| `F_housekeeping` | Periodic prune of images and build caches | `shepherd-clearcache`, weekly cron | Ours: `docker buildx prune` + `docker system prune`, **weekly not nightly** (the purge cadence is the cache's real lifetime) | 🔧 |
| `F_safe_reboot` ⁿᵉʷ | Graceful "wait until it's safe" before a host reboot, so a reboot never lands mid-build | `shepherd-cli shutdown` — blocks until Jenkins is idle | Nothing. But if the poll is one cron loop holding a lock file, "safe" is just "the lock is free" — much cheaper than it was with Jenkins | 🔧 |

## Proposed drops

Say so if any of these is wrong:

- **`F_web_admin`** — the browser UI, its user registry, Google SSO and the email-domain allowlist.
- **`F_reserved_ids`** — there is no admin plane left to collide with.
- **The naming contract** — `shepherd_PROJECTID` / `shepherd/PROJECTID` / `PROJECTID.shepherd`. It
  existed because there was no scheduler or registry, so the name *was* the lookup. Dokku owns naming.
- **`shepherd-java-api` on Maven Central** — no successor library; published versions stay published.
- **Jenkins, and everything downstream of it**: the `jenkins-admin.<domain>` vhost, the Jenkins
  credentials store as our secret store, the `admin.int` network, `docker-compose.yaml`.
- **`F_build_cpu_limit`** — not by choice; the Dockerfile builder can't. Build *memory* still caps, which
  is the one that actually protects the box from a runaway JVM build.

## Open questions — these decide the shape

Roughly in the order they need answering; each becomes a `D_` entry once settled.

- **`Q_descriptor`** — declarative per-project file + a converger script, or an imperative runbook of
  `dokku` commands? Decides whether this repo is software or a guide, and whether `F_memory_quota`,
  `F_smart_update`, `F_project_owner` and per-project cache ids are cheap or impossible. *(Section D.)*
- **`Q_proxy`** — nginx (Dokku's default) or the official Traefik plugin? nginx wins on per-app ingress
  tuning, on being a host process (no network gotcha), and on keeping both cert plugins available.
  Traefik wins on us already knowing it. They are not symmetric: choosing Traefik forecloses `Q_cert`
  options 1 and 2.
- **`Q_cert`** — one cert we renew ourselves (`dokku-global-cert`), or per-app ACME with renewal solved
  (`dokku-letsencrypt`)? The requirement as written says the former; the requirement may be worth
  relaxing now that a new app appearing is a `dokku` command rather than a JSON file edit.
- **`Q_cache`** — which of the five positions on `F_cache_isolation`? **Downgraded 2026-09-09**: the
  per-app `--cache-to` carries over, so this is no longer a regression to absorb but a pre-existing gap
  (the app's own cache mounts) to close or accept. `D_no_shared_cache` deserves re-reading before we
  pick. Cheap either way if `Q_descriptor` goes declarative — the cache flags are two more lines the
  converger emits.
- **`Q_isolation`** — keep one Docker network per app, or accept Dokku's shared default bridge? Cheaper
  than before (no network-sharing gotcha) but more manual, and the admin plane it protected is gone.
- **`Q_web_admin`** — confirm the drop, or is "no browser UI at all" the thing that makes this not worth
  doing? A middle option exists and is not obviously silly: a read-only status page generated by cron
  from `dokku *:report --format json`, served as static files. No auth to get wrong, no framework, and
  it covers "is everything up" without covering "administer the box".
- **`Q_build_history`** — accept that build history and build logs are gone, or keep something? Cheapest
  non-nothing: the poll cron tees each build's output to `/var/log/shepherd2/<app>/<timestamp>.log` and
  rotates. That is ~5 lines and recovers most of what `shepherd-cli buildlog` was for.
- **`Q_quota`** — keep `F_memory_quota`? It has never been Dokku's job and never will be. Summing
  `resource:report --format json` across apps and refusing an over-commit is maybe 20 lines *if*
  `Q_descriptor` goes declarative, and impossible if it doesn't.
- **`Q_credentials`** — `git:auth` is per *host*, not per project, so one GitHub token would cover the
  whole box. Is per-project git credentials still a requirement, or was it an artifact of Jenkins having
  a credentials store? (Deploy keys per project may still work; `[unverified]`.)
- **`Q_language`** — what is the glue written in? Bash matches both predecessors and adds no runtime.
  Anything richer buys real argument parsing and JSON handling for `Q_descriptor`'s converger. Depends
  on `Q_descriptor`; not worth deciding before it.

## A concrete sketch, to argue against

Assuming the declarative answer to `Q_descriptor`, nginx for `Q_proxy` and `dokku-global-cert` for
`Q_cert` — i.e. the most feature-preserving reading — the whole repo is roughly:

```
projects/PROJECTID.json      # per-project descriptor, in git, the source of truth
shepherd2-apply PROJECTID    # converge one project: apps:create, config:set, resource:limit,
                             #   domains:set, ports:set, network:set, builder-dockerfile:set,
                             #   docker-options build args + per-project --cache-to/--cache-from,
                             #   then git:sync --build-if-changes
shepherd2-poll               # weekly-ish cron: shepherd2-apply for every project, serially,
                             #   under a lock file; tees build logs
shepherd2-renew-cert         # lego/certbot DNS-01 → dokku global-cert:set
shepherd2-clearcache         # weekly: docker buildx prune + docker system prune
shepherd2-install            # dokku bootstrap.sh + daemon address pools + plugins + globals + crons
shepherd2-uninstall
```

Seven Bash scripts and a directory of JSON, against today's Jenkins + Traefik + compose + five scripts +
a Kotlin/Vaadin repo. **`shepherd2-poll` is the whole of Jenkins**, and `F_safe_reboot` is `flock` on the
lock file it already holds.

Where this sketch is weakest: `shepherd2-apply` has to know which changes need a rebuild versus a
re-apply, which is `F_smart_update` and is where shepherd-java's non-obvious logic lived. `Q_cache` is
*mostly* handled by it — the converger emits `docker-options:add … build '--cache-to …'` per project, so
the layer cache is enforced the way `shepherd-build` enforces it today; what the sketch still cannot do
is scope an app's own `RUN --mount=type=cache`, which stays convention (`--build-arg CACHE_ID=PROJECTID`
plus a documented `id=`, cooperation rather than enforcement).
