# SOLUTION.md — the v1 box, assembled

> **This box has been assembled once, in `http` mode, on a throwaway VM (2026-09-11).** Every piece
> below is written — both installers and the CLI — and the install, four real apps, a poll tick, a
> teardown and an uninstall all ran. Everything here is decided (each claim names the `D_` entry that
> decided it); what remains `[unverified]` is Dokku behaviour that run did not reach, and each such
> claim points at `RESEARCH.md` → *Questions only a box can answer*.
>
> **The `https` steps are the notable gap** — step 8 below has never executed. See *What is not yet
> proven on a box*, at the end.

**What this file owns:** the *assembly* — what ends up on the box, and how the pieces move together
end to end. Those flows cross four or five decisions each and are therefore inside none of them.

**What it does not own, and must never restate:** *why* a piece was chosen (`DECISIONS.md`), *what
Dokku does* (`RESEARCH.md`), *how to operate the box* (`README.md`), or a script's arguments and env
knobs (that script's comment header, once it exists). Where a one-line fact saves a jump it is
repeated here; the argument behind it never is. There is no feature list anywhere and no `F_` namespace
(`D_no_feature_list`): what the box *does* is this file plus `README.md`'s cheat sheet, and what it
deliberately does not do is *What v1 does not do*, at the end.

---

## The box after `install`

| Piece | What it is | Decided by |
|---|---|---|
| **Ubuntu 24.04 LTS** | the host OS, on the box and on the development VM. Not 26.04 — Dokku's installer refuses it and no `dokku` package is built for it | `D_host_os` |
| **Dokku v0.38.27** | the PaaS: build, run, route, app state. Installed as upstream's deb from packagecloud, pinned by apt version and `apt-mark hold`. Never below v0.38.2 | `D_dokku`, `D_install_apt` |
| **Docker** | Ubuntu's `docker.io` + `docker-buildx` + `docker-compose-v2`, installed before Dokku. `/etc/docker/daemon.json` gets enlarged `default-address-pools` | `D_install_apt`, `D_isolation` |
| **nginx, on the host** | Dokku's default proxy. Not a container, not Traefik, no plugin | `D_proxy` |
| **herokuish** | the builder. Arrives with Dokku — a `Recommends` of the deb, not a `Depends` | `D_builder` |
| **`dokku-global-cert`** | *https mode only.* The one third-party plugin this box depends on | `D_cert` |
| **lego** (`apt`, universe) | *https mode only.* Issues and renews `*.mydomain.me` over DNS-01; its GoDaddy credentials live in a root-only file | `D_cert` |
| **ruby** (`apt`) | the CLI's runtime. Stdlib only — no gems, no bundler | `D_ruby` |
| **`shepherd2`** | one Ruby dispatcher on `PATH`: `create-app`, `destroy-app`, `poll`, `rebuild`, `wait-idle`, `clearcache` | `D_ruby`, `D_dokku_is_truth` |
| **`shepherd2-install` / `-uninstall`** | Bash, `set -euo pipefail`. The only parts that run before, or after, everything else exists | `D_ruby` |
| **`/etc/cron.d/shepherd2`** | the `*/5` poll and the weekly prune, plus the daily `lego renew` in https mode. One file, written whole, so `uninstall` deletes rather than unpicks | `D_dokku`, `D_cert`, `D_builder` |

And a set of **global Dokku properties**, which is the whole of the box's configuration:

| Property | Value | Why, in one line |
|---|---|---|
| `domains:set-global` | `mydomain.me` | the app name becomes the subdomain, so `PROJECTID.<domain>` is free |
| `builder:set --global selected` | `herokuish` | short-circuits detection, so a committed `Dockerfile` is never read (`D_builder`) |
| `ps:set --global restart-policy` | `always` | survive a crash and a reboot; Dokku's default is `on-failure:10` |
| `config:set --global SHEPHERD_TLS_MODE` | `https` or `http` | the install mode, recorded where `uninstall` can find it (`D_cert`) |
| `builds:set --global retention` | `300` | ~a day of poll ticks, so a real build's log outlives the churn that buries it (`D_poll_churn`) |

**What is deliberately absent:** Jenkins, Traefik, `docker-compose.yaml`, any JVM, any web UI, any
directory of ours holding project state, and any Dokku fork or plugin we maintain.

## Two install modes, chosen once

`install` asks once and never asks again; the modes are not switchable on a running box, because HSTS
makes the downgrade unrepairable from here (`D_cert`).

| | `https` | `http` |
|---|---|---|
| certificate | one wildcard `*.mydomain.me` | none |
| installs | lego, DNS credentials, `dokku-global-cert`, the renewal cron | none of it |
| needs | a DNS zone with `@` and `*` records, API access to it, and an email address for the ACME account | nothing; the client's `/etc/hosts` resolves app names |
| for | the real box | a throwaway test VM |

`domains:set-global` is identical in both, and so is everything about building and running apps. The
http mode is defined by *absence*: an app with no certificate is served over port 80 by the same nginx,
with no redirect and no HSTS header — confirmed on a box, along with the fact that `hsts` is *inert*
rather than unset there, which is what makes the choice one-way (`RESEARCH.md` → *nginx*).

## `shepherd2-install`, in order

Bash, root, on Ubuntu 24.04 (`D_host_os`) with nothing else on it. **Dokku is installed from its
authors' deb with apt; `bootstrap.sh` is never run** (`D_install_apt`) — the steps below are what that
script does on this box's one code path, minus the parts that exist for other distros.

1. **Preflight** — refuse anything but a supported OS, and 26.04 with a message naming `D_host_os`
   rather than letting apt fail obscurely. Require that `hostname -f` resolves. Warn that installing
   Dokku empties `/etc/nginx/sites-enabled`. Take the mode (`https` | `http`), the domain, the admin
   SSH key, and in https mode the DNS API credentials. Refuse early rather than half-install.
2. **Docker** — `apt install docker.io docker-buildx docker-compose-v2` from Ubuntu's archive, all
   three by name and before Dokku. By name because `docker-compose` is a real (obsolete, Python v1)
   package in Ubuntu, so apt resolving Dokku's dependency unaided would install *that* instead of the
   v2 package that provides the name (`D_install_apt`).
3. **Prerequisites** — `gpg-agent`, `software-properties-common`, `add-apt-repository universe`. The
   last one is needed twice over: Dokku's own install does it, and lego lives there (`D_cert`).
4. **Dokku** — packagecloud's key into `/usr/share/keyrings/dokku-archive-keyring.asc`, checked against
   a pinned fingerprint and referenced with `signed-by=`; the `deb …/dokku/dokku/ubuntu/ noble main`
   sources line; the five `dokku/*` debconf answers preseeded; then `apt-get install dokku=0.38.27`
   — **with recommends**, since that is how `herokuish` arrives — `dokku plugin:install-dependencies
   --core`, and `apt-mark hold dokku`.
5. **Address pools** — merge enlarged `default-address-pools` into `/etc/docker/daemon.json` with
   `python3` and restart the daemon. Before any app exists, because a stock daemon walls at 29 bridge
   networks and the change cannot be applied without a restart. It is always a merge, never a create:
   step 4 has just installed Dokku, whose postinst wrote that file to set `live-restore`.
6. **Admin key and domain** — `ssh-keys:add admin`, `domains:set-global mydomain.me`.
7. **Globals** — `builder:set --global selected herokuish`, `ps:set --global restart-policy always`.
8. **https mode only** — `apt install lego`; write the DNS credentials to a root-only file;
   `plugin:install …/dokku-global-cert.git global-cert`; the first
   `lego --accept-tos --email … --dns godaddy -d '*.mydomain.me' --path /root/.lego run`;
   `global-cert:set` with the result. **lego's own flags are global and precede the subcommand** —
   only `--days` and `--renew-hook` belong to `renew`.
9. **Ruby and the CLI** — `apt install ruby`, then `shepherd2` onto `PATH`.
10. **Crons** — one `/etc/cron.d/shepherd2` holding the `*/5` poll, the weekly prune, and in https
    mode the daily renewal.
11. **Record the mode** — `config:set --global SHEPHERD_TLS_MODE=…`, written *last*, so it means "this
    mode's steps all succeeded".

`shepherd2-uninstall` is the inverse, and staying symmetric with `install` is its whole contract: it
reads `SHEPHERD_TLS_MODE` to know whether lego, the plugin and the renewal cron are there to remove,
and must not trip over their absence in http mode. It does **not** remove `ruby` — an archive package
other things may share.

It destroys every project on the way, since the install's inverse cannot leave apps on a box with no
Dokku, and it asks for the box's hostname before doing so. Three asymmetries are deliberate: the two
steps that reach past Shepherd2's own layer are opt-out (`--keep-docker`, `--keep-pools`);
`/etc/docker/daemon.json` has only the `default-address-pools` key deleted, the rest of the file
written back, and is removed outright only if that key was all it held; and
Dokku's two state directories — `/home/dokku`, holding the app repositories, and `/var/lib/dokku`,
holding plugin data and the build records — are *reported*, not deleted; `apt purge` leaves both.
Installing Dokku emptied `/etc/nginx/sites-enabled`, and that is not undoable from here.

## The CLI surface

Every verb exists because Dokku has no single command for it. Anything Dokku *does* have a command for
is used as-is and documented in `README.md`'s cheat sheet — **Shepherd2 never wraps a command Dokku
already has** (`D_dokku_is_truth`).

| Verb | What it does |
|---|---|
| `create-app ID URL [REF]` | the guarded registration sequence, below |
| `destroy-app ID` | its exact inverse |
| `poll` | the `*/5` cron: `git:sync --build-if-changes` over every registered app, serially, under a non-blocking lock |
| `rebuild ID` | the forced `git:sync --build` — the retry after a failed build, and the only way to rebuild an unchanged ref |
| `last-build [ID] [--log]` | the last *real* build's status, and its log — the one read the poll's churn breaks (`D_poll_churn`), and the one verb here with an expiry date |
| `wait-idle` | blocks until no build is running, so a reboot never lands mid-build |
| `clearcache` | the weekly prune |
| `stats [--json]` | what the box holds: memory (free *and* committed), disk, and the build cache per project — a snapshot, never monitoring (`D_stats`) |

`create-app`'s flags: `--owner EMAIL`, `--mem`, `--cpu`, `--build-mem`, `--build-cpu`, `--buildpack`,
`--build-dir`. There is no `--domain` (custom domains are v2, and `domains:add` is a `dokku` command),
no `--postgres` (a managed database is v2), and no cache flag of any kind (`D_builder` — the cache is a
volume Dokku names). The limit defaults are the farm's one profile — **`256m` / 1 CPU runtime and
`2g` / 2 CPU build** (operator, 2026-09-10, CPU added 2026-09-11): one build runs at a time box-wide,
so the build figures are a peak rather than a per-app multiplier. All four are always applied; `clear`
as a flag value is Dokku's own way to ask for no limit.

## Flow — registering a project

```
shepherd2 create-app demo https://github.com/me/demo main --owner me@example.com --buildpack heroku/java
```

1. **Validate, before mutating anything.** The id must not match `admin*` (`D_admin_namespace`);
   Dokku's own app-name rules apply underneath.
2. `apps:create demo` — guarded by `apps:exists`.
3. `config:set --no-restart demo SHEPHERD_GIT_URL=… SHEPHERD_OWNER=…` — the only two per-project facts
   Shepherd2 owns, and the URL is written **before** the first build, so a project whose first build
   fails is still in the poll (`D_dokku_is_truth`).
4. `resource:limit --memory … --cpu … demo`, and `resource:limit --process-type build --memory … demo`.
   Build CPU and memory both take effect on the herokuish path — measured, `nanocpus` and `mem` on
   the build container, with a real build peaking at 202 % of a 4-core host.
5. `network:create app-demo` — guarded by `network:exists` — then
   `network:set demo initial-network app-demo` (`D_isolation`).
6. `buildpacks:set demo heroku/java`, if `--buildpack` was given. Otherwise the repo's own
   `.buildpacks` names it; **relying on detection is a bug** — herokuish tries `nodejs` before `java`
   (`D_builder`).
7. `builder:set demo build-dir …`, if `--build-dir` was given.
8. `git:sync --build demo <url> <ref>` — the first build.

**Nothing here touches TLS.** In https mode `dokku-global-cert` imports the wildcard at app creation;
in http mode there is nothing to import (`D_cert`).

**The whole sequence is re-runnable.** A first build that fails is the *normal* case — the
`Procfile` / buildpack / `system.properties` trio usually needs a couple of tries — so steps 1–7 are
guarded and idempotent and step 8 simply runs again. No `destroy-app` first, no half-created app to
unpick.

**Pass the ref explicitly.** Dokku's `deploy-branch` defaults to `master`; `git:sync` with a ref sets it
to that ref, and every later sync can then omit it.

## Flow — a poll tick to a running container

```
*/5 * * * *   shepherd2 poll
```

1. **`flock -n` on `/run/lock/shepherd2-poll.lock`.** Non-blocking: a tick that lands on a running build
   exits quietly rather than queueing, which at 288 ticks a day is the difference between skipping and
   accumulating. The whole poll is inside one lock, so **builds are serial box-wide** — which is the
   other half of the cache story, since concurrent writers are what corrupt one. Whether `rebuild`
   takes the same lock is an implementation choice; if it does not, the backstop is Dokku's own per-app
   deploy lock, which is *non-waiting* — a collision on the same app fails fast and tells the operator
   to retry, it does not queue (`RESEARCH.md` → *`git:sync`*).
2. For each app in `apps:list` that has a `SHEPHERD_GIT_URL`, in turn:
   `dokku git:sync --build-if-changes <app> <url>` — no ref needed, Dokku remembers the deploy branch.
3. **Dokku fetches. If the ref did not move, nothing is built** — so 288 ticks produce a build only on a
   real change, and a failed build is not retried until upstream commits again. `shepherd2 rebuild` is
   the override. *Nothing built is not nothing done:* the tick still writes a build record and a log
   file, which is what step 6 has to be read past.
4. **If it moved:** herokuish builds in a container with the app's own `cache-$APP` volume mounted at
   `/cache`, where the Heroku Java buildpack keeps `maven.repo.local`. Another project's artifacts are
   unreachable by construction — Dokku names the volume and the app has no Dockerfile in which to name
   another, demonstrated by two ids on one repo downloading 924 artifacts from Central each. The second
   build comes back warm: Maven 2m12s → 15s, Gradle 46s → 33s. Build-phase resource limits apply here.
5. **Release:** a new container on the app's own `app-<id>` network with `restart-policy always`, the
   proxy port wired from the buildpack's `$PORT` with nothing in `ports:set` — detected before the
   first deploy and never promoted into set state — nginx's vhost regenerated, the old container
   stopped.
6. **Dokku records it itself** — a build record and a log per deploy, `builds:list` / `builds:output`,
   300 per app, captured whether the deploy came from a push or from `git:sync`. The poll tees nothing
   and writes no log of its own. The record carries no git SHA, but
   `apps:report --app-deploy-source-metadata` holds `<url>#<sha>` after a successful build — which is
   also the free drift check: a last deploy that did not come from the app's `SHEPHERD_GIT_URL` is
   worth noticing. (`config:get <app> GIT_REV` is the other half: the last commit Dokku *started*
   building, so it survives a failure the metadata never records.)

   **The records are mostly poll noise, and two things make them readable anyway** (`D_poll_churn`). A
   no-change tick writes a record too, and reaped ticks land on disk as `failed` with `exit_code: -1`
   (`RESEARCH.md` → *Build tracking*) — so the install raises the window to 300 records, about a day of
   ticks, and `shepherd2 last-build` is the read that skips past them. `dokku builds:report` is *not*:
   it names the newest record, which on an idle app is always an abandoned tick. The same churn reaches
   the reboot flow below, where it decides how `wait-idle` asks whether a build is running.

## Flow — certificate renewal (https mode only)

One daily line in `/etc/cron.d/shepherd2`, and it is not a script (`D_cert`):

```
. /root/.shepherd2-dns-credentials && lego --dns godaddy -d '*.mydomain.me' --path /root/.lego \
     renew --days 30 \
     --renew-hook 'dokku global-cert:set /root/.lego/certificates/_.mydomain.me.crt \
                                          /root/.lego/certificates/_.mydomain.me.key'
```

**Flag order is load-bearing, not style:** `--dns`, `-d` and `--path` are lego's *global* flags and
must precede `renew`, which owns only `--days` and `--renew-hook` (verified against lego's
`cmd/flags.go` and `cmd/cmd_renew.go`, 2026-09-10).

The credentials file holds `GODADDY_API_KEY` / `GODADDY_API_SECRET`, is root-only, and must stay
unreadable to the `dokku` user — it can rewrite the whole zone, which makes it a bigger secret than the
certificate it produces.

lego runs the hook **only when a renewal actually happened**. `global-cert:set` then re-applies the
certificate to every app that uses the global one, leaving any app with its own certificate untouched,
and reloads nginx `[unverified — punch-list 4]`. `--days 30` is explicit because Ubuntu's lego is a
major version behind upstream's dynamic default. Nothing runs per app, ever.

## Flow — reboot, and staying out of a build's way

Unattended: Docker's `always` policy plus Dokku's `ps:restore` from the init service bring every app
back after a reboot, skipping any that was manually stopped. A **daemon** restart is gentler than that
and was run on a live box: `live-restore` — set by Dokku's own postinst — means the containers are
never stopped at all, `ps:restore` still fires and briefly leaves a duplicate container that exits 143
on its own within ~17 s, and nginx's upstreams still match afterwards (`RESEARCH.md` → *Processes,
restarts and reboot*). **A true power cycle remains untested**; see *What is not yet proven on a box*.

Deliberate: `shepherd2 wait-idle` first. It blocks on the same poll lock and on `builds:list` with no
app, which lists every running build box-wide, and exits when both are clear. That is the whole of the
graceful-shutdown wait shepherd-java-client used to provide.

The one subtlety, and it is load-bearing: *running* here means `display_status`, Dokku's liveness check
on the recorded pid — never the stored `status`, which a no-op poll tick holds at `running` forever
(`D_poll_churn`). A `status`-based check is permanently true on a healthy box, so anything else that
ever asks "is a build running?" inherits the same trap.

## Flow — destroying a project

```
shepherd2 destroy-app demo
```

`apps:destroy --force demo`, then `network:destroy app-demo`, then `nginx:reload` — and each of the
two tails matters. Without the network destroy the box leaks a Docker network per project destroyed
(`D_isolation`). Without the reload the *running* nginx keeps serving `demo.mydomain.me` from a config
it still holds in memory, so requests to a destroyed project hang for 60s each rather than being
refused: `apps:destroy` removes the vhost file without signalling nginx (`RESEARCH.md` → *nginx*).
`apps:destroy` removes the `cache-demo` volume itself (verified on a box), so `destroy-app`'s
`repo:purge-cache` first is belt-and-braces rather than load-bearing. There is nothing else per
project: no file, no certificate, no service, no firewall rule.

## Housekeeping

Weekly, `shepherd2 clearcache` → `docker system prune -f`: dangling images and stopped containers.
This is the one place Shepherd2 calls `docker` instead of `dokku`, because Dokku has no prune.

**Never a blanket volume prune, and never `--volumes`.** Under `D_builder` the build cache *is* the
per-app `cache-$APP` volume, nothing garbage-collects it, and at a five-minute poll a build is always
about to want it. The per-app lever is `dokku repo:purge-cache <app>`, run deliberately. `docker buildx
prune` has nothing to prune here — there is no BuildKit cache in this design.

## Everything Shepherd2 stores

The complete list. If a fact is not here, it is Dokku's, and the way to read it is
`dokku *:report --format json` (`D_dokku_is_truth`).

| Where | What | Written by |
|---|---|---|
| `config:set <app> SHEPHERD_GIT_URL` | what the poll fetches | `create-app` |
| `config:set <app> SHEPHERD_OWNER` | a contact email — **not** an ACL (`D_single_operator`) | `create-app` |
| `config:set --global SHEPHERD_TLS_MODE` | `https` or `http` | `install` |
| `/run/lock/shepherd2-poll.lock` | the build serialisation lock; tmpfs, gone on reboot | `poll`, read by `wait-idle` |
| `/etc/cron.d/shepherd2`, `/etc/docker/daemon.json`, the apt source + keyring for Dokku, lego's credentials file | box configuration | `install` |

No project descriptor, no converger, no data directory, no database of ours. The reinstall story is
this repo plus Dokku's own state, or re-running `create-app` per project.

## What v1 does not do

Each of these is deferred with a decision behind it, not forgotten:

- **No database.** `dokku-postgres` is not installed and `create-app` has no `--postgres`. The cheapest
  deferral on this list — a database attaches to an app that already exists — except that when it lands
  it must be created with `--initial-network app-<id>`, which is creation-time only (`D_isolation`).
- **No private repos.** Every hosted repo must be publicly cloneable; the box holds no git credential
  (`Q_credentials` in `ideas/private-repo-credentials.md`).
- **No custom or apex domains**, because the wildcard covers neither (`D_cert`). Both are v2 rather than
  dropped, and v2 is `dokku-letsencrypt` on the affected apps only.
- **No multi-user anything.** One keyholder, who can do everything to every app (`D_single_operator`),
  and no web UI (`Q_web_admin` in `ideas/web-admin-ui.md`). Password and Google-SSO login go with the
  UI — a CLI has nothing to log in to — and the one v2 route that brings them back is option 3 there.
- **No egress filtering, and the host is reachable from every container.** Unchanged from both
  predecessors; deferred to v2 in `ideas/harden-container-egress.md`, which also records the two things
  v1 must not do to keep that fix cheap.
- **No memory quota.** Nothing refuses a project whose runtime + build memory overflows the box
  (`Q_quota` in `ideas/box-memory-quota.md`): the only enforcement point available is `create-app`, and
  a later hand `resource:limit` bypasses it. `shepherd2 stats` *reports* the over-commit — the sum of
  the limits against what the box has — and refuses nothing (`D_stats`).
- **No frontend build cache.** Every app here uses Vaadin's pre-compiled production bundle, so there is
  no npm or Vite run to cache; the candidates for the day one is needed are in
  `ideas/vaadin-build-under-herokuish.md`.
- **No `Dockerfile` builds**, by choice and box-wide (`D_builder`).

## What is not yet proven on a box

The 2026-09-11 run settled most of the punch list — `RESEARCH.md` → *Questions only a box can answer*
records each answer against its item. Four things are left, and only the first is load-bearing for v1:

- **Item 4, the whole `D_cert` chain.** Step 8 above — lego's first issuance, `global-cert:set`, the
  renewal hook re-applying to every app, and a new app picking the certificate up on its first deploy
  — has never executed. It cannot be run here: `D_cert` makes the TLS mode one-way, so it needs its own
  box with a real DNS zone. Planned in `ideas/production-cutover.md`.
- **A true reboot.** The box survived a Docker daemon restart with `live-restore`, `ps:restore` and the
  restart policy all doing their part, but a daemon restart is not a power cycle: it leaves the kernel,
  the bridges and nginx untouched. The probe agent ran *on* the VM, so rebooting would have killed the
  session mid-run.
- **The two `shepherd2-uninstall` fixes made after the teardown** — the surgical `daemon.json` edit and
  the second leftover directory. Both were exercised against the file shapes they handle, neither has
  been through a real uninstall.
- **Items 14 and 16**, which are v2 and wait on an app that customises its frontend.
