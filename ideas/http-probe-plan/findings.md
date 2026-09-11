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

**Deployed app containers are named `<app>.<process-type>.<index>` — `hello.web.1`.** Dokku creates
them under a transient name and renames on success: `Renaming container hello.web.1.upcoming-8948
(37d0f33c73cb) to hello.web.1`. So `lazydocker` / `ctop` show something useful without help, and the
naming contract the predecessors maintained by hand (`D_dokku_is_truth`) is simply Dokku's own.

**Build containers, by contrast, get a random Docker name** (`optimistic_rosalind`, `dreamy_curran`).
What both carry is labels, and those are the reliable handle:

```
com.dokku.app-name:hello   com.dokku.builder-type:herokuish   com.dokku.image-stage:build
com.gliderlabs.herokuish/stack:heroku-24   org.label-schema.vendor:dokku
```

```
# the deployed container adds:
com.dokku.container-type:deploy   com.dokku.dyno:web.1   com.dokku.process-type:web
com.dokku.image-stage:release
```

So `docker ps --filter label=com.dokku.app-name=hello` selects everything of an app's, and
`--filter label=com.dokku.image-stage=build` isolates a running build. Image is `dokku/hello:latest`.

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

Nothing in `ports:set`; `http:80:5000` is detected. **It survived** three further builds and two
successful deploys — `Ports map` is still empty and `Ports map json` still `null`. Item 8 closed.

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

**Closed against the deployed app**, once `hello` served a 200:

```
$ curl -D- http://hello.shepherd2.test/
HTTP/1.1 200 OK
Server: nginx
Content-Type: text/html;charset=utf-8
Set-Cookie: JSESSIONID=…
X-Frame-Options: SAMEORIGIN          # …and nothing else
$ curl -sI … | grep -ic strict-transport-security   → 0
$ curl -L -o /dev/null -w '%{url_effective} %{num_redirects}'
  http://hello.shepherd2.test/ 0     # no redirect; still http
```

Plain http on 80, **no `Strict-Transport-Security`**, **no redirect to https**. Both `[unverified]`
inferences from the nginx template are confirmed, and item 18 is closed.

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
- **`-Pproduction` is Vaadin-24-and-lower advice, and the cut is exactly Vaadin 25.0.** Checked
  against Vaadin's own docs on 2026-09-11:

  | Vaadin | What produces a production build |
  |---|---|
  | **≤ 24** | `mvn clean package -Pproduction`. The `production` profile carries the `vaadin-maven-plugin` `build-frontend` execution; `start.vaadin.com` starters ship the profile, hand-made projects must add it **[docs]** |
  | **≥ 25.0** | `mvn package`. No `production` profile exists; `build-frontend` runs in the default lifecycle and dev-mode tooling is excluded by default **[docs]** |

  > "Vaadin 25.0 updates the production build flow so it no longer depends on a dedicated
  > `production` Maven profile." — [Vaadin 25.0 release](https://vaadin.com/blog/vaadin-25-0-release)

  > "Previously, the production build had to be manually activated using the `production` profile in
  > `pom.xml`. … In Vaadin 25, there's no longer a separate production profile in `pom.xml`. … The
  > build — e.g. invoked with `mvn package` — now creates production-ready artifacts."
  > — [Simpler and more compatible builds](https://vaadin.com/blog/vaadin-25-simpler-and-more-compatible-builds),
  > which names buildpacks as a beneficiary: the change makes "CI pipelines and buildpacks behave more
  > like a standard Java build".

  Both probe repos are 25.2.x, so neither has the profile and passing `-Pproduction` would only raise
  "The requested profile could not be activated". **README's *Vaadin under herokuish* §1 is not wrong,
  it is unversioned** — it states the ≤ 24 rule as if it were universal. It needs the split above,
  because the farm will carry apps on both sides of the line for as long as any app is still on 24.
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

### Not a box finding — `karibu-helloworld-application-maven` did not produce a runnable distribution

**Fixed upstream on 2026-09-11** by the operator, in `1f65117 fix jakarta.servlet-api missing at
runtime`: the pom now declares `jakarta.servlet:jakarta.servlet-api` at `compile` scope explicitly,
overriding the `provided` that `vaadin-bom` manages it to. Recorded anyway, because the same shape
will greet every Vaadin Boot app coming off a `Dockerfile`. The app built and deployed, then
crash-looped:

```
Exception in thread "main" java.lang.NoClassDefFoundError: jakarta/servlet/ServletContext
	at com.github.mvysny.vaadinboot.common.JettyWebServer.createWebAppContext
```

Cause, from the build's own `target/mvn-dependency-list.log`:

```
jakarta.servlet:jakarta.servlet-api:jar:6.1.0:provided
```

`vaadin-bom` manages `jakarta.servlet-api` to **`provided`** — correct for a WAR dropped into a servlet
container that supplies the API, wrong for an app embedding Jetty via Vaadin Boot — and
`maven-assembly-plugin`'s `dependencySet` defaults to runtime scope, so the jar was in neither `lib/`
nor the `tar.gz`. **The repo's own `Dockerfile` image would have failed identically**; nothing about
herokuish or this box was involved. `vaadin-boot-example-maven` carries the same
`src/main/assembly/zip.xml` and the same `provided` scope, so it needs the same one-line override.

*(A first guess that `useTransitiveFiltering` was dropping the jar along with `com.vaadin:vaadin-dev`
was wrong — removing it changed nothing. The scope is the whole story.)*

Also worth knowing for the migration: **both Maven repos' assemblies emit only archives**
(`includeBaseDirectory=false`, formats `zip` + `tar.gz`), and a `Procfile` cannot untar anything —
there is no shell. Adding `<format>dir</format>` gives an exploded
`target/<finalName>-zip/` for the `Procfile` to name, and the `dir` format **does** preserve the
`fileMode 0755` on `bin/app`.

## Still open at the pause

Items 2, 6, 10, 11, 12, 19, 20, the deployed-app half of 18, and the `ports:report` survival half of 8.
All of them need one app that actually *runs*; the next move is `karibu-helloworld-application` (the
Gradle sibling, already onboarded upstream) rather than more surgery on the Maven pair.

### FINDING — punch-list 19 / `Q_poll_churn`: every `[src]` claim holds, and the churn is real

All three claims confirmed on `hello`, with the poll cron disabled so every tick was deliberate.

**Three no-op `shepherd2 poll` ticks** (`git:sync --build-if-changes`, ref unmoved) — each logs
`Skipping build as no changes were detected`, and each still writes a record and a log:

```
mtwslbpulbzlek  status=running  display=abandoned  exit=(absent)
mtwslbhdo9wyod  status=running  display=abandoned  exit=(absent)
mtwslb92r3et4i  status=running  display=abandoned  exit=(absent)
```

…one `.log` apiece, 265 bytes, containing the fetch chatter and nothing else. The on-disk record has
no `finished_at` and no `exit_code`.

**Then a real deploy**, and all three flipped as predicted:

```
mtwslbpulbzlek  status=failed  display=failed  exit=-1   dur=1m43s
mtwslbhdo9wyod  status=failed  display=failed  exit=-1   dur=1m43s
mtwslb92r3et4i  status=failed  display=failed  exit=-1   dur=1m43s
```

**And the eviction, which is the half that decides the question.** `builds:report` names the window:

```
Builds computed retention:     20
```

16 further no-op ticks took the list to exactly 20 records — and the four oldest, *including the
successful real deploy at 10:05:30*, dropped off. So:

> **At the installed cadence of 288 ticks a day, a 20-record window is consumed in about 100 minutes.**
> A build log is gone long before anyone reads it, and `builds:report <app>` — the at-a-glance — reports
> the app's build status as **`abandoned`** after any idle period, rather than `succeeded`.

Two things soften it, and one hardens it again:

- `builds:list <app> --status succeeded` (and `--kind build|deploy`) **still reached the evicted
  record** — the cap is on the default listing, not on what is stored. So does `builds:output <app>
  <id>` by id.
- **…until `builds:prune` runs.** `dokku builds:prune hello` deleted four `.log` files (24 → 20 on
  disk) and the evicted successful build vanished from `--status succeeded` too (2 records → 1).
  `builds:output` for that id then silently returns the *current* build's output rather than erroring,
  which is worse than a failure.

**The knob `Q_poll_churn` did not know about:** retention is settable, globally and per app, and
reverts cleanly.

```bash
dokku builds:set --global retention 200     # Builds computed retention: 200
dokku builds:set hello retention 50         # per-app override wins
dokku builds:set --global retention         # unset → back to 20
```

So the question is no longer "is churn real" (it is) but which of three to take: raise `retention`
globally in the install; have `poll` pre-check the remote ref so a no-op never enters `git:sync`; or
accept it and document `--status succeeded` as the way to read build history. The first is one line in
`shepherd2-install` and needs no code.

### FINDING — punch-list 11: what an app reaches on the host, measured

From inside `hello.web.1` (on `app-hello`, `172.16.1.3`, gateway `172.16.1.1`). The container image
ships `curl`, so no tooling had to be added.

| Target | Result |
|---|---|
| host service bound **`0.0.0.0:9099`**, via the bridge gateway | **200 — reachable** |
| host service bound **`127.0.0.1:9098`**, via the bridge gateway | 000 — not reachable |
| host **nginx** by gateway IP, `Host: hello.shepherd2.test` | **200** |
| host nginx by the box's LAN IP `192.168.122.124`, same header | **200** |
| `169.254.169.254/` (cloud metadata) | 000 — nothing listening *on this box* |
| KVM host `192.168.122.1:22` | 000 |
| outbound `https://repo.maven.apache.org/` | 200 |

Read carefully, because two of those zeroes prove nothing: the box runs **no sshd** and KVM offers no
metadata service, so `000` there is "nobody home", not "blocked". The deliberate pair of listeners is
what actually sizes the exposure:

> **Any host service bound to `0.0.0.0` is reachable from inside every app container; anything bound
> to loopback is not.** Nothing is firewalled — the bridge gateway is simply the host.

The concrete consequence for `ideas/harden-container-egress.md`: **an app can fetch any other app on
the box** by sending the host nginx a spoofed `Host:` header, bypassing nothing (that is just nginx
doing its job) but making `D_isolation`'s per-app networks a *container-to-container* boundary only,
never a container-to-anything boundary. And on a real VPS, `169.254.169.254` would answer — that is
the one with a genuinely bad worst case, and it is the strongest argument for the v2 `DOCKER-USER`
rule. Measured, as the item asked, to decide whether v2 bothers: **it should.**

### FINDING — an http-mode box still listens on 443, and that is Dokku being careful

Worth recording under item 18 because it looks alarming and is not. `/etc/nginx/conf.d/00-default-vhost.conf`
is Dokku's catch-all, installed by the deb:

```nginx
server {
    listen 80 default_server;  listen [::]:80 default_server;
    listen 443 ssl default_server;  listen [::]:443 ssl default_server;
    server_name _;
    ssl_reject_handshake on;
    return 444;
}
```

So on a box with no certificate, port 443 is **open but rejects every TLS handshake**
(`tlsv1 unrecognized name`) — there is no half-configured TLS endpoint and no certificate to leak — and
an unknown `Host:` on port 80 gets `444` (connection closed, no response). An app is reachable by its
exact vhost name and by nothing else.

### Note — the box has no sshd, so the admin key authorises nothing

`shepherd2-install --ssh-key` describes the key as "the key that may `git push` and run `dokku` over
ssh", and it is duly installed (`dokku ssh-keys:list` shows it). But this VM has **no
`openssh-server`**: nothing listens on 22. The install succeeds and says nothing about it.

Not a bug in what the installer *does* — but its preflight checks `hostname -f`, RAM and outbound
network, and does not check the one service the key it asks for depends on. A one-line preflight
warning would have saved the next person the confusion. (On a real VPS sshd is always there, which is
why it took a local VM to notice.)

### FINDING — punch-list 2: `D_isolation` works exactly as claimed, both halves

Two real apps, `hello` (Maven) and `gradle-a` (Gradle), each serving on its unpublished port 5000.
The before/after the item insists on, run by unsetting `initial-network` and restarting, then setting
it back:

| State | hello → gradle-a :5000 by IP | gradle-a → hello :5000 by IP | nginx `hello` | nginx `gradle-a` |
|---|---|---|---|---|
| **before** — no `initial-network`, both on the default `bridge` (172.17.0.2 / .3) | **200** | **200** | 200 | 200 |
| **after** — per-app networks (`app-hello` 172.16.1.3 / `app-gradle-a` 172.16.2.3) | **timeout** | **000** | 200 | 200 |

And the control that makes the "after" row mean something: **each app still reached *itself* on
:5000 → 200**, so the port is genuinely open and listening and it is the network, not the app, doing
the refusing.

`dokku network:set <app> initial-network` + `ps:restart` is all it takes; nothing re-attaches anything,
and host-nginx routing is untouched in every state. **Item 2 closed, and `D_isolation`'s central claim
is confirmed on a box.**

### FINDING — punch-list 10: a foreign network works, **and the rung `D_isolation` rejected is reachable**

`initial-network` accepts a network Dokku did not create:

```bash
docker network create -o com.docker.network.bridge.enable_icc=false foreign-icc-off   # 172.16.3.0/24
dokku network:set hello initial-network foreign-icc-off && dokku ps:restart hello
```

The app deploys, gets `172.16.3.2`, and **routes: 200**. Dokku keeps the distinction visible —
`network:list` lists it, `network:list --dokku-managed` shows only `app-hello` / `app-gradle-a`.

Then the part the item said "only matters if `D_isolation` is ever revisited" — so it was worth five
more minutes. **Both apps on that one shared `icc=false` network:**

| | hello → gradle-a :5000 | gradle-a → hello :5000 | nginx both |
|---|---|---|---|
| one shared network, `enable_icc=false` | **timeout** | **000** | 200 |

So a **single** shared network with inter-container communication disabled gives the *same* isolation
as N per-app networks, and routes identically. `D_isolation` recorded that rung as rejected; this says
it is **available**, not unreachable — which matters because it side-steps the address-pool wall
entirely (one network, not one per app) and would make punch-list 3's sub-bullet moot.

It does not overturn the decision — per-app networks are Dokku-native, need no `docker network create`
flag the CLI can't express, and survive `network:list --dokku-managed` as a legible inventory — but
**`D_isolation`'s "rejected alternatives" section is now factually wrong where it implies this cannot
be done through Dokku**, and should be corrected when the findings graduate.

### FINDING — punch-list 20: the Gradle buildpack works, all three parts

Against `mvysny/karibu-helloworld-application` **unmodified from GitHub** — it already carries the four
files README §4 prescribes, which is itself the confirmation that the §4 recipe is complete.

- **Which task runs:** the committed `.env` was honoured verbatim —
  `$ ./gradlew clean installDist -Pvaadin.productionMode`. So `GRADLE_TASK` reaches the build from a
  committed `.env`, confirming the ENV_DIR path `[src]` for the app's own files.
- **`-Pvaadin.productionMode` is the way in:** `> Task :vaadinBuildFrontend` ran, and the app says so
  at runtime — `Vaadin is running in production mode`, `Vaadin production mode is on: … "productionMode": true`.
- **`~/.gradle` does land in the cache volume**, and it is the whole toolchain:

```
$ docker run --rm -v cache-gradle-a:/cache alpine du -sh /cache/.[!.]*
1.3G  /cache/.gradle          →  787.5M  .gradle/wrapper   (the Gradle distribution + JDK)
                                 560.3M  .gradle/caches    (dependencies + build cache)
480.0K  /cache/.gradle-project
```

compared with Maven's `282.1M /cache/.m2`. The warm build shows the build cache working:
`> Task :compileKotlin FROM-CACHE`.

**Timings, from Dokku's own build records** (whole `git:sync --build`, clone to deployed):

| App | cold | warm |
|---|---|---|
| `gradle-a` (Gradle) | **3m15s** (Gradle itself 46s) | **1m37s** (Gradle itself 33s) |
| `hello` (Maven) | **3m02s** (Maven itself 2m12s) | **1m05s** (Maven itself 15s) |

Item 20 closed. **The capacity note worth carrying forward: a Gradle app's cache volume is ~1.3 GB**,
against Maven's ~280 MB, and `clearcache` never touches volumes by design. Nine Gradle apps would be
~12 GB of cache volumes on a box that currently has 42 GB free.

### NOT RUN — punch-list 3's sub-bullet, the ~30-network wall, and why not

The plan called for a VM snapshot before phase 1 and this run did not get one, so the rollback the
sub-bullet needs was never available. The plan's fallback — move `daemon.json` aside, restart the
daemon, loop `network:create` — looked more attractive once the box showed `live-restore: true` is
set by Dokku's postinst, since app containers survive a daemon restart. **It was still not run, for a
different and better reason:**

> On stock pools Docker's *second* default pool is **`192.168.0.0/16` at size 20**, and this VM lives
> on **`192.168.122.0/24`**. Allocating ~30 networks out of stock pools would hand one of them a
> `/20` covering `192.168.122.0`, and the box's only route to the world is that subnet. The plan
> already names this hazard in *The box*; running the drill on the live VM would have been a decent
> chance of losing the machine mid-probe.

So the arithmetic in `D_isolation` stays arithmetic until someone runs this on a throwaway with a
snapshot. **Note that punch-list 10's result may make the whole question moot**: one shared
`icc=false` network gives the same isolation and allocates exactly one subnet.

### FINDING — punch-list 6: cache isolation is impossible to breach, demonstrated

`vbm-a` and `vbm-b` are **the same repository deployed under two ids**, which is the only way to
guarantee the shared Maven coordinates the item needs: both build
`com.example:vaadin-boot-example-maven:1.0-SNAPSHOT`. `vbm-a` finished first and installed its
artifact where a shared cache would have exposed it:

```
$ docker run --rm -v cache-vbm-a:/cache alpine \
    ls /cache/.m2/repository/com/example/vaadin-boot-example-maven/1.0-SNAPSHOT/
vaadin-boot-example-maven-1.0-SNAPSHOT.jar           7,044,343
vaadin-boot-example-maven-1.0-SNAPSHOT-zip.tar.gz   21,811,646
vaadin-boot-example-maven-1.0-SNAPSHOT-zip.zip      21,827,802
vaadin-boot-example-maven-1.0-SNAPSHOT.pom
maven-metadata-local.xml
```

Then `vbm-b` was registered from the same URL, minutes later. It resolved **nothing** of `vbm-a`'s:

| | `vbm-a` | `vbm-b` |
|---|---|---|
| Maven `Total time`, cold | **1:00 min** | **1:02 min** |
| `Downloaded from central` lines | **924** | **924** |
| cache volume | `cache-vbm-a`, 205.2M | `cache-vbm-b`, 205.2M |

**924 downloads each, to the artifact.** The second app re-fetched the entire dependency tree and
rebuilt the identical `1.0-SNAPSHOT` into its own volume. There is no arrangement of app ids,
coordinates or timing that would let one project see another's `.m2` — `D_builder`'s claim is not a
policy the box enforces, it is a shape the box cannot express. **Item 6 closed as the demonstration
it was meant to be.**

Cache volumes after the run, for capacity planning:

```
cache-hello     282.1M   (Maven + Kotlin compiler)
cache-vbm-a     205.2M   (Maven)
cache-vbm-b     205.2M   (Maven, an exact duplicate of vbm-a's by construction)
cache-gradle-a    1.3G   (Gradle: wrapper distribution + JDK + dependency and build caches)
```

The duplication is the price of the isolation and is worth naming out loud: two ids on one repo cost
two full copies. Disk went 18G → 20G used of 62G across the four apps.

### FINDING — punch-list 12: confirmed, and the failure is *worse* than the expected 502

First correction to the plan: **`traefik-vhosts` is a Dokku *core* plugin**, installed and enabled by
the deb like `nginx-vhosts` and `haproxy-vhosts`. Nothing has to be installed to test this, and the
plan's "it installs a plugin the product deliberately does not use, so do it last" caution is milder
than written — the plugin is already on every Shepherd2 box, merely unused.

`dokku traefik:show-config vbm-b` renders what it *would* run, and that is the evidence `D_proxy`
wants:

```yaml
services:
  traefik:
    image: "traefik:v3.7.10"
    command:
      - --entrypoints.http.address=:80
      - --providers.docker
      - --providers.docker.exposedByDefault=false
    network_mode: bridge          # <-- the whole finding
    ports:
      - "80:80"                   # <-- and the second one
```

- **`network_mode: bridge`.** Traefik is put on Docker's *default* bridge and nothing anywhere
  attaches it to an app's network. An app whose `initial-network` is `app-vbm-b` (172.16.x) is
  therefore on a different L2 from the proxy meant to reach it — which is exactly the `[src]` reading
  ("no network attachment logic anywhere in it"), now confirmed against generated output rather than
  source. The expected 502 follows directly.
- **`ports: "80:80"`.** Traefik wants the host's port 80, which Dokku's own nginx already holds. So on
  a Shepherd2 box `traefik:start` cannot even bind without stopping nginx first — every app on the box
  goes dark to run the experiment.

**Then run for real**, on `gradle-a`, once the box was due for teardown (it needs nginx stopped
box-wide). Dokku wires the app up correctly — the labels are right:

```
traefik.enable:true
traefik.http.routers.gradle-a-web-http.rule:Host(`gradle-a.shepherd2.test`)
traefik.http.services.gradle-a-web-http.loadbalancer.server.port:5000
```

…and the two containers are on different networks, as the config said they would be:

```
traefik-traefik-1   bridge=172.17.0.2
gradle-a.web.1      app-gradle-a=172.16.2.3
```

**The result is not a 502. It is a hang.**

| From | To | Result |
|---|---|---|
| `curl -H 'Host: gradle-a…'` → traefik | the app | **timed out at 20s, no response at all** |
| inside traefik → `172.16.2.3:5000` | the app | **timed out at 6s** |
| inside traefik → `172.17.0.1:22` (control) | its own gateway | "Connection refused", *immediately* |
| inside the app → `172.16.2.3:5000` (control) | itself | **200** |

The two controls are what make this conclusive: the tool reports a refusal promptly when there is one,
and the app is alive and listening the whole time. The app's network is simply unroutable from
traefik's, so packets are **dropped rather than refused** and traefik sits there until its own timeout
rather than answering 502.

That is a sharper argument than `D_proxy` currently makes. The entry anticipates a 502 — a thing an
operator diagnoses in seconds. The reality is a silent hang with **nothing in traefik's logs**, which
is the worst diagnostic shape available. Item 12 closed.

One correction to the plan while here: it warned that this "installs a plugin the product deliberately
does not use". It does not — `traefik-vhosts` is **core**, shipped and enabled by the deb alongside
`nginx-vhosts` and `haproxy-vhosts`, so the experiment installs nothing. What it does need is
`systemctl stop nginx` (traefik wants `ports: "80:80"`), which is why it still belongs last.

## Bugs the box found in our own code, beyond the punch list

The punch list asks about Dokku. These are three things wrong with **Shepherd2**, none of which any
amount of reading would have found. All three are fixed and the fixes are verified on the box.

### BUG 1 — `shepherd2-install` aborted at the admin-key step

Covered above under *Phase 1*. `dokku ssh-keys:add admin < FILE` is invisible to Dokku, and a trailing
blank line in a `.pub` file defeats the argument form.

### BUG 2 — `shepherd2 wait-idle` could never return on a live box

`running_builds` selected build records with `status == 'running'`. **Every no-op poll tick leaves a
record at exactly that, permanently** — there is no `finished_at` for a build that never started — and
the cron writes one every five minutes. So on any box that has been up for five minutes, `wait-idle`
blocked until its timeout and exited 1. The box at the time of the test:

```
Counter({('running', 'abandoned'): 14, ('running', 'running'): 1})
```

Dokku already computes the distinction — it checks whether the recorded pid is still alive and
publishes the answer as `display_status`. A live build reads `running`/`running`; an abandoned tick
reads `running`/`abandoned`. Keying off `display_status` (falling back to `status`) fixes it:
with 12 abandoned records present, `wait-idle` went from *timing out at 30s with exit 1* to
**returning in 0.116s with exit 0**.

This is the direct operational consequence of `Q_poll_churn` and is the strongest argument yet for
settling it: the churn did not merely clutter a listing, it broke the verb that exists to make a
reboot safe.

### BUG 3 — `destroy-app` left the destroyed app's hostname black-holing requests

`dokku apps:destroy` removes the per-app vhost file (`/home/dokku/<app>/nginx.conf`) but **does not
reload nginx**. The running nginx therefore keeps serving the destroyed app's hostname from the config
it still holds in memory, proxying to a container that no longer exists — so requests **hang for
`proxy_connect_timeout` (60s)** instead of being refused.

Isolated by elimination, which is why it is worth writing down: `nginx -T` showed **no** `vbm-b`
server block, `/home/dokku/vbm-b/` was gone, and `grep -r vbm-b /etc/nginx` found nothing — yet only
that one hostname misbehaved, case-insensitively:

```
nosuchapp.shepherd2.test -> code=000 time=0.000282     # catch-all `return 444`, instant
vbm-b.shepherd2.test     -> code=000 time=6.002944     # hangs
vbm-c.shepherd2.test     -> code=000 time=0.000386     # instant
```

`systemctl reload nginx` made `vbm-b` behave like the others immediately. So the stale config was in
the *running* nginx, not on disk — which is exactly the failure the operator would never diagnose,
because every tool that inspects config says the app is gone.

The mechanism, pinned down without a build by using an app that was created and never deployed — such
an app gets a `return 502` vhost, which is enough to see the effect:

```
$ dokku apps:create probe-vhost            → "Creating http nginx.conf / Reloading nginx"
  Host: probe-vhost.shepherd2.test         → 502          (served)
$ dokku apps:destroy --force probe-vhost
  /home/dokku/probe-vhost/nginx.conf       → gone         (removed synchronously)
  Host: probe-vhost.shepherd2.test         → 502          (still served, from memory)
```

So `apps:create` reloads nginx and `apps:destroy` does not. **There is no race** — the file is gone
before anything of ours runs; Dokku simply never signals nginx on the way out.

Fixed with Dokku's own command rather than a reach-around: `destroy_app` now ends with
`dokku nginx:reload`, best-effort. End to end, with the fix:

```
before destroy: 502
t+0s: 502      ← still stale
t+1s: 000      ← catch-all; cleared
t+2s … t+6s: 000
```

**`dokku nginx:reload` is asynchronous** — it returns 0 immediately and the old config is served for
about another second. That cost an hour of confusion here: the first verification curled instantly
after `destroy-app` returned, saw the old vhost, and looked like the fix had failed. It had not. Worth
knowing before anyone writes a test that asserts a hostname is dead the moment a destroy returns.

This is **not** a Dokku bug to report upstream so much as a consequence of `apps:destroy` being
designed for a box where the next deploy reloads nginx soon anyway; on Shepherd2 a destroyed project
may be the last thing that happens for days.

### FINDING — not on the punch list: the box survives a Docker daemon restart

Nothing numbered covers this, and everything depends on it, so it was run before teardown. `RESEARCH.md`
carries three `[docs]` claims that together are "the apps come back": Docker's `live-restore`, Dokku's
`ps:restore` from the init service, and our `ps:set --global restart-policy always`.

```
$ docker info --format '{{.LiveRestoreEnabled}}'   → true      (from Dokku's postinst, not from us)
$ systemctl restart docker
```

All three hold, and the shape is worth knowing:

- **Containers are not restarted at all.** `hello.web.1` still read `Up About an hour` afterwards — its
  uptime was never interrupted. That is `live-restore` doing exactly what it claims.
- **`ps:restore` still fires, and briefly starts a duplicate.** A second container,
  `gradle-a.web.1.1789125735`, appeared alongside the running `gradle-a.web.1` and **exited 143
  (SIGTERM) about 17 seconds later** on its own. Transient and self-correcting, but an operator
  watching `docker ps` in that window sees two containers for one app and should not panic.
- **Routing stays consistent.** Both apps' nginx upstreams matched their containers' current IPs
  afterwards, and both served 200:

  ```
  hello:    container=172.16.1.2  nginx=172.16.1.2:5000  MATCH
  gradle-a: container=172.16.2.2  nginx=172.16.2.2:5000  MATCH
  ```

**Caveat on what this does and does not prove.** A daemon restart is the mechanism `ps:restore` hangs
off, but it is *not* a reboot: it leaves the kernel, the bridges and nginx untouched. A true
`reboot` test was not run because the agent driving this probe runs **on the VM**, so it would have
killed the session mid-run. It stays worth doing — one command, and the only way to prove the box
comes back unattended after a power cycle.

## `shepherd2-uninstall` — run for the first time, as the teardown

Never executed anywhere before this. It exited 0 and is **very nearly clean**; the audit is
`uninstall-pre-state.txt` / `uninstall-post-state.txt`, the transcript `uninstall-http.log`.

What it removed, all correctly: both projects (containers, caches, networks), the dokku package, the
apt source, the keyring, the cron file, the CLI, the poll lock, and docker.io/buildx/compose-v2 —
which takes nginx with it, since that arrived as a Dokku dependency. `ruby` stays, as the header
promises. **The box's listening sockets afterwards are identical to `pre-install-baseline.txt`**
(cups on 631, systemd-resolved on 53) — the strongest single statement that the install is reversible.

Leftovers, all of them reported by the script rather than silently left:

```
1.5M  /home/dokku        ← warned about by name
148K  /var/lib/dokku     ← NOT warned about (see below)
4.0K  /var/lib/docker
```

### FINDING — the `--keep-pools` default is unreachable on any real box *(v1 gap)*

```
==> Docker address pools
warning: /etc/docker/daemon.json is not what the install wrote; leaving it alone.
       Remove the default-address-pools stanza by hand if you want Docker's defaults back.
```

This is the direct consequence of punch-list 3, and the two scripts disagree about it:

- **The install `merge`s** its pools into the file Dokku's postinst already wrote (`live-restore: true`)
  — that is the branch *every* install takes.
- **The uninstall only removes the stanza if the file matches what the install wrote** — byte for byte,
  a file containing nothing but the pools.

Those two can never both be true. So the "remove the pools" default path is **dead code on a real box**,
and every uninstall leaves `/etc/docker/daemon.json` carrying Shepherd2's `172.16.0.0/12` pools behind
on a machine that no longer runs Shepherd2. It is safe — it warns clearly and refuses to touch a file
it does not recognise, which is the right instinct — but the documented default never happens.

The fix is to make the uninstall symmetric with the install: parse the JSON, delete the
`default-address-pools` key, keep everything else, and write the file back (removing it entirely only
if nothing is left). That is the same `python3` dependency the install already relies on.

### Smaller: `/var/lib/dokku` is left behind unmentioned

`apt purge dokku` leaves 148K in `/var/lib/dokku`. The script's *WHAT IT DELIBERATELY DOES NOT REMOVE*
section and its closing summary both name `/home/dokku` and neither names this one, so an operator
following the script's own advice cleans up one and not the other.
