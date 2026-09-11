# The http-mode probe run — how the punch list actually gets executed

Written 2026-09-11. **Run on 2026-09-11 — see `ideas/http-probe-plan/findings.md`, which is where
every result lives.** `RESEARCH.md` → *Questions only a box can answer* owns *what* is being asked and
stays the authority on each item; this note owns *the order, the traps and the exact commands* for
running the http-mode subset on the dev VM, and it is deleted once the findings have landed. The
https subset cannot run here at all — see `ideas/production-cutover.md`.

**Graduation is under way, one finding at a time** (agreed with the operator on 2026-09-11): each is
discussed, implemented, then cut out of `findings.md` with a note saying where it landed, and this note
is deleted when the last one goes. The status table below marks what has graduated. Until a finding
does, this folder is its only record — and it is complete enough to graduate from without the box.

## Where the run got to

| Item | Status |
|---|---|
| 2 isolation + routing | **closed** — both halves, with a self-reach control |
| 3 `daemon.json` | **closed** (first half) — Dokku's postinst writes it; the merge arm is the live one — and **graduated** (+ the `--keep-pools` uninstall fix it exposed) |
| 3 the ~30-network wall | **closed** — 29 networks, 30th fails; run after the uninstall, on genuinely stock pools — and **graduated** |
| 6 two-build drill | **closed** — 924 downloads from central each, nothing shared |
| 7 container naming | **closed** — `hello.web.1`; build containers get random names; `com.dokku.*` labels |
| 8 ports auto-wired | **closed** — `http:80:5000`, detected, survives rebuilds |
| 10 foreign `initial-network` | **closed**, and it found a correction for `D_isolation` |
| 11 what an app reaches | **closed** — measured, and it argues *for* the v2 `DOCKER-USER` rule |
| 12 Traefik 502 | **closed** — and it is not a 502, it is a silent hang |
| 13 warm second build | **closed** for both Maven and Gradle |
| 15 pre-compiled bundle | **closed** on a box, not just off it |
| 17 build CPU | **closed** — holds; marker dropped from `shepherd2:25` |
| 18 http-only mode | **closed** — both the 502 and 200 paths |
| 19 no-op tick churn | **closed**, and **graduated** → `D_poll_churn` (retention 300 + `shepherd2 last-build`) |
| 20 Gradle buildpack | **closed** — all three parts |
| 4, 9, 14, 16 | out of scope here, as planned |

**Three v1 bugs in our own code came out of it, all fixed and all verified on the box** — none of
which any amount of reading would have found. See *Bugs the box found in our own code* in
`findings.md`:

1. `shepherd2-install` aborted at the admin-key step (`ssh-keys:add` is invisible to a `<` redirect).
2. `shepherd2 wait-idle` could never return on a live box — the no-op poll records it counted as
   running never stop being `status: running`.
3. `shepherd2 destroy-app` left the destroyed app's hostname hanging for 60s a request, because
   `apps:destroy` removes the vhost without reloading nginx.

Plus the address-pool comment, which pointed at the branch the install never takes.

Sidecars, all in `ideas/http-probe-plan/`:

- `findings.md` — **the results.** Everything else here is evidence for it.
- `pre-install-baseline.txt` — the virgin-box capture taken before anything was installed. The *pre*
  half of item 3, and not retakeable once Docker exists.
- `install-http.log` / `install-http-2.log` — the failed first install and the clean re-run.
- `build-hello-*.log`, `build-gradle-a-*.log`, `poll-real-deploy.log` — build and deploy transcripts,
  ANSI and Maven download chatter stripped.

## The box

`mavi-fw-vm-sh2`, verified ready 2026-09-11: Ubuntu 24.04.5 LTS, amd64, 4 vCPU, 7.7 GB RAM + 4 GB swap,
48 GB free on `/`, `hostname -f` resolves, ports 80/443 free, `universe` on (lego 4.9.1 available),
Ruby 3.2.3, outbound to archive/packagecloud/ACME/GoDaddy all reachable. Suite and shellcheck green at
`b0ddb84`.

A KVM guest on libvirt's default NAT: its own address is **192.168.122.124**, gateway
`192.168.122.1`, egress `91.152.95.153`, **no inbound**. Two consequences worth having in mind:

- `172.16.0.0/12` at size 24 (the install's `default-address-pools`) does not collide with
  `192.168.122.0/24`, so the line the installer's header flags as the one to change stays as it is.
  Stock Docker's *second* pool, `192.168.0.0/16` at size 20, would have overlapped the VM's own
  subnet — replacing the pools removes that hazard rather than adding one.
- Anything requiring the box to be reachable from outside is out of scope here, which is most of what
  pushes item 4 to production.

**Snapshot the VM from the KVM host before phase 1.** Not optional: `D_cert` makes the TLS mode
one-way, phase 2b needs stock address pools back, and phase 2c installs a plugin the product
deliberately does not use.

## The domain: `shepherd2.test`

Any name works as long as `/etc/hosts` carries it, so pick the one that cannot bite: **`.test` is
reserved by RFC 6761 for exactly this** and is never resolvable publicly, so a typo cannot reach a
stranger's server, and — unlike `.local` — it is not mDNS, so systemd-resolved leaves it alone. The
docs keep `mydomain.me` as their placeholder (`CLAUDE.md`); this is the VM's real value, not a new
placeholder.

`/etc/hosts` has no wildcards, so it is one line per app rather than one for the domain. That is cheap
here — the run needs four apps — but it is the reason a browser on the KVM host needs its own copy:

```
# inside the VM                        # on the KVM host, to browse from the desktop
127.0.0.1 hello.shepherd2.test         192.168.122.124 hello.shepherd2.test
127.0.0.1 gradle-a.shepherd2.test      192.168.122.124 gradle-a.shepherd2.test
127.0.0.1 vbm-a.shepherd2.test         192.168.122.124 vbm-a.shepherd2.test
127.0.0.1 vbm-b.shepherd2.test         192.168.122.124 vbm-b.shepherd2.test
```

## Phase 1 — install, and item 3 falls out of the transcript

Run from the checkout (the installer copies the CLI out of `SCRIPT_DIR`), and **keep the output**:

```bash
cd /home/mavi/work/my/shepherd2-dokku
sudo ./shepherd2-install --domain shepherd2.test --mode http \
     --ssh-key /home/mavi/.ssh/id_ed25519.pub --yes 2>&1 | tee ideas/http-probe-plan/install-http.log
```

`--email` is unused in http mode. `--yes` skips the confirmation before nginx's `sites-enabled` is
emptied.

**Item 3's first half needs no separate experiment — the installer's own log line is the finding.**
`configure_address_pools` has three branches with distinct output, and which one fires *is* the answer:

| Log line | Means |
|---|---|
| `wrote /etc/docker/daemon.json: 172.16.0.0/12 at size 24` | nothing got there first — the expectation, and what `shepherd2-install:352` marks `[unverified]` |
| `/etc/docker/daemon.json already sets default-address-pools` | something wrote pools before us; find out what |
| (python3 merge, no skip line) | Docker's package wrote the file but not pools — the merge path, previously untested |

Given the sidecar shows no `/etc/docker` at all on a box with no Docker packages, the first row is
expected. Confirm afterwards that the daemon came up with the pools in effect:
`docker network create probe0 && docker network inspect probe0 | jq '.[0].IPAM.Config'` → a `172.x/24`.

## Phase 2 — structural probes, no builds yet

Nothing here needs an app to have been built, so it all runs before the slow half.

| Item | What to run |
|---|---|
| **7** container naming | `docker ps --format '{{.Names}}'`; then `lazydocker` / `ctop` if they are worth installing. Turns `RESEARCH.md`'s `[unverified]` on naming into fact |
| **2** isolation + routing | the load-bearing one. Two apps, each on its own `initial-network`; from A's container reach B's unpublished port by container IP (expect refused), and `curl` both through nginx by `Host:` (expect 200). Do the before/after halves the item asks for, or the "and not after" proves nothing |
| **11** what an app reaches on the host | from inside a container: `curl http://192.168.122.1:22`, nginx by gateway IP with a `Host:` header for the other app, and `curl http://169.254.169.254/`. Sizes the v2 `DOCKER-USER` rule in `ideas/harden-container-egress.md` — measured to decide whether v2 bothers, not to unblock v1 |
| **18** the http-only mode | the mode is defined by absence, so confirm the absence behaves: plain http on 80, **no** `Strict-Transport-Security`, **no** redirect to https. `curl -sI http://hello.shepherd2.test/`. Then check `nginx:set <app> hsts` is inert without a certificate — that is *why* the mode is one-way |
| **10** foreign `initial-network` | `docker network create -o com.docker.network.bridge.enable_icc=false` then point `initial-network` at it. Lowest priority; only matters if `D_isolation` is ever revisited |

### 2b — the ~30-network wall, and why it needs its own snapshot

Item 3's sub-bullet wants `network:create` about 30 times **on stock pools**, to get the real wall
rather than the arithmetic. Our install replaces the pools at step 5, so this cannot be run after a
normal install. Do it on a rollback: install Docker only, leave `daemon.json` absent, loop
`docker network create wall-$i` until it fails, record the number, then roll forward. Running it on the
live probe box by moving `daemon.json` aside and restarting the daemon would work but puts every
probe app's networking through a daemon restart — not worth it.

### 2c — item 12, the Traefik 502

`proxy:set <app> type traefik` on an app whose `initial-network` is its own network; the plugin has no
attachment logic `[src]`, so the expectation is a 502. This is the evidence under `D_proxy`'s
strongest reason. It installs a plugin the product deliberately does not use, so do it **last in the
phase** and roll the snapshot back afterwards, or leave it to the end of the whole run.

## Phase 3 — the build-dependent half

Four apps, all real, so nothing is invented:

- **`hello`** ← `karibu-helloworld-application-maven`, the cheapest real Java build, for items 8 and 19.
- **`gradle-a`** ← ~~`vaadin-boot-example-gradle`~~ **`karibu-helloworld-application`**, for item 20.
  Changed on the day: the planned repo carries none of the four files README §4 requires, while
  `karibu-helloworld-application` carries all of them, so it goes in unmodified from GitHub and its
  success doubles as a check that the §4 recipe is complete.
- **`vbm-a`** and **`vbm-b`** ← *both* from `vaadin-boot-example-maven`. Deploying one repo under two
  ids is the only way to *guarantee* the shared Maven coordinates item 6 needs; picking two different
  repos and hoping they collide on `1.0-SNAPSHOT` is how that drill gets run inconclusively.

Buildpacks are pinned, never detected — herokuish sees the committed `package.json` and picks nodejs
before java, so relying on detection is a bug (`D_builder`):

```bash
sudo shepherd2 create-app hello https://github.com/mvysny/karibu-helloworld-application-maven \
     --owner mavi@vaadin.com --buildpack heroku/java
```

The four limits need no flags — 256m/1 CPU runtime and 2g/2 CPU build are the defaults as of
2026-09-11.

**These apps will not deploy as they stand, and that is the point of doing it here first.** Two things
have to be in place before the first build is worth watching, both from `README.md` →
*Coming from a Dockerfile* and *Vaadin under herokuish*:

- a **`Procfile`** and, for Maven, a **`system.properties`** in each repo — none of them has either,
  since the predecessor built from a `Dockerfile`;
- ~~**`MAVEN_CUSTOM_OPTS=-DskipTests -Pproduction`**~~ — **wrong, and the run proved it.** Vaadin
  **25.0** dropped the `production` profile; `build-frontend` now runs in the default lifecycle, so
  `mvn install` *is* the production build and the buildpack's default goals already carry
  `-DskipTests`. No config var was set and the app came up in production mode. The advice still holds
  for **Vaadin ≤ 24**, which is why README needs the version split rather than a deletion.

So phase 3's real first finding is the unnumbered one: **does a Vaadin app deploy under herokuish at
all**, and how many rounds of the `Procfile` / `system.properties` / `MAVEN_CUSTOM_OPTS` trio it takes.
Items 8, 19, 13 and 6 all assume that already works. Time-box it and write down what each round needed
— that transcript is the first draft of the migration runbook the nine repos need.

| Item | What to run |
|---|---|
| **8** ports auto-wired | falls out of the first deploy: `dokku ports:report hello` shows `http:80:5000` with nothing in `ports:set`, and survives a rebuild |
| **19** no-op tick churn | decides `Q_poll_churn`. `git:sync --build-if-changes` ×3 with no upstream commit, then `builds:list hello --format json`: three records, `running`/`abandoned`, one `.log` each. Deploy for real, re-list: the three should be `failed` with `exit_code: -1` and the previous real record gone. All three claims are `[src]`-derived — a confirmation, not an open question |
| **13** warm second build | deploy `vbm-a`, commit trivially, `git:sync --build` again, and **split the timing**: Maven resolving out of `/cache/.m2/repository` (expect yes) versus the frontend half — `~/.vaadin` node download, `node_modules`, npm fetches — re-done from scratch (expect yes). Item 15 already says the farm's apps all use the pre-compiled bundle, so this is measurement, not a blocker |
| **6** the two-build drill | the `COMPARISON.md` timing drill, then deploy `vbm-b` and check whether it resolves `vbm-a`'s `1.0-SNAPSHOT` jar. Under `D_builder` this is **impossible by construction** — each app's `.m2` is its own `cache-$APP` volume — so run it once as the demonstration |
| **17** build CPU | see below; the framing in the punch list needs correcting first. Now load-bearing: `--build-cpu 2` is a *default*, so if herokuish ignores it every app builds uncapped |
| **20** the Gradle buildpack | added to the punch list 2026-09-11, and the one genuine hole: everything else assumes Maven while about half the farm is Gradle. Needs a fourth app from a Gradle repo — `vaadin-boot-example-gradle` — with `heroku/gradle` pinned. Which task runs by default, whether `-Pvaadin.productionMode` is the way in, and whether `~/.gradle` lands in the cache volume |

### Item 17 is mis-framed, and it matters for production — **resolved: the documented route works**

The punch list asks whether `--cpus` works at build time via
`docker-options:add <app> build '--cpus 2'` — a question inherited from the Dockerfile builder, where
build CPU genuinely cannot be capped. But `RESEARCH.md` → *Resource limits* already records, `[docs]`,
that **herokuish supports build `cpu` and `memory` both**, so the documented route is the special
`build` process type:

```bash
dokku resource:limit --process-type build --cpu 2 --memory 2g <app>
```

…which is exactly what `create-app --build-cpu` / `--build-mem` already emit (`shepherd2:249`). So what
wanted verifying was not the `docker-options` hack but that the *documented* route takes effect — and it
does: the build container is created with `mem=2147483648` and `nanocpus=2000000000`, and a real build
peaked at **202% CPU on a 4-core host**. The marker is already dropped from `shepherd2:25`; the
punch-list item still needs rewriting when this graduates. `ideas/production-cutover.md` depended on
this one and is unblocked.

## Out of scope here

- **Item 4, the `D_cert` chain** — needs a real DNS zone and an https-mode box; `D_cert` forbids
  converting this one. → `ideas/production-cutover.md`.
- **Item 15** — answered off-box on 2026-09-10 by the operator, not something a VM can add to.
- **Items 9, 14, 16** — v2 (managed Postgres, npm cache warming, relocating `~/.vaadin`). Cheap if the
  box is already up and there is appetite, but nothing in v1 waits on them.

## Where the findings go

Per `CLAUDE.md` → *Ideas & their graduation*, and the reason this note gets deleted rather than kept:

- verified Dokku behaviour → **`RESEARCH.md`**, with the `[unverified]` marker replaced by what was
  actually seen, and the punch-list item struck through the way items 1 and 5 already are
- anything that changes a choice → a **`D_`** entry (item 17 holding would touch `D_builder`'s
  consequences; item 19 settles `Q_poll_churn`, which then graduates out of `ideas/`)
- an operator recipe or a troubleshooting line → **`README.md`**, the exact command in the cheat sheet
- a correction to the install order or a flow → **`SOLUTION.md`**
- the install transcript and the baseline are sidecar files and die with this note — cut the *findings*
  out of them before deleting
