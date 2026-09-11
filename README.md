# Shepherd2 (Dokku)

> **DESIGN PHASE — there is nothing to install yet.**
>
> This repo currently holds documentation only. The v1 design is settled and written up in
> [SOLUTION.md](SOLUTION.md) — what gets installed, what the CLI is, and how a build flows through the
> box. Code follows that file.

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
* Administration is Dokku's own CLI, from an SSH session on the box — see *Day-to-day operations*
  below. There is no web UI and no JVM anywhere.

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
| see the whole box at once — what is installed, and how a build flows through it | [SOLUTION.md](SOLUTION.md) |
| know what **Dokku** does — a command, a flag, a plugin, a gap | [RESEARCH.md](RESEARCH.md) |
| know *why* it's built this way, and what was rejected | [DECISIONS.md](DECISIONS.md) (`D_` entries) |
| see what's still being figured out | [`ideas/`](ideas/) — `ls` is the index |
| do something to a running project — logs, a restart, a config change, a forced rebuild | *Day-to-day operations*, below |
| change things without breaking something remote | [CLAUDE.md](CLAUDE.md) |
| know whether some *other* PaaS should have been picked | [`COMPARISON.md` in shepherd-traefik](https://github.com/mvysny/shepherd-traefik/blob/main/COMPARISON.md) |

## Minimum requirements

Provisional — inherited from shepherd-traefik and Dokku's own documented minimums, not yet checked on a
real box.

* A VM with 8–16 GB of RAM; x86-64 or arm64. Ideally with a public IPv4 address.
  * Dokku's own documented minimum is 1 GB, but that is for Dokku, not for building JVM apps on the box.
* **Ubuntu 24.04 LTS.** That is what the box and the development VM both run, and the only thing this
  is tested on ([`D_host_os`](DECISIONS.md)). Dokku also supports 22.04 and Debian 11+, which would
  probably work and are not tested here.
  * **Not 26.04, yet.** Dokku's installer refuses to run on it, and no `dokku` package is built for
    it — see [`D_host_os`](DECISIONS.md) for what has to change upstream first. Do not work around it.
* A DNS domain with the IPv4 "A" record pointing at the VM. **Two records** are needed, `@` and `*`, so
  that wildcard subdomains work.
* **API access to that domain's DNS**, at a provider [lego](https://go-acme.github.io/lego/dns/) supports.
  The one wildcard certificate is issued over the DNS-01 challenge, so the box holds an API token that
  can edit the zone (root-only). GoDaddy is what the reference box uses; note that GoDaddy restricts its
  DNS API to accounts with 10+ domains or a Discount Domain Club plan.
  * **Both DNS points apply only to an https box.** A box installed in **http mode** needs no zone, no
    `*` record and no API token — see *Installation*. That mode exists for a test VM, where resolution
    comes from `/etc/hosts` on whatever machine browses it.
* **Docker comes from Ubuntu** — `docker.io`, `docker-buildx`, `docker-compose-v2`, installed by
  `shepherd2-install` ([`D_install_apt`](DECISIONS.md)). 24.04 carries 29.1.3, well above the 19.03
  Dokku asks for. No BuildKit requirement applies here: nothing on this box runs `docker build` at all
  (see [`D_builder`](DECISIONS.md) — the build cache is a per-app Docker volume, not a BuildKit cache).
* **Ruby**, from the distro archive — the `shepherd2` CLI is a Ruby script using nothing but the
  standard library. The installer runs `apt install ruby`; there is no gem to install and no version
  manager. See [`D_ruby`](DECISIONS.md).
* **A listening `sshd`**, for everything remote: your own session, `git push dokku@box`, and
  `ssh dokku@box dokku …`. Any VPS has one; a local VM may not, and the key the install authorises then
  authorises nothing. `shepherd2-install` warns if port 22 is silent rather than failing — the box
  still builds and serves apps, it just cannot be administered except from the console.
* **`python3`**, which Ubuntu has already. Both installers use it for one job: editing
  `/etc/docker/daemon.json` around keys they do not own, since Dokku's package writes that file too.
  `shepherd2-install` stops with the stanza to add by hand if it is missing.

## Installation

One script, run as root from a checkout of this repository on a vanilla Ubuntu 24.04 box.
**No box has been installed from it yet** — it is written but unproven, and the punch list in
[RESEARCH.md](RESEARCH.md) is what proving it means.

```bash
# A real box: one wildcard certificate for *.mydomain.me, issued over DNS-01.
export GODADDY_API_KEY=... GODADDY_API_SECRET=...     # never as arguments: argv is world-readable
sudo -E ./shepherd2-install --mode https --domain mydomain.me \
     --email you@example.com --ssh-key ~/.ssh/id_ed25519.pub

# A throwaway test VM: no certificate, no DNS zone, no token. Apps are served over plain http.
sudo ./shepherd2-install --mode http --domain mydomain.me --ssh-key ~/.ssh/id_ed25519.pub
```

Add `--acme-server https://acme-staging-v02.api.letsencrypt.org/directory` while testing an https
install: Let's Encrypt caps duplicate certificates at five a week. The value is recorded in the
renewal cron line too, so issuance and renewal always talk to the same ACME server.

**The mode is chosen once and is not switchable on a running box** — HSTS makes the downgrade
unrepairable from here ([`D_cert`](DECISIONS.md)). To change it, reinstall.

Every step is guarded, so the script is safe to re-run: that is how a failed install is fixed —
correct the script and run it again, rather than repairing the box by hand.
`shepherd2-install --help` is the authority on its arguments; [SOLUTION.md](SOLUTION.md) lists the
steps in order.

To undo it, `sudo ./shepherd2-uninstall` — which **destroys every hosted project** and asks for the
box's hostname before it does. It removes what the install added, in reverse, including Docker and the
address-pool change — of `/etc/docker/daemon.json` it deletes the `default-address-pools` key and
leaves everything else in the file alone, `live-restore` included. `--keep-docker` and `--keep-pools`
opt out of those two steps. It leaves `ruby`, and reports rather than deletes the two directories
`apt purge` leaves behind — `/home/dokku` (the app repositories) and `/var/lib/dokku` (plugin data and
build records).

**Dokku is installed as its authors' deb package, with apt** — no `curl | bash`, and Dokku's own
`bootstrap.sh` is never run ([`D_install_apt`](DECISIONS.md)). That script is itself only a wrapper
that adds packagecloud's apt repository and installs the same package, so this costs nothing and gains
a readable install: the version is pinned once, as the apt version, and held with `apt-mark hold`.
**Upgrading Dokku is therefore deliberate**, and is four commands rather than an `apt upgrade`:

```bash
sudo apt-mark unhold dokku
sudo apt-get install dokku=0.38.NN        # the new pinned version
sudo dokku plugin:install-dependencies --core
sudo apt-mark hold dokku
```

Five more things are already settled and are here so they are not forgotten, because each is awkward or
impossible to retrofit:

* **Installing Dokku empties `/etc/nginx/sites-enabled`.** If that box was ever an nginx host, move
  anything you care about out of the way first. This is Dokku's behaviour, not ours.

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

* **Docker's address pools are enlarged before anything is deployed, and that is why.** Each project
  gets its own Docker network (`D_isolation` in [DECISIONS.md](DECISIONS.md)), and a stock daemon runs
  out of them at **29 apps** — measured, and the 30th `network:create` fails outright. The install
  merges a wider `default-address-pools` into `/etc/docker/daemon.json` and restarts the daemon, the
  same edit shepherd-traefik needs. Nothing for you to do; it is here because it cannot be applied
  later without restarting Docker, so a box that skipped it would have to be rebuilt rather than
  fixed.
* **Leave the proxy alone.** Dokku's default nginx is the proxy (`D_proxy`); do not install the Traefik
  plugin. Per-app tuning is `dokku nginx:set PROJECTID …`.
* **In https mode, one wildcard certificate for every app** (`D_cert`). `lego` from the Ubuntu repos
  issues `*.mydomain.me` over DNS-01, a daily root cron line renews it, and its renew hook runs
  `dokku global-cert:set`, which pushes the new certificate into every app. New apps pick it up at
  creation. Nothing is done per app; do not install `dokku-letsencrypt`. In http mode none of this is
  installed, and there is nothing to run instead.

## Adding your project

Unproven — no project has been onboarded onto a Shepherd2 box yet — but the contract is settled.
**It has changed from both predecessors** — see
[`D_builder`](DECISIONS.md). A project is no longer expected to carry a `Dockerfile`; if it has one it
is ignored, because the box builds every app with Heroku buildpacks so that each project's dependency
cache is isolated from every other's.

### What the repo needs

1. **A publicly cloneable git URL.** The box holds no git credentials in v1, so it must be able to
   `git clone` the repo anonymously; private repos are a v2 feature.
2. A `Procfile` at the root, naming the `web` process.
3. For any JVM project, a `system.properties` pinning `java.runtime.version` — without one you get
   whatever the newest LTS JDK is, currently 25. The Maven buildpack then runs
   `mvn clean dependency:list install -DskipTests`, the Gradle one `./gradlew stage`, unless
   `MAVEN_CUSTOM_GOALS` / `MAVEN_CUSTOM_OPTS` / `GRADLE_TASK` say otherwise — and a **Vaadin** project
   has to say otherwise either way, or it is built in development mode (*Vaadin under herokuish*,
   below).
4. **The buildpack, named — one way or the other** (next section). Don't rely on auto-detection: a
   Java project that commits a `package.json`, which Vaadin tells you to do, is detected as a *Node*
   app, because `nodejs` is tried before `java`.
5. Optionally a `.env`, for build-time settings the project wants to carry itself — see *The `.env`
   recipe* below.

**Then check your work without leaving your machine.** The builder is an ordinary Docker image, so
the box's exact build — and the app it produces — can be run locally before anyone registers your
project. That is *Rehearse the build locally*, at the end of this section, and it is the fastest way
through everything in between.

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

Pin a buildpack to a commit — `https://github.com/someone/their-buildpack#a1b2c3d` — or it is
re-cloned at whatever that branch points to on the day, and the same commit of your app stops
building the same way twice. **This applies to the Heroku buildpacks too.** They ship pinned inside
the builder image, but that pin is what auto-*detection* uses; the moment one is *named* — in
`.buildpacks`, in `app.json` or at registration — it is git-cloned from its default branch instead,
and the bundled copy is ignored. If that matters more than the convenience of the shorthand, name it
in full and pin it: `https://github.com/heroku/heroku-buildpack-gradle.git#v49`. The `heroku/gradle`
shorthand cannot carry a ref — Dokku rejects `heroku/gradle#v49` as invalid.

### Coming from a Dockerfile: the swap, line by line

If your project was hosted on either predecessor it carries a `Dockerfile`, and that file is the thing
this box no longer reads ([`D_builder`](DECISIONS.md)). Leave it in the repo if you build locally with
it — the box simply ignores it — and add the herokuish equivalents beside it:

| What the `Dockerfile` did | What replaces it here |
|---|---|
| `FROM openjdk:21-…` — picked the JDK | `system.properties` in the repo root: `java.runtime.version=21` |
| `RUN ./mvnw … -Pproduction` — ran the build | the buildpack's own goals, adjusted with `MAVEN_CUSTOM_OPTS` (next section — **Vaadin apps must adjust them**) |
| `CMD java -jar …` — named the process | `Procfile` in the repo root: `web: java -Xmx200m -jar target/your-app.jar` |
| `EXPOSE 8080` | nothing. Listen on `$PORT` — see the end of this section |
| `ARG offlinekey` / `ENV VAADIN_OFFLINE_KEY=…` | a config var the operator sets; build args are gone with the Dockerfile |
| `RUN --mount=type=cache,target=/root/.m2 …` | nothing. The buildpack already keeps `.m2/repository` in this app's own `/cache` volume |

The `Procfile` line is per project — whatever your build actually produces, whether that is a jar, an
appassembler `bin/run` script or an exploded directory. Three things about it that bite:

- **`web` is the process type the proxy routes to.** Name it anything else and the app deploys and is
  unreachable.
- **The line is not a shell command line.** `$PORT` is expanded, and then the words are `exec`'d
  directly — there is no shell, so a leading `VAR=value` fails at startup with
  `unable to run VAR=value: file does not exist`, and pipes, `&&` and redirects have nobody to run
  them. When a process needs a variable, put `env` in front of it:
  `web: env SERVER_PORT=$PORT ./bin/myapp`.
- **Keep `-Xmx` under the memory limit** (256 MB by default), for the reason at the end of this section.

### Vaadin under herokuish

Everything above applies to any JVM app. These four are specific to Vaadin, and the first one is not
optional.

**1. The production build is not what you get by default.** The Java buildpack runs
`mvn clean dependency:list install -DskipTests` — which does *not* activate Vaadin's `production`
profile. Without it your app is built in development mode and tries to start a Vite dev server at
runtime, on a box with no Node and no network to fetch one. So every Vaadin Maven project needs:

```dotenv
# .env in the repo root — MAVEN_CUSTOM_OPTS *replaces* the default opts, so keep -DskipTests
MAVEN_CUSTOM_OPTS=-DskipTests -Pproduction
```

…or the same thing from the box side, which wins over `.env` and keeps a platform detail out of your
repository:

```bash
dokku config:set myproject MAVEN_CUSTOM_OPTS='-DskipTests -Pproduction'
```

**2. Do this if your app builds Vite.** It only does when it has to: an app with no custom JS/TS and no
frontend-customising add-ons uses Vaadin's **pre-compiled production bundle** (24.1+) and skips npm and
Vite entirely. That is the recommended state — **stay on the default bundle** — because on this box the
frontend build is slow and stays slow: `vaadin-maven-plugin` downloads its own Node into `~/.vaadin`
and installs `node_modules` into the source checkout, and both are thrown away after every build, since
`$HOME` *is* that checkout during the Maven build. If your app genuinely must customise the frontend:

- **commit `src/main/bundles/`**, as Vaadin's own guidance says, so the compiled bundle travels in the
  repo instead of being rebuilt here every time the poll finds a commit;
- if you cannot, expect the full npm + Vite cost on every build, and read *The `.env` recipe* below for
  the two unverified lines that might cut it down.

**3. Do this if you need `VAADIN_OFFLINE_KEY`** — i.e. your app uses Pro or Prime components. The
licence has to be present **at build time**, and on the predecessors that meant a Docker build arg,
which no longer exists. Here it is a config var, which the builder bundles into the build environment:

```bash
# the *server* licence key from vaadin.com/myaccount/licenses — not the offline development key
dokku config:set --no-restart myproject VAADIN_OFFLINE_KEY='the-key'
```

- **Set it before the first build**, or that build fails and you retry with `shepherd2 rebuild`.
- **Never put it in `.env`.** That file is committed to your repository; a licence key is a secret, and
  `dokku config:set` is what keeps it on the box. (Ask the operator to set it: config vars are theirs.)
- It reaches the build because the herokuish builder bundles every app config var into an `ENV_DIR`
  before the buildpack runs — see [RESEARCH.md](RESEARCH.md#config-env-vars-and-app-metadata). That is
  read from Dokku's source, not yet confirmed on a running box.

**4. Gradle projects need four things, and none of the defaults will do.** The Gradle buildpack runs
exactly one command — `./gradlew $GRADLE_TASK` — and with `GRADLE_TASK` unset it looks for a `stage`
task, guesses a task for Spring Boot / Micronaut / Quarkus / Ratpack, and otherwise falls back to
`stage` anyway. A Vaadin Boot app is none of those, so it fails with *Task 'stage' not found* until
you say what to run. The four things below were worked out by rehearsing a Vaadin Boot + Karibu-DSL
app against the same builder image the box uses — do the same with yours (*Rehearse the build
locally*, below) before you ask for it to be registered.

- **`gradlew` must be committed** — the buildpack no longer supplies a wrapper and stops if yours is
  missing.
- **`GRADLE_TASK`, in a committed `.env`** — it belongs in the repo, since every app needs it and
  nothing about it is secret or box-specific:
  ```dotenv
  GRADLE_TASK=clean installDist -Pvaadin.productionMode
  ```
  The value is word-split and handed to `./gradlew` verbatim, so flags belong in it, and
  `-Pvaadin.productionMode` is Vaadin's production switch for Gradle — there is no Maven profile to
  activate. Use **`installDist`**, not `build`: it is the `application` plugin's "unpack the
  distribution" task, and it leaves a runnable `build/install/<name>/bin/<name>` for the `Procfile` to
  name, where `build` leaves only a `.tar` that nothing here untars. It also skips your test suite,
  which you do not want standing between a commit and a deploy. `dokku config:set` overrides `.env`
  from the box side if an app ever needs it to; defining a `stage` task in `build.gradle.kts` avoids
  the variable altogether.
- **`settings.gradle.kts` naming the root project.** Without one, Gradle names the root project after
  the directory it happens to be building in — and here that directory is `/tmp/build`, so an
  `application`-plugin app installs to `build/install/build/bin/build` and the `Procfile` path you
  worked out on your own machine is simply wrong. `rootProject.name = "myproject"` makes the path the
  same everywhere.
- **`system.properties`.** Left out, the buildpack installs the newest LTS JDK — **currently 25, not
  21** — and says so in the build log.

Gradle's caching here is better than Maven's, and costs you nothing: the buildpack points
`GRADLE_USER_HOME` at the per-app cache volume, so dependencies, the Gradle build cache, the wrapper's
Gradle distribution and the JDK are all warm from the second build on.

### The `.env` recipe

A committed `.env` reaches the **build** environment, so a project can point its own caches at the
per-app cache volume that Dokku mounts at `/cache`. That volume is yours alone and survives between
builds, which is what stops the Maven tree being re-downloaded on every scheduled rebuild.

**As this box actually runs, you need nothing here for *caching*** — not for Maven, and not for
Vaadin. The buildpack already puts `.m2/repository` in the cache volume, and an app on Vaadin's
pre-compiled production bundle runs no frontend build, so there is nothing to cache. (The one `.env`
line a Vaadin app *does* generally need is `MAVEN_CUSTOM_OPTS`, and that is about the production
profile rather than the cache — see *Vaadin under herokuish* above.)

**If you do need a real frontend build on the box, expect it to be slow — the fix is a v2 topic.**
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

**Pay attention to the limits your app runs under** — **256 MB and 1 CPU at runtime, 2 GB and 2 CPU
during the build**, unless the operator gave your app something else. If the JVM asks for more memory
than the runtime limit it is hard-killed by the Linux OOM killer with no warning and no log message
(only the host's `dmesg` records it). Run Java with `-Xmx` a little below the limit, so the app dies
with an `OutOfMemoryError` that shows up in the logs instead.

**Listen on `$PORT`, not on a port of your choosing.** The buildpack sets it (5000), and Dokku wires
the proxy to it automatically — so the `EXPOSE`/`ports:set` dance the predecessors needed does not
arise. Details in [RESEARCH.md](RESEARCH.md#ports--the-expose-trap).

### Rehearse the build locally

**Do this before you ask for your project to be registered.** The builder is a plain Docker image —
`gliderlabs/herokuish:latest-24`, the one Dokku pins — so the box's build, and the app it produces,
both run on your own machine with no box and no operator involved. Every mistake in the sections
above is an order of magnitude cheaper to find here than in a deploy log. All you need is Docker.

**Rehearse in your own checkout, not in a copy of it.** What you are tuning — the `Procfile`, the
`.env`, the `Procfile` path that depends on your project's name — are files you are going to commit,
so get them right where you will commit them from.

**1. Write the settings into the repository.** Put everything the build needs in the repo and
registration needs nothing but the buildpack name: no config vars for the operator to remember, and
the same repo builds the same way on the next box. For a Vaadin Boot + Gradle app that is four files,
written in your editor like any other:

```
.env                  GRADLE_TASK=clean installDist -Pvaadin.productionMode
system.properties     java.runtime.version=21
settings.gradle.kts   rootProject.name = "my-app"
Procfile              web: env SERVER_PORT=$PORT JAVA_OPTS=-Xmx200m build/install/my-app/bin/my-app
```

Secrets stay out — `.env` is committed. A licence key like `VAADIN_OFFLINE_KEY` is a config var the
operator sets (*Vaadin under herokuish*, above).

**2. Clean.** Your `build/` or `target/` is copied into the builder along with everything else, so
clear it and the builder starts where a fresh clone would:

```bash
./gradlew clean          # or: mvn clean
```

**3. Build.** `/build` is the image's own entrypoint for this, and it is what the box runs:

```bash
docker run --name rehearsal -v "$PWD:/tmp/app:ro" \
  -v rehearsal-cache:/cache -e CACHE_PATH=/cache \
  gliderlabs/herokuish:latest-24 /build
```

- **`:ro` — your checkout is never written to.** It is copied to `/app`, built in `/tmp/build`, and
  it is that build directory which becomes the app image. `/tmp/build` is also why the *directory
  name* your build tool sees is `build` rather than your project's, which is what the
  `settings.gradle.kts` above is for.
- `/cache` with `CACHE_PATH=/cache` is the per-app cache volume, mounted just as the box mounts
  `cache-<app>`. Keep the volume between runs and your second build is warm exactly as a scheduled
  rebuild is; `docker volume rm rehearsal-cache` is your `shepherd2 clearcache`.
- Leave `--rm` off. The finished container *is* the built app, and step 4 needs it.
- **The one thing the box does that this does not is expand the `heroku/…` shorthand** — Dokku
  rewrites it before the builder ever sees it, and herokuish on its own rejects it. So here, either
  let detection choose (which is what a repo with no root `package.json` gets anyway) or pass the URL
  in full: `-e BUILDPACK_URL=https://github.com/heroku/heroku-buildpack-gradle.git`.
- To stand in for a config var the operator will set, mount an env directory — one file per variable,
  named for it, containing the value: `-v /tmp/rehearse-env:/tmp/env`, and not read-only, because the
  builder chowns it.

**4. Run what you just built**, under the box's runtime memory limit, with the same `Procfile`:

```bash
docker commit rehearsal rehearsal-slug
docker run -d --name rehearsal-run --memory 256m -e PORT=5000 -p 5000:5000 \
  rehearsal-slug /start web
docker logs -f rehearsal-run          # until it says it is listening; Ctrl-C to stop following
curl -fsS -o /dev/null -w '%{http_code}\n' http://localhost:5000/
```

`/start web` is the runtime entrypoint the box uses, so this exercises your `Procfile` line, your
`$PORT` handling and your `-Xmx` against the real limit. Watch `docker stats rehearsal-run` while you
click around: if the app sits near 256 MB idle, ask the operator for more memory *before* the OOM
killer finds it in production.

**What to check in the output, in order:**

| The log says | Check that |
|---|---|
| `-----> <X> app detected` | `X` is the language you meant. If it says Node and you meant Java, name the buildpack |
| `Installing … OpenJDK <N>` | `N` is your JDK. With no `system.properties` this is the newest LTS, currently 25 |
| the build command it echoes | the goals and flags are yours, production profile included |
| `Procfile declares types -> web` | it says `web`. `No process types found` means the app will never start |
| the container answers `200` | …and the log shows production mode, not a dev-mode server looking for Vite |

**5. Commit what made it work — and check that you did.** This rehearses your *working tree*; the box
builds your *commit*, checked out with only its tracked files in it. So an uncommitted `Procfile`
passes here and fails there, and an untracked scratch file that the build quietly depends on does the
same. `git status` before you hand the URL over. Then registration is one command with nothing else
to arrange:

```bash
shepherd2 create-app my-app https://github.com/me/my-app --buildpack heroku/gradle
```

**What this cannot tell you:** anything above the app — your domain, the certificate, the poll, the
build's CPU cap. Those are the operator's side, and none of them depend on your repository.

## Day-to-day operations

**Shepherd2 wraps nothing Dokku already has** ([`D_dokku_is_truth`](DECISIONS.md)), so almost everything
below is plain `dokku`; the six `shepherd2` verbs exist only where Dokku has no single command. Run them
logged in on the box as an admin user — `dokku …` and `shepherd2 …` then come from one shell. Dokku's
sanctioned remote form, `ssh dokku@host <command>`, reaches only `dokku`, never `shepherd2`; in v1
there is one keyholder, who can do everything to every app ([`D_single_operator`](DECISIONS.md)).

Nothing here needs a project file, because there isn't one: every fact about an app is Dokku's, and
`dokku <plugin>:report <app> --format json` is how you read it.

| To… | Run |
|---|---|
| **register a project** | `shepherd2 create-app ID URL [REF] --owner you@example.com --buildpack heroku/java` |
| **delete one**, network and all | `shepherd2 destroy-app ID` |
| force a rebuild — retry a failed build, or rebuild an unchanged ref | `shepherd2 rebuild ID` |
| **did the last build work?** · and its log | `shepherd2 last-build ID` · `shepherd2 last-build ID --log` |
| **which projects are red?** | `shepherd2 last-build` |
| make sure a reboot won't land mid-build | `shepherd2 wait-idle` |
| prune images now rather than on Sunday | `shepherd2 clearcache` |
| list projects · read everything about one | `dokku apps:list` · `dokku apps:report ID` |
| **see the runtime log** | `dokku logs ID -t -p web` |
| see why the last deploy failed | `dokku logs:failed ID` |
| **list past builds** (newest first, 300 kept — mostly poll ticks, see below) | `dokku builds:list ID [--format json]` |
| read one build's log | `dokku builds:output ID <build-id>` |
| watch the build that is running | `dokku builds:output ID current` |
| stop a build that is running | `dokku builds:cancel ID` |
| **restart** · stop · start | `dokku ps:restart ID` · `dokku ps:stop ID` · `dokku ps:start ID` |
| set a runtime env var · read them all | `dokku config:set ID KEY=VALUE` · `dokku config:show ID` |
| change a **build-time** setting | `dokku config:set ID KEY=VALUE`, then `shepherd2 rebuild ID` |
| change the runtime memory or CPU cap | `dokku resource:limit --memory 512m --cpu 1 ID` |
| change the build memory cap | `dokku resource:limit --process-type build --memory 3g ID` |
| see what limits an app has | `dokku resource:report ID` |
| throw away one project's build cache | `dokku repo:purge-cache ID` |
| add another hostname (http only — see below) | `dokku domains:add ID host.example.com` |
| allow a bigger upload · a slower endpoint | `dokku nginx:set ID client-max-body-size 20m` · `dokku nginx:set ID proxy-read-timeout 300s` |
| check the generated vhost | `dokku nginx:show-config ID`, `dokku nginx:validate-config` |
| see CPU and memory per container | `docker stats`, or `lazydocker` / `ctop` |
| see what the box has been doing | `dokku events -t` |

Nine things that bite, all of them documented at length in [RESEARCH.md](RESEARCH.md):

- **Most build records are poll ticks, so don't ask Dokku which build was the last one — ask
  `shepherd2 last-build`.** Every five-minute poll writes a record even when there is nothing to build,
  and once a later deploy reaps them those land on disk as `failed` with `exit_code: -1`. Two
  consequences: `dokku builds:report ID` names the *newest* record, so it calls a perfectly healthy
  app's build status `abandoned`, and `dokku builds:list ID --status failed` selects reaped ticks
  alongside real failures. `shepherd2 last-build ID` skips both traps — newest record that really
  built, or the one building right now — and `--log` prints its log:

  ```
  $ shepherd2 last-build hello
  hello: failed (exit 1) · id mtwslbpulbzlek · started 2026-09-11T10:05:30Z · duration 1m43s
    log: /var/lib/dokku/data/builds/hello/mtwslbpulbzlek.log
    read it: shepherd2 last-build hello --log
  ```

  With no project id it does every registered project, one line each, which is the *which of these is
  red* view. In `dokku` alone the same filter is `exit_code != -1`, and it needs `jq`:

  ```bash
  dokku builds:output ID "$(dokku builds:list ID --status failed --format json \
      | jq -r '[.[] | select(.exit_code != -1)][0].id')"
  ```

- **A build log is deleted by the next deploy, not by the passage of time.** Polling deletes nothing —
  records pile up on disk — but a real deploy prunes the app to its newest 300 records, and since every
  poll tick is newer than the last build, that is what removes the *previous* build's log. So a failed
  build stays readable until something deploys, which under the poll means until someone commits. What
  the count of 300 really bounds is what `dokku builds:list ID` will *show* you — about 25 hours of
  ticks. `shepherd2 last-build` is unaffected by that cut (it filters the listing, which Dokku never
  caps), so use it rather than scrolling. `dokku builds:set ID retention 600` gives one project more
  room; `dokku logs:failed ID` (the container's own output, not the build's) is the last resort.

- **`dokku builds:output ID` with no build id does not mean "the last build".** It resolves one from the
  app's deploy lock, so on an idle app it prints `App not currently deploying` rather than the failure
  you came for. `dokku builds:output ID current` is the right way to watch a build that is *running*.
- **A build record carries no git SHA.** Which commit is live is
  `dokku apps:report ID --app-deploy-source-metadata`, which reads `<url>#<sha>` after a *successful*
  deploy — and doubles as a drift check, since a URL that isn't the app's `SHEPHERD_GIT_URL` is worth
  noticing. After a *failed* one, `dokku config:get ID GIT_REV` is the commit it tried.
- **`config:set` restarts the app.** Add `--no-restart` when you are about to `shepherd2 rebuild`
  anyway. A buildpack app gets its config vars at build time as well as at run time, which is why a
  build-time setting is a config var here and not a build arg.
- **The poll won't pick up a config change on its own.** `git:sync --build-if-changes` builds only when
  the ref moved, so after changing anything that affects the build you must `shepherd2 rebuild ID`.
- **A second hostname gets no https in v1.** The one wildcard certificate covers `*.<domain>` and
  nothing else; custom and apex domains are a v2 feature ([`D_cert`](DECISIONS.md)). Don't reach for
  `dokku-letsencrypt` to patch one app.
- **Destroy a project with `shepherd2 destroy-app`, not `dokku apps:destroy`.** Dokku deletes the
  app's vhost file but never tells the running nginx, which keeps serving that hostname from memory and
  proxying to a container that is gone — so requests to it **hang for 60 seconds each** instead of
  being refused, until some unrelated deploy reloads nginx. Nothing you can inspect shows why: the
  config is off the disk, `nginx -T` has no trace of the app, and the hostname misbehaves anyway.
  `shepherd2 destroy-app` ends with `dokku nginx:reload` for exactly this reason. If you have already
  destroyed an app the raw way, `sudo dokku nginx:reload` fixes it — allow it a second to take effect,
  because that command returns before the new config is live.

- **Never prune volumes.** Not `docker volume prune`, not `docker system prune --volumes`: the build
  cache *is* the per-app `cache-ID` volume, nothing garbage-collects it, and at a five-minute poll a
  build is always about to want it ([`D_builder`](DECISIONS.md)). `repo:purge-cache` is the per-app
  lever, and `shepherd2 clearcache` is the safe blanket one.

**Prefer a `dokku` command to a `docker` one** — `dokku ps:restart` over `docker restart`, the reports
over `docker inspect`. Reaching around Dokku to the daemon is how its state drifts out from under it.
`docker stats` is the exception that matters: Dokku does not do monitoring, by design, and apps are
plain containers.
