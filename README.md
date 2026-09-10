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
address-pool change; `--keep-docker` and `--keep-pools` opt out of those two. It leaves `ruby` and
reports `/home/dokku` rather than deleting it.

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

**Pay attention to the memory limit** the container will run under — **256 MB** unless the operator
gave your app more. If
the JVM asks for more it is hard-killed by the Linux OOM killer with no warning and no log message
(only the host's `dmesg` records it). Run Java with `-Xmx` a little below the limit, so the app dies
with an `OutOfMemoryError` that shows up in the logs instead.

**Listen on `$PORT`, not on a port of your choosing.** The buildpack sets it (5000), and Dokku wires
the proxy to it automatically — so the `EXPOSE`/`ports:set` dance the predecessors needed does not
arise. Details in [RESEARCH.md](RESEARCH.md#ports--the-expose-trap).

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
| make sure a reboot won't land mid-build | `shepherd2 wait-idle` |
| prune images now rather than on Sunday | `shepherd2 clearcache` |
| list projects · read everything about one | `dokku apps:list` · `dokku apps:report ID` |
| **see the runtime log** | `dokku logs ID -t -p web` |
| see why the last deploy failed | `dokku logs:failed ID` |
| **list past builds** (newest first, 20 kept — mostly poll ticks, see below) | `dokku builds:list ID [--format json]` |
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

Seven things that bite, all of them documented at length in [RESEARCH.md](RESEARCH.md):

- **`dokku builds:output ID` with no build id does not mean "the last build".** It resolves one from the
  app's deploy lock, so on an idle app it prints `App not currently deploying` rather than the failure
  you came for. The last *really* failed build's log is two steps — and the `exit_code` filter is not
  optional, for the reason in the next bullet:

  ```bash
  dokku builds:output ID "$(dokku builds:list ID --status failed --format json \
      | jq -r '[.[] | select(.exit_code != -1)][0].id')"
  ```

- **Most build records are poll ticks, and a build log survives about 95 minutes.** Every five-minute
  poll writes a record even when there is nothing to build, and those records land on disk as `failed`
  with `exit_code: -1` — so `builds:list` is mostly noise, and once 19 further ticks have gone by the
  real build's record *and* its log are pruned away. Read a failed build's log the same day it failed;
  after that `dokku logs:failed ID` (the container's own output) is what is left. Raising
  `dokku builds:set ID retention 200` buys hours rather than fixing it.
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
- **Never prune volumes.** Not `docker volume prune`, not `docker system prune --volumes`: the build
  cache *is* the per-app `cache-ID` volume, nothing garbage-collects it, and at a five-minute poll a
  build is always about to want it ([`D_builder`](DECISIONS.md)). `repo:purge-cache` is the per-app
  lever, and `shepherd2 clearcache` is the safe blanket one.

**Prefer a `dokku` command to a `docker` one** — `dokku ps:restart` over `docker restart`, the reports
over `docker inspect`. Reaching around Dokku to the daemon is how its state drifts out from under it.
`docker stats` is the exception that matters: Dokku does not do monitoring, by design, and apps are
plain containers.
