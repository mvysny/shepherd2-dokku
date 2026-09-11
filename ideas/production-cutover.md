# Going to production — the https box, and the nine apps that move onto it

Written 2026-09-11. **Gated on `ideas/http-probe-plan.md` coming back green** — specifically items 2,
8, 13, 17 and 19. Nothing here starts before that.

This note holds the cutover: the one place the https half of the punch list gets run, the nine projects
that migrate off the Traefik + Jenkins farm, and the resource profile they run at. It is a scratchpad —
the operator recipes graduate to `README.md`, the profile probably to a `D_` entry, and then this note
is deleted.

## Why https is tested in production, of all places

Operator's call, 2026-09-11. It is less reckless than it sounds, and the reason is in `D_cert`: the
wildcard is issued over **DNS-01**, which never contacts the host. So the certificate needs a real DNS
zone with API access — which the production domain has and the dev VM never will — but it needs *no
inbound connectivity to the new box*. The whole https chain can therefore be exercised on the new box
while the old farm is still serving traffic, and the DNS flip comes last.

The dev VM cannot be promoted into this: `D_cert` makes the mode one-way, HSTS makes the downgrade
unrepairable from the box, and nothing anywhere may offer to convert a running box between the two. A
box is born `http` or `https` and stays that way.

**Issue against Let's Encrypt staging first.** Production caps duplicate certificates at 5 per week and
punch-list item 4's forced-renewal drill burns through that in an afternoon:

```bash
sudo ./shepherd2-install --domain <DOMAIN> --mode https --email mavi@vaadin.com \
     --ssh-key /home/mavi/.ssh/id_ed25519.pub \
     --acme-server https://acme-staging-v02.api.letsencrypt.org/directory --yes
```

`GODADDY_API_KEY` / `GODADDY_API_SECRET` go in the environment, never in argv — `/proc` is
world-readable. The installer writes them to `/root/.shepherd2-dns-credentials` at 0600; that token can
rewrite the whole zone, which makes it a bigger secret than the certificate it produces, and it must
stay unreadable to the `dokku` user.

### Item 4, the four checks

Once staging issuance works, re-run against production and then confirm, in order:

1. `lego run --dns godaddy` succeeds with the current GoDaddy key and secret on Ubuntu's packaged
   **4.9.1** (confirmed available; it is what the VM's `universe` offers).
2. `global-cert:set` with the result serves https on an app that already exists.
3. A **forced renewal** — `lego renew --days 3650 --renew-hook …` — re-applies to every app and reloads
   nginx with no dropped connections. This is the one that justifies staging.
4. An app **created but never deployed** serves the global cert on its first successful deploy. This is
   why `create-app` touches no certificates: the plugin is supposed to cover new apps by itself.

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
| `karibu-helloworld-application` | `karibu-helloworld-application` | TBD — likely `heroku/gradle` (a `-maven` sibling exists) |
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
- for the Maven projects, a **`system.properties`** pinning `java.runtime.version`;
- optionally a `.env` for build-time settings the project carries itself.

That is per-repo work in nine *other* repositories, and it is the real gate on the cutover — not the
box. `SOLUTION.md` warns that the `Procfile` / buildpack / `system.properties` trio "usually needs a
couple of tries", which is why `create-app`'s steps are ordered to be resumable. Budget for it, and do
one app end to end before touching the other eight.

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
build runs at a time box-wide (`SOLUTION.md`'s poll lock), so the build figure is a box-wide peak and
not a per-app multiplier — the same point `ideas/box-memory-quota.md` makes. About 4.3 GB of 8 GB, which
matches the old farm's 49% quota reading. Nothing here needs `Q_quota`, which stays deferred.

One open point: **the build CPU figure assumes ≥ 4 vCPU on the box**, so that a 2-CPU build leaves
room for nine running apps. The admin UI does not report the old host's core count — check it before
reusing the figure, because it is now a default rather than something typed per app.

And one dependency: `--build-cpu` rests on punch-list item 17, which the VM run settles first.
`ideas/http-probe-plan.md` argues the item is mis-framed and that the documented herokuish route
(`resource:limit --process-type build --cpu N`) is what `create-app` already emits — but **do not put
the production profile on an unverified flag**. If 17 fails, build CPU is uncapped in production until
something else caps it.

## Cutover order

The DNS-01 property above is what makes this safe, so keep the flip last:

1. New box, `--mode https`, **staging** ACME. Item 4's checks 1–3.
2. Re-issue against production ACME. One issuance, not five.
3. The nine repos get their `Procfile` / `system.properties` commits — one app first, end to end,
   including a real `git:sync --build` and a look at the running site by `/etc/hosts` override.
4. Register the remaining eight. `shepherd2 wait-idle` between them if the poll is already running:
   one build at a time means nine first builds are serialised, and the Vaadin ones are not fast.
5. Verify all nine over https by `/etc/hosts` override, pointing the old hostnames at the new box —
   the cert is already valid for them, so this is a genuine end-to-end check *before* any user sees it.
6. Flip the zone's `@` and `*` A records. Watch the renewal cron survive its first real run.
7. Only then retire the old farm. It stays readable on GitHub either way, and nothing is copied out
   of it (`CLAUDE.md`).

One thing to check at step 5 rather than discover at step 6: **whether the old farm already serves
HSTS** for these hostnames. If it does, browsers will refuse plain http on the new box — which is fine,
since the new box is https, but it also means there is no falling back to an http box mid-cutover.
