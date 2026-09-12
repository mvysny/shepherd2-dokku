# Going to production — the https box, and the nine apps that move onto it

Written 2026-09-11. **The gate is open**: the http probe run answered items 2, 8, 13, 17 and 19 on a
box the same day, and its findings have graduated into `research.md`, `decisions.md`, `README.md` and
`solution.md` — that note is gone. What is left is the half no http box can reach, item 4, plus the
migration itself — and **as of 2026-09-12 those are two runs, not one**: item 4 moves to a throwaway
https VM against Let's Encrypt staging, and what happens in production is a single issuance and the
nine apps.

This note holds both: the staging rehearsal of the `D_cert` chain, the nine projects that migrate off
the Traefik + Jenkins farm, and the resource profile they run at. It is a scratchpad — the operator
recipes graduate to `README.md`, the profile probably to a `D_` entry, and then this note is deleted.

## Item 4 runs on a throwaway VM, not in production

**Revised 2026-09-12.** This section used to argue the opposite — that the https chain had to be
exercised on the production box, because only the production domain has a DNS zone and the dev VM
"never will". The premise was wrong. What DNS-01 needs is a *zone with API access*, not a public IP
and not the production box, and nothing stops us pointing a throwaway VM at one.

What makes the whole chain portable is in `D_cert`: the wildcard is issued over **DNS-01**, which never
contacts the host. lego writes a `_acme-challenge.<domain>` TXT record through the GoDaddy API, Let's
Encrypt resolves it from public DNS, and the certificate comes back down the connection lego opened. So
the box needs:

- **outbound 443** to the ACME directory and `api.godaddy.com`;
- **outbound 53**, for lego's own propagation check before it tells ACME to validate — if the VM's
  resolver is a libvirt / systemd-resolved stub and that check misbehaves, `--dns.resolvers 1.1.1.1:53`
  is the escape hatch (confirm the spelling against 4.9.1; 4.x renamed the flag at some point);
- **nothing inbound at all.** No port 80/443 forward, no NAT hole, no A record pointing at the VM.

That property is still what makes the *production* run safe — the certificate is obtained while the old
farm is serving and the DNS flip comes last — but it is equally what makes a NAT'd VM on the desk a
legitimate place to run the drills.

### What a real zone is needed for, and what it is not

Only one of the two halves needs anything real:

- **Issuance needs a real, public zone with API access.** The challenge TXT has to be resolvable by
  Let's Encrypt from the internet. `/etc/hosts` cannot help here and there is no way around it.
- **Resolution needs nothing.** Do **not** add a `*.<domain>` A record pointing at the dev VM — that
  aims live traffic at the wrong box. Use `curl --resolve 'probe.<domain>:443:<ip>'` per command rather
  than an `/etc/hosts` line: nothing to clean up afterwards, and curl does no HSTS, so a staging
  certificate cannot pin a production hostname into a browser by accident.

Which zone to hand the VM, in preference order:

1. **A second cheap domain on the *same* GoDaddy account.** Confines issuance, and any pinning, to a
   name nobody is using. Same account *deliberately*: GoDaddy's 2024 API restriction is **per account**
   (`research.md` → *TLS*), so a fresh account bought for isolation would likely lose API access
   outright and fail check 1 for a reason that has nothing to do with us.
2. **The production zone, from the dev VM.** Costs nothing. lego only writes and deletes transient
   `_acme-challenge` records; `@` and `*` are untouched, so the old farm keeps serving throughout.
   Against staging ACME this is harmless.
3. *A Cloudflare zone with a properly scoped token* — rejected. It exercises `--dns cloudflare`, which
   is not the provider we ship, so check 1 would go green without answering the question. It stays what
   `D_cert` already makes it: the fallback if GoDaddy's API access ever bites.

The cost of moving item 4 off production is the one `D_cert` already logs under *Consequences* — the
GoDaddy token is account-wide and can rewrite every zone we own, and now it lives on a throwaway VM as
well. `GODADDY_API_KEY` / `GODADDY_API_SECRET` go in the environment, never in argv (`/proc` is
world-readable); the installer writes them to `/root/.shepherd2-dns-credentials` at 0600, and they must
stay unreadable to the `dokku` user.

### Three things the VM buys that production cannot

- **The forced-renewal drill happens where a mistake costs nothing.** It is the check most likely to
  find a bug, because the renew hook has never executed anywhere.
- **It is the only chance to test `shepherd2-uninstall`'s https branch.** It reads `SHEPHERD_TLS_MODE`
  and tears down lego, the plugin, the cron line and the credentials file — code that has never run and
  that production will never run.
- **HSTS stops being a hazard.** The VM is disposable, so the one-way-ness has nothing to damage. The
  VM still cannot be *promoted* into the production box — `D_cert` makes the mode one-way, HSTS makes
  the downgrade unrepairable, and nothing may offer to convert a running box between the two; a box is
  born `http` or `https` and stays that way. But it was never going to be promoted anyway.

### The run: install against staging

```bash
sudo ./shepherd2-install --domain <TEST-DOMAIN> --mode https --email mavi@vaadin.com \
     --ssh-key /home/mavi/.ssh/id_ed25519.pub \
     --acme-server https://acme-staging-v02.api.letsencrypt.org/directory --yes
```

Staging is what makes the drills repeatable: production caps duplicate certificates at 5 per week and
check 3 burns through that in an afternoon. Its price is that the staging chain roots at Let's
Encrypt's bogus staging CA, so **every curl below is `-k`** and each assertion has to be about the
certificate's *identity* rather than its validity.

### Item 4, the four checks

Nine probe apps first — nine because that is the production farm's size, and check 3 is the one place
the app count matters. See *The probe rig* below; for this run the probe has to **serve** rather than
sleep. Then, in order:

1. **`lego run --dns godaddy` succeeds** with the current GoDaddy key and secret on Ubuntu's packaged
   **4.9.1** (confirmed available; it is what the VM's `universe` offers). Assert the *filenames* too:
   `shepherd2-install` hardcodes `$LEGO_PATH/certificates/_.$DOMAIN.crt` / `.key` into the renew hook,
   and if lego names them otherwise the hook fails silently in sixty days with nobody watching.
2. **`global-cert:set` serves https on an app that already exists.** Assert **issuer and SAN**, not a
   200 — `curl -kv --resolve 'probe.<domain>:443:127.0.0.1' https://probe.<domain>/`, then check the
   issuer is the staging CA and the SAN is `*.<domain>`. That is what separates our certificate from
   Dokku's self-signed default; an app with no certificate refuses 443 outright, so all three outcomes
   stay tellable apart.
3. **A forced renewal re-applies to every app and reloads nginx with no dropped connections.** Run one
   renewal with `--renew-hook 'printenv > /tmp/hook.env'` first and read what lego actually exports —
   never hand the hook `global-cert:set` before that. Then `lego renew --days 3650 …` for real, with a
   load loop running throughout:
   ```bash
   while :; do curl -sk -o /dev/null -w '%{http_code}\n' \
     --resolve "probe.$D:443:127.0.0.1" "https://probe.$D/"; done | tee /tmp/renew.log
   ```
   and count the non-200s. `global-cert:set` re-applies per app and each one rebuilds that app's nginx
   config, so at nine apps this is a rehearsal of the real reload storm rather than one graceful
   reload. This is the check that justifies staging.
4. **An app created but never deployed serves the global cert on its first successful deploy.** Split
   it in two: `create-app` the probe, confirm `dokku certs:report <app>` already shows a certificate
   *at creation*, then deploy and curl. Otherwise a pass conflates "the plugin imported it" with
   "nginx served it". This is why `create-app` touches no certificates — the plugin is supposed to
   cover new apps by itself.

### Two installer changes the run may force

Candidates, not fixes to make in advance; checks 1 and 3 decide:

- **The renew hook hardcodes the certificate paths**, where lego exports `LEGO_CERT_PATH` /
  `LEGO_CERT_KEY_PATH` (`research.md` → *TLS*). Using those would remove the filename guess, but needs
  **single quotes** in the crontab line so the cron shell does not expand them before lego runs the
  hook.
- **A failed renewal is silent.** cron mails root and the box has no MTA. Out of v1 scope, but it is
  the same gap `ideas/build-failure-notifications.md` covers for builds, and belongs as a line there
  rather than being rediscovered in sixty days.

## What is being migrated

The farm as it stands, read off the admin UI on 2026-09-11: **9 projects**, backend Traefik + Jenkins,
max 1 concurrent build, serving at `*.5678912.xyz`. (The docs keep `mydomain.me` as their placeholder;
this is the real target.)

| | Now | Headroom |
|---|---|---|
| Runtime quota | 2304 MB of 4668 MB | 49% |
| Host memory | 2490 MB of 8104 MB | 30% |
| Host swap | 28 MB of 2147 MB | 1% |
| Host disk | 21596 MB of 80307 MB | 26% |

2304 MB over 9 projects is **exactly 256 MB each** — so the farm already runs at the runtime figure
below, and `DEFAULT_MEMORY` was never a guess. Worth keeping: the new box wants at least this machine's
8 GB and 80 GB, and it is only at 26–30% today.

### The nine

Buildpacks are **pinned, never detected** — every one of these commits a `package.json` because Vaadin
says to, and herokuish tries `nodejs` before `java`, so detection picks Node and the build fails
confusingly (`D_builder`, and `README.md` → *Naming the buildpack*). The `-maven` / `-gradle` suffixes
settle four of them outright; `karibu-helloworld-application` is almost certainly Gradle *because* a
separate `-maven` variant exists alongside it, but that is inference. **Read the build file before
registering** — the four marked TBD are unverified guesses, not findings.

| Project id | Repo (`github.com/mvysny/…`) | Buildpack |
|---|---|---|
| `beverage-buddy-ktorm` | `beverage-buddy-ktorm` | TBD — Kotlin, likely `heroku/gradle` |
| `karibu-helloworld-application` | `karibu-helloworld-application` | `heroku/gradle` — **verified**, and rehearsed end to end (below) |
| `karibu-helloworld-application-maven` | `karibu-helloworld-application-maven` | `heroku/java` |
| `vaadin-boot-example-gradle` | `vaadin-boot-example-gradle` | `heroku/gradle` |
| `vaadin-boot-example-maven` | `vaadin-boot-example-maven` | `heroku/java` |
| `vaadin-boot-example-maven-tomcat` | `vaadin-boot-example-maven-tomcat` | `heroku/java` |
| `vaadin-coroutines-demo` | `vaadin-coroutines-demo` | TBD — Kotlin, likely `heroku/gradle` |
| `vaadin-loom` | `vaadin-loom` | TBD |
| `vaadin8-sampler` | `vaadin8-sampler` | TBD — Vaadin 8, the oldest; its JDK pin is the one most likely to need attention |

Ids are kept identical to the old farm's, so every URL survives the move unchanged apart from the
backend behind it. All nine are public, which is what v1 requires — the box holds no git credentials
(`Q_credentials`).

### The cost nobody has paid yet: these repos are not herokuish-ready

The predecessor built **from each project's own `Dockerfile`**, and `D_builder` removed that path
entirely. So before any of these can be registered, each repo needs commits of its own
(`README.md` → *What the repo needs*):

- a **`Procfile`** at the root naming the `web` process — none of them has one, since Jenkins never
  needed it;
- a **`system.properties`** pinning `java.runtime.version`, Maven or Gradle alike — without one the
  buildpack installs the newest LTS JDK, which is 25 today;
- optionally a `.env` for build-time settings the project carries itself.

That is per-repo work in nine *other* repositories, and it is the real gate on the cutover — not the
box. `solution.md` warns that the `Procfile` / buildpack / `system.properties` trio "usually needs a
couple of tries", which is why `create-app`'s steps are ordered to be resumable. Budget for it, and do
one app end to end before touching the other eight.

**One of the nine has now been rehearsed off-box (2026-09-11).** `karibu-helloworld-application`
built and ran green under `gliderlabs/herokuish:latest-24` in plain Docker — the procedure is
`README.md` → *Rehearse the build locally*, and it needs no box, so the other eight can be worked
through the same way before the box exists. What that one repo needed, over and above the list above:

```
.env                  GRADLE_TASK=clean installDist -Pvaadin.productionMode
system.properties     java.runtime.version=21
settings.gradle.kts   rootProject.name = "karibu-helloworld-application"
                      # without it Gradle names the root project after /tmp/build, and the app
                      # installs to build/install/build/bin/build
Procfile              web: env SERVER_PORT=$PORT JAVA_OPTS=-Xmx200m \
                        build/install/karibu-helloworld-application/bin/karibu-helloworld-application
```

**All four live in the repo, which is the point**: the registration is then
`create-app <id> <url> --buildpack heroku/gradle` and nothing else — no config vars to remember per
app, and each repo stays portable to the next box. Three of the four generalise to every Gradle app
on the list, and the `env` prefix to all nine: Vaadin Boot reads `SERVER_PORT`, not `PORT`, and a
`Procfile` line is `exec`'d without a shell. It answered as expected: 200, production mode, Java 21,
153 MB resident against the 256 MB limit — *comfortable but not roomy*, and worth re-measuring per app
rather than assuming.

## The resource profile

Operator's figures, 2026-09-11: **build 2 GB RAM / 2 CPU, runtime 256 MB RAM / 1 CPU.**

**All four are now the CLI's defaults** (operator, 2026-09-11 — the open question this note used to
carry, decided): `DEFAULT_MEMORY` 256m, `DEFAULT_CPU` 1, `DEFAULT_BUILD_MEMORY` 2g,
`DEFAULT_BUILD_CPU` 2, all emitted on every registration rather than left unset. Nine registrations
were nine chances to forget a flag; a default nobody has to remember is worth more than the ability to
leave a limit off by accident. `clear` as a flag value is Dokku's own way to ask for no limit, and is
the escape hatch for the one app that ever needs it.

So every registration reads, with no limit flags at all:

```bash
sudo shepherd2 create-app <id> https://github.com/mvysny/<repo> \
     --owner mavi@vaadin.com --buildpack heroku/java
```

The arithmetic: 9 × 256 MB = **2304 MB** committed at runtime, plus **2 GB** for the single build. One
build runs at a time box-wide (`solution.md`'s poll lock), so the build figure is a box-wide peak and
not a per-app multiplier — the same point `ideas/box-memory-quota.md` makes. About 4.3 GB of 8 GB, which
matches the old farm's 49% quota reading. Nothing here needs `Q_quota`, which stays deferred.

One open point: **the build CPU figure assumes ≥ 4 vCPU on the box**, so that a 2-CPU build leaves
room for nine running apps. The admin UI does not report the old host's core count — check it before
reusing the figure, because it is now a default rather than something typed per app.

And one dependency that is now discharged: `--build-cpu` rested on punch-list item 17, and the VM run
settled it. The documented herokuish route — `resource:limit --process-type build --cpu N`, which is
what `create-app` already emits — reaches the build container as real `nanocpus`, with a build peaking
at 202 % of a 4-core host (`research.md` → *Resource limits*). The profile below is no longer resting
on an unverified flag.

## Cutover order

The DNS-01 property above is what makes this safe, so keep the flip last:

0. **On the throwaway VM, beforehand:** item 4 end to end against staging, then `shepherd2-uninstall`
   to exercise the https teardown. Nothing below starts until this run is green.
1. New box, `--mode https`, **production** ACME — the mechanism already proven, so this is one
   issuance, not five.
2. The nine repos get their `Procfile` / `system.properties` commits — one app first, end to end,
   including a real `git:sync --build` and a look at the running site by `/etc/hosts` override.
3. Register the remaining eight. `shepherd2 wait-idle` between them if the poll is already running:
   one build at a time means nine first builds are serialised, and the Vaadin ones are not fast.
4. Verify all nine over https by `/etc/hosts` override, pointing the old hostnames at the new box —
   the cert is already valid for them, so this is a genuine end-to-end check *before* any user sees it.
   (`curl --resolve` for the scripted half; `/etc/hosts` when you want a browser, which here you do.)
5. Flip the zone's `@` and `*` A records. Watch the renewal cron survive its first real run.
6. Only then retire the old farm. It stays readable on GitHub either way, and nothing is copied out
   of it (`AGENTS.md`).

One thing to check at step 4 rather than discover at step 5: **whether the old farm already serves
HSTS** for these hostnames. If it does, browsers will refuse plain http on the new box — which is fine,
since the new box is https, but it also means there is no falling back to an http box mid-cutover.

## The probe rig, worth reusing for item 4

The http run's most useful tool, kept here because this is the next run that will want it. When the
question is *"what does the build container actually see?"*, building a Vaadin app to find out costs
minutes per attempt; a four-file app on the **`heroku-community/inline`** buildpack — whose whole job
is to run `bin/compile` out of the app's own repo — answers in about five seconds and can print
anything.

```
bin/detect    echo probe
bin/compile   dumps $ENV_DIR, $CACHE_DIR, /proc/self/mountinfo, cgroup limits, env
bin/release   default_process_types: web: sleep infinity
Procfile      web: sleep infinity
```

`buildpacks:set probe heroku-community/inline`, deployed from a `file://` source. Two things the rig
itself taught, both now in `research.md`: the `heroku-community/x` shorthand is rewritten to
`heroku/heroku-buildpack-x` (the org is a fiction of the shorthand) and a buildpack URL cannot be
`file://` the way an app source can; and a `file://` app source must be **owned** by the `dokku` user,
not merely readable by it.

**Item 4 wants the rig twice over, with one change.** The renew hook is the direct analogue — "what
does the hook see?" is a shell script rather than a buildpack, and the answer is the same instinct:
`--renew-hook 'printenv > …'` before `--renew-hook 'dokku global-cert:set …'`.

The other use is the nine apps checks 2–4 need something to be served *on*, and there the probe cannot
`sleep infinity` — it has to answer on `$PORT`. `Procfile: web: python3 -m http.server $PORT` on the
same inline buildpack deploys in seconds where a Vaadin app costs minutes, and nine of them make check
3's reload storm real. Confirm `python3` is on the heroku-24 stack image; the fallback is `heroku/python`
with an empty `requirements.txt`, which costs a runtime download but nothing else.
