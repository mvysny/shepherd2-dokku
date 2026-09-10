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

**Status:** Accepted 2026-09-09. Not yet implemented — this repo is the implementation.

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

- *Keep maintaining Shepherd-Traefik.* The status quo works, and rejecting it costs real features (see
  `ideas/features-to-preserve.md` for the inventory, and the regressions listed under *Consequences*).
  Rejected because the maintenance surface — two repos, a Jenkins, a JVM web app, a network-repair
  script — is out of proportion to a box hosting demo apps.
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
`ideas/features-to-preserve.md`. What is decided here is that shepherd-java-client is not carried forward.

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
  ownership to v2 (`Q_multi_user` in `ideas/features-to-preserve.md`).
- **Five behaviours lose their only home** and must each be re-provided, re-scoped or consciously
  dropped: the project descriptor, the box-wide memory quota, reserved ids, the smart-update logic, and
  the graceful "safe to reboot" wait. None has a Dokku counterpart. `D_dokku_is_truth` settles the first,
  second and fourth (descriptor and smart-update dropped, quota enforced at creation time); reserved ids
  and the safe-reboot wait are still `F_` entries in `ideas/features-to-preserve.md`.
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

**Status:** Accepted 2026-09-10. Nothing to implement — nginx is Dokku's default, so this decision is
mostly a commitment *not* to do something. `D_isolation` depends on it.

**Context.** Dokku ships five proxy implementations and nginx is the default; the official `traefik`
plugin is one of the alternatives, switched on per app with `proxy:set <app> type traefik`. Traefik was
the obvious candidate because shepherd-traefik *is* a Traefik box — the labels, the DNS-01 config and
the failure modes are all knowledge this project already has, and "keep the part that works" was a real
option rather than a straw man.

**Decision.** Use **nginx**, Dokku's default. The Traefik plugin is not installed and no app sets
`proxy:type`.

**Why.** The two are not symmetric, and every asymmetry runs the same way:

- **nginx is a host process; Traefik is a container.** nginx dials app containers at `IP:PORT` from
  `.DOKKU_APP_<PROC>_LISTENERS`, so it needs no Docker network membership at all, and
  `dokku-event-listener` rewrites its config when a container IP changes. This is the single biggest
  architectural gain of the whole Dokku move (`D_dokku`), and it is what makes `D_isolation` free.
- **The Traefik plugin has no network-attachment logic whatsoever** — no `docker network connect`, no
  read of an app's `initial-network` / `attach-*` properties (`plugins/traefik-vhosts/internal-functions`
  **[src]**). So a per-app isolated network is plausibly unreachable by it, and repairing that would be
  `shepherd-traefik-connect-networks` reincarnated as ours. **Choosing Traefik would cost either
  `F_network_isolation` or a reconciler cron** — exactly the script `D_dokku` celebrates deleting.
- **Per-app ingress tuning is first-class on nginx and absent on Traefik.** `nginx:set <app>
  client-max-body-size` / `proxy-read-timeout` are app-scoped properties, where **every `traefik:set`
  property is global-only** — per-app tuning would have to be hand-written
  `traefik:labels:add` directives. `F_ingress_tuning` is a feature both predecessors ship.
- **Traefik forecloses two of the three TLS routes.** "Managed certificates provided by the `certs`
  plugin are ignored" under Traefik, which rules out `dokku-global-cert` and the `certs` plugin
  outright. See *Consequences* for what that does to `Q_cert`.
- Two smaller Traefik restrictions: only `web` containers get labels injected, and only `http:80` /
  `https:443` port mappings are supported.

All five are in `RESEARCH.md` (*Proxies*), which owns the citations.

**Alternatives rejected.**

- *The official Traefik plugin.* Rejected on the four asymmetries above. What it genuinely buys, and
  what we are giving up: ACME renewal becomes Traefik's problem rather than a cron of ours (as it is
  today), which is `Q_cert`'s route 3 — at the price of per-app ACME orders and no declared wildcard
  SAN. Familiarity was the strongest argument for it and is not enough: the knowledge that transfers is
  knowledge of a component we were trying to stop maintaining.
- *Keep both — nginx globally, Traefik for one app that needs it.* Dokku allows this (`proxy:type` is
  per app). Rejected because the two proxies have disjoint TLS stories, so a mixed box would need both
  cert mechanisms alive at once; and because a per-app exception is exactly the kind of state that is
  invisible until it breaks.
- *A proxy of our own in front of Dokku's.* Not seriously considered — it re-creates the component
  `D_dokku` deleted.

**Consequences.**

- **`Q_cert` narrows to two routes, not three.** `dokku-global-cert` (one wildcard cert we renew) and
  `dokku-letsencrypt` (per-app ACME, renewal solved upstream) both stay available; the Traefik DNS-01
  route is gone. That is the intended direction — the requirement as written asks for one wildcard cert
  — but it is now foreclosed rather than merely unchosen. `D_cert` has since taken the first of the two.
- **`F_ingress_tuning` is preserved** as `nginx:set <app> client-max-body-size` / `proxy-read-timeout`.
- **nginx is an apt package on the host**, so it is part of what a box reinstall must reproduce, and
  Dokku's own bootstrap installs it. Nothing for us to configure beyond `nginx:set`.
- **The `proxy` plugin's other implementations stay unused but present.** If a future need forces
  Traefik, this entry is the thing to re-read — and `D_isolation` has to be re-read with it, because it
  is the dependent decision.

## D_isolation — One Dokku-managed bridge network per project (2026-09-10)

**Status:** Accepted 2026-09-10. Not yet implemented; `initial-network` isolating apps while leaving
nginx routing intact is `[unverified]` until the first box (punch-list items 2, 9, 12).

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
dokku postgres:create <svc> --initial-network app-<id>   # if the project wants a database
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
  traffic never does. Rejected on three counts: `network:create` passes no driver options, so the network
  would be a hand-made `docker network create -o …` living outside Dokku's model and outside a
  reinstall; topology beats filtering for untrusted code, since under per-app networks app A cannot
  *address* app B and there is nothing left to filter; and an iptables rule can be silently absent with
  nothing in Dokku noticing. Its one advantage was avoiding the address-pool ceiling, which turned out
  to be an install-time line rather than a cost.
- *The sibling's n+1 shape* — per-app networks **plus** a separate network for the admin plane. Not
  needed: Dokku's control plane is a host binary and a git remote, with no dashboard container, no
  control-plane database and no published admin port to move off the app wire.
- *`attach-post-create` / `attach-post-deploy` instead of `initial-network`.* A category error worth
  naming, because the plugin's tutorial recommends `attach-post-create` and it looks interchangeable:
  the `attach-*` properties **add** networks, so an app with only those set is still on the shared
  bridge. They are for reachability; only `initial-network` isolates.

**Consequences.**

- **`/etc/docker/daemon.json` needs enlarged `default-address-pools`, at install time.** A stock daemon
  walls at ~30 bridge networks, i.e. ~30 apps. This is precedent, not a new cost — shepherd-traefik
  already does it — but it needs a daemon restart, so it belongs in the installer and cannot be
  retrofitted cheaply. Whether Dokku's `bootstrap.sh` writes that file is `[unverified]`.
- **A project's database must be created with `--initial-network`.** It is a creation-time flag; a
  service created without it sits on the shared bridge, where the app can no longer reach it under this
  decision. `postgres:set <svc> post-create-network` is the repair. `postgres:link` additionally adds a
  legacy `--link`, whose behaviour on a user-defined bridge is `[unverified]` (punch-list item 9).
- **Project teardown grows a step:** `network:destroy app-<id>` after `apps:destroy`, or `F_uninstall`
  leaks a network per project.
- **This decision depends on `D_proxy`.** Under the Traefik plugin it would cost either the isolation or
  a reconciler cron. Do not switch proxies without re-reading both entries.
- **Two things isolation does not buy.** The L7 front door stays open — any app can reach nginx by the
  bridge gateway IP and ask for another app's vhost with a `Host:` header, which is harmless because
  that surface is public anyway. And **the host stays reachable**: every container keeps a route to its
  bridge gateway regardless of membership, so sshd and anything else bound on the box are reachable from
  every app. That axis needs a `DOCKER-USER` rule and is deferred — see
  `ideas/harden-container-egress.md`. It is also where the sibling's "app → admin plane" concern lands
  here.
- **Egress is unfiltered**, same note.

## D_dokku_is_truth — Dokku's own state is the source of truth; Shepherd2 supplements it, never fronts it (2026-09-10)

**Status:** Accepted 2026-09-10. Not yet implemented — there is no code yet. The two source-level facts
it leans on (what `git:sync` persists; `apps:set` having no metadata slot) are `[src]`-verified at
v0.38.27 but not yet seen on a box.

**Context.** shepherd-java's per-project JSON file was the source of truth, and a control plane converged
Docker onto it, because there was nothing else to converge onto: plain Docker has no persisted per-app
configuration. `F_project_descriptor` asked whether to carry that shape forward — a descriptor per
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
  variant, `--build`), and the box-level crons and installer. **Everything else is `dokku` itself** —
  logs, build output, restart, config, domains, ingress tuning, limits — listed in `README.md` as a
  cheat sheet from feature to command.
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
  three of them (`apps:create`, `network:create`, `postgres:create`) not idempotent, plus the cache flags
  and the first sync. That earns a script. Every day-N action is one well-named `dokku` command, and
  re-exposing those one-to-one is `shepherd-cli` again — the component class `D_retire_shepherd_java`
  retired.
- **Config var over inference, because of one edge.** `git:sync` does record its URL (`apps:report
  --app-deploy-source-metadata`), but only after a build that succeeded far enough to fire
  `deploy-source-set`. Many first builds fail — the Dockerfile usually needs a couple of iterations — and
  an app with no recorded URL is invisible to a poll derived from Dokku's records, so the developer's fix
  upstream is never picked up. A config var written *before* the first build puts the app in the poll
  from the moment it exists, and the next upstream commit heals it. `RESEARCH.md` → *`git:sync`* has
  the source reading.

**Alternatives rejected.**

- *Declarative descriptor + converger* — shepherd-java's shape, and the ideas file's original instinct.
  Rejected on the conflict above and on the third-copy argument: Dokku's property store is already the
  descriptor, spread across plugins. It would have bought `F_smart_update` and a git-reviewable project
  set; see *Consequences* for what that costs.
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

- **`F_project_descriptor` and `F_smart_update` are dropped.** Changing a build arg is
  `docker-options:remove`, `docker-options:add`, `ps:rebuild` — three commands, once a year for a key
  rotation, a runbook line in `README.md`. **`F_memory_quota` survives at creation time only**:
  `create-app` sums `resource:report --format json` across apps and refuses an over-commit; a later
  hand `resource:limit` is not checked. **`F_project_owner`** is `SHEPHERD_OWNER`. Per-project cache
  flags are set once by `create-app`.
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
- **`Q_language` loses its main input** — there is no descriptor to parse, only reports to read.
- **A third-party client such as wharf may be adopted, never depended on.** It is a pure SSH client
  holding no server-side state, so its death costs nothing; that is the property `D_retire_shepherd_java`
  found missing in the class. Whether any browser UI returns is still `Q_web_admin`.
- **`D_retire_shepherd_java`'s open "shape of the replacement" is closed for the CLI half** by this entry.

## D_single_operator — v1 has one keyholder; per-user project ownership is v2 (2026-09-10)

**Status:** Accepted 2026-09-10 for the first version. Deliberately scoped: this decides *v1*, and it
defers rather than drops multi-user. `Q_multi_user` in `ideas/features-to-preserve.md` stays open as
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

- **`F_multi_user` and `F_user_login` are deferred, not dropped.** They stay in the ideas file as the v2
  fork. The only v2 route to `F_user_login` (Google SSO) is the reworked Vaadin admin, option 3 of
  `Q_web_admin`.
- **Store `SHEPHERD_OWNER` in a form v2 can match against a key name.** The `user-auth` trigger sees the
  key's `$SSH_NAME`, so if v1 records an email, v2 either names keys by email (`ssh-keys:add
  alice@example.com …`) or adds a mapping. Naming keys by email is the cheap answer; note it in
  `create-app`'s header when it is written.
- **Nothing in v1 may assume more than one keyholder** — no per-user paths, no owner checks in
  `shepherd2` — so that v2 adds the hook without unpicking anything.

## D_cert — One wildcard certificate: lego DNS-01 on the host, propagated by `dokku-global-cert` (2026-09-10)

**Status:** Accepted 2026-09-10, awaiting implementation — it lands as `install` steps (lego, the plugin,
the first issuance, one root cron line) and nothing per app. Depends on `D_proxy`: the `certs` plugin
this rides on is ignored under the Traefik plugin.

**Context.** `F_wildcard_https` asks for **one** `*.mydomain.me` certificate, so that a new app is on
https the moment it exists and nobody performs a per-app ACME order, ever. shepherd-traefik does this
today with Traefik's DNS-01 challenge against GoDaddy. Dokku's nginx cannot: nginx has no ACME client,
so under `D_proxy` something else has to issue and renew. Two routes survived `D_proxy` — the official
`dokku-letsencrypt` plugin (per-app orders, renewal solved upstream) and the community
`dokku-global-cert` plugin (one cert, renewal ours) — and which one is right turned entirely on whether
"one cert" is still the requirement or merely how it happened to be built.

It is the requirement. Every app this product has ever hosted was a demo at `PROJECTID.<domain>` under a
wildcard DNS record; the production use with foreign domains that the predecessors allowed for never
materialised. Once `F_custom_domains` and `F_apex_domain` are deferred (see *Consequences*), per-app
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
  `F_custom_domains` stayed, because a wildcard covers no foreign domain and every app would have needed
  its own cert anyway; with that feature deferred it only adds an ACME order per app. Two further costs:
  the app "needs to already be deployed and reachable on the public internet over HTTP before a
  certificate can be issued", so an app whose first builds fail — the normal case — has no https until
  someone re-runs `enable`; and its wildcard support is "not officially supported" (issue #189). It
  stays the v2 tool for `F_custom_domains`, on those apps only, and coexists with the global cert.
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

- **`F_custom_domains` and `F_apex_domain` are deferred, not dropped.** A `*.mydomain.me` cert matches
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
- **Box questions before this can be called done** (`RESEARCH.md` → *Questions only a box can answer*):
  that `lego run --dns godaddy` succeeds with the current credentials; that `global-cert:set` on renewal
  re-applies to every app and reloads nginx without dropping connections; and that an app created and
  never yet deployed serves the global cert on its first successful deploy.

## D_builder — Apps are built by a buildpack, never a Dockerfile; herokuish by default (2026-09-10)

**Status:** Accepted 2026-09-10. Not yet implemented. One `[unverified]` could force a re-read rather
than a reversal: whether a Vaadin *frontend* build stays warm across rebuilds (punch-list items 13–17).
Supersedes nothing, but it makes `D_no_shared_cache` in shepherd-traefik's *Known gap* closed rather
than inherited.

**Context.** Dokku ships **seven** builders (`RESEARCH.md` → *The builders, and how one is chosen*), and
Shepherd2 had only ever considered one, because both predecessors built a `Dockerfile` and the feature
survey recorded that as `F_build_dockerfile` — preserved, ✅, not examined. Two requirements, stated by
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
- **`F_build_cpu_limit` probably closes as a side effect.** On the herokuish path the build-phase
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
  removes the on-box rebuild that `F_poll_rebuild` exists for, needs a registry and per-project
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

- **`F_build_dockerfile` and `F_custom_dockerfile` are dropped features**, not preserved ones. This is
  the first feature the Dokku move deliberately *removes* rather than migrates, and it is the entry to
  cite when someone asks why a project's `Dockerfile` is being ignored.
- **Every hosted repo needs descriptors it does not have today** — at minimum a `Procfile`, usually a
  `system.properties`. Acceptable only because we own the apps; on a farm of repos we did not control
  this decision would not be available. Onboarding is no longer "point at the repo", and `README.md`
  owns the recipe.
- **The buildpack must be *named*, never detected — and the repo names it.** Detection is a trap
  here: herokuish detects `nodejs` **before** `java` **[src]**, and Vaadin's own source-control
  guidance says to commit `package.json` **[docs]**, so a stock Vaadin repo would build as a Node app.
  The fix is a one-line **`.buildpacks` at the repo root** (`heroku/java` — the shorthand is expanded
  to the full GitHub URL, and an unparseable line fails the build rather than being ignored
  **[src]**). This is the same file the project already needs a `Procfile` and `system.properties`
  alongside, it keeps the box free of per-app knowledge, and it is the reason `create-app` stays
  generic. `app.json`'s `buildpacks` array works too, and outranks `.buildpacks`.
- **`dokku buildpacks:set <app> …` remains as the operator override, one layer above the repo.** The
  real precedence, from `getBuildpacks` and the `buildpacks` plugin's `post-extract` trigger
  **[src]** — note the function's own doc comment states the reverse and is stale:

  | | source | who controls it |
  |---|---|---|
  | 1 | `buildpacks:set` / `:add` app property | operator; **overwrites** the repo's `.buildpacks` in the extracted source |
  | 2 | `app.json` `buildpacks[].url` | the repo; likewise overwrites `.buildpacks` |
  | 3 | `.buildpacks` at the repo root | the repo; kept, with each line validated and normalised |
  | 4 | herokuish's own detection order | nobody — the trap above |

  So the default path needs no per-app state at all, and a repo we cannot edit, or one whose choice
  turns out to be wrong, is still fixable with one command and no fork. That is the layering we want,
  and it comes free.
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
- **`F_build_args` gets simpler.** `builder-herokuish/pre-build` bundles every app config var into an
  ENV_DIR inside the build **[src]**, so the Vaadin offline key is a plain `dokku config:set` with no
  `--build-arg` plumbing. The flip side is that every *runtime* secret is visible to the build too.
- **The `.m2` cache now lives in a Docker volume that nothing garbage-collects.** buildkitd's GC, the
  ~48 h mount eviction and the whole `--cache-to type=local` apparatus stop applying. Housekeeping
  becomes one lever — `repo:purge-cache <app>` — and the successor to `shepherd-clearcache` prunes
  *volumes*, not buildx caches. Punch-list item 1 (does `--cache-to type=local` export at all) is moot
  and has been struck.
- **The frontend half of a Vaadin build is the one thing this decision does not solve,** and it is not
  a herokuish weakness — the frontend is driven by Maven, so it is invisible to the node buildpack
  that would otherwise have cached it, on any builder. What the decision *does* give is the place to
  put the fix, **and the fix is app-side like the buildpack choice**: `/cache` is a per-app volume
  that the build can write to (herokuish chowns it to the build user before `bin/compile` **[src]**),
  and a committed `.env` reaches the build environment **[src]** — so `npm_config_cache=/cache/npm`
  warms npm, and `MAVEN_CUSTOM_OPTS=… -Duser.home=/cache/home` should relocate `~/.vaadin` into the
  same volume. Both are lines in the repo; the box learns nothing per-app. Vaadin's pre-compiled
  production bundle (24.1+) removes the frontend build entirely for apps with no custom frontend or
  add-ons, which is likely most of the farm. Note what is *not* available: **providing a system
  Node** — it is not in `heroku/heroku:24-build` **[docs]**, `heroku/nodejs` exports no `PATH` to a
  later buildpack **[src]**, and we do not build the herokuish image — so `~/.vaadin` must be
  relocated rather than made unnecessary. Tracked in `ideas/vaadin-build-under-herokuish.md`;
  punch-list items 13–17.
- **A `heroku/nodejs` + `heroku/java` multi-buildpack is not the answer to that**, and the reason is
  worth recording so nobody re-derives it: the node buildpack's cache bracket opens and closes inside
  *its own* compile, which runs before Maven, so anything Maven creates is saved by nobody; it prunes
  devDependencies unconditionally at the end of that compile, removing exactly the Vite that Vaadin
  then reinstalls; and it writes no `export` file beyond a pnpm store line **[src]**, so
  `heroku-buildpack-multi` propagates no `PATH` and the node it installed is not visibly on `PATH`
  when Maven runs. It also makes the build *fail* outright if its `detect` finds no `package.json`,
  since multi exits when any listed buildpack fails to detect **[src]**.
- **`ideas/build-cache.md` is deleted.** Its fork was conditional on the Dockerfile builder and is moot;
  its surviving Dokku facts went to `RESEARCH.md`, and the unpinned poll interval it flagged moved to
  `F_poll_rebuild` in the feature survey.
- **`D_dokku_is_truth` is unaffected and slightly strengthened** — the builder choice is `builder:report`
  state, not a file of ours, and the cache is a Docker volume Dokku names. Still no descriptor.
