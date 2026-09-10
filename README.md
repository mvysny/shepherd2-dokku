# Shepherd2 (Dokku)

> **DESIGN PHASE — there is nothing to install yet.**
>
> This repo currently holds documentation only. The feature set is being agreed in
> [`ideas/features-to-preserve.md`](ideas/features-to-preserve.md); code follows after that.

Builds given git repos periodically and automatically deploys them to a Linux box running
[Dokku](https://dokku.com). Serves as a homebrew "replacement" for Heroku, to publish your own pet
projects. Built with off-the-shelf tools: **Dokku and nothing else.**

How this is meant to work:

* Each app is a Dokku app, built from its git repo by a **Heroku buildpack** — you supply a `Procfile`,
  not a `Dockerfile` — and run as a Docker container, published at `PROJECTID.<domain>` over https.
  Each project gets its own build cache, so one project can never resolve another's jars.
* Dokku **polls** each repo on a schedule rather than waiting for a push
  (`dokku git:sync --build-if-changes`), so Shepherd2 can host repos you don't own.
* Dokku's proxy terminates https and routes by hostname; Docker keeps the containers up and brings them
  back after a reboot.
* Administration is `ssh dokku@host …` — Dokku's own CLI. There is no web UI and no JVM anywhere.

The two predecessors of this project stay online and readable:
[Vaadin Shepherd](https://github.com/mvysny/shepherd) (Kubernetes) and
[shepherd-traefik](https://github.com/mvysny/shepherd-traefik) + [shepherd-java-client](https://github.com/mvysny/shepherd-java-client)
(Docker + Traefik + Jenkins + a Vaadin web admin). Why they were retired in favour of Dokku, and what
that cost: `D_dokku` and `D_retire_shepherd_java` in [DECISIONS.md](DECISIONS.md).

There is a sibling repo, [shepherd2-dokploy](https://github.com/mvysny/shepherd2-dokploy), which asks
the same question of [Dokploy](https://dokploy.com). The two are alternatives, not stages: Dokku
enforces a per-project build cache and caps build memory but has no web UI; Dokploy keeps a browser UI
and the same Traefik as shepherd-traefik, and enforces nothing about the cache. `D_dokku` argues that
fork out.

## Where things are documented

| If you want to… | Read |
|---|---|
| run, install or troubleshoot this box | this file (once there is something to run) |
| know what **Dokku** does — a command, a flag, a plugin, a gap | [RESEARCH.md](RESEARCH.md) |
| know *why* it's built this way, and what was rejected | [DECISIONS.md](DECISIONS.md) (`D_` entries) |
| see what's still being figured out | [`ideas/`](ideas/) — `ls` is the index |
| know which features are being preserved, glued or dropped | [`ideas/features-to-preserve.md`](ideas/features-to-preserve.md) |
| change things without breaking something remote | [CLAUDE.md](CLAUDE.md) |
| know whether some *other* PaaS should have been picked | [`COMPARISON.md` in shepherd-traefik](https://github.com/mvysny/shepherd-traefik/blob/main/COMPARISON.md) |

## Minimum requirements

Provisional — inherited from shepherd-traefik and Dokku's own documented minimums, not yet checked on a
real box.

* A VM with 8–16 GB of RAM; x86-64 or arm64. Ideally with a public IPv4 address.
  * Dokku's own documented minimum is 1 GB, but that is for Dokku, not for building JVM apps on the box.
* **Ubuntu 22.04 / 24.04, or Debian 11+** — Dokku supports these and nothing else. Ubuntu latest LTS is
  the target.
* A DNS domain with the IPv4 "A" record pointing at the VM. **Two records** are needed, `@` and `*`, so
  that wildcard subdomains work.
* **API access to that domain's DNS**, at a provider [lego](https://go-acme.github.io/lego/dns/) supports.
  The one wildcard certificate is issued over the DNS-01 challenge, so the box holds an API token that
  can edit the zone (root-only). GoDaddy is what the reference box uses; note that GoDaddy restricts its
  DNS API to accounts with 10+ domains or a Discount Domain Club plan.
* Docker 24+ is wanted so BuildKit is the default. (The build cache itself is a per-app Docker volume,
  not a BuildKit cache — see [`D_builder`](DECISIONS.md).)

## Installation

Not written yet. Dokku's own install is two commands and is documented in
[RESEARCH.md](RESEARCH.md#versions-platform-install); everything Shepherd2 adds on top of it is what
this section will become.

Two steps are already settled and are here so they are not forgotten, because both are awkward to
retrofit:

* **Enlarge Docker's address pools before deploying anything.** Each project gets its own Docker network
  (`D_isolation` in [DECISIONS.md](DECISIONS.md)), and a stock daemon runs out of them at **~30 apps**.
  Add a wider `default-address-pools` to `/etc/docker/daemon.json` and restart the daemon — the same
  edit shepherd-traefik needs. It cannot be applied later without restarting Docker, so it belongs in
  the install rather than in a fix.
* **Leave the proxy alone.** Dokku's default nginx is the proxy (`D_proxy`); do not install the Traefik
  plugin. Per-app tuning is `dokku nginx:set PROJECTID …`.
* **One wildcard certificate for every app** (`D_cert`). `lego` from the Ubuntu repos issues
  `*.mydomain.me` over DNS-01, a daily root cron line renews it, and its renew hook runs
  `dokku global-cert:set`, which pushes the new certificate into every app. New apps pick it up at
  creation. Nothing is done per app; do not install `dokku-letsencrypt`.

## Adding your project

Not written yet. **The contract has changed from both predecessors** — see
[`D_builder`](DECISIONS.md). A project is no longer expected to carry a `Dockerfile`; if it has one it
is ignored, because the box builds every app with Heroku buildpacks so that each project's dependency
cache is isolated from every other's. What it needs instead:

1. A `Procfile` at the root of its git repo, naming the `web` process.
2. A `.buildpacks`, also at the root, naming the buildpack — one per line, `heroku/java` shorthand
   accepted. **Don't skip this and rely on auto-detection:** a Java project that commits a
   `package.json` (which Vaadin tells you to do) is detected as a Node app, because `nodejs` is tried
   before `java`.
3. For a Maven project, a `system.properties` pinning `java.runtime.version`; the buildpack runs
   `mvn clean dependency:list install -DskipTests` unless `MAVEN_CUSTOM_GOALS` / `MAVEN_CUSTOM_OPTS`
   say otherwise.
4. Optionally a committed `.env` for build-time settings — it reaches the build environment, so a
   Vaadin project points its caches at the per-app cache volume there:
   `npm_config_cache=/cache/npm`. `dokku config:set` does the same thing from the box side and wins.

The project chooses its own buildpack, and the box does not need to know about it. If a repo can't be
edited or picks wrongly, the operator can override it without touching the repo:
`dokku buildpacks:set PROJECTID heroku/java`.

**Pay attention to the memory limit** the container will run under (256 MB on the reference box). If
the JVM asks for more it is hard-killed by the Linux OOM killer with no warning and no log message
(only the host's `dmesg` records it). Run Java with `-Xmx` a little below the limit, so the app dies
with an `OutOfMemoryError` that shows up in the logs instead.

**Listen on `$PORT`, not on a port of your choosing.** The buildpack sets it (5000), and Dokku wires
the proxy to it automatically — so the `EXPOSE`/`ports:set` dance the predecessors needed does not
arise. Details in [RESEARCH.md](RESEARCH.md#ports--the-expose-trap).
