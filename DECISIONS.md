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
  fragile.
- **A second thing gets better:** `dokku-postgres` makes the per-project Postgres service that was a
  README TODO for two implementations a two-command feature.

## D_retire_shepherd_java — No web admin, no Java; Dokku's CLI is the interface (2026-09-09)

**Status:** Accepted 2026-09-09 in principle; **the shape of the replacement is still open** — see
`ideas/features-to-preserve.md`. What is decided is that shepherd-java-client is not carried forward.

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
  control* in `RESEARCH.md`, and `F_multi_user` / `Q_multi_user` in `ideas/features-to-preserve.md` for
  whether we want it at all.
- **Five behaviours lose their only home** and must each be re-provided, re-scoped or consciously
  dropped: the project descriptor, the box-wide memory quota, reserved ids, the smart-update logic, and
  the graceful "safe to reboot" wait. They are itemised as `F_` entries in
  `ideas/features-to-preserve.md`; none of them has a Dokku counterpart.
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
