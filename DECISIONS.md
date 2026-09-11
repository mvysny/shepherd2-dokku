# DECISIONS.md

A living record of the design decisions behind Shepherd2 — especially the *roads not taken*. It exists
because the code and its comments record *what* the box does and `README.md` records *how to operate
it*, but the rationale for the alternative that was rejected has nowhere else to live, and that
rationale is what a future maintainer (or agent) actually needs before "simplifying" something
load-bearing.

It is the *why-we-chose* record. It is **not** the operator guide (`README.md`), the
what-you-must-not-break orientation (`CLAUDE.md`), the what-Dokku-does reference (`RESEARCH.md`), or a
scratchpad for undecided things (`ideas/`). When a fact belongs in one of those, put it there and link —
see *Documentation targets* in `CLAUDE.md`.

**Format.** One entry per decision. The ID is a slug, not a number: `D_` (says "this is a decision")
plus a 1–4-word hint at the subject (`D_dokku`), so a reference carries meaning on its own — a running
counter would not, and renumbering silently invalidates every existing reference. **Underscores
throughout, never hyphens**: the id has to be one *token*, so that vim's `w` / `*` / `ciw` and
`grep -w` act on the whole thing rather than on a fragment. Backtick it in prose, both because some
downstream Markdown parsers italicise intraword `_` and because a backticked id is copy-pasteable into
a search. The `(date)` on the heading is *decided* provenance, not a log position; git owns the edit
history, so don't narrate how an entry used to read. Keep each entry tight: context, the decision, the
alternatives rejected and why, and the consequences a future maintainer would trip over. A decision is
worth logging the moment it's *made* — implementation can lag, and the `Status:` line says which.

**Entries are mutable — edit in place, don't append addendums.** Each entry is the single coherent home
for one *live* decision; keep it current as the decision is refined or extended. Two things that does
*not* license:

- **The roads-not-taken stay.** "We chose X, rejected Y because Z" is live content of the current
  decision, not stale history — never edit it away. It is the most valuable thing in the file.
- **A reversed *shipped* decision forks a tombstone, it is not overwritten.** When something was
  deployed and then thrown away, leave the old entry as the scar, set its `Status:` to
  **Superseded by `D_<slug>`**, and write the replacement fresh. The line: *refined or extended* → edit
  in place; *reversed after shipping* → tombstone + new entry.

**Only decisions already made.** An entry records a position this project has actually taken — shipped,
or accepted and awaiting implementation (that is what `Status:` is for). Speculative features, ideas and
"we might one day" belong in `ideas/`, never here; a TODO is not a decision. The one adjacent case that
*is* in scope is a rejected alternative, which is a road not taken **within** a decision already made,
not an open question.

**Inherited history lives upstream.** Shepherd2 is the third implementation of the same product. The
decisions of the first two — Kubernetes (`D_kubernetes`), then plain Docker + Traefik
(`D_docker_traefik`, `D_network_per_project`, `D_poll_scm`, `D_no_shared_cache`) — are recorded in
[shepherd-traefik's `DECISIONS.md`](https://github.com/mvysny/shepherd-traefik/blob/main/DECISIONS.md)
and are **not** copied here. Cite them by slug with that repo named, e.g. "see `D_no_shared_cache` in
shepherd-traefik". A `D_` heading in *this* file is always a Shepherd2 decision.

---

## D_dokku — Rebuild on Dokku instead of maintaining our own PaaS (2026-09-09)

**Status:** Accepted 2026-09-09, and **implemented**: this repo is the implementation, and on
2026-09-11 a dev VM was installed from it in `http` mode, ran four real apps, and was torn down again.
What that run did *not* touch is the https half — see `D_cert`.

**Context.** Shepherd-Traefik works, but every part of it is ours to maintain: a Jenkins container per
box, a `docker-compose.yaml`, five Bash scripts, a Traefik network-reattachment repair tool, and a
separate Java/Kotlin project (shepherd-java-client) supplying the CLI and web admin. The product it
delivers — build a git repo, run it as a container at `https://PROJECTID.<domain>` — is a solved,
commodity problem with several mature open-source implementations.

**Decision.** Retire Shepherd-Traefik and rebuild the same product on **Dokku** (MIT, v0.38.x), keeping
Dokku upstream and unforked. Our deliverable is the *glue*: the host setup, the per-project convergence,
the periodic-rebuild trigger, the wildcard-TLS story and the housekeeping crons.

**Why Dokku and not the alternatives.** The full survey — Coolify, Dokploy, Dokku, CapRover, and the
filtered-out Kamal / Piku / Kubero — is
[`COMPARISON.md` in shepherd-traefik](https://github.com/mvysny/shepherd-traefik/blob/main/COMPARISON.md),
which owns the `R_` requirement boxes and the per-product citations. Not restated here. The short form
of why the verdict landed on Dokku:

- **It subtracts rather than substitutes.** `dokku git:sync --build-if-changes` is a literal SCM poll,
  so Jenkins — the heaviest single component of the old box — is deleted for one crontab line. Plain
  Docker, no Swarm, no control-plane database, no Postgres to upgrade.
- **Bash + Go plugins is the smallest conceptual delta** from Bash + compose.
- **It is the only one that accepts our build command.** `docker-options:add <app> build '--cache-to …'`
  reaches `docker image build` through a flag allowlist, so the per-project build cache is kept rather
  than traded away — the one requirement none of the other three can meet.
- **Nothing is hidden.** State is files under `/home/dokku` plus Docker; every operation is a command
  whose output can be read (`--format json` on the reports).

**Alternatives rejected.**

- *Keep maintaining Shepherd-Traefik.* The status quo works, and rejecting it costs real features —
  the regressions are under *Consequences*, and `D_builder`, `D_cert` and `D_single_operator` each name
  what their own subject cost. Rejected because the maintenance surface — two repos, a Jenkins, a JVM
  web app, a network-repair script — is out of proportion to a box hosting demo apps.
- *Coolify.* Checks every box on plain Docker with the largest community, a REST API and an official Go
  CLI — but four mandatory containers idling at ~1 GB before a single app is deployed, and a
  demonstrated willingness to break the build cache by injecting per-build args. Rejected on footprint.
- *Dokploy.* The best fit if a web UI were non-negotiable, and its native cron *Schedules* would make
  periodic rebuild in-product. Rejected on Docker Swarm (which also makes container TUIs show churning
  task IDs instead of apps), a proprietary subdirectory in an otherwise Apache-2.0 repo, and being
  pre-1.0 when the deliverable is written against it.
- *CapRover.* Weakest match: wildcard/DNS-01 and resource limits both need hand-written overrides, and
  it cannot pass extra flags to `docker build` at all.
- *Kubernetes, in any distribution.* Already tried and thrown away once — see `D_kubernetes` in
  shepherd-traefik. Not on the table.

**Consequences.**

- **The naming contract is deleted, not ported.** `shepherd_PROJECTID` / `shepherd/PROJECTID` /
  `PROJECTID.shepherd` existed because there was no scheduler or registry, so the name *was* how a
  container was found again. Dokku owns naming now. Do not reintroduce a naming contract.
- **Jenkins goes; the build history does not go with it — corrected 2026-09-09.** Dokku's core `builds`
  plugin (new in 0.38.0) records every deploy and keeps its log on disk, 20 per app by default, and the
  capture is trigger-independent — so `git:sync` from our rebuild cron is recorded like a `git push`
  (`RESEARCH.md`, *Build tracking*). The per-project build list and build log that the Web Admin shows
  today have a direct upstream counterpart in `builds:list` / `builds:output`. What is genuinely lost is
  the *browser* view of them (`D_retire_shepherd_java`) and the git SHA per build, which Dokku's record
  does not carry.
  - **Amended 2026-09-10, and this one is a real dent:** "20 per app" is 20 *records*, and a
    `--build-if-changes` tick that finds nothing writes one too — so under the five-minute poll the
    default window holds ~95 minutes of no-op ticks and prunes real build logs out from under itself
    (`RESEARCH.md`, *Build tracking*). The upstream counterpart is therefore only as good as our poll
    is quiet. It does not change the choice — Jenkins is not coming back — but the sentence above
    over-promised, so read it with `D_poll_churn` attached, which is where the window, the way to read
    past the noise, and the upstream report live.
- **Build cache isolation is *not* a regression, which is a large part of why Dokku won.** The
  Dockerfile builder allowlists `--cache-to`/`--cache-from` and appends them to `docker image build`, so
  today's per-project `type=local` cache directory migrates as one `docker-options:add` per app —
  enforced on the build command, exactly as `shepherd-build` enforces it now (`RESEARCH.md`,
  *Build caching*). Coolify, Dokploy and CapRover expose no such knob. What does *not* carry over is the
  `RUN --mount=type=cache` half: the app writes its own Dockerfile and so names its own mount ids, which
  stays a convention rather than a boundary — the same known gap `D_no_shared_cache` in shepherd-traefik
  already records, neither widened nor closed by the move.
- **Build CPU cannot be limited** with the Dockerfile builder — memory can. Documented `✗` upstream.
- **One thing gets strictly better:** Dokku's nginx runs on the *host*, not in a container, and reaches
  apps by container IP. That deletes shepherd-traefik's network-sharing gotcha — and with it
  `shepherd-traefik-connect-networks` — outright. Per-app network isolation becomes opt-in rather than
  fragile. Both halves of that are now decisions of their own: `D_proxy` (keep the host nginx) and
  `D_isolation` (take the isolation it makes cheap).
- **A second thing gets better:** `dokku-postgres` makes the per-project Postgres service that was a
  README TODO for two implementations a two-command feature.

## D_retire_shepherd_java — No web admin, no Java; Dokku's CLI is the interface (2026-09-09)

**Status:** Accepted 2026-09-09 in principle. The shape of the CLI replacement is settled by
`D_dokku_is_truth` (2026-09-10); whether any browser UI returns is still `Q_web_admin` in
`ideas/web-admin-ui.md`. What is decided here is that shepherd-java-client is not carried forward.

**Context.** [shepherd-java-client](https://github.com/mvysny/shepherd-java-client) supplies today's
Vaadin web admin, the `shepherd-cli` command-line client, and the `ShepherdClient` library on Maven
Central. It also holds real behaviour that lives nowhere else: the single-file project descriptor,
box-wide memory-quota validation at project-creation time, reserved project ids, the
"which change needs which kind of restart" logic, and Google-SSO-gated multi-user login. Keeping it as
a front-end over Dokku was a live option — `COMPARISON.md` explicitly notes that driving a platform by
issuing commands and parsing output is already how it drives Docker and Kubernetes today.

**Decision.** Retire it. **Dokku's own CLI, over SSH, is the administration interface**, and Shepherd2
ships no JVM component. Whatever glue Shepherd2 needs is written in the same language as the rest of the
box.

**Alternatives rejected.**

- *Keep the Vaadin Web Admin and reimplement its backend against Dokku.* The most feature-preserving
  option, and the only one that keeps a browser UI. Rejected because it keeps a second repo, a JVM
  runtime and a Gradle build alive to administer a box whose whole point is being small — and because
  `R_admin_interface` was relaxed to accept a CLI precisely so this could go.
- *Dokku Pro.* The official web UI. Proprietary, paid, licence-checked against the public internet.
  Rejected: replacing a component we own with a paid closed one is the wrong direction.
- *A third-party Dokku web UI.* `wharf` is alive (262★, AGPL-3.0, single-maintainer); `ledokku` — 642★,
  MIT, and the one Dokku itself endorsed in 2021 — died in 2023, as did `atlas` and `HarborJS`.
  Rejected on the pattern, not on any single row: this is a component class with a demonstrated death
  rate, and swapping a dependency we control for one we don't on exactly that class is a bad trade.

**Consequences.**

- **No browser UI at all**, unless a later decision reverses this. Administration is `ssh dokku@host …`
  and whatever local scripts this repo grows.
- **Google SSO and the multi-user registry go away.** Access control becomes SSH keys
  (`dokku ssh-keys:add`, where a key name containing `admin` is privileged) — and that is *less* than it
  sounds: core Dokku has no app ownership, so every authorised key may run every command against every
  app. Per-user scoping would have to be built on the `user-auth` trigger. See *Users and access
  control* in `RESEARCH.md`; `D_single_operator` scopes v1 to one keyholder and leaves per-user
  ownership to v2 (`Q_multi_user` in `ideas/multi-user-ownership.md`).
- **Five behaviours lose their only home** and must each be re-provided, re-scoped or consciously
  dropped: the project descriptor, the box-wide memory quota, reserved ids, the smart-update logic, and
  the graceful "safe to reboot" wait. None has a Dokku counterpart. `D_dokku_is_truth` settles the first,
  second and fourth (descriptor and smart-update dropped, quota deferred to v2); reserved ids came back
  broadened as `D_admin_namespace`, and the safe-reboot wait is `shepherd2 wait-idle`.
- **The Maven Central artifact `com.github.mvysny.shepherd:shepherd-java-api` stops gaining versions.**
  Already-published versions stay published; nothing here replaces the library.

## D_research_md — Dokku's behaviour gets a durable file, not an ideas sidecar (2026-09-09)

**Status:** Accepted 2026-09-09; implemented as `RESEARCH.md`.

**Context.** This project is mostly glue around a product we don't own, so a large share of its
knowledge is *findings about Dokku* — what a command does, which flag exists on which version, which
documented feature turns out not to work. The `ideas-folder` convention says an idea's research goes in
a same-stem sidecar folder and **dies with the idea**, while "verified behaviour goes to the project's
durable place". For a glue project there was no such durable place: upstream behaviour is not our
decision (`DECISIONS.md`), not an operator instruction (`README.md`), and not a per-script truth.

**Decision.** One durable, top-level **`RESEARCH.md`** owns everything established about Dokku, with
each claim marked `[docs]`, `[src]` or `[unverified]`. Idea sidecars stay for reasoning that dies with
the idea — why an alternative was rejected, whether a blog post was accurate. A *fact about Dokku* is
backported to `RESEARCH.md` before the idea is deleted.

**Alternatives rejected.**

- *Research in `ideas/<name>/` sidecars only.* The skill's default, and correct when research serves one
  idea. Rejected here because the same Dokku facts serve every idea, and a sidecar is deleted at
  graduation — the box-verified answer to "does `initial-network` isolate apps?" would be lost with the
  idea that prompted asking.
- *Fold it into `README.md`.* Puts an operator reading an install step next to a paragraph on which
  version of a plugin gained DNS-01 support. Different audience, different lifetime.
- *Fold it into `DECISIONS.md`.* Upstream behaviour is not a decision of ours, and it changes when Dokku
  releases — whereas an entry here is stable once made.

**Consequences.**

- **`RESEARCH.md` is the fifth documentation target**, and the graduation map in `CLAUDE.md` names it as
  the destination for verified Dokku behaviour.
- **It has a shelf life.** Claims are dated and version-stamped against a Dokku release; a claim about a
  version we no longer run is stale, not history. Re-check before relying on anything version-sensitive.
- **`[unverified]` is load-bearing.** It is the marker that separates "Dokku's docs say" from "we saw it
  work", and *Questions only a box can answer* at the end of the file is the punch list built from it.

## D_proxy — Dokku's default host nginx, not the Traefik plugin (2026-09-10)

**Status:** Accepted 2026-09-10, **its central risk measured on a box 2026-09-11** (punch-list 12).
Nothing to implement — nginx is Dokku's default, so this decision is mostly a commitment *not* to do
something. `D_isolation` depends on it.

**Context.** Dokku ships five proxy implementations and nginx is the default; the official `traefik`
plugin is one of the alternatives, switched on per app with `proxy:set <app> type traefik`. Traefik was
the obvious candidate because shepherd-traefik *is* a Traefik box — the labels, the DNS-01 config and
the failure modes are all knowledge this project already has, and "keep the part that works" was a real
option rather than a straw man.

**Decision.** Use **nginx**, Dokku's default. No app sets `proxy:type` and `traefik:start` is never
run. Note that there is no plugin to refrain from installing: `traefik-vhosts` is a Dokku *core*
plugin, shipped and enabled by the deb, so it sits on every Shepherd2 box unused.

**Why.** The two are not symmetric, and every asymmetry runs the same way:

- **nginx is a host process; Traefik is a container.** nginx dials app containers at `IP:PORT` from
  `.DOKKU_APP_<PROC>_LISTENERS`, so it needs no Docker network membership at all, and
  `dokku-event-listener` rewrites its config when a container IP changes. This is the single biggest
  architectural gain of the whole Dokku move (`D_dokku`), and it is what makes `D_isolation` free.
- **The Traefik plugin has no network-attachment logic whatsoever** — no `docker network connect`, no
  read of an app's `initial-network` / `attach-*` properties (`plugins/traefik-vhosts/internal-functions`
  **[src]**). So a per-app isolated network is unreachable by it, and repairing that would be
  `shepherd-traefik-connect-networks` reincarnated as ours. **Choosing Traefik would cost either
  the per-project network isolation or a reconciler cron** — exactly the script `D_dokku` celebrates
  deleting.

  **Measured, and the failure mode is worse than this entry originally assumed.** It is not a 502: the
  request **hangs** until Traefik's own timeout, because packets to a network it has no route to are
  dropped rather than refused, and **nothing appears in `traefik:logs`**. A 502 is diagnosable in
  seconds; a silent hang with empty logs is the worst diagnostic shape there is, so the cost of
  switching proxies without re-reading this entry is higher than "it breaks" — it is "it breaks
  invisibly". `RESEARCH.md` → *Traefik (official plugin)* has the run, the controls and the generated
  compose file.
- **Per-app ingress tuning is first-class on nginx and absent on Traefik.** `nginx:set <app>
  client-max-body-size` / `proxy-read-timeout` are app-scoped properties, where **every `traefik:set`
  property is global-only** — per-app tuning would have to be hand-written
  `traefik:labels:add` directives. Per-project body size and read timeout are a feature both
  predecessors ship.
- **Traefik forecloses two of the three TLS routes.** "Managed certificates provided by the `certs`
  plugin are ignored" under Traefik, which rules out `dokku-global-cert` and the `certs` plugin
  outright. See *Consequences* for what that does to the choice of TLS route.
- Two smaller Traefik restrictions: only `web` containers get labels injected, and only `http:80` /
  `https:443` port mappings are supported.

All five are in `RESEARCH.md` (*Proxies*), which owns the citations.

**Alternatives rejected.**

- *The official Traefik plugin.* Rejected on the four asymmetries above. What it genuinely buys, and
  what we are giving up: ACME renewal becomes Traefik's problem rather than a cron of ours (as it is
  today), which is route 3 in `RESEARCH.md` → *TLS* — at the price of per-app ACME orders and no
  declared wildcard SAN. Familiarity was the strongest argument for it and is not enough: the
  knowledge that transfers is knowledge of a component we were trying to stop maintaining.
- *Keep both — nginx globally, Traefik for one app that needs it.* Dokku allows this (`proxy:type` is
  per app). Rejected because the two proxies have disjoint TLS stories, so a mixed box would need both
  cert mechanisms alive at once; and because a per-app exception is exactly the kind of state that is
  invisible until it breaks.
- *A proxy of our own in front of Dokku's.* Not seriously considered — it re-creates the component
  `D_dokku` deleted.

**Consequences.**

- **The TLS question narrows to two routes, not three** (`RESEARCH.md` → *TLS* has all three,
  `D_cert` the answer). `dokku-global-cert` (one wildcard cert we renew) and `dokku-letsencrypt`
  (per-app ACME, renewal solved upstream) both stay available; the Traefik DNS-01 route is gone.
  That is the intended direction — the requirement as written asks for one wildcard cert — but it is
  now foreclosed rather than merely unchosen. `D_cert` has since taken the first of the two.
- **Per-project ingress tuning is preserved** as `nginx:set <app> client-max-body-size` /
  `proxy-read-timeout`, and `README.md`'s cheat sheet is where an operator finds it.
- **nginx is an apt package on the host**, so it is part of what a box reinstall must reproduce, and
  Dokku's own bootstrap installs it. Nothing for us to configure beyond `nginx:set`.
- **The `proxy` plugin's other implementations stay unused but present.** If a future need forces
  Traefik, this entry is the thing to re-read — and `D_isolation` has to be re-read with it, because it
  is the dependent decision.
- **Trying Traefik is not a per-app experiment; it takes the box down.** Its compose file asks for host
  port `80:80`, which Dokku's nginx already holds, so `traefik:start` requires stopping nginx — every
  app on the box goes dark for the duration. Anyone tempted to "just test it on one app" should know
  that the blast radius is all of them.

## D_isolation — One Dokku-managed bridge network per project (2026-09-10)

**Status:** Accepted 2026-09-10, **confirmed on a box 2026-09-11**. The central claim — `initial-network`
isolating apps while leaving nginx routing intact — was run with the before/after and a self-reach
control, and holds; so does the per-app network for a *build* container, and (item 9, run early) an
app's own Postgres. The claim about the Traefik proxy is item 12, which belongs to `D_proxy`.

**Context.** The box hosts other people's example projects and addons — mutually untrusted code, on one
Docker daemon. Both predecessors gave each project its own network (`D_network_per_project` in
shepherd-traefik), and in shepherd-traefik that isolation was the *most expensive* thing on the box: a
container proxy had to join every app network, lost those attachments whenever it was re-created, and
needed `shepherd-traefik-connect-networks` to repair the 502s. Dokku's default is the opposite of
isolated — "apps will default to being associated with the default `bridge` network", where any app can
reach any other app's unpublished ports by container IP.

**Decision.** One bridge network per project, created and attached through Dokku:

```bash
dokku network:create app-<id>
dokku network:set    <app> initial-network app-<id>
dokku postgres:create <svc> --initial-network app-<id>   # v2 only — the database is deferred, and this
                                                         #   flag is the one thing it must not forget
```

The requirement this delivers, stated honestly: **no app can reach another app's non-public ports.**
(The old wording added "or the admin plane"; there is no longer an admin plane — see *Consequences*.)

**Why this shape.** Dokku's `network` plugin contributes *membership and nothing else* —
`network:create` is a wrapper over `docker network create --attachable --label …` and accepts no driver
options, and there are no ACLs, no per-port policy and no egress rules anywhere in Dokku. So the
boundary is whatever a Docker bridge gives, and the design question is only *which* networks exist. Two
properties of Dokku's version make the predecessor's price disappear:

- **Membership is managed state, not a live attachment.** `initial-network` is a persisted app property
  re-applied every time Dokku creates a container, so it survives deploys, `ps:restart`, rebuilds and
  reboots; `network:rebuild` / `network:rebuildall` re-assert on demand. Nothing of ours needs to
  re-assert it — which `D_dokku_is_truth` later made a requirement rather than a convenience.
  **Every** container Dokku creates for the app, which the box showed includes the *build* container:
  a build in flight is on the project's own network, so the isolation covers untrusted code while it
  is being compiled and not only once it is running.
- **The proxy needs no membership at all** — `D_proxy`. Between them, **`shepherd-traefik-connect-networks`
  has no successor in this repo.** That is the whole reason this decision is cheap here and was not
  cheap before.

**Alternatives rejected.**

- *Accept Dokku's shared default bridge.* Free, and one fewer moving part. Rejected: it is the only
  option that gives up a feature both predecessors shipped, and the mitigation people reach for — "the
  default bridge has no DNS, so apps can't find each other" — is not a boundary. A container IP is
  enough, and they are guessable.
- *One shared network with inter-container communication filtered off* (`enable_icc=false`, app↔app
  dropped in the host's `FORWARD` chain). Genuinely available here and worth recording as a road not
  taken, because it is **structurally impossible on the Docker Swarm sibling** — a Dokku app's bridge
  lives in the root network namespace, so host netfilter sees app-to-app traffic, where intra-overlay
  traffic never does. **Measured on a box 2026-09-11, and it works**: `initial-network` accepts a
  hand-made `icc=false` network, the app routes, and two apps sharing that one network isolate exactly
  as two per-app networks do (`RESEARCH.md` → *Networking and app isolation*). So this is a live option
  rejected on judgement, not a dead end — and the three counts against it survive the measurement with
  one correction:
  - `network:create` passes no driver options, so the network is a hand-made `docker network create
    -o …`. **The correction:** Dokku does not spit it out — it accepts it as `initial-network` and
    lists it, merely excluding it from `network:list --dokku-managed`. What is true is narrower and
    still decisive: the network is outside Dokku's model in the sense that *nothing in a reinstall
    recreates it*, so the box stops being reproducible from this repo alone.
  - Topology beats filtering for untrusted code: under per-app networks app A cannot *address* app B,
    and there is nothing left to filter.
  - An iptables rule can be silently absent with nothing in Dokku noticing, where a missing
    `initial-network` is visible in `network:report`.

  Its one advantage was avoiding the address-pool ceiling — one subnet rather than one per app — which
  is real but bought at install time instead, by a line in `daemon.json` that takes the ceiling from 29
  to 4096.
- *The sibling's n+1 shape* — per-app networks **plus** a separate network for the admin plane. Not
  needed: Dokku's control plane is a host binary and a git remote, with no dashboard container, no
  control-plane database and no published admin port to move off the app wire.
- *`attach-post-create` / `attach-post-deploy` instead of `initial-network`.* A category error worth
  naming, because the plugin's tutorial recommends `attach-post-create` and it looks interchangeable:
  the `attach-*` properties **add** networks, so an app with only those set is still on the shared
  bridge. They are for reachability; only `initial-network` isolates.

**Consequences.**

- **`/etc/docker/daemon.json` needs enlarged `default-address-pools`, at install time.** A stock daemon
  walls at **29** bridge networks — measured, not estimated (`RESEARCH.md` → *Networking and app
  isolation*) — i.e. 29 apps. This is precedent, not a new cost — shepherd-traefik already does it —
  but it needs a daemon restart, so it belongs in the installer and cannot be retrofitted cheaply.
  The file is **already there** when the installer reaches it: not from Docker's package, as this entry
  once guessed, but from Dokku's own postinst setting `live-restore`. So both installers edit a file
  they share with Dokku, which is where their `python3` dependency comes from.
- **A project's database must be created with `--initial-network` — a v2 obligation this entry records
  in advance.** The managed database is deferred to v2 (2026-09-10), so v1 creates no services and
  this costs nothing yet; it is written down because the flag is *creation-time only*. A service
  created without it sits on the shared bridge, where the app can no longer reach it under this
  decision, and the repair is `postgres:set <svc> post-create-network`. `postgres:link` additionally
  adds a legacy `--link`, whose behaviour on a user-defined bridge is `[unverified]` (punch-list item
  9, now a v2 question).
- **Project teardown grows a step:** `network:destroy app-<id>` after `apps:destroy`, or the box leaks
  a Docker network per project destroyed.
- **This decision depends on `D_proxy`.** Under the Traefik plugin it would cost either the isolation or
  a reconciler cron. Do not switch proxies without re-reading both entries.
- **Two things isolation does not buy, both now measured** (2026-09-11, `RESEARCH.md` → *Networking and
  app isolation*). The L7 front door stays open — any app can reach nginx by the bridge gateway IP and
  ask for another app's vhost with a `Host:` header: **200**, confirmed, and harmless because that
  surface is public anyway. And **the host stays reachable**, with a sharper edge than this entry
  assumed: a host service bound to `0.0.0.0` answered a container on the gateway address, one bound to
  `127.0.0.1` did not. So the exposure is exactly "whatever the operator binds to all interfaces", and
  the cheap half of the mitigation needs no firewall at all — bind admin things to loopback. The rest
  of that axis needs a `DOCKER-USER` rule and is **deferred to v2** (2026-09-10) — see
  `ideas/harden-container-egress.md`, which also records the two things v1 must not do if that fix is to
  stay cheap: no firewall state on the per-app path, and a deliberately chosen address pool, since the
  pool subnet is probably what the rule matches on. It is also where the sibling's "app → admin plane"
  concern lands here.
- **Egress is unfiltered**, same note.

## D_dokku_is_truth — Dokku's own state is the source of truth; Shepherd2 supplements it, never fronts it (2026-09-10)

**Status:** Accepted 2026-09-10, **implemented and exercised on a box 2026-09-11**. The two
source-level facts it leans on (what `git:sync` persists; `apps:set` having no metadata slot) held in
practice: four projects were registered, polled, rebuilt and destroyed with no descriptor of ours
anywhere, and every project fact read back out of `dokku *:report`.

**Context.** shepherd-java's per-project JSON file was the source of truth, and a control plane converged
Docker onto it, because there was nothing else to converge onto: plain Docker has no persisted per-app
configuration. The open design question was whether to carry that shape forward — a descriptor per
project plus a converger script — or to run the box from a runbook. Dokku changes the premise: it *is* a
persisted, idempotent, per-app state store with `--format json` reports on every plugin. The question
became whether to keep a second one on top of it.

**Decision.**

- **Dokku's state is the single source of truth for every project.** No descriptor file, no converger,
  no per-project file of ours anywhere on the box or in this repo.
- **The two facts Dokku has no slot for live in Dokku anyway, as config vars**, set by `create-app` with
  `config:set --no-restart`: `SHEPHERD_GIT_URL` (what the poll fetches) and `SHEPHERD_OWNER` (a contact).
  These are the *only* per-project data Shepherd2 owns, and the `SHEPHERD_` prefix is the only naming
  contract it keeps.
- **Shepherd2 provides exactly what Dokku has no single command for**: `create-app` and `destroy-app`
  (the multi-command, partly non-idempotent sequences), `poll` (serial, under a lock, iterating
  `apps:list` and calling `git:sync --build-if-changes` with each app's URL), `rebuild` (the forced
  variant, `--build`), `wait-idle` (block until no build is running, so a reboot never lands
  mid-build), `clearcache` (the weekly prune), and the box-level crons and installer. **Everything
  else is `dokku` itself** — logs, build output, restart, config, domains, ingress tuning, limits —
  listed in `README.md` as a cheat sheet from feature to command.
- **Shepherd2 never wraps a command Dokku already has.**

**Why.**

- **A reconstruction test almost passes.** Every project fact comes back from `*:report --format json`
  except two: the owner, which Dokku has no concept of, and the poll URL after a first build that
  failed (below). A descriptor would be a copy of everything else.
- **An authoritative file conflicts with every other edit path.** If the descriptor is truth, then a
  hand `dokku config:set`, or an edit in wharf, is drift the converger must revert, ignore or fail on —
  so every UI becomes read-only in practice for the fields the file owns. If Dokku is truth there is no
  converger and no drift policy to get wrong. Since this box is used only through Shepherd2 and `dokku`,
  there is no third thing to reconcile.
- **Creation is the error-prone part; operation is not.** Onboarding a project is roughly ten commands,
  two of them (`apps:create`, `network:create`) not idempotent, plus the first sync — and it was more
  before `D_builder` deleted the cache flags and the managed database moved to v2. That still earns a
  script. Every day-N action is one well-named `dokku` command, and re-exposing those one-to-one is
  `shepherd-cli` again — the component class `D_retire_shepherd_java` retired.
- **Config var over inference, because of one edge.** `git:sync` does record its URL (`apps:report
  --app-deploy-source-metadata`), but only after a build that succeeded far enough to fire
  `deploy-source-set`. Many first builds fail — the `Procfile` / buildpack / `system.properties` trio
  usually needs a couple of iterations — and an app with no recorded URL is invisible to a poll derived
  from Dokku's records, so the developer's fix upstream is never picked up. A config var written *before* the first build puts the app in the poll
  from the moment it exists, and the next upstream commit heals it. `RESEARCH.md` → *`git:sync`* has
  the source reading.

**Alternatives rejected.**

- *Declarative descriptor + converger* — shepherd-java's shape, and the ideas file's original instinct.
  Rejected on the conflict above and on the third-copy argument: Dokku's property store is already the
  descriptor, spread across plugins. It would have bought the smart-update logic — rebuild only when a
  *build* input changed — and a git-reviewable project set; see *Consequences* for what that costs.
- *Derive the poll list from `deploy-source-metadata`.* Zero convention, pure Dokku. Rejected on the
  failed-first-build edge; also "where the last deploy came from" is history, not intent.
- *A projects table of ours* (`id url ref owner`, one line per project). The same two facts, held in a
  file outside Dokku and outside Dokku's backup — a second truth for exactly the thing the poll runs on.
  The config vars are that table, inside Dokku.
- *`app.json` in the app's own repo* — Dokku's native, Heroku-shaped descriptor. Wrong owner (we host
  repos we don't control) and wrong scope (no limits, domains or build options).
- *A checked-in shell script of `dokku` commands per project.* Persisted and replayable, but the "how"
  is duplicated across every file and the non-idempotent commands need guards in each.
- *Wrapping day-N commands* (`shepherd2 logs`, `shepherd2 restart`, …). Rejected as `shepherd-cli`
  reincarnated: it would have to track Dokku's command surface forever for no gain.

**Consequences.**

- **The descriptor and the smart-update logic are dropped**, and with them the question of which change
  needs which kind of restart. Changing a build arg is `docker-options:remove`, `docker-options:add`,
  `ps:rebuild` — three commands, once a year for a key rotation, a cheat-sheet line in `README.md`.
  **The box-wide memory quota is deferred to v2** (operator, 2026-09-10): the only enforcement point
  this design leaves is `create-app`, where a later hand `resource:limit` bypasses it, and a guard that
  holds only on the path the operator already controls was not worth writing before the box exists.
  `Q_quota` in `ideas/box-memory-quota.md` stays open as the v2 question — the interesting half of which
  is whether *any* enforcement point exists that Dokku's own state does not undermine. **Recording who
  owns a project** survives as `SHEPHERD_OWNER`. Per-project cache flags are set once by `create-app`.
- **Both config vars are injected into the container's environment.** Acceptable because neither is a
  secret: a git URL never carries a token here (credentials go through `git:auth`), and the owner is a
  contact address.
- **Every deploy on this box goes through `git:sync`** — `poll` or `rebuild`. Pushing to the box as a
  git remote and `git:from-image` are not supported paths. `deploy-source-metadata` is a free
  cross-check: an app whose last deploy did not come from its `SHEPHERD_GIT_URL` is drift worth
  reporting, and its `#<sha>` answers "which commit is running".
- **A failed build is not retried until upstream moves** — `--build-if-changes` semantics, same as
  Jenkins poll-SCM. `rebuild` is the manual override, and this is its second reason to exist.
- **The per-project configuration is not in git.** The reinstall story is this repo plus Dokku's own
  state (`~dokku` and `/var/lib/dokku`; that this is the complete set is `[unverified]`), or re-running
  `create-app` per project. A read-only export of the reports into git would mitigate it; not decided.
- **The `Q_multi_user` hook stays cheap** regardless of which way that question goes: "is `$SSH_NAME`
  the app's `SHEPHERD_OWNER`" is one `config:get`.
- **The choice of implementation language loses its main input** — there is no descriptor to parse,
  only reports to read; `D_ruby` decided it on `create-app`'s flag list instead.
- **A third-party client such as wharf may be adopted, never depended on.** It is a pure SSH client
  holding no server-side state, so its death costs nothing; that is the property `D_retire_shepherd_java`
  found missing in the class. Whether any browser UI returns is still `Q_web_admin`.
- **`D_retire_shepherd_java`'s open "shape of the replacement" is closed for the CLI half** by this entry.

## D_single_operator — v1 has one keyholder; per-user project ownership is v2 (2026-09-10)

**Status:** Accepted 2026-09-10 for the first version. Deliberately scoped: this decides *v1*, and it
defers rather than drops multi-user. `Q_multi_user` in `ideas/multi-user-ownership.md` stays open as
the v2 question.

**Context.** Shepherd today has users: an admin adds them, and each sees, creates, edits and deletes only
their own projects, filtered on `owner.email`. Core Dokku has nothing of the kind — an authorised SSH key
may run every command against every app, the only privilege distinction being the substring `admin` in a
key name. So "access control becomes SSH keys" is not a mapping of the old model; it is its removal. Any
per-user model would be built on the `user-auth` trigger, by us or by the stale `dokku-acl` plugin.
`RESEARCH.md` → *Users and access control* has the detail.

**Decision.** **In v1 exactly one person holds a key: the operator.** They log into the box as an admin
user and run `dokku` and `shepherd2` from one shell (`Q_web_admin`). No `user-auth` hook, no `dokku-acl`,
no `ssh dokku@host` remote access for anyone else. `SHEPHERD_OWNER` is a contact field, not an ACL.

**Why.** Every multi-user option costs a security-critical component in the authorization path — our own
hook, an unaudited plugin, or Dokku Pro — and none of it is needed to get a box building and serving
projects. Deciding it later costs nothing *provided* v1 stores the one input v2 needs, which is the owner
per app; `D_dokku_is_truth` already does.

**Alternatives rejected** (for v1 only; all remain v2 candidates and are argued in `Q_multi_user`).

- *Our own `user-auth` hook* — "is `$SSH_NAME` the app's `SHEPHERD_OWNER`", one `config:get`. Cheap, and
  the likely v2 shape, but a hook we would own in the authorization path before the box even exists.
- *`dokku-acl`.* Stale (last commit 2024-01, adapting to a trigger rename), self-described as not
  security-audited; on a Dokku trigger rename it silently stops enforcing.
- *Dokku Pro.* Teams and SSO, paid and proprietary; already rejected in `D_retire_shepherd_java`.

**Consequences.**

- **Per-user project ownership is deferred, not dropped** — `ideas/multi-user-ownership.md` is the v2
  fork, and its cheap favourite is a `user-auth` hook of our own. Password and Google-SSO **login** is
  the harder half: its only v2 route is the reworked Vaadin admin, option 3 in `ideas/web-admin-ui.md`,
  because nothing else short of Dokku Pro provides it and a CLI has nothing to log in to.
- **`SHEPHERD_OWNER` is an email address** (operator, 2026-09-10), which is what shepherd-java's `owner`
  held and what a contact field is for. The `user-auth` trigger sees the key's `$SSH_NAME`, so v2 closes
  the gap from the other end: **name SSH keys by email** (`ssh-keys:add alice@example.com …`) and the
  hook is a string comparison with no mapping table. Note that in `create-app`'s header when it is
  written, because it is the one v1 field a v2 decision depends on.
- **Nothing in v1 may assume more than one keyholder** — no per-user paths, no owner checks in
  `shepherd2` — so that v2 adds the hook without unpicking anything.

## D_cert — One wildcard certificate: lego DNS-01 on the host, propagated by `dokku-global-cert` — or plain http, chosen at install (2026-09-10)

**Status:** Accepted 2026-09-10, **written, and half-proven**. Both modes are implemented as `install`
steps (lego, the plugin, the first issuance, one root cron line — nothing per app). The **`http` mode
ran end to end on a box 2026-09-11**, including the two claims that make it safe to run and one-way to
leave: no HSTS header and no redirect without a certificate, and `nginx:set hsts true` emitting nothing
at all (`RESEARCH.md` → *nginx*). **The `https` mode has never been executed anywhere** — lego, the
`global-cert` push and the renewal hook are punch-list item 4, which needs a real DNS zone and is
planned in `ideas/production-cutover.md`. Depends on `D_proxy`: the `certs` plugin
this rides on is ignored under the Traefik plugin. **Amended the same day** with the http-only mode: https as
described here is one of *two* install modes, and the second one is the absence of all of it.

**Context.** The inherited requirement asks for **one** `*.mydomain.me` certificate, so that a new app is on
https the moment it exists and nobody performs a per-app ACME order, ever. shepherd-traefik does this
today with Traefik's DNS-01 challenge against GoDaddy. Dokku's nginx cannot: nginx has no ACME client,
so under `D_proxy` something else has to issue and renew. Two routes survived `D_proxy` — the official
`dokku-letsencrypt` plugin (per-app orders, renewal solved upstream) and the community
`dokku-global-cert` plugin (one cert, renewal ours) — and which one is right turned entirely on whether
"one cert" is still the requirement or merely how it happened to be built.

It is the requirement. Every app this product has ever hosted was a demo at `PROJECTID.<domain>` under a
wildcard DNS record; the production use with foreign domains that the predecessors allowed for never
materialised. Once custom and apex domains are deferred (see *Consequences*), per-app
issuance buys nothing and the wildcard is the whole story. And a wildcard is DNS-01 by definition —
Let's Encrypt issues wildcards over no other challenge (`RESEARCH.md` → *TLS*).

**Decision.**

- **One certificate, `*.mydomain.me`, issued and renewed on the host by [lego](https://go-acme.github.io/lego/)**
  with its `godaddy` DNS provider. Renewal is a daily root cron line running `lego renew --days 30` with
  a `--renew-hook` that calls `dokku global-cert:set` on the new files; lego runs the hook only when a
  renewal actually happened.
- **Propagation is `dokku-global-cert`**, installed by `install`. It imports the cert into every new app
  at creation, re-applies it to every app using it on `global-cert:set`, and leaves apps with their own
  certificate alone. It is the one third-party plugin Shepherd2 depends on, and this entry is the `D_`
  that `CLAUDE.md`'s *Conventions* require for that.
- **No per-app ACME in v1.** `dokku-letsencrypt` is not installed; no app runs `letsencrypt:enable`.
- **TLS is an install-time *mode*, and `http` is a supported one** — added 2026-09-10.
  `install` asks once, and the answer is recorded on the box:
  - **`https`** — everything above: lego, the DNS credentials, `dokku-global-cert`, the renewal cron.
    This is what a real box runs, and it needs a DNS zone with `@` and `*` records plus API access to it.
  - **`http`** — none of the above is installed. Apps are served over port 80 by the same nginx, which
    needs no flag for it: an app with no certificate is an http app, and `domains:set-global` is
    identical in both modes. It exists for a throwaway VM where obtaining a wildcard certificate is
    either impossible or not worth it, and it is how the box gets tested without a DNS zone at all —
    `app1.mydomain.me`, `app2.mydomain.me` … in the *client's* `/etc/hosts`, pointed at the VM.
  - **The two are not switchable on a running box**, by decision rather than by mechanism — see
    *Consequences*. Pick per install; to change, reinstall.

**Why.**

- **Under nginx, "automatic" is either a plugin or a cron; there is no third thing.** `dokku-letsencrypt`
  automates renewal but issues per app, which is the half of the requirement that matters. The wildcard
  route is the only one where creating an app involves zero certificate work, and it is what we run today.
- **lego is Traefik's ACME engine.** Traefik "relies internally on Lego for ACME", so `lego --dns godaddy`
  with the same API key and secret is the code path renewing our certificate right now, on an account
  already known to clear GoDaddy's API-access restriction. Zero new provider risk, and the credentials
  carry over unchanged.
- **certbot would have been the first choice and is not available for this provider.** certbot ships a
  renewal timer with its Ubuntu package, so it would have cost us no cron of our own; but its thirteen
  first-party DNS plugins do not include GoDaddy, and the third-party `certbot-dns-godaddy` is a pip
  install outside the distro — the non-standard path the whole choice is trying to avoid. lego's price
  for being in the distro *with* GoDaddy is one cron line.
- **The plugin over a `certs:add` loop of our own** because it hooks app creation: an app created by a
  hand-typed `apps:create` still gets https, where our loop would cover it only at the next renewal, up
  to two months later. And its leave-own-certs-alone rule is exactly what lets v2 add per-app
  certificates for foreign domains without touching this design.

**Alternatives rejected.**

- *`dokku-letsencrypt`, per-app orders, HTTP-01 or DNS-01.* Would have been the answer had
  custom domains stayed, because a wildcard covers no foreign domain and every app would have needed
  its own cert anyway; with that feature deferred it only adds an ACME order per app. Two further costs:
  the app "needs to already be deployed and reachable on the public internet over HTTP before a
  certificate can be issued", so an app whose first builds fail — the normal case — has no https until
  someone re-runs `enable`; and its wildcard support is "not officially supported" (issue #189). It
  stays the v2 tool for custom domains, on those apps only, and coexists with the global cert.
- *The Traefik plugin with `challenge-mode dns`.* Foreclosed by `D_proxy`, and it was per-app orders too,
  since nothing in it declares a wildcard SAN.
- *certbot with a DNS plugin.* No GoDaddy in the distro; see *Why*. It becomes the right tool the day the
  domain moves to a provider certbot ships a plugin for (Cloudflare, Route53, …) — and nothing else in
  this entry changes when it does, only the two lines that issue and renew.
- *Our own propagation: `create-app` runs `certs:add`, the renew hook loops over `apps:list`.* Five lines
  and no dependency, but misses hand-created apps, and the plugin already writes through `certs:add`,
  so if `dokku-global-cert` ever dies the migration to this shape is trivial. Kept as the fallback.
- *The raw variant — `server.crt` / `server.key` in `/home/dokku/tls`.* Documented, but whether it
  covers app vhosts or only the default server was not investigated, because the plugin does the job.
- *Move the domain to Cloudflare to unlock certbot's stock plugin.* Not needed while GoDaddy's API works
  for this account. Kept as the fallback if GoDaddy's 2024 access restriction (10+ domains or a Discount
  Domain Club plan) ever bites.

**Consequences.**

- **Custom domains and the apex domain are deferred, not dropped.** A `*.mydomain.me` cert matches
  neither `foo.example.org` nor `mydomain.me` itself. Custom domains are v2 via `dokku-letsencrypt` on
  the affected apps only. The apex is one more `-d mydomain.me` on the lego command plus a Dokku app
  named as the FQDN — cheap, but there is nothing to run there in v1, since a visitor cannot ask for an
  app to be published.
- **A DNS API token lives on the box, readable by root only.** It can rewrite the whole zone, which makes
  it a bigger secret than any certificate and one more reason `D_single_operator` holds: whatever v2 does
  about keyholders, lego runs from root's crontab and the `dokku` user must never be able to read that
  file.
- **`shepherd2-renew-cert` in the ideas sketch is not a script.** It is the cron line plus a two-line
  hook. `install` owns: `apt install lego`, `plugin:install … global-cert`, the first `lego run`, the
  first `global-cert:set`, and the cron line; `uninstall` is the inverse. `create-app` does nothing for
  TLS.
- **Ubuntu's lego lags upstream by a major version** (4.9.1 on 24.04 against 5.x upstream), so pass
  `--days 30` explicitly rather than relying on v5's dynamic default, and if the packaged `godaddy`
  provider ever misbehaves, the fallback is upstream's static binary, pinned the way Dokku is.
- **Rate limits stop mattering.** One certificate renewed roughly every sixty days is far below every
  Let's Encrypt limit, where a per-app route would have had to batch a farm migration.
- **The mode is one-way in practice, and that is why it is an install-time question.** Mechanically
  Dokku would let you add a certificate later; what makes the switch a bad promise is the *other*
  direction. nginx's `hsts` property defaults to **`true`**, with `hsts-include-subdomains` `true` and
  `hsts-max-age` `15724800` — 182 days (`RESEARCH.md` → *nginx*). So the moment one app is served over
  https, every browser that saw it refuses plain http for half a year, and the fix lives in each
  visitor's browser rather than on the box. Downgrading is therefore not something `install` can undo,
  and rather than support half a switch we support neither: **pick per install; to change, reinstall.**
  Two implications for the code: `install` records the mode where `uninstall` can find it (so the
  teardown stays symmetric), and nothing in http mode may pre-set `nginx:set … hsts`, which
  is inert without a certificate but would go live the instant one appeared.
- **The mode is recorded as `dokku config:set --global SHEPHERD_TLS_MODE=https|http`** (2026-09-10) —
  the box-level counterpart of `D_dokku_is_truth`'s rule that a fact of ours is a `SHEPHERD_*` config
  var or it does not exist. `install` writes it last, once the mode's steps have succeeded; `uninstall`
  reads it to decide whether lego, the plugin and the renewal cron are there to remove. A file under
  `/etc/shepherd2/` was the alternative and was rejected for the same reason the project descriptor was:
  it is state of ours outside Dokku, needing its own backup and its own drift story. Like every global
  var it is injected into each app's build and runtime environment, which is harmless — it is not a
  secret, and an app that reads it learns only what its own scheme already tells it.
- **http mode makes the DNS requirements conditional, not the domain.** `domains:set-global mydomain.me`
  is still set and apps are still `PROJECTID.mydomain.me`; what http mode drops is the zone, the `*`
  record and the API token. Resolution can then come from the client's `/etc/hosts`, one line per app —
  which is exactly why this mode is the one a test VM uses, and why `README.md` owns that recipe.
- **Box questions before this can be called done** (`RESEARCH.md` → *Questions only a box can answer*).
  The http half is **answered** (2026-09-11): an app on a box with no certificate serves plain http on
  80, emits no `Strict-Transport-Security` and issues no redirect, and `hsts` is *inert* rather than
  merely unset — `nginx:report` computes it `true`, and the header still appears nowhere, because it
  hangs off an ssl listener that does not exist. That is what makes the mode safe to run and
  unrepairable to leave. **Nothing of the https half has been run**: that `lego run --dns godaddy`
  succeeds with the current credentials; that `global-cert:set` on renewal re-applies to every app and
  reloads nginx without dropping connections; and that an app created and never yet deployed serves
  the global cert on its first successful deploy. Those are punch-list item 4 and need their own box —
  `ideas/production-cutover.md`.

## D_builder — Apps are built by a buildpack, never a Dockerfile; herokuish by default (2026-09-10)

**Status:** Accepted 2026-09-10, and **the requirement it exists for was demonstrated on a box
2026-09-11**: one repository deployed under two ids, both installing the same
`1.0-SNAPSHOT` coordinates, downloaded 924 artifacts from Central *each* and shared nothing
(`RESEARCH.md` → *The herokuish cache volume*). The one `[unverified]` that could have forced a
re-read — whether a Vaadin *frontend* build stays warm across rebuilds — **stopped being load-bearing
the same day**: every app on this box uses Vaadin's pre-compiled production bundle, so it runs no
frontend build at all, and caching one is deferred to v2 (see *Consequences*).
Supersedes nothing, but it makes `D_no_shared_cache` in shepherd-traefik's *Known gap* closed rather
than inherited.

**Context.** Dokku ships **seven** builders (`RESEARCH.md` → *The builders, and how one is chosen*), and
Shepherd2 had only ever considered one, because both predecessors built a `Dockerfile` and the feature
survey recorded that as preserved, ✅, not examined. Two requirements, stated by
the operator on 2026-09-10, turned out to decide the whole question:

- a scheduled rebuild must **not** re-download the Maven dependency tree from Central, and
- that cache must be **per project**, so one project's `mvn install` of `com.example:my-app:1.0-SNAPSHOT`
  can never be resolved by another's build.

The second is `D_no_shared_cache` in shepherd-traefik, promoted from *known gap* to requirement. The
path that bites is not malice: a demo farm is full of forks of the same starter, so two projects
legitimately share a `1.0-SNAPSHOT` coordinate and the second silently resolves the first one's jar
with a green build.

**The finding that decided it: the builder decides *who names the build cache*.**

| builder | who names the dependency cache | per-project? |
|---|---|---|
| dockerfile | the app's own `RUN --mount=type=cache,id=…` | convention only |
| herokuish | Dokku — `cache-$APP` volume, mounted at `/cache` | **enforced** |
| pack (CNB) | pack, from the image ref; or us, via `--cache` | **enforced** |
| nixpacks / railpack | us, via `--cache-key` on the build command | **enforced** |

Under the Dockerfile builder there is **nothing** on the build command that can remap a cache mount:
`id=` lives in the repo, `--builder` is a dead end (a `docker-container` builder would need `--load`,
which is not on the allowlist), and the only enforcing move available — pruning
`type=exec.cachemount` between builds — buys isolation by making every build cold, which fails the
first requirement. **No option keeps the Dockerfile *and* satisfies both requirements.** That is the
whole decision in one sentence.

**Decision.** Three parts.

1. **Apps are built by a buildpack builder, and the Dockerfile builder is prohibited box-wide.** The
   install runs `dokku builder:set --global selected herokuish`, which short-circuits detection
   entirely, so a committed `Dockerfile` is never read — no warning, no partial detection.
2. **herokuish is the builder — the only one, in v1.** Because the prohibition *is* the global
   `selected` property, that is the same single command: `create-app` sets nothing per app.
3. **pack (Cloud Native Buildpacks) is deferred to v2**, not offered as a v1 alternative. Dokku
   supports it natively (`builder:set <app> selected pack`, stack `heroku/builder:24`), so the door
   stays open at the cost of one command — but v1 does not install the `pack` CLI, does not document
   a second path, and does not carry two cache stories. Same shape as `D_single_operator` and
   `D_cert`: one mechanism in v1, the second only when something forces it.

**Why herokuish and not the others.**

- **It satisfies both requirements by construction, not by cooperation.** Dokku runs
  `docker volume create cache-$APP` and mounts it `-v cache-$APP:/cache --env=CACHE_PATH=/cache`; the
  Heroku Java buildpack then runs Maven with `-Dmaven.repo.local=${CACHE_DIR}/.m2/repository`. The app
  never learns the volume's name and, having no Dockerfile, has no syntax in which to open a different
  mount. The pleasing detail: that buildpack's *default* goals are `clean dependency:list install` —
  the exact `mvn install` we were afraid of is what it does by default, and it is safe because the
  local repo it installs into is the app's own volume.
- **Per-app cache purging works.** `dokku repo:purge-cache <app>` is literally
  `docker volume rm -f cache-<app>` **[src]**. Under pack the same command is a documented no-op, and
  purging one app's cache would mean `docker volume rm` on a hash-named volume — reaching around Dokku
  to the daemon, which is exactly what *Conventions when editing* tells us not to do.
- **No new binary on the box.** herokuish ships inside the image Dokku already pulls. `pack`,
  `nixpacks` and `railpack` are each a CLI we would have to install, pin and re-install after a rebuild.
- **It is Dokku's own default and fallback** — the best-trodden path on this platform, which matters
  more than ecosystem-wide popularity, and the path most likely to be fixed quickly when it breaks.
- **Capping build CPU probably closes as a side effect.** On the herokuish path the build-phase
  `docker-options` are passed to `docker container create` with **no allowlist filtering** **[src]**, so
  `--cpus` should simply work — a gap the feature survey had written off as unfixable, because on the
  *Dockerfile* path the flag is silently dropped.
- **The build stops being arbitrary root-privileged code we host.** The app supplies no build
  instructions at all; a fixed buildpack compiles it. That is a real reduction in attack surface on a
  box running other people's example projects, and it is the cheapest security win available here.

**Alternatives rejected.**

- ***Keep the Dockerfile, keep `id=` as a convention*** (the incumbent, and `ideas/build-cache.md`
  position A). The operator reads every Dockerfile at onboarding, so a convention policed by one
  keyholder (`D_single_operator`) is stronger than the self-service setting `D_no_shared_cache` was
  written for. Rejected because it leaves the requirement satisfied only as long as nobody makes a
  mistake, and because the failure is *silent* — a green build resolving the wrong jar. The operator
  explicitly chose to give up the Dockerfile rather than keep policing it.
- ***Keep the Dockerfile, prune cache mounts between builds*** (position B). Enforced by the platform,
  and it fails the warm-cache requirement by design: every build starts cold on exactly the directories
  that make a Vaadin rebuild bearable. Struck.
- ***pack / CNB, as the default or as a second supported path in v1.*** The strategically better bet —
  CNB is where Heroku itself went (Fir apps are CNB-only; Cedar got CNB as an opt-in on 2026-09-03),
  and `heroku/builder:24`'s Maven buildpack keeps the repository in a restored cache layer
  (`buildpacks/maven/src/layer/maven_repo.rs`: a `CachedLayerDefinition` named `repository`,
  `-Dmaven.repo.local` pointed into it, restored with `KeepLayer` **[src]**), so the cache story is
  genuinely as good. Note that is a property of *Heroku's* CNB and not of CNB in general — Paketo's
  own docs say their Java buildpack does **not** cache Maven dependencies between builds and tell you
  to bind-mount `$HOME/.m2` yourself **[docs]** — so the claim depends on the stack being pinned.
  Lost on three practical points: a CLI to install and pin, a `repo:purge-cache` that is a documented
  no-op, and no build CPU knob. **Deferred to v2 rather than rejected**, because that verdict could
  age: if the classic v2a line stops tracking JDK releases, this entry is the thing to re-read, and
  the migration is one `builder:set` per app.
- ***nixpacks.*** Popular in the Coolify/Dokploy world and a Dokku core plugin, but its default cache
  identifier is a hash of the absolute build directory, and Dokku builds in a fresh `mktemp -d` every
  time — so on Dokku it should be cache-cold on **every** build unless `--cache-key` is set. A builder
  whose headline feature is off by default, on a platform its upstream does not test, plus ten months
  without a release while Railway itself moved on. No.
- ***railpack.*** Actively developed and the best-designed of the Railway family, but it requires a
  long-running **privileged** `moby/buildkit` container and a global `BUILDKIT_HOST` in
  `/etc/default/dokku`. A second build daemon with its own cache store and its own GC, and a privileged
  container on a box whose isolation story is `D_isolation`. The cost is not close to the benefit.
- ***Don't build on the box at all*** — build in CI, deploy with `git:from-image`. Both requirements
  become moot because the cache becomes CI's problem. Rejected because it is a different product: it
  removes the on-box rebuild the scheduled poll exists for, needs a registry and per-project
  credentials, and makes every hosted project maintain a pipeline — the exact chore Shepherd exists to
  spare them.
- ***A Maven repository proxy (Nexus et al.).*** Rejected in `D_no_shared_cache` on cost and because it
  is cooperation (each app's `settings.xml` must point at it, and Central is https so it cannot be
  forced). Unchanged here, and now unnecessary: it was a *sharing* answer to an *isolation* problem. If
  bandwidth ever becomes the complaint rather than isolation, it comes back as a speed measure.
- ***Per-app `builder:set` instead of the global prohibition.*** Rejected as the primary mechanism: it
  makes the guarantee "per app we remembered to set" rather than a property of the box. Note the
  per-app override is *not* a hole — only the keyholder runs `dokku` (`D_single_operator`), so a
  project can never opt itself back into the Dockerfile builder. It is an operator tool, and that is
  how the pack alternative is delivered.

**Consequences.**

- **Building from the project's own `Dockerfile`, and a per-project Dockerfile path, are dropped
  features**, not preserved ones. This is
  the first feature the Dokku move deliberately *removes* rather than migrates, and it is the entry to
  cite when someone asks why a project's `Dockerfile` is being ignored.
- **Every hosted repo needs descriptors it does not have today** — at minimum a `Procfile`, usually a
  `system.properties`. Acceptable only because we own the apps; on a farm of repos we did not control
  this decision would not be available. Onboarding is no longer "point at the repo", and `README.md`
  owns the recipe.
- **The buildpack must be *named*, never detected — and the repo names it.** Detection is a trap
  here: herokuish detects `nodejs` **before** `java` **[src]**, and Vaadin's own source-control
  guidance says to commit `package.json` **[docs]**, so a stock Vaadin repo would build as a Node app.
  **v1 supports naming it from either end, and both are first-class:**
  - **in the repo** — a one-line `.buildpacks` at the root (`heroku/java`; the shorthand is expanded
    to the full GitHub URL, and an unparseable line fails the build rather than being ignored
    **[src]**), sitting alongside the `Procfile` and `system.properties` the project already needs.
    `app.json`'s `buildpacks` array works too, and outranks `.buildpacks`.
  - **at registration** — `create-app … --buildpack heroku/java`, which is
    `dokku buildpacks:set <app> …` and is expected to be the common case here, since nearly every
    project on this box is the same kind of Java app. It is also the repair for a repo we cannot
    edit or one that chose wrongly, with no commit and no fork.

  These compose rather than competing: registration wins, so the repo's choice is a default the
  operator can override. Neither is mandatory, but *relying on detection* is a bug waiting to happen.
- **The precedence, from `getBuildpacks` and the `buildpacks` plugin's `post-extract` trigger**
  **[src]** — note the function's own doc comment states the reverse and is stale:

  | | source | who controls it |
  |---|---|---|
  | 1 | `buildpacks:set` / `:add` app property | operator; **overwrites** the repo's `.buildpacks` in the extracted source |
  | 2 | `app.json` `buildpacks[].url` | the repo; likewise overwrites `.buildpacks` |
  | 3 | `.buildpacks` at the repo root | the repo; kept, with each line validated and normalised |
  | 4 | herokuish's own detection order | nobody — the trap above |

  So a self-describing repo needs no per-app state at all, and `--buildpack` at registration is one
  property when we'd rather say it on the box. The layering comes free — it is Dokku's, not ours.
- **Letting the repo name its buildpack costs no privilege, only provenance.** Worth writing down
  because it looks alarming and mostly isn't. A custom buildpack's `bin/compile` runs in the same
  build container, as the same unprivileged user, with the same config vars, the same `/cache` and
  the same network as the app's own `pom.xml` already does — and a `pom.xml` can run arbitrary
  plugins. The build container is not privileged, mounts no Docker socket and gets no special
  network **[src]**. So a hostile `.buildpacks` achieves nothing a hostile repo could not achieve
  anyway; the earlier framing of this as "re-opening the door the Dockerfile prohibition closed" was
  wrong. The prohibition was never about arbitrary build code — it was about **who names the cache**,
  and a buildpack cannot name it: `cache-$APP` is Dokku's, always.

  The real and much smaller delta is **supply chain**: a `.buildpacks` line is a URL cloned at build
  time at whatever the ref points to *then*, so the same git SHA can build differently tomorrow, and
  whoever controls that repo controls our builds. The bundled buildpacks don't have this property —
  they are pinned inside the herokuish image (`heroku/heroku-buildpack-java v81`). Mitigation, if a
  project ever needs a third-party buildpack: pin it, `https://…/repo#<commit-sha>` — multi does a
  full `git clone` then `git checkout "$ref"` **[src]**, so a SHA works where a branch name drifts.
- **Per-project build args get simpler.** `builder-herokuish/pre-build` bundles every app config var into an
  ENV_DIR inside the build **[src]**, so the Vaadin offline key is a plain `dokku config:set` with no
  `--build-arg` plumbing. The flip side is that every *runtime* secret is visible to the build too.
- **The `.m2` cache now lives in a Docker volume that nothing garbage-collects.** buildkitd's GC, the
  ~48 h mount eviction and the whole `--cache-to type=local` apparatus stop applying. Housekeeping
  becomes one lever — `repo:purge-cache <app>` — and the successor to `shepherd-clearcache` prunes
  *volumes*, not buildx caches. Punch-list item 1 (does `--cache-to type=local` export at all) is moot
  and has been struck.
- **Isolation is paid for in disk, and the bill is now measured.** A Maven app's cache volume is
  ~205–280 MB; **a Gradle app's is ~1.3 GB**, because that buildpack caches Gradle itself and the JDK
  as well as dependencies. Two ids on one repo cost two full copies — that is the same property the
  requirement asks for, seen from the cost side. Roughly half the farm is Gradle
  (`ideas/production-cutover.md`), so nine Gradle apps is ~12 GB of volumes that nothing reclaims on
  its own: `clearcache` never touches volumes by design, and `repo:purge-cache <app>` is the only
  lever. Worth watching on the production box rather than assuming the dev VM's headroom.
- **The frontend half of a Vaadin build is the one thing this decision does not solve — and v1 does not
  need it solved.** It is not a herokuish weakness: the frontend is driven by Maven, so it is invisible
  to the node buildpack that would otherwise have cached it, on any builder. What retires the problem
  is the app side. Vaadin's pre-compiled production bundle (24.1+) removes the frontend build entirely
  for an app with no custom frontend and no frontend-customising add-ons **[docs]**, and **every app on
  this box is such an app** (operator, 2026-09-10). So **caching `node_modules` and `~/.vaadin` is
  deferred to v2**, and `README.md`'s recommendation is to stay on that bundle rather than to configure
  a cache.
- **When v2 needs it, the fix is app-side like the buildpack choice** — `/cache` is a per-app volume the
  build can write to (herokuish chowns it to the build user before `bin/compile` **[src]**) and a
  committed `.env` reaches the build environment **[src]**, so `npm_config_cache=/cache/npm` warms npm
  and `MAVEN_CUSTOM_OPTS=… -Duser.home=/cache/home` should relocate `~/.vaadin` into the same volume.
  Two things bound that plan, both recorded 2026-09-10. **Vaadin has no property for where `~/.vaadin`
  lives** — `require.home.node` only *forces* that location, and the project-local alternative sits in
  the throwaway build directory **[docs]** — so moving `user.home` is the only lever; and **providing a
  system Node is unreachable** (not in `heroku/heroku:24-build` **[docs]**, `heroku/nodejs` exports no
  `PATH` **[src]**, and we do not build the herokuish image). Whether the two settings belong in the
  repo's `.env` or in a box-side `config:set --global` is the live fork, since a committed `/cache` path
  is a platform path in someone else's repo. Tracked in `ideas/vaadin-build-under-herokuish.md`;
  punch-list 13 and 15 are v1 curiosities, 14 and 16 are v2.
- **A `heroku/nodejs` + `heroku/java` multi-buildpack is not the answer to that**, and the reason is
  worth recording so nobody re-derives it: the node buildpack's cache bracket opens and closes inside
  *its own* compile, which runs before Maven, so anything Maven creates is saved by nobody; it prunes
  devDependencies unconditionally at the end of that compile, removing exactly the Vite that Vaadin
  then reinstalls; and it writes no `export` file beyond a pnpm store line **[src]**, so
  `heroku-buildpack-multi` propagates no `PATH` and the node it installed is not visibly on `PATH`
  when Maven runs. It also makes the build *fail* outright if its `detect` finds no `package.json`,
  since multi exits when any listed buildpack fails to detect **[src]**.
- **`ideas/build-cache.md` is deleted.** Its fork was conditional on the Dockerfile builder and is moot;
  its surviving Dokku facts went to `RESEARCH.md`, and the unpinned poll interval it flagged is now
  pinned at five minutes (`SOLUTION.md`).
- **`D_dokku_is_truth` is unaffected and slightly strengthened** — the builder choice is `builder:report`
  state, not a file of ours, and the cache is a Docker volume Dokku names. Still no descriptor.

## D_ruby — The `shepherd2` CLI is Ruby; `install` and `uninstall` stay Bash (2026-09-10)

**Status:** Accepted 2026-09-10, **implemented**: the Ruby CLI, both Bash installers and the minitest
suite exist, and all three ran on a box on 2026-09-11. The split held under the one pressure that could
have broken it — the installers needed JSON surgery on `/etc/docker/daemon.json` before Ruby exists on
the box, and reached for `python3` rather than for an interpreter that is not there yet.

**Context.** Both predecessors wrote their glue in Bash, and `CLAUDE.md` carried "scripts are Bash with
`set -euo pipefail`" as a convention inherited from them. `D_dokku_is_truth` then removed that
convention's main input: there is no descriptor to parse, only `dokku *:report --format json` to read.
What is left for the CLI to do is argument handling (`create-app` carries about eight flags), reading
JSON, running a partly non-idempotent sequence behind guards, and holding a lock.

**Decision.**

- **One `shepherd2` dispatcher, written in Ruby**, holding every verb: `create-app`, `destroy-app`,
  `poll`, `rebuild`, `wait-idle`, `clearcache`. One command on `PATH`, one place to look — split into a
  library and its executable by `D_api_surface`, which leaves the command itself exactly where it is.
- **Ruby standard library only.** `json` and `optparse` are in it. No `Gemfile`, no bundler, no gem to
  pin, and nothing to re-install after a distro upgrade.
- **`shepherd2-install` and `shepherd2-uninstall` stay Bash** with `set -euo pipefail`. They run on a
  box where Ruby is not yet guaranteed to exist and after it may have been removed, and they are a
  linear sequence of root commands — which is the thing Bash is actually good at.

**Why.**

- **The dispatcher is a program; the installer is a sequence.** `create-app` parses flags, validates an
  id *before* mutating anything, reads two JSON reports, and runs eight commands with an existence guard
  on each of the non-idempotent ones. Bash does all of that, at a cost that starts compounding around
  the fifth flag; the installer does none of it.
- **`jq` in Bash is already a second language**, and a worse one for this shape — `--format json` output
  has to be threaded through subshells and re-quoted at every step, where Ruby parses it once into a
  hash. The Bash case rested on "no new runtime", and that is the only thing it wins.
- **Ruby is on this operator's shelf.** `Q_web_admin`'s cheapest v2 candidate is a TUI on
  [Tuile](https://github.com/mvysny/tuile), and the prior art for the shape is the Ruby `dokku-cli` gem.
  Writing v1's CLI in Ruby means that TUI shells out to — or eventually requires — the same code rather
  than reimplementing a model of the box in a second language.
- **The runtime cost is one `apt install ruby`** from the distro archive, no third-party repository and
  no version manager. It is a smaller addition than the JVM this project just deleted, and unlike the
  JVM nothing long-running hosts it: every invocation is a short-lived process started by cron or by the
  operator.
- **Keeping the installer in Bash keeps the bootstrap honest.** The install has to work on a machine
  with nothing on it; it is the one part of Shepherd2 that must not depend on anything Shepherd2
  installs. That is also why it, and not the dispatcher, is what `apt install ruby` lives in.

**Alternatives rejected.**

- *Bash + `jq` throughout.* Matches both predecessors, adds no runtime, and would be right if
  `create-app` were three commands. It is the fallback if Ruby ever becomes awkward to have on the box,
  and the port is mechanical for every verb except `create-app`.
- *Ruby for `install` too.* Chicken-and-egg — the installer would have to install its own interpreter
  and then re-exec — for no gain on a script that is a list of `apt`, `dokku` and `cron` lines.
- *Something compiled — Go, matching Dokku's own plugins.* The repo is deployed to the box by
  `git pull`, so a compiled artifact adds a build-and-ship step to a project whose entire deployment
  story is "the guide is the deliverable". Go's other draw, single-binary distribution, buys nothing
  when there is exactly one box.
- *Python.* The same class of answer as Ruby with no advantage here; Ruby wins purely on the operator's
  own toolchain and on Tuile.

**Consequences.**

- **`CLAUDE.md`'s Bash convention is amended, not dropped** — Bash with `set -euo pipefail` remains the
  rule for `install`, `uninstall` and any future box script; Ruby is the rule for the CLI. A new script
  picks by which of the two it is.
- **The box gains a language runtime**, so `README.md`'s requirements grow `ruby`, and `install`
  installs it. `uninstall` does **not** remove it: it is an archive package that other things may share,
  and removing shared packages is not symmetry, it is collateral damage.
- **Target Ruby 3.2**, which is what the box runs — Ubuntu 24.04, fixed by `D_host_os`. (26.04's 3.3
  would have been fine too; it is not available for reasons that have nothing to do with Ruby.) Don't
  reach for syntax newer than 3.2 for the sake of it: the floor moves when the box does, not before.
- **Nothing on the box parses `shepherd2` output.** The verbs are for a human and for cron; keeping them
  free of a machine-readable contract is what stops the CLI growing into the `shepherd-cli` that
  `D_dokku_is_truth` refused.
- **The installers have exactly one non-Bash dependency: `python3`**, for editing
  `/etc/docker/daemon.json` around the `live-restore` key Dokku's postinst puts there — JSON surgery
  being the one thing on that list Bash genuinely cannot do. Ubuntu ships it; `README.md` lists it. It
  is also the sharpest form of the chicken-and-egg above: the address pools are install step 5 and
  `apt install ruby` is step 9, so at the moment that file is edited there is no Ruby on the box.
- **The Ruby half still shells out to `dokku`**, never to `docker` and never to `/var/lib/dokku`
  directly — `CLAUDE.md`'s *Conventions* are unchanged by the language. Ruby makes reaching around Dokku
  easier, which is the one risk this decision introduces.

## D_testing — minitest from the distro, no bundler; the CLI's seams are its test surface (2026-09-10)

**Status:** Accepted 2026-09-10 and applied the same day — `test/` exists and CI runs it. Follows
`D_ruby`, which forbids a `Gemfile` for the *runtime* and left open what testing then looks like.

**Context.** `D_ruby` put the CLI on the standard library alone: no `Gemfile`, no bundler, nothing to
re-install after a distro upgrade. That settles the box and says nothing about the repository, and the
obvious next question — "so how is it tested?" — has a tempting wrong answer, because a `Gemfile` for
test-only gems is what almost every Ruby project does.

The thing to be tested is also unusual. `create-app` is eight `dokku` invocations behind guards; its
*sequence* is the design (`SOLUTION.md` → *Flow — registering a project*), and a reordering that put
the first build before `network:set` would still deploy — onto the wrong network, silently.

**Decision.**

- **minitest, installed as `ruby-minitest` from Ubuntu's archive** (universe; 5.22.2 on noble). A
  dev-only dependency: it is documented in `test/run`'s header and **never appears in
  `shepherd2-install`** — the box runs the CLI, not the suite.
- **No `Gemfile`, no bundler, no `Gemfile.lock`, no Rakefile.** The suite is `ruby test/run`.
- **CI runs inside an `ubuntu:24.04` container**, not on the runner's toolchain, so the tests execute
  against the box's exact Ruby (3.2) and the distro's exact minitest.
- **The CLI takes its process-running seams as constructor arguments** — `Dokku`, `Docker`, `BuildLock`
  — and the tests inject doubles that record calls and replay canned output. What they assert is the
  command sequence.
- **A `ruby --disable-gems` load test** stands guard over `D_ruby`'s constraint, so "standard library
  only" is enforced rather than promised.
- **Dokku's own behaviour is not tested here.** That is the punch list in `RESEARCH.md`, run on a box.

**Why.**

- **One dev gem, packaged by the distro, is below bundler's line.** Bundler earns its keep resolving
  many gems and locking them; here it would exist to install a single test-only gem that `apt` already
  has, at the cost of a lockfile, `bundle exec` on every run, and a CI cache step.
- **Bundler would make CI *less* faithful, not more.** `bundle install` fetches from rubygems.org at
  whatever version resolves today — not the 5.22.2 the box's archive carries. Pinning the distro's
  exact version by hand in a `Gemfile`, forever, to recover parity we get for free, is the whole
  argument in miniature.
- **A `Gemfile` is the sanctioned place to add a gem.** `D_ruby`'s runtime constraint holds only while
  adding a dependency is visibly awkward; a test-only manifest is precisely the crack through which
  "just for tests" becomes "just for `create-app`".
- **The sequence is the design, so the seam is what makes it assertable.** Without one there is nothing
  to test but string building; with one, the eight-command registration flow, its guards and its
  re-runnability are pinned by fast unit tests and a reorder goes red.
- **Faking Dokku's *behaviour* would test our model of Dokku.** The doubles deliberately record and
  replay rather than simulate: what Dokku actually does is `RESEARCH.md`'s job, verified on a box, and
  a mock that "knows" how `git:sync` behaves would launder an unverified claim into a green test.

**Alternatives rejected.**

- *Bundler with rspec (or minitest).* The Ruby default, and right for an application with a gem
  runtime. Rejected on all three counts above. It becomes correct the day the dev toolchain needs more
  than one gem — see *Consequences*.
- *A zero-dependency assertion harness of our own*, ~40 lines, so `ruby test/run` works on a box with
  nothing but the interpreter. Genuinely tempting and matches the project's ethos; rejected because
  minitest's failure output is worth more than the 40 lines are worth saving. **Kept as the fallback**
  if `ruby-minitest` ever leaves the archive.
- *bats for the installer.* A third-party dependency to test a script whose entire risk is
  environmental — apt, debconf, a daemon restart. `bash -n` and `shellcheck` are the static half; the
  real test is running it on a snapshot, twice, once per mode.
- *Automated box-level integration tests* — spin a VM per run, install, deploy a real app. That is the
  punch list, and automating it costs a VM per CI run to test somebody else's product. v2 at best.
- *`gem install minitest` instead of the apt package.* Works, needs no bundler either, but pulls a
  version the box does not have and puts the test toolchain outside the distro — the exact thing
  `D_install_apt` and `D_ruby` avoid everywhere else.

**Consequences.**

- **The revisit trigger is a second dev gem.** If the toolchain ever wants rubocop, simplecov or a
  fixture library, bundler stops being ceremony and this entry gets rewritten. One distro-packaged gem
  is below that line; two is not.
- **CI is the only thing pinning Ruby 3.2.** Development machines run newer (26.04 ships 3.3), so a
  suite that passes locally proves nothing about the box's interpreter. That is why the workflow runs
  in a container and prints `ruby --version` as a step.
- **`ruby-minitest` must never enter `shepherd2-install`.** A test dependency on the box is how the
  next person concludes the box needs gems after all.
- **The fixtures are hand-written from `RESEARCH.md` until a box exists**, and are to be replaced with
  real `--format json` captures the first time one does — which is itself a small item on the punch
  list, since a fixture that never matched reality is worse than no fixture.

## D_admin_namespace — App ids beginning with `admin` are reserved (2026-09-10)

**Status:** Accepted 2026-09-10. Reverses the proposed drop of shepherd-java's reserved-id check, in a
different shape from the rule it replaces.

**Context.** shepherd-java refused project ids that collided with the admin plane — `admin` and
`*-admin` — and the feature survey proposed dropping the rule outright, on the correct observation that
there is no admin plane left to collide with. True today; likely false later. Every candidate in
`Q_web_admin` — a cron-generated status page, wharf, a reworked Vaadin admin, even a plain nginx vhost
serving build logs — is reached over http and therefore needs a hostname on this box's wildcard domain.
Hostnames here are first-come: the app name *is* the subdomain.

**Decision.** `create-app` refuses any id matching `admin*` — the whole prefix, so `admin`,
`admin-status` and `admintools` are all reserved. Nothing else is reserved by Shepherd2; Dokku's own
app-name restrictions (tightened in 0.38.2 against command injection) apply underneath and are Dokku's
business, not ours to restate.

**Why.**

- **A namespace is far cheaper to reserve than to reclaim.** Reclaiming one means renaming a live app,
  which changes its URL, breaks whatever links to it, and — because the app name is the Dokku app — is
  a destroy-and-recreate, losing the build cache with it. The cost of reserving is one regex, paid once.
- **The wildcard certificate already covers it.** `admin.mydomain.me` falls under `*.mydomain.me`
  (`D_cert`), so a v2 admin surface needs no certificate work at all, only a name that is still free.
- **A prefix beats an exact list.** shepherd-java's `admin` + `*-admin` protected two spellings and
  needed extending every time a new name was wanted. A prefix protects the whole namespace and never
  needs maintenance — which matters precisely because we do not yet know what the admin surface is
  called.
- **It costs one check in the one place ids are minted.** `create-app` is the only creation path
  Shepherd2 offers, and the check runs before anything is mutated (see `D_ruby`).

**Alternatives rejected.**

- *Reserve nothing* — the feature survey's proposal, on the grounds that the collision target is gone.
  Rejected because the collision target's absence is a v1 property, not a permanent one, and the rule is
  unaffordable to add later: by then someone owns the name.
- *Reserve shepherd-java's exact list* (`admin`, `*-admin`). The suffix half protects names nobody will
  choose; the prefix is where an admin surface actually lands.
- *Put the admin surface on the apex domain instead, and reserve nothing.* The apex domain is deferred
  (`D_cert`) and the apex is **not** covered by the wildcard certificate, so that route costs a second
  certificate before it costs anything else. A reserved subdomain costs nothing.
- *Enforce it in Dokku rather than in `create-app`* — an `app-create` plugin trigger of ours. Rejected
  by `CLAUDE.md`'s standing rule against maintaining a plugin, and unnecessary under `D_single_operator`:
  the one person who could bypass the rule by typing `dokku apps:create admin-foo` is the person the
  rule is for.

**Consequences.**

- **Reserved project ids are preserved, not dropped** — the feature survey had them on its drop list,
  wrongly, and the rule that replaced them is broader than the original.
- **v2's admin surface has a name waiting for it**, on https from the day it exists, with no
  certificate step and no rename of anything.
- **`destroy-app` needs no counterpart** — nothing was allocated, only refused.
- **A hand-typed `dokku apps:create admin-foo` is not blocked**, by design. Shepherd2 validates its own
  entry point and does not police Dokku's.

## D_host_os — The box is Ubuntu 24.04; 26.04 waits on upstream (2026-09-10)

**Status:** Accepted 2026-09-10. Applies to the reference box *and* to the VM this is developed in —
deliberately the same, so a bug is never "the dev machine is a different distro". Revisit when the two
upstream items in *Why* both clear; this entry is edited in place when they do, which is why its slug
names the subject and not the version.

**Context.** Ubuntu 26.04 LTS is out and is the obvious default for a new box; the operator asked
whether to use it. Dokku is the whole of this product's runtime (`D_dokku`), so the question is
entirely about what Dokku supports, not about what the distro offers us.

**Decision.** **Ubuntu 24.04 LTS, on the box and on the development VM.** Dokku pinned as already
decided, everything else from the distro archive. 22.04 and Debian 11+ are Dokku-supported and would
probably work, but they are not what we run and not what we test.

**Why — the state of 26.04, checked 2026-09-10.**

- **Dokku's installer refuses to run.** `bootstrap.sh` reads `VERSION_ID` from `/etc/os-release` and
  exits unless it is one of `22.04 24.04 10 11 12 13` **[src]**. The documented two-command install is
  therefore not available at all; the docs list the same two Ubuntu releases **[docs]**.
- **No `dokku` package is built for `resolute`.** packagecloud carries the whole satellite set for that
  dist — herokuish, plugn, sshcommand, sigil, procfile-util, netrc, lambda-builder, the two docker
  helpers, `dokku-update`, `dokku-event-listener` — but not Dokku itself, which stops at `noble`
  **[verified against the dist indexes]**.
- **Upstream is aware and stalled.** Issue #8768 (opened 2026-06-23) and PR #8791 (opened 2026-07-03),
  the latter a one-line addition to the version whitelist, with no maintainer response and no movement
  in two months.
- **bash 5.3 is the real risk, not the whitelist.** 26.04 ships bash 5.3, which already turned a
  tolerated pattern into a **hard error** in four of Dokku's builder plugins (#8566, fixed by #8578 and
  present in v0.38.27). Dokku is mostly bash, its CI runs 22.04/24.04, and that bug reached a user
  rather than a test. `core-post-extract` — the plugin that broke — is on every build's path here.

**Why not the workaround.** It exists and it is small: patch the downloaded `bootstrap.sh`'s whitelist,
and the script's own codename fallback (any unrecognised Ubuntu codename → `noble`) installs the noble
deb. Every dependency resolves — the distro ones are all in 26.04, the packagecloud ones are published
for `resolute` at the required versions, and Docker publishes a `resolute` dist so `get.docker.com`
works. Rejected anyway: it puts the one component we deliberately do not maintain onto a platform its
maintainers do not test, and turns every future oddity into "us, Dokku, or bash 5.3?" — which is the
debugging tax `D_dokku` exists to stop paying. Being one merged line away from supported is a reason to
wait, not a reason to hack.

**Alternatives rejected.**

- *26.04 now, with the patched bootstrap and the noble package channel.* Above. It is what to do if
  something ever forces 26.04 before upstream is ready — a hardware or kernel requirement, say — and it
  would need this entry rewritten, not a quiet `sed` in the installer.
- *A 26.04 development VM against a 24.04 box.* Cheap-looking and the worst of the options: it puts a
  bash-version difference between where a script is written and where it runs, on a product that is
  almost entirely shell and cron.
- *22.04, the older LTS.* Supported by Dokku, but older for no benefit; 24.04 is the newest thing Dokku
  actually tests.

**Consequences.**

- **Ruby 3.2 is the floor** — what 24.04 ships — which supersedes the 3.0 floor `D_ruby` set for 22.04.
- **`install` should refuse 26.04 with a real message** rather than letting `bootstrap.sh` fail with a
  distro error the operator has to decode. The preflight is the place; see `SOLUTION.md`.
- **26.04 costs us nothing else.** lego is the same 4.9.1 there as on 24.04, so `D_cert` is unaffected
  either way, and Ruby 3.3 would have been welcome but is not needed.
- **What to watch:** dokku/dokku #8791 merging *and* a `dokku` deb appearing in packagecloud's
  `resolute` dist. Both, not either — the whitelist alone only unlocks installing the noble package.

## D_install_apt — Install Dokku from the authors' deb with apt, not by running `bootstrap.sh` (2026-09-10)

**Status:** Accepted 2026-09-10, **implemented as the first half of `shepherd2-install` and run on a
box 2026-09-11** — twice, since the install is re-runnable and the first attempt failed at a later
step. It changes *how* Dokku is installed, not *what* is installed: the package is upstream's own, at
the pinned version.

**Context.** Dokku's documented install is two commands — fetch `bootstrap.sh`, run it as root with
`DOKKU_TAG` set. The operator does not want to run a shell script fetched from the internet as root,
and prefers a distribution package from the authors. Both halves of that are available here, because
**the deb *is* the authors' artifact**: `bootstrap.sh` does not build anything, it adds
packagecloud's `dokku/dokku` apt repository and runs `apt-get install dokku=<version>`.

Read at v0.38.27, its ten steps on our path are enumerated in `RESEARCH.md` → *Versions, platform,
install*; the short version is that nine of them are apt plumbing and the tenth is
`plugin:install-dependencies --core`. Everything else in the file is other distributions, the source
path, and version branches back to 0.3.13.

**Decision.** `shepherd2-install` performs those steps itself, with apt, and **never runs
`bootstrap.sh`**. Concretely, and in this order:

- **Docker first, from Ubuntu's own archive** — `docker.io`, `docker-buildx` and `docker-compose-v2`,
  installed explicitly, before Dokku. Not `get.docker.com`, and not Docker's apt repository: one fewer
  third-party key and source, and upgrades come from the distro like everything else. **The staleness
  worry does not apply to 24.04** — `noble-updates` carries `docker.io` 29.1.3, `docker-buildx` 0.30.1
  and `docker-compose-v2` 2.40.3 (checked 2026-09-10), and Dokku requires only >= 19.03.
- **Prerequisites:** `gpg-agent`, `software-properties-common`, `add-apt-repository universe` — which
  `D_cert` needs anyway, since lego lives in universe.
- **Dokku's repository, key-scoped:** packagecloud's key into
  `/usr/share/keyrings/dokku-archive-keyring.asc`, checked against a fingerprint pinned in the
  installer, and referenced with `signed-by=` on the sources line.
- **The debconf answers, preseeded deliberately** (`dokku/hostname`, `dokku/vhost_enable`,
  `dokku/key_file` or `dokku/skip_key_file`, `dokku/nginx_enable`) rather than left to the package's
  defaults.
- **`apt-get install dokku=0.38.27`** — the version pin, in one place.
- **`dokku plugin:install-dependencies --core`** afterwards.
- **`apt-mark hold dokku`**, so no unattended upgrade moves it. Upgrading is a deliberate runbook
  sequence in `README.md`.

**Why.**

- **It is the same package from the same authors.** There is no second, more official deb; this is
  upstream's distribution channel, and the pin is the same version string bootstrap would have passed.
  `CLAUDE.md`'s "Dokku stays upstream and unforked" is untouched — we are declining a *convenience
  script*, not the product.
- **We are writing an installer anyway**, and its stated job is that the box is
  reproducible from this repo. A dozen apt lines we can read and re-run beats a 300-line script that
  branches across five distros, two install methods and versions back to 0.3.13, of which our box
  exercises exactly one path.
- **The pin stops being double.** Today the version has to match in the `bootstrap.sh` URL *and* in
  `DOKKU_TAG`; as an apt version it is written once, and a mismatch becomes impossible rather than
  merely documented.
- **Ubuntu's Docker satisfies Dokku's packaging on its own terms.** `docker.io` is one of the seven
  alternatives Dokku's deb accepts for the engine, `docker-buildx` one of three for buildx, and
  `docker-compose-v2` declares `Provides: docker-compose`, which is the third compose alternative. So
  nothing is being forced: apt resolves the dependency the way the package author allowed for.
- **Three concrete security improvements, none of them theatre:** no root shell pipeline from the
  internet (neither Dokku's nor Docker's), a key scoped with `signed-by=` instead of
  `/etc/apt/trusted.gpg.d/dokku.asc` — which bootstrap installs, and which trusts that key for *every*
  repository on the box — and a fingerprint we check rather than assume.
- **We know our debconf answers.** Preseeding them explicitly is how the install stays non-interactive
  *and* intentional; bootstrap only forwards them when the caller sets five environment variables.

**Alternatives rejected.**

- *Run `bootstrap.sh` as documented.* The upstream-blessed path, and the thing our steps must stay
  faithful to — it remains the reference and the fallback. Rejected for the reasons above; the
  ten-second sleep, the `get.docker.com` pipe and the multi-distro detection are all cost we pay for
  nothing on a single known box.
- *Install from source (`make install`), the "advanced installation" route.* Rejected: it builds on
  the box, has no apt upgrade path, and is *further* from what upstream tests, not closer.
- *Docker CE from `download.docker.com`* — what `get.docker.com` installs, and what this entry
  originally specified. Rejected on 2026-09-10 once the versions were checked: it buys a marginally
  faster upstream cadence at the cost of a second third-party key and apt source, on a box whose whole
  install story is "readable and from the distro". It stays the documented fallback for the day
  Ubuntu's engine lags something Dokku needs — swapping back is three lines in `install` and touches
  nothing else in this repo.
- *`docker.io` alone, letting apt pull the rest as dependencies.* Rejected on a sharp edge, recorded in
  *Consequences*: `docker-compose` is a **real** package in Ubuntu (the obsolete Python v1, 1.29.2), so
  apt resolving Dokku's alternation unaided installs that rather than the v2 provider.
- *Vendor the `.deb` into this repo.* A third-party binary in git, no upgrade path, and one more thing
  to re-verify by hand at every bump.

**Consequences.**

- **`install` must not silently drift from `bootstrap.sh`.** When the Dokku pin is bumped, re-read
  upstream's `bootstrap.sh` at that tag and diff it against our steps — this is the maintenance cost
  this decision buys, and the script's comment header carries the list of steps it mirrors so the diff
  is cheap.
- **Two preflight checks come from bootstrap and must survive:** `hostname -f` has to resolve, and the
  operator has to be told that installing Dokku empties `/etc/nginx/sites-enabled`.
- **Install `docker-compose-v2` by name, before Dokku.** Dokku's compose alternative is
  `docker-compose-plugin | moby-compose | docker-compose`; Ubuntu has no plugin package, and
  `docker-compose` **is a real package** — the obsolete Python v1 (1.29.2) — so apt left to itself
  installs *that* rather than the v2 package that merely `Provides` the name. Installing v2 first
  satisfies the dependency and the legacy package is never considered. The same ordering argument is
  why `docker.io` goes in before Dokku at all.
- **`docker-compose-v2` must come from `noble-updates`, not the release pocket.** 24.04 shipped 2.24.6,
  which does **not** declare `Provides: docker-compose`; 2.40.3 in updates does. Updates are enabled by
  default, so this is a fact to know when something looks wrong, not a step.
- **Install Dokku *with* recommends — never `--no-install-recommends`.** `herokuish` is a **Recommends**
  of the `dokku` package, not a Depends, and herokuish is the builder this whole box is built around
  (`D_builder`). So are `dokku-update` and `dokku-event-listener`. Suppressing recommends produces an
  installation that looks fine until the first build.
- **Docker now lives in `universe`.** That is where `docker.io` and friends are, so security updates
  come through Ubuntu's universe pockets (they do — 24.04's 29.1.3 arrived that way) and the long-tail
  guarantee is Ubuntu Pro's. `add-apt-repository universe` is already a step for lego's sake.
- **Upgrading Dokku becomes explicit** — `apt-mark unhold`, install the new pinned version, re-run
  `plugin:install-dependencies --core`, `apt-mark hold`. A `README.md` runbook line, not a script:
  it is `apt`, not something Dokku lacks a command for.
- **If packagecloud is ever unavailable**, the fallbacks are upstream's `bootstrap.sh` or the source
  install, in that order. Recorded, not planned for.

## D_no_feature_list — The feature set gets no durable file; the `F_` slugs are retired (2026-09-10)

**Status:** Accepted 2026-09-10 and applied the same day: `ideas/features-to-preserve.md` is deleted and
every `F_` citation swept out of the durable files and the two surviving idea notes.

**Context.** Shepherd2 is the third implementation of the same product, so the rebuild opened with a
migration inventory — every feature the old box had, what Dokku answers it with, and a verdict of
*Dokku does it* / *glue we write* / *dropped* / *deferred*. That inventory lived in
`ideas/features-to-preserve.md` and gave each row a slug, `F_poll_rebuild`, `F_wildcard_https`,
`F_safe_reboot` and 36 more. The slugs were useful while the design was open: a `D_` entry could say
"costing `F_ingress_tuning`" and the reader could look the row up. By 2026-09-10 every row had a verdict
and the note was a ledger awaiting graduation — but it was also the only place any of the 39 slugs was
*defined*, and they were cited 69 times across `DECISIONS.md`, `SOLUTION.md`, `RESEARCH.md`,
`CLAUDE.md` and two other idea notes.

**Decision.** **There is no feature list, and no `F_` namespace.** The graduation dropped the slug at
every citation and kept the prose. What each surviving feature *is* is described where it lives: the
preserved half in `README.md` → *Day-to-day operations* (task → command) and in `SOLUTION.md`'s
inventory, CLI surface and flows; the deferred half in `SOLUTION.md` → *What v1 does not do*; the
dropped half in `CLAUDE.md` → *What is deliberately gone* and in the `D_` entry that dropped it. The
enumerated-slug rule in `CLAUDE.md` now applies to exactly two namespaces: **`D_` in `DECISIONS.md`,
`Q_` in `ideas/`.**

**Alternatives rejected.**

- *A seventh documentation target, `FEATURES.md`, owning the slugs and the migration table.* The
  `D_research_md` move, and the reason it doesn't apply: `RESEARCH.md` holds facts about a product we
  don't own, which have no other home. A feature row holds facts about *this* box, and every one of
  them already has a home — so the file would be a fourth copy that drifts, which is the failure mode
  the *Documentation targets* table exists to prevent.
- *A compact `F_` → one-line → decided-by table in `SOLUTION.md`.* The cheap option: it keeps all 69
  citations valid for the price of one table. Rejected because a table of names and one-line glosses,
  with the substance elsewhere, is a **glossary** — which this repo deliberately does not have — and
  because it would define `F_web_admin`, `F_postgres` and `F_user_login` inside the file that describes
  what the box *holds*.
- *Keep the note alive as the definition file.* What the note itself proposed, on the grounds that the
  migration view has no other home. Rejected on the `ideas/` contract: a note that never graduates is
  the stale `ideas/` folder the convention exists to prevent, and "is worth keeping until someone
  confirms it has no readers" is not a lifetime.
- *Half-retire — keep the slugs that read well, drop the rest.* Worse than either end. A namespace whose
  definitions are gone but whose citations survive sends the reader looking for a file that was deleted.

**Consequences.**

- **Don't reintroduce an `F_` namespace, or any feature-list file.** If a feature needs naming from a
  distance, name it in prose and link the file that owns it. This is the invariant `CLAUDE.md` carries.
- **The migration view is gone on purpose, and it is recoverable.** Feature-by-feature "what did
  shepherd-traefik do and what replaced it" is answered by git history here plus both predecessors,
  which stay readable on GitHub — the same reason `CLAUDE.md` forbids copying their decisions in.
- **`COMPARISON.md` in shepherd-traefik is not a feature list, and a reader sent there will assume it
  is.** Its `R_` boxes are *requirements for choosing a product*, written to discriminate between
  Coolify, Dokploy, Dokku and CapRover, so they compress or omit anything all four did equally.
  Building the inventory from Shepherd's own scripts and shepherd-java-client turned up **11 features
  with no `R_` box at all**, most of them in the component being deleted. So `COMPARISON.md` answers
  "should some other PaaS have been picked", nothing more — which is how `README.md` cites it.
- **The `README.md` cheat sheet is load-bearing now, not a convenience.** It is where the *Dokku does
  it* rows landed, and `D_dokku_is_truth` and `SOLUTION.md` both promise it exists. A day-N capability
  that is in neither the cheat sheet nor a `dokku` command is a capability this box has quietly lost.
- **Four open questions kept their `Q_` slugs and got notes of their own** —
  `ideas/multi-user-ownership.md`, `ideas/web-admin-ui.md`, `ideas/box-memory-quota.md`,
  `ideas/private-repo-credentials.md`. The *answered* questions (`Q_descriptor`, `Q_proxy`, `Q_cert`,
  `Q_cache`, `Q_isolation`, `Q_language`, `Q_build_history`) are cited nowhere any more: an entry that
  used to point at one now points at the `D_` entry that answered it, or at `RESEARCH.md`.

---

## D_poll_churn — Raise Dokku's build retention and read past the churn with `last-build`; the poll keeps calling `git:sync` (2026-09-11)

**Status:** Accepted 2026-09-11 and implemented the same day — `builds:set --global retention 300` in
`shepherd2-install` → *Global Dokku properties*, and the `shepherd2 last-build` verb. The upstream bug
report is part of this decision and not yet filed. The `ls-remote` guard in `poll` is **deferred, not
rejected** — see *Consequences*.

**Context.** `dokku git:sync --build-if-changes` starts a build record *before* it fetches and before it
compares refs, and its no-change path returns without finalizing that record (`RESEARCH.md` → *Build
tracking*, `[src]`). The `*/5` poll therefore writes 288 records and 288 log files per app per day when
nothing at all is happening. Measured on the probe box on 2026-09-11, every step of that held:

- Three no-op ticks left three records at `status: running` / `display_status: abandoned`, one 244-byte
  log apiece. Reaping stamps `finished_at` at the reap moment, so a one-second no-op is later recorded
  as a **1m29s failed build**.
- The next real deploy reaped all three as `status: failed`, `exit_code: -1` — on disk,
  indistinguishable from a build that really failed.
- Sixteen further ticks pushed the *successful* real deploy out of Dokku's default 20-row listing. At
  288 ticks a day that window is **~100 minutes**, so "why did last night's deploy fail?" was
  unanswerable by breakfast — and a later deploy is what then deletes it for good.

Two things the measurement changed. First, the churn was never cosmetic: `shepherd2 wait-idle` filtered
running builds on `status`, which an abandoned tick holds forever, so on any box that had been up five
minutes it blocked until timeout and exited 1 — the verb that exists to make a reboot safe, broken by
poll noise. (Fixed by keying off `display_status`, Dokku's own liveness check on the recorded pid.)
Second, **`builds:set retention` exists** — globally and per app, reverting cleanly — which nothing in
the design had noticed.

**Decision.** Three parts, and the first two are the whole of v1:

1. **The install raises retention to 300 records per app.** One line next to `builder:set` and
   `ps:set`. 300 ticks is about a day, which is the horizon the one question worth answering needs.
2. **`shepherd2 last-build [ID] [--log]` is how a build is read**, because neither of Dokku's own
   answers survives the churn: `builds:report` names the newest record, which on an idle box is always
   an abandoned tick, and `--status failed` selects reaped ticks alongside real failures. The verb
   reports the newest record that really built — `status` in `succeeded|failed|canceled` **and**
   `exit_code != -1` — or the build running right now if there is one.
3. **The ordering gets reported upstream.** `CLAUDE.md`'s *Dokku stays upstream and unforked* makes a
   bug report the sanctioned move, and this looks like a plain bug rather than a design position: a
   record is opened for a run that may never build, and the no-change path is the only exit that skips
   finalization. Filed 2026-09-11 as
   [dokku/dokku#9030](https://github.com/dokku/dokku/issues/9030). A fix upstream retires all three
   parts of this decision.

**Alternatives rejected.**

- *Pre-check the remote ref in `poll` (`git ls-remote` against `config:get GIT_REV`) and skip `git:sync`
  entirely when it has not moved.* The original favourite, and **deferred rather than rejected**: it is
  cheaper than the status quo (one `ls-remote` replaces a full fetch for 287 of 288 ticks) and it stops
  the churn at the source instead of tolerating it. Not in v1 because it puts a *second* copy of
  Dokku's change detection in our code — the shape `CLAUDE.md` warns about — and retention 300 buys
  the year or so that waiting for an upstream fix might take. If it ever lands it is a tidy-up, not a
  repair.
- *Accept the noise and stop treating the records as history.* Zero lines, and honest. Rejected because
  the cost it accepts is the only build-log story the box has, and the two parts taken instead are a
  line of Bash and a read-only verb.
- *Tee `git:sync`'s output to a log of our own, per app.* Exactly the glue `D_dokku_is_truth` was
  pleased to delete: rotation, disk growth, and a second place to look. Only worth it if Dokku's
  records were unreadable, and they are merely noisy.
- *Retention per app, set by `create-app`.* Rejected as strictly worse: the churn rate is the same for
  every app because the cron is box-wide, so a per-app value is a global value with N places to drift.
  The per-app override stays available for an app that wants a different window.
- *A much larger retention — 2000, say, so nothing is ever pruned.* The point of a window is that it
  closes; a number chosen to never close is a leak with extra steps. 300 is picked to cover the
  overnight question and nothing more — and since `last-build` reads a filtered listing, which Dokku
  never caps, a bigger number would buy it nothing anyway.
- *A general build-history surface in the CLI — `shepherd2 builds`, `shepherd2 logs`.* This is
  `shepherd-cli` reincarnated and `CLAUDE.md` forbids it. `last-build` reports exactly one build and
  points at `dokku builds:list` / `builds:output` for everything else, which is the line between a
  verb Dokku lacks and a wrapper around verbs it has.
- *Patch Dokku, or carry a plugin of our own.* `CLAUDE.md`: Dokku stays upstream and unforked. The
  sanctioned moves are a wrapper, a cron line, a documented manual step — or a bug report, which is
  part 3.

**Consequences.**

- **`dokku builds:report ID` still lies, and nothing here fixes that.** It reports the newest record,
  so on an idle box it calls a healthy app's build status `abandoned`. Read `shepherd2 last-build`
  instead; the cheat sheet says so.
- **`--status failed` is still polluted, and `exit_code` is the only discriminator.** A reaped tick
  always carries `-1` and a real failure the builder's own positive code; `kind` does not help, because
  `git:sync` maps to `build` either way. The one case this mislabels as churn is a real build the box
  killed mid-flight — a reboot during a build, reaped the same way — for which `dokku logs:failed ID`
  is what is left.
- **`shepherd2 last-build` has an expiry date, stated in the script header.** Delete it when the
  upstream ordering is fixed or when the `ls-remote` guard lands. Nothing else in the CLI depends on
  it, which is the property that keeps deleting it cheap.
- **`builds:list ID` is now ~300 rows of noise instead of ~20.** Deliberate: the record surviving
  matters more than the listing being short, and the listing was already mostly noise at 20.
- **Retention caps a listing; it does not delete anything — and the box corrected this entry on
  2026-09-11.** Polling evicts nothing: records pile up on disk untouched (41 observed against a
  retention of 20) and only the *unfiltered* listing is cut to the count. Deletion happens in
  `PruneAppBuilds` at the end of a **real deploy**, which keeps the newest by `started_at` — so it is
  the next deploy that removes the *older real build* while keeping the ticks that are newer than it
  (`RESEARCH.md` → *Build tracking*). Three things follow:
  - **A failed build's log survives until something deploys**, which under `--build-if-changes` means
    until upstream moves. That is better than this entry first claimed, and it is the reason the
    overnight question is answerable at all.
  - **300 is about visibility and about the prune threshold**, not about buying time before eviction.
    At the `*/5` cron it is ~25 hours of ticks; changing the poll cadence changes that horizon.
  - **`last-build` must pass a filter**, because Dokku skips the cap for any filtered listing. It sends
    `--kind build`, which is why it still finds the last real build under an app idle for days. Reading
    the default listing — what it did first — reported "no real build" with the record and log sitting
    on disk.
- **`wait-idle` must key off `display_status`, not `status`**, and that is not a detail of this entry
  but its most expensive consequence: the same churn that eats build logs makes a `status`-based
  liveness check permanently true. Anything else that ever asks Dokku "is a build running?" inherits
  the same trap.
- **`ideas/build-failure-notifications.md` (v2) is partly unblocked.** It deferred its alert design
  because a failed build's log vanished before anyone could be pointed at it; with a day of retention
  and `last-build`, an alert can now name a build that will still be readable when the mail is opened.

## D_stats — `stats` reports the box's capacity; it is a snapshot, never monitoring (2026-09-11)

**Status:** Accepted 2026-09-11, shipped with the verb.

**Context.** Two questions come up on a single-box farm and nothing on the box answers either. *Will
another project fit?* — free memory does not say, because the apps are idle but capped, and Dokku has
no command that sums anything across apps (`RESEARCH.md` → *What Dokku does not do*: "nothing sums them
or refuses an over-committing app"). *What is eating the disk?* — the per-app build cache is a
`cache-<app>` Docker volume that nothing garbage-collects (`D_builder`), and **nothing in Dokku knows
that volume belongs to an app**: `repo:purge-cache` deletes it by name and that is the whole of Dokku's
awareness. Monitoring is explicitly out of scope for Dokku, so there is no command to wrap and no
plugin to install — the box ships with no way to answer either question short of `df`, `free`,
`docker system df -v` and arithmetic by hand.

**Decision.** One verb, `shepherd2 stats [--json]`, printing a box section (memory, committed memory,
swap, the filesystem behind Docker's root dir), a docker section (images, volumes) and one line per
project (its cache volume). **And a boundary, which is the other half of the decision:** `stats` is a
*snapshot*, not monitoring. No `--watch`, no history, no thresholds, no alerting, no exit code that
depends on how full the disk is, no per-container CPU — `docker stats` is that, and the `README.md`
cheat sheet already points at it. A `stats` that grows a time axis has become the status page in
`Q_web_admin`, which is a separate decision with a separate hostname waiting for it
(`D_admin_namespace`).

**Why.**

- **It is on the right side of *Shepherd2 never wraps a command Dokku already has*.** Same test
  `last-build` passes: the question has no Dokku command, and the part that makes it *ours* is the
  attribution — `cache-<app>` ↔ app — which only Shepherd2's own naming convention makes possible.
- **The committed figure is the answer to the question actually being asked.** Runtime limits summed
  across every app, plus *one* build limit rather than one per app, because the poll's non-blocking
  lock means one build runs at a time box-wide (`SOLUTION.md` → *Flow — a poll tick*). An app with no
  readable limit is **named, not counted as zero** — the sum would otherwise be quietly wrong in the
  one direction that matters.
- **Every app is counted, registered or not.** A hand-made `dokku apps:create` never enters the poll,
  but it eats the box's memory and disk all the same. Printing it as `(unregistered)` is also the only
  place that drift is visible (`D_dokku_is_truth` — we read Dokku's state, we do not maintain a list).
- **`--json` from the start, because the consumer is already sketched.** Option 1 in `Q_web_admin` is a
  cron-generated status page fed by `--format json` reports; this is the one report Dokku cannot
  provide, so emitting bytes-as-integers now costs a few lines and saves that page from parsing a page
  meant for a human.
- **Binary units (`GiB`), not Docker's SI.** The operator checks this page against `free -h` and
  `df -h`, both binary; an 8 GiB box printed as "8.6 GB" reads as a bug. The unit label carries the
  difference — a volume Docker calls `1.2GB` appears here as `1.1 GiB`.

**Alternatives rejected.**

- *Leave it to `docker system df -v` and `free`.* That is what exists today, and it answers neither
  question: `system df -v` lists volumes by name with no idea which app owns one, and neither knows
  what the box has *promised* to apps that are currently idle.
- *Two verbs — `stats` for the machine, something else for the projects.* The two numbers are only
  useful next to each other: a cache size means nothing without the free space it is eating.
- *A cron that mails when the box is over-committed* — option 2 in `Q_quota`. Not rejected so much as
  **not yet**: this verb is its measurement half, and a notifier needs the transport question in
  `ideas/build-failure-notifications.md` settled first.
- *Refuse an over-committing `create-app`.* That is `Q_quota` itself, still open, and still open for
  the same reason: `create-app` is the only enforcement point available and a later hand
  `dokku resource:limit` routes around it. Reporting has no such hole — it re-reads Dokku's state every
  time it runs.
- *Measure the cache with `du` on the volume's mountpoint* rather than asking the daemon. Kept in
  reserve: it needs no size-string parsing and gives exact bytes, and `docker system df -v` hands us
  the mountpoint anyway. Rejected for now because one call answers both the per-project and the
  box-wide question, and because walking Docker's storage directory ourselves is precisely the
  reaching-around that `CLAUDE.md` warns about.
- *Sum image sizes the way `docker system df` does.* Its non-verbose totals are computed by the daemon
  and cannot be derived from the verbose listing without a second call and a second walk of every
  volume. `stats` sums *unique* sizes instead, which under-reports a shared base layer rather than
  double-counting it, and reports as reclaimable only what `shepherd2 clearcache` actually removes —
  the dangling images, not every unused one.

**Consequences.**

- **`stats` is interactive-only and nothing periodic may call it.** The daemon walks every volume's
  directory to answer `system df -v`, so on a box with a warm multi-gigabyte Maven cache the verb takes
  seconds. Cost unmeasured on a real box — `RESEARCH.md`'s punch list, item 21.
- **A second `docker` call joins `clearcache`'s.** Shepherd2 now reaches the daemon in two verbs rather
  than one, both for things Dokku has no command for, both named in the script header as
  `CLAUDE.md` requires.
- **Orphaned `cache-*` volumes become visible.** `apps:destroy` removes the cache volume with the app
  (verified, `RESEARCH.md`), so the orphan list should stay empty forever; an entry in it is a
  regression in that behaviour, which nothing else on the box would surface.
- **`Q_quota` keeps its slug and its question.** Its *reporting* half has landed here; the enforcement
  point it was really about is untouched, and `SOLUTION.md` → *What v1 does not do* still says there is
  no memory quota — because there is not.
- **Shepherd2 now parses two size conventions.** Docker's SI strings on the way in, binary limit
  suffixes out of `resource:limit`, one renderer in IEC units. Anything added here has to pick a side
  deliberately; the units test is what keeps that honest.

## D_api_surface — The verbs are a Ruby API that returns data; rendering belongs to the front-end (2026-09-11)

**Status:** Accepted 2026-09-11 and **implemented the same day**: `shepherd2.rb` and `shepherd2-cli`
exist, both installers place them, and the suite is split along the same seam. Not yet run on a box.
Refines `D_ruby`, whose "one file on `PATH`" this splits in two without moving the command.

**Context.** The CLI is one file of 1180 lines, 621 of them code, and the layering a second front-end
would need is already most of the way there: `CLI` does argument parsing and nothing else, `Shepherd2`
holds one public method per verb, and the four process seams (`Dokku`, `Docker`, `Machine`,
`BuildLock`) are constructor arguments. What it does not have is a *boundary*. `Shepherd2` takes
`out:`/`err:` and prints prose (`say "polling demo"`), owns ~120 lines of renderer (`print_box` …
`human_bytes`), reads `$stdin` directly to confirm a destroy, and returns an exit code from every verb.

That is invisible while the only caller is a terminal. `Q_web_admin`'s option 4 — a Tuile TUI — is
the candidate `D_ruby` already leaned on when it put Ruby on the box ("that TUI shells out to — or
eventually requires — the same code"), and *requires* is the half that does not work today. A TUI
calling `poll` gets an integer and a stream of prose to scrape; a TUI calling `destroy_app` has its
keyboard stolen mid-frame by a `$stdin.gets` inside the API; and every verb that builds streams Dokku's
build log straight to fd 1, because `Dokku#run` is `system` with the terminal attached.

**Decision.**

- **The verbs return data, never text.** `stats` returns the hash it already assembles, `last_build` a
  build record or `nil` — and, with `log:`, that build's captured output as a string — `poll` a
  per-app result list, `rebuild` `:built` or `:busy`. The mapping from those onto `EXIT_OK` /
  `EXIT_FAILURE` / `EXIT_BUSY` is the executable's job, and `EXIT_*` exist only there.
- **Progress leaves through a listener; the confirmation comes in as a callback.** No `out:`, no `err:`,
  no `$stdin` in the API. `destroy_app` takes `confirm:`, defaulting to the tty prompt the CLI wants.
- **Nothing renders, nothing streams, every return value is a snapshot.** `Dokku#run` **discards** the
  child's output by default; the executable opts into inheriting the terminal, because watching a build
  scroll past is what an operator onboarding a project wants. Discarding loses nothing: Dokku captures
  every build's output to `<build-id>.log` itself (`RESEARCH.md` → *Build tracking*), which is what
  `last-build` then reads.
- **Three verbs block for the length of a build, and that is Dokku's execution model rather than ours.**
  `git:sync` is fully synchronous and its exit code *is* the build's (`RESEARCH.md` → *`git:sync`*,
  from source), so `create-app`, `poll` and `rebuild` return when the container is up. Blocking and
  streaming are separate properties and only the second is ours to remove: a front-end that cannot
  block calls these off its UI thread and watches the listener. `wait-idle` blocks by design.
- **Each verb's rdoc says what it waits for**, in the concrete terms a caller needs — "blocks until the
  project has been built and deployed, which is minutes" rather than a flag. `stats` walks every
  Docker volume and `clearcache` prunes the daemon, so the honest reading is that no verb belongs on a
  UI thread; the rdoc is there to say which ones will hold it for minutes rather than a moment.
- **Two artifacts.** `shepherd2.rb` is the library, named for the class it defines; `shepherd2-cli` is
  the executable, holding `CLI`, every renderer, the exit codes and the root check.
- **Everything nests under `Shepherd2`** — `Shepherd2::Dokku`, `::Docker`, `::Machine`, `::BuildLock`,
  `::Error` (was `Shepherd2Error`), `::UsageError`, and the defaults `create-app` reads.
- **The installed command does not change.** Both files go to `/usr/local/lib/shepherd2/`, with
  `/usr/local/bin/shepherd2` a symlink to the executable. `shepherd2 poll` stays `shepherd2 poll`.

**Why.**

- **The split enforces what discipline would not.** Returning data is a rule someone breaks six months
  later with one `@out.puts` in a verb, and a reviewer will not catch it. With the renderer in another
  file there is no `@out` in scope: the API *cannot* print. That is the whole reason for two files —
  not length, which barely moves (roughly 850 lines of library against 300 of executable).
- **The confirmation is the sharp case.** Prose on stdout merely makes a TUI ugly; `$stdin.gets` in the
  middle of `destroy_app` takes its input away. Nothing short of removing it from the API fixes that.
- **Named for its class because a loader will care.** Zeitwerk maps file to constant, so
  `shepherd2-api.rb` would demand the constant be `Shepherd2Api`. Nesting the seams is the same
  argument one level down: `shepherd2/dokku.rb` → `Shepherd2::Dokku` later, with no rename. It also
  stops a `require` of this library dropping bare `Docker` and `Machine` into a caller's namespace —
  which a Docker-adjacent TUI is entitled to want for itself.
- **The installed name is an interface and the repo name is not.** There are 66 `shepherd2 <verb>`
  references across `README.md`, `SOLUTION.md`, `DECISIONS.md` and `ideas/`, plus both cron lines
  (`shepherd2-install`, step 10) and the hint `last-build` prints. A symlink keeps every one of them
  true, so the rename costs four lines across the two installers.
- **This adds no layer.** The API is not something new between the CLI and Dokku; it is the object that
  exists today with its printer removed. Nothing gains an indirection, and the verbs keep reaching
  `dokku` directly.

**Alternatives rejected.**

- *Leave it one file and keep the discipline.* Free today, and the failure mode is the one above: the
  boundary is unenforced exactly where it is easiest to cross. The data-returning half would still be
  needed for the TUI, so this saves only the split.
- *Keep rendering in the API behind an injected formatter*, one implementation per front-end. Tempting
  — one file, one seam more. Rejected because it puts the API in charge of *what to say*, which is
  precisely what differs between a scrolling terminal and a repainted pane: the TUI would be writing
  against an interface shaped by the CLI's needs. Data out, and each front-end decides.
- *Detach the build so every verb returns immediately* — spawn `git:sync` and hand back a build id,
  which would make the whole API non-blocking and is the shape a UI would prefer. Rejected because
  Dokku offers no detached build and doing it ourselves discards the two things that make the design
  work. The **exit code is the only trustworthy status** — `D_poll_churn` exists because the build
  *records* are not, and `RESEARCH.md` puts it plainly: a caller branches on `$?` and needs no other
  progress signal. And **the lock's duration is the build's**: `poll` holds `BuildLock` until the build
  ends, which is what makes the next `*/5` tick skip and `rebuild` fail fast with `EXIT_BUSY`. A poll
  that returns at once releases the lock at once, and the next tick starts a second build.
- *Skip the Ruby API; have the TUI shell out to `shepherd2 <verb> --json`.* **Not rejected — still
  open**, and this decision is what makes either road cheap, since both need the verbs to return data
  first. It is the heavier contract of the two (a JSON shape per verb, versioned across the wire) and
  it would reopen `D_ruby`'s "nothing on the box parses `shepherd2` output"; `stats --json` (`D_stats`)
  is the one place that line is already spent.
- *Rename the installed command to `shepherd2-cli` too.* 66 doc references, two cron lines and the
  operator's fingers, in exchange for a name nobody outside the repo ever types.
- *Adopt Zeitwerk now.* It is a gem. `D_ruby` forbids gems on the box and `test/stdlib_only_test.rb`
  enforces that with `ruby --disable-gems`. Honour the naming convention, take no dependency.
- *A third artifact for `stats`' data gathering* — `app_inventory`, `disks`, `project_stats`, the size
  parsers, ~150 lines with a genuine single purpose. Deferred, not refused: one file per boundary that
  has actually shown up, and this one has not.
- *Put both files in `/usr/local/bin`.* No symlink and no change to `uninstall`, at the price of a
  non-executable library sitting in `bin`.

**Consequences.**

- **`D_ruby` is refined, not reversed.** Ruby, standard library only, Bash installers: untouched. Its
  "one file on `PATH`" becomes one *command* on `PATH` backed by two files, and its "nothing on the box
  parses `shepherd2` output" is untouched too — the data contract is in-process, and stdout is
  unchanged.
- **The `*/5` poll goes quiet, which is what cron wants.** Its build output is discarded rather than
  inherited, so a tick no longer mails root a build log; the log itself is untouched, in
  `builds:output` where `last-build` finds it. `create-app` and `rebuild` keep their live output,
  because the executable asks for it.
- **The tests change shape, and improve.** `test/helper.rb` loads the *library* rather than the
  executable, which is exactly what a TUI does, so the suite proves that path. Assertions on `@out`
  strings (`last-build`, `stats`) become assertions on returned data; the prose they pin moves to a
  thinner set of CLI tests. `stdlib_only_test.rb` grows a second case for the library alone, since the
  TUI loads it without the executable.
- **`D_testing`'s seam-as-constructor-argument surface gains two members.** The progress listener and
  the confirm callback are seams like `Dokku` and `BuildLock`, injected the same way and faked the same
  way.
- **A verb that must ask the operator something goes through the callback**, or it is not allowed to
  ask. Extending that contract is a deliberate act, which is the point.
- **The listener and `confirm:` run on whatever thread called the verb**, and marshalling onto a UI
  thread is the front-end's job — the API knows nothing about threads and must not learn. `confirm:`
  blocks its caller until answered, so a TUI hands the question to its UI thread and waits there
  rather than answering inline. The CLI, single-threaded, is unaffected by all of this.
- **`last-build --log` reads a log instead of handing over the terminal**, and the snapshot rule makes
  two of Dokku's sharp edges ours to handle. `builds:output` **`tail -f`s a live build and `cat`s a
  finished one**, so the status on the record is consulted first and the log is fetched only for a
  build that has finished — a running build returns its record and no log, never a call that would
  block. And `builds:output` **exits 0 having printed nothing** for a pruned or mistyped id
  ([dokku#9031](https://github.com/dokku/dokku/issues/9031)), so "rotated away" and "printed nothing"
  must come back as distinguishable values rather than both as `""`. Today's code is exposed to
  neither, because it hands the terminal to Dokku and lets the operator see whatever appears.
- **Two script headers, with the audiences split.** The executable's keeps USAGE, `create-app` OPTIONS
  and EXIT CODES — the operator's half; the library's owns the verbs and what each returns, the
  listener contract, PREREQUISITES and WHAT THIS STORES — the caller's half. They will drift into
  duplicates if that line is not held.
- **`uninstall` removes a directory rather than a file**, so a third file added later cannot leak.
  `CLAUDE.md`'s *Script index* grows a row and `SOLUTION.md`'s inventory grows the lib directory.
