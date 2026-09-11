# http-mode probe run — raw findings

Run on `mavi-fw-vm-sh2` starting 2026-09-11, against `ideas/http-probe-plan.md`. This is the running
transcript of *what the box actually did*; findings graduate out of here into `RESEARCH.md` /
`DECISIONS.md` / `README.md` / `SOLUTION.md` and this file dies with the plan note.

## Deviations from the plan, and why

- **The four apps are served from local git repos**, `/srv/probe-repos/<repo>`, cloned from GitHub and
  then committed to locally. Reason: all three upstream repos need herokuish onboarding files added
  (`Procfile`, `system.properties`, and for Gradle `settings.gradle.kts` + `.env`), and the probe has
  no business pushing those to public repositories. `git:sync` is given a `file:///srv/probe-repos/…`
  URL. Nothing the punch list asks about is sensitive to the transport.

- **The Gradle app is `mvysny/karibu-helloworld-application` straight from GitHub**, unmodified — it
  already carries the four files README §4 prescribes (`Procfile`, `.env` with `GRADLE_TASK`,
  `settings.gradle.kts`, `system.properties`), because it is the app the 2026-09-11 local rehearsal
  used. It replaces `vaadin-boot-example-gradle` from the plan, which carries none of them.
- **The poll cron was commented out in `/etc/cron.d/shepherd2`** for the duration, so a scheduled
  build cannot take the box-wide lock in the middle of a timing drill. Re-enabled and exercised at
  the end of the run.

## Phase 1 — install

Transcript: `install-http.log` (first attempt, **failed**) and `install-http-2.log` (after the fix,
clean). Docker is Ubuntu's `docker.io` **29.1.3**; Dokku **0.38.27** from packagecloud.

### FINDING — `shepherd2-install` aborted at the admin-key step. Two Dokku quirks, one fix. *(v1 bug, fixed)*

`dokku ssh-keys:add admin < "$SSH_KEY_FILE"` exits 1 with `! No key specified via file or pipe`.
Reproduced and narrowed on 0.38.27:

| Form | Result |
|---|---|
| `dokku ssh-keys:add admin < key.pub` | **fails** — "No key specified via file or pipe" |
| `cat key.pub \| dokku ssh-keys:add admin` | works |
| `dokku ssh-keys:add admin key.pub` | works — *unless* the file has a trailing blank line |
| `dokku ssh-keys:add admin key.pub`, file ends with a blank line | **fails** — "Too many keys provided, set one per invocation" |

So `ssh-keys:add` tests stdin for being a **pipe**, not for being a non-tty: a plain `<` redirect is
invisible to it. And the `KEY_FILE` argument form splits on newlines and counts a trailing blank line
as a second key — which a stock `ssh-keygen` `.pub` written by some tools has. The box's own
`/home/mavi/.ssh/id_ed25519.pub` was exactly such a file (2 lines, 101 bytes), so both forms failed
for different reasons.

Fix, now in `shepherd2-install` → `configure_admin_and_domain`: pipe it, blank lines stripped.

```bash
grep -v '^[[:space:]]*$' "$SSH_KEY_FILE" | dokku ssh-keys:add admin
```

### FINDING — punch-list 3, first half: the merge branch is the live one, and it works

The installer has three branches for `/etc/docker/daemon.json`. The one that fired was the third —
**`merged default-address-pools into the existing /etc/docker/daemon.json`** — not the "nothing got
there first" branch the script's comment called expected. The writer is **Dokku's own deb**:
`/var/lib/dpkg/info/dokku.postinst` creates the file if absent and `jq`-merges `"live-restore": true`
into it, then reloads Docker. The pre-install baseline confirms it is not Ubuntu's `docker.io`: that
box had no `/etc/docker` at all.

The merge did the right thing — it kept `live-restore` and added the pools:

```json
{ "live-restore": true,
  "default-address-pools": [ { "base": "172.16.0.0/12", "size": 24 } ] }
```

…and the pools are in effect after the restart: the first network created gets `172.16.0.0/24`.

```
$ docker network create probe0 && docker network inspect probe0 → IPAM.Config
[{'Subnet': '172.16.0.0/24', 'IPRange': '', 'Gateway': '172.16.0.1'}]
```

Two consequences: the `[unverified — punch-list 3]` comment in `configure_address_pools` was pointing
at the wrong branch and has been corrected, and **the previously-untested python3 merge path is the
one every install takes** — so `python3` is a hard prerequisite of the install, not a fallback.

### FINDING — the install is re-runnable, as designed

The second run reported `(already done)` for the packagecloud key, the apt source, the dokku package
and the address pools, and re-applied the rest idempotently. Fixing a failed install by editing the
script and running it again — the workflow the header claims — works.

## Phase 3 — the build-dependent half

### Note, not a finding — `file://` sources must be readable *as the dokku user*

`git:sync` clones as `dokku`, and git refuses a repo owned by someone else:
`fatal: detected dubious ownership in repository at '/srv/probe-repos/…/.git'`. Fixed by
`chown -R dokku:dokku /srv/probe-repos`. An artefact of this run's local-repo route; a real box
clones over https and never sees it.

Everything *before* the clone in `create-app` ran correctly on the first attempt: `apps:create`, both
`resource:limit` calls, `network:create app-hello`, `network:set initial-network`, and the two
`SHEPHERD_*` config vars — written before the build, as the header promises, so a failed first build
leaves a registered project behind. Re-running `create-app` after the fix is the documented repair
and is what was done.

### FINDING — punch-list 17: build limits *are* honoured. The item was mis-framed, and the documented route works

`create-app` emits `resource:limit --process-type build --cpu 2 --memory 2g`, and the build container
Dokku creates carries exactly that — read straight off the daemon, mid-build:

```
$ docker inspect <build container>
mem=2147483648   nanocpus=2000000000
$ docker stats   MEM 146.3MiB / 2GiB
```

`2147483648` is 2 GiB and `2000000000` nanocpus is 2 CPUs. So the **documented** route — the special
`build` process type — takes effect on the herokuish path; the `docker-options:add <app> build
'--cpus 2'` hack the punch list asks about is not needed and was a Dockerfile-builder artefact.
**Drop the `[unverified — punch-list 17]` marker on `shepherd2:25`.** Since `--build-cpu 2` /
`--build-mem 2g` are *defaults*, this was load-bearing: had it not held, every app on the box would
build uncapped.

### FINDING — punch-list 7: container naming, plus something better than names

The build container gets a **random Docker name** (`optimistic_rosalind`) — Dokku derives nothing
from the app. What it *does* attach is labels, and those are the usable handle:

```
com.dokku.app-name:hello   com.dokku.builder-type:herokuish   com.dokku.image-stage:build
com.gliderlabs.herokuish/stack:heroku-24   org.label-schema.vendor:dokku
```

So `docker ps --filter label=com.dokku.app-name=hello` is the reliable selector, not the name.
Image is `dokku/hello:latest`.

**And a bonus that matters to `D_isolation`: the build container is on the app's own network** —
`app-hello (172.16.1.2)`. `initial-network` covers the build, not just the runtime container.

### FINDING — punch-list 8: ports are auto-wired, and before the first deploy at that

```
$ dokku ports:report hello          # app created, never deployed
Ports map:                          (empty)
Ports map detected:                 http:80:5000
Ports map detected json:            [{"container_port":5000,"host_port":80,"scheme":"http"}]
Ports map json:                     null
```

Nothing in `ports:set`; `http:80:5000` is detected. (Survival across a rebuild still to check.)

### FINDING — punch-list 18: the http-only mode behaves, and `hsts` is genuinely inert

On the undeployed app, `nginx:show-config hello` is a plain-http vhost — `listen 80` / `listen [::]:80`
and **no `ssl`, no `443`, no redirect, no `Strict-Transport-Security` anywhere in the generated file**.
Over the wire: `HTTP/1.1 502 Bad Gateway` from nginx with no HSTS header (the 0.38.0 "undeployed apps
get a 502 vhost" behaviour, confirmed).

The `hsts` half is the important one, because `D_cert` leans on it:

```
$ dokku nginx:report hello
Nginx computed hsts:                    true          # the default is on
...
$ dokku nginx:set hello hsts true                     # ask for it explicitly
$ dokku nginx:show-config hello | grep -c Strict-Transport-Security
0
```

So HSTS is computed `true` and emitted **nowhere** without a certificate — it is attached to the ssl
listener, which does not exist. That is why an http-mode box is safe to run, and why the mode is
one-way: the moment a certificate exists the same setting starts sending a 182-day `max-age`.

*(Still open until the app deploys: the same checks against a 200 rather than a 502.)*

### FINDING — the unnumbered one: **a Vaadin app builds under herokuish, first time, with no coaxing**

`shepherd2 create-app hello file:///srv/probe-repos/karibu-helloworld-application-maven master
--owner mavi@vaadin.com --buildpack heroku/java`, and the build half worked on the first attempt:

```
-----> Java app detected                          # the pinned buildpack, not detection
-----> Installing Azul Zulu OpenJDK 21.0.12.1     # system.properties honoured
-----> Executing Maven
       $ ./mvnw -DskipTests clean dependency:list install
       [INFO] BUILD SUCCESS
       [INFO] Total time:  02:12 min
-----> Discovering process types
       Procfile declares types -> web
```

Three things fall out of that, all of which the docs currently get half-right:

- **`MAVEN_CUSTOM_OPTS` was never set, and the build was a production build anyway.** The log shows
  `vaadin-prod-bundle-25.2.6.jar` downloaded and **no npm, no Vite, no `~/.vaadin` node download**, and
  the app says so at runtime:
  `Vaadin production mode is on: … flow-build-info.json contains '"productionMode": true'`.
  **Punch-list 15 is confirmed on a box**, not just off it.
- **`-Pproduction` is Vaadin-24-era advice and is wrong for these repos.** Neither
  `karibu-helloworld-application-maven` (25.2.6) nor `vaadin-boot-example-maven` (25.2.7) has a
  `production` profile at all; both run `vaadin-maven-plugin:build-frontend` in the default lifecycle,
  so `mvn install` *is* the production build. Passing `-Pproduction` would only raise
  "The requested profile could not be activated". **README's *Vaadin under herokuish* §1 needs this
  qualification** — it currently says every Vaadin Maven project needs
  `MAVEN_CUSTOM_OPTS=-DskipTests -Pproduction`.
- **The buildpack's default goals already include `-DskipTests`**, so an app that needs nothing else
  needs no `MAVEN_CUSTOM_OPTS` line whatsoever.

### FINDING — punch-list 13, the Maven half: **cold 2m12s → warm 15.0s**

Second build of the same app after a one-line commit, same `cache-hello` volume:

| | Maven `Total time` | `shepherd2 rebuild` wall clock |
|---|---|---|
| cold (first build) | **2:12 min** | — |
| warm (second build) | **14.999 s** | 1m12s including clone, slug and deploy |

`maven.repo.local` is inside the cache volume, as `[src]` said:
`Installing /tmp/build/target/…jar to /cache/.m2/repository/com/example/…`. The frontend half of the
question **did not arise at all** — there is no frontend build to be cold, because of the
pre-compiled bundle. For this farm, item 13 is answered: builds come back warm and the expensive half
does not exist.

### Not a box finding — `karibu-helloworld-application-maven` does not produce a runnable distribution

Recorded because it cost an hour and it is the operator's own repo. The app builds and deploys, then
crash-loops:

```
Exception in thread "main" java.lang.NoClassDefFoundError: jakarta/servlet/ServletContext
	at com.github.mvysny.vaadinboot.common.JettyWebServer.createWebAppContext
```

Cause, from the build's own `target/mvn-dependency-list.log`:

```
jakarta.servlet:jakarta.servlet-api:jar:6.1.0:provided
```

`jakarta.servlet-api` is **`provided`** scope, and `maven-assembly-plugin`'s `dependencySet` defaults
to runtime scope — so it is in neither `lib/` nor the `tar.gz`. **The repo's own `Dockerfile` image
would fail identically**; nothing about herokuish or this box is involved. `vaadin-boot-example-maven`
carries the same `src/main/assembly/zip.xml` and will do the same.

Also worth knowing for the migration: **both Maven repos' assemblies emit only archives**
(`includeBaseDirectory=false`, formats `zip` + `tar.gz`), and a `Procfile` cannot untar anything —
there is no shell. Adding `<format>dir</format>` gives an exploded
`target/<finalName>-zip/` for the `Procfile` to name, and the `dir` format **does** preserve the
`fileMode 0755` on `bin/app`.

## Still open at the pause

Items 2, 6, 10, 11, 12, 19, 20, the deployed-app half of 18, and the `ports:report` survival half of 8.
All of them need one app that actually *runs*; the next move is `karibu-helloworld-application` (the
Gradle sibling, already onboarded upstream) rather than more surgery on the Maven pair.
