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
  not a `Dockerfile` — and run as a Docker container, published at `PROJECTID.<domain>` over https (or
  plain http, if that is how the box was installed — see *Installation*).
  Each project gets its own build cache, so one project can never resolve another's jars.
* Dokku **polls** each repo **every 5 minutes** rather than waiting for a push
  (`dokku git:sync --build-if-changes`), so Shepherd2 can host repos you don't own. A commit is live
  within a few minutes of being pushed *somewhere else*, and nothing is rebuilt when nothing changed.
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
  * **Both DNS points apply only to an https box.** A box installed in **http mode** needs no zone, no
    `*` record and no API token — see *Installation*. That mode exists for a test VM, where resolution
    comes from `/etc/hosts` on whatever machine browses it.
* Docker 24+ is wanted so BuildKit is the default. (The build cache itself is a per-app Docker volume,
  not a BuildKit cache — see [`D_builder`](DECISIONS.md).)

## Installation

Not written yet. Dokku's own install is two commands and is documented in
[RESEARCH.md](RESEARCH.md#versions-platform-install); everything Shepherd2 adds on top of it is what
this section will become.

Four things are already settled and are here so they are not forgotten, because each is awkward or
impossible to retrofit:

* **Decide first: https or http. You do not get to change your mind.** The install runs in one of two
  modes (`D_cert`), and the choice is recorded on the box:
  * **https** — one wildcard `*.mydomain.me` certificate, the bullet below. This is what a real box runs.
  * **http** — plain http on port 80, no certificate, no lego, no DNS credentials. For a VM you are
    testing in, or any box where a wildcard certificate is not worth the trouble.

  Nothing in Dokku forbids switching, but Shepherd2 does not support it and the reason is not
  squeamishness: nginx sends HSTS by default with a **182-day** max-age and `includeSubdomains`, so once
  a browser has loaded any app on the domain over https it will refuse plain http for half a year, and
  no amount of work *on the box* undoes that. To change modes, reinstall.

  **Testing an http box without wildcard DNS**: you need no DNS at all. Put the app names in the
  `/etc/hosts` of the machine doing the browsing — one line per app, all pointing at the VM:

  ```
  192.168.122.10  app1.mydomain.me
  192.168.122.10  app2.mydomain.me
  ```

* **Enlarge Docker's address pools before deploying anything.** Each project gets its own Docker network
  (`D_isolation` in [DECISIONS.md](DECISIONS.md)), and a stock daemon runs out of them at **~30 apps**.
  Add a wider `default-address-pools` to `/etc/docker/daemon.json` and restart the daemon — the same
  edit shepherd-traefik needs. It cannot be applied later without restarting Docker, so it belongs in
  the install rather than in a fix.
* **Leave the proxy alone.** Dokku's default nginx is the proxy (`D_proxy`); do not install the Traefik
  plugin. Per-app tuning is `dokku nginx:set PROJECTID …`.
* **In https mode, one wildcard certificate for every app** (`D_cert`). `lego` from the Ubuntu repos
  issues `*.mydomain.me` over DNS-01, a daily root cron line renews it, and its renew hook runs
  `dokku global-cert:set`, which pushes the new certificate into every app. New apps pick it up at
  creation. Nothing is done per app; do not install `dokku-letsencrypt`. In http mode none of this is
  installed, and there is nothing to run instead.

## Adding your project

Not written yet, but the contract is settled. **It has changed from both predecessors** — see
[`D_builder`](DECISIONS.md). A project is no longer expected to carry a `Dockerfile`; if it has one it
is ignored, because the box builds every app with Heroku buildpacks so that each project's dependency
cache is isolated from every other's.

### What the repo needs

1. **A publicly cloneable git URL.** The box holds no git credentials in v1, so it must be able to
   `git clone` the repo anonymously; private repos are a v2 feature.
2. A `Procfile` at the root, naming the `web` process.
3. For a Maven project, a `system.properties` pinning `java.runtime.version`. The buildpack runs
   `mvn clean dependency:list install -DskipTests` unless `MAVEN_CUSTOM_GOALS` / `MAVEN_CUSTOM_OPTS`
   say otherwise.
4. **The buildpack, named — one way or the other** (next section). Don't rely on auto-detection: a
   Java project that commits a `package.json`, which Vaadin tells you to do, is detected as a *Node*
   app, because `nodejs` is tried before `java`.
5. Optionally a `.env`, for build-time settings the project wants to carry itself — see *The `.env`
   recipe* below.

And one thing the box does not offer yet: **there is no managed database.** An app that needs Postgres
cannot be hosted here in v1; the plugin that will provide it (`dokku-postgres`) is a v2 addition, and it
attaches to an app that already exists, so nothing about onboarding changes when it lands.

### Naming the buildpack: in the repo, or at registration

Both work, and they compose — **whatever is set at registration wins over the repo**, so a project
that gets it wrong is fixable without a commit.

```bash
# in the repo: .buildpacks, one entry per line, heroku/… shorthand accepted
heroku/java

# …or at registration, which is what most projects here do:
shepherd2 create-app myproject https://github.com/me/myproject --buildpack heroku/java

# …or after the fact, on an app that already exists:
dokku buildpacks:set myproject heroku/java
```

Pin a *third-party* buildpack to a commit — `https://github.com/someone/their-buildpack#a1b2c3d` —
or it is re-cloned at whatever that branch points to on the day, and the same commit of your app
stops building the same way twice. The bundled Heroku buildpacks are already pinned inside the
builder image.

### The `.env` recipe

A committed `.env` reaches the **build** environment, so a project can point its own caches at the
per-app cache volume that Dokku mounts at `/cache`. That volume is yours alone and survives between
builds, which is what stops the Maven tree being re-downloaded on every scheduled rebuild.

**As this box actually runs, you need no `.env` at all** — not for Maven, and not for Vaadin. The
buildpack already puts `.m2/repository` in the cache volume, and every Vaadin app here relies on
Vaadin's **pre-compiled production bundle**, which skips npm and Vite entirely for an app with no
frontend-customising add-ons and no custom JS/TS (Vaadin 24.1+). No frontend build means nothing to
cache, and that is the recommendation rather than a happy accident: **stay on the default bundle.** If
your app must customise the frontend, commit `src/main/bundles/` as Vaadin's own guidance says, so the
compiled bundle travels in the repo instead of being rebuilt here every five minutes.

**If you ever do need a real frontend build on the box, expect it to be slow — the fix is a v2 topic.**
`vaadin-maven-plugin` downloads its own Node into `~/.vaadin` and installs `node_modules` into the
source checkout, and both are discarded after every build, because during the Maven build `$HOME` *is*
that checkout. The two lines below are the candidate fix. They are **unverified — never run on a real
box** — and are tracked in `ideas/vaadin-build-under-herokuish.md`:

```dotenv
# .env — build-time only; not your runtime config. UNVERIFIED; see above.
npm_config_cache=/cache/npm
MAVEN_CUSTOM_OPTS=-DskipTests -Pproduction -Duser.home=/cache/home
```

- `npm_config_cache` keeps npm's downloads across rebuilds. It does not stop `npm install` running,
  only its trips to the network.
- `-Duser.home=/cache/home` moves `~/.vaadin` — where Vaadin installs its own Node — into the cache
  volume, so that download happens once rather than every build. Vaadin has no setting for *where* that
  directory lives, so relocating `user.home` is the only lever. Drop it if your build doesn't like a
  relocated home.
- `-Pproduction` is Vaadin's production profile; keep `-DskipTests`, which is the buildpack default
  you are replacing.
- **`/cache` exists only on this box**, which is the argument against carrying these lines in a repo at
  all. Nothing on your own machine reads `.env` — not Maven, not npm — so they are inert locally; but
  `dokku config:set` from the box side does the same job without putting a platform path in your source,
  and is the likelier home for them.

Prefer `.env` to `.npmrc` for the npm cache: recent pnpm no longer expands `${VAR}` in a
repository-controlled `.npmrc`, and Vaadin's own recommended `.gitignore` excludes that file anyway.
`dokku config:set` sets the same variables from the box side and wins over `.env`.

**Pay attention to the memory limit** the container will run under (256 MB on the reference box). If
the JVM asks for more it is hard-killed by the Linux OOM killer with no warning and no log message
(only the host's `dmesg` records it). Run Java with `-Xmx` a little below the limit, so the app dies
with an `OutOfMemoryError` that shows up in the logs instead.

**Listen on `$PORT`, not on a port of your choosing.** The buildpack sets it (5000), and Dokku wires
the proxy to it automatically — so the `EXPOSE`/`ports:set` dance the predecessors needed does not
arise. Details in [RESEARCH.md](RESEARCH.md#ports--the-expose-trap).
