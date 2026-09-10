# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

**Shepherd2 is a homebrew Heroku replacement built on [Dokku](https://dokku.com).** It builds git repos
and deploys them as Docker containers at `https://PROJECTID.<domain>` on a single Linux box. Dokku does
the building, running, routing and TLS; this repo is the **glue** — host setup, per-project
convergence, the periodic-rebuild trigger, the wildcard-certificate story, and housekeeping.

**Status: the design is agreed and v1 is written but unproven** — both installers, the `shepherd2` CLI
and its tests exist, and **no box has been installed from any of it yet**.
**`SOLUTION.md` is what is to be built** — the box's inventory, the install order, the CLI surface and the flows. Write against
that file rather than inventing a shape; if the shape is wrong, change `SOLUTION.md` (and the `D_` entry
underneath it) first. One thing still gates a *finished* v1: the punch list in `RESEARCH.md` needs a
throwaway VPS. The feature survey that decided *what* the rebuilt thing does has graduated and is gone
(`D_no_feature_list`); what is left in `ideas/` is five open questions carrying `Q_` slugs and two
pieces of deferred work — all v2 except `Q_poll_churn`, which is a v1 gap in the poll's build-log story.

**It is the third implementation of the same product.** The predecessors, and what each one's decisions
were:

| | Runtime | Where its decisions live |
|---|---|---|
| [Vaadin Shepherd](https://github.com/mvysny/shepherd) | Kubernetes | `D_kubernetes` in shepherd-traefik |
| [shepherd-traefik](https://github.com/mvysny/shepherd-traefik) + [shepherd-java-client](https://github.com/mvysny/shepherd-java-client) | Docker + Traefik + Jenkins + a Vaadin web admin | `D_docker_traefik`, `D_network_per_project`, `D_poll_scm`, `D_no_shared_cache` in shepherd-traefik |
| **Shepherd2** (this repo) | Dokku on plain Docker | `D_dokku`, `D_retire_shepherd_java`, `D_dokku_is_truth` here |

Both predecessors stay readable on GitHub, so **nothing is copied out of them**. Cite an inherited
decision by slug *with the repo named* — "see `D_no_shared_cache` in shepherd-traefik". A `D_` heading
in this repo's `DECISIONS.md` is always a Shepherd2 decision. The product survey that chose Dokku over
Coolify/Dokploy/CapRover is
[`COMPARISON.md` in shepherd-traefik](https://github.com/mvysny/shepherd-traefik/blob/main/COMPARISON.md)
and is not restated here either; `D_dokku` links to it.

**What is deliberately gone** (don't reintroduce): Jenkins, Traefik-as-ours, the
`shepherd_PROJECTID` / `shepherd/PROJECTID` / `PROJECTID.shepherd` naming contract, `docker-compose.yaml`,
`/etc/shepherd/java/config.json`, the per-project JSON descriptor and its converger, and every JVM
component. See `D_dokku`, `D_retire_shepherd_java` and `D_dokku_is_truth`. Gone as of `D_builder`, and
this one is a *feature* rather than a component: **building from the project's own `Dockerfile`**, with
it `build.dockerFile`, `build.buildArgs` as build args, and the per-project buildx cache directory.

## Documentation targets

This repo's prose lives in six places, each with a distinct audience and *what it is allowed to own*.
Match the target before writing a line — the failure mode is a fact explained twice, which then drifts.

| Target | Audience | Scope & length | Owns |
|---|---|---|---|
| **README.md** | the operator at the front door | thin: positioning, requirements, install, troubleshooting, how to onboard a project, and the day-N cheat sheet | *how to run this box* — every common task as the exact command — and routing the reader onward |
| **SOLUTION.md** | someone asking "what *is* this box, end to end?" | the assembled picture: an inventory and a handful of flows | *how the pieces are wired together* — the install inventory, and the sequences that cross several decisions |
| **CLAUDE.md** (this file) | a contributor / coding agent | invariant-focused; pointers, not reference | what you must not break *from a distance*, the doc map, and the index of whatever code appears |
| **DECISIONS.md** | someone asking "why is it like this?" | one coherent, mutable entry per live decision *already made* (`D_` slugs) | the *why-we-chose*, including the roads not taken |
| **RESEARCH.md** | someone asking "what does Dokku actually do?" | a reference on the upstream product, claim-by-claim | verified Dokku behaviour, each claim marked `[docs]` / `[src]` / `[unverified]` |
| **`ideas/*.md`** | us, mid-thought | a scratchpad per idea; deleted on graduation | nothing durably — see *Ideas & their graduation* |

Once there is code, a seventh target opens: **each script's comment header**, dense and standalone,
owning that script's arguments, env knobs and prerequisites. `shepherd-traefik-connect-networks` in the
old repo is the model for what one should look like. A script header may defer *motivation* ("see
`D_dokku`"), never *usage*.

**`SOLUTION.md` is the newest and the easiest to get wrong**, because everything it describes is
decided somewhere else. It owns *composition* and nothing else: the box's inventory, and the flows —
registration, a poll tick, a renewal, a teardown — that no single `D_` entry can own because each spans
four or five of them. It argues nothing, so a paragraph there that explains *why* has drifted into
`DECISIONS.md`'s territory and a paragraph that explains *what Dokku does* into `RESEARCH.md`'s. The
test when adding to it: if this fact stopped being true, which file would be wrong? If the answer is
another file, link instead.

Rules that make six targets survivable:

- **Single source of truth per fact.** Each fact has one home and the others link to it. When tempted to
  explain something twice, link instead — the failure mode to watch for is compressing a `D_` entry into
  a bullet here, which reads like a summary and is really a third copy.
- **But don't over-link into unreadability.** A one-line load-bearing restatement is fine when it saves a
  jump ("build CPU can't be limited on the Dockerfile builder; see `RESEARCH.md`"). Repeat the *fact*,
  defer the *explanation*.
- **`RESEARCH.md` is about Dokku; `DECISIONS.md` is about us.** "Dokku's nginx runs on the host" is
  research. "We chose nginx over the Traefik plugin" is a decision. Neither file argues the other's case.
- **DECISIONS.md records only decisions already taken.** Shipped, or accepted-and-not-yet-implemented
  (that is what its `Status:` line is for). A speculative feature, an idea, an open question or a TODO is
  *not* a decision and gets no `D_` — it goes to `ideas/`. The roads-not-taken inside an existing entry
  are the only "what we didn't do" content that file carries.
- **Enumerated items get slugs, not numbers** — `D_dokku`, `Q_multi_user`, underscores throughout,
  backticked in prose. Stable once published; rename only with a sweep of every reference. There are
  exactly **two** namespaces: **`D_` decisions in `DECISIONS.md`** and **`Q_` open questions in
  `ideas/`**, one note per question. The `F_` feature slugs were retired with the feature survey —
  **don't reintroduce them, or any feature-list file** (`D_no_feature_list`).
- There is deliberately **no CHANGELOG** (the deploy is a `git pull`, so git *is* the changelog), no
  glossary, and no feature list.

## Ideas & their graduation

`ideas/*.md` is transient — a one-file-per-idea scratchpad where rationale is born, not held to this
repo's doc-quality rules, because it is going to be deleted. `ls ideas/` is the index; don't add a
README or ToC there. An idea that accumulates real research gets a same-stem sidecar folder
(`ideas/<name>/`), which lives and dies with it. See the `ideas-folder` skill for the procedure; **this
section is the authority on where nuggets land in Shepherd2**:

- verified behaviour of **Dokku** (or a Dokku plugin) → **RESEARCH.md**, with a `[docs]`/`[src]`/`[unverified]` marker
- the choice made + the alternatives rejected → **DECISIONS.md** (a `D_` entry)
- work deferred *as a consequence of a logged decision* → that entry's *Consequences*
- an operator-facing setup step, requirement or troubleshooting recipe → **README.md**; a day-N task and
  the exact command for it → its *Day-to-day operations* cheat sheet
- where a piece sits in the assembled box — an install step in sequence, a flow that crosses several
  decisions, a fact about what the box holds → **SOLUTION.md**
- a cross-cutting invariant ("never reintroduce a naming contract") → **CLAUDE.md**
- the precise truth of one script — arguments, env knobs, prerequisites → **that script's comment header**

As pieces land, cut them from the note; a fully-graduated note is *deleted*, not left as a stub. Only a
standalone open topic with no decision yet keeps a note alive.

**The sidecar trap, sharpened for this repo:** because most of our research is about Dokku and most
Dokku facts outlive the idea that prompted looking them up, the default destination for a sidecar
finding is `RESEARCH.md`, not the bin. Scan `ls ideas/<name>/` at graduation, not just the idea file.

## Script index

A map, not a reference: each entry is a pointer plus what the thing is for, with **every script's own
comment header the authority** on its arguments, env knobs and prerequisites. Put new technical truth
*there*, not here.

| Script | What it is for |
|---|---|
| `shepherd2-install` | Bash. Vanilla Ubuntu 24.04 → a working box: Docker, Dokku, address pools, TLS mode, the CLI, cron. Re-runnable; every step guarded |
| `shepherd2-uninstall` | Bash. The inverse, driven by `SHEPHERD_TLS_MODE`. Destroys every project; `--keep-docker` / `--keep-pools` opt out of the two steps that reach past Shepherd2's own layer |
| `shepherd2` | Ruby, one dispatcher: `create-app`, `destroy-app`, `poll`, `rebuild`, `wait-idle`, `clearcache`. Its process-running seams (`Dokku`, `Docker`, `BuildLock`) are constructor arguments — that is the test surface |
| `test/` | minitest, run as `ruby test/run`. `ruby-minitest` from apt, dev-only — **no `Gemfile`** (`D_testing`) |
| `.github/workflows/test.yml` | the suite plus shellcheck, in an `ubuntu:24.04` container so it runs on the box's Ruby |

## Conventions when editing

- **Dokku stays upstream and unforked.** If something is missing, the answer is a wrapper script, a
  crontab line or a documented manual step — not a patched Dokku, not a fork, not a plugin we maintain
  unless there is a `D_` entry saying so.
- **Apps are built by buildpacks; the Dockerfile builder is prohibited, and that is load-bearing.**
  The install sets `builder:set --global selected herokuish`, so a committed `Dockerfile` is never
  read. Don't "fix" a build by re-enabling it: the Dockerfile is what makes per-project cache
  isolation unenforceable, which is the whole reason for the prohibition. Buildpacks are pinned per
  app with `buildpacks:set` rather than detected (herokuish detects `nodejs` before `java`, and Vaadin
  apps commit a `package.json`). The build cache is the `cache-$APP` volume Dokku names, purged with
  `repo:purge-cache <app>` — never a `RUN --mount` and never `--cache-to`. `pack`/CNB is a v2 option,
  not a v1 alternative. See `D_builder`.
- **The proxy is Dokku's default host nginx, and it is not a container.** Don't install the Traefik
  plugin or set `proxy:type` on an app; per-app ingress tuning is `nginx:set`. See `D_proxy` — and note
  that `D_isolation` *depends* on this, so switching proxies is not a local change.
- **TLS is one wildcard certificate, and nothing per app.** lego issues and renews it on the host, and
  `dokku-global-cert` pushes it into every app; that plugin is the one third-party plugin we depend on.
  Don't install `dokku-letsencrypt` or `letsencrypt:enable` an app in v1, and don't make `create-app`
  touch certificates — the plugin covers new apps at creation. The DNS API token is root-only and must
  stay unreadable to the `dokku` user. See `D_cert`.
  - **…but https is a *mode*, and the box also installs http-only.** Everything above is the `https`
    mode; the `http` mode installs none of it. So nothing outside `install` /
    `uninstall` may *assume* a certificate exists, and nothing anywhere may offer to convert a running
    box between the two — the choice is made once, at install, and HSTS makes the downgrade
    unrepairable from the box. See `D_cert`.
- **Each project gets its own Docker network, and nothing has to re-attach anything.** `initial-network`
  is persisted app state that Dokku re-applies at container creation, so there is no successor to
  `shepherd-traefik-connect-networks` — if you find yourself writing one, something else is wrong. See
  `D_isolation`.
- **Dokku's state is the only source of truth, and there is no project descriptor.** No per-project
  file anywhere, no converger, nothing that re-applies configuration. The only per-project data of ours
  are the `SHEPHERD_GIT_URL` / `SHEPHERD_OWNER` config vars, written once by `create-app`, plus one
  box-level `SHEPHERD_TLS_MODE` written by `install`. If you need a
  project fact, read `dokku *:report --format json`; if you need to store one, it is a `SHEPHERD_*`
  config var or it does not exist. See `D_dokku_is_truth`.
- **Shepherd2 never wraps a command Dokku already has.** `create-app` / `destroy-app` / `poll` /
  `rebuild` exist because Dokku has no single command for them; `dokku logs`, `ps:restart`,
  `config:set`, `domains:add` are used as they are and documented in the `README.md` cheat sheet. A
  `shepherd2 logs` is `shepherd-cli` reincarnated — don't.
- **Prefer a Dokku command to a `docker` command.** `dokku ps:restart` over `docker restart`; the
  reports (`--format json`) over `docker inspect`. Reaching around Dokku to the daemon is how state
  drifts out from under it. Where a `docker` call is genuinely required, say why in the script header.
- **The CLI is Ruby; the installers are Bash.** `shepherd2` is one Ruby dispatcher holding every verb,
  standard library only — no `Gemfile`, no gems — and written against Ruby 3.2, which is what the box
  ships (Ubuntu 24.04, `D_host_os`). `shepherd2-install` and `shepherd2-uninstall` stay Bash with
  `set -euo pipefail`, as does any future box script: they run before Ruby is guaranteed to exist and
  after it may be gone. A new file picks by which of the two it is. See `D_ruby`.
- **Project ids beginning with `admin` are reserved** — `create-app` refuses them, so a future admin
  surface has a hostname waiting under the wildcard certificate. See `D_admin_namespace`.
- **Anything the box must survive a reinstall of belongs in this repo**, not in a command someone once
  typed. The install is reproducible *from the guide* — that is the whole deliverable.
- `mydomain.me` is the placeholder DNS domain throughout; the operator replaces it (or adds
  `/etc/hosts` entries for a toy setup).
- **Pin Dokku's version.** Never below v0.38.2, which carries security fixes. See `RESEARCH.md`.
- **The box is Ubuntu 24.04, and so is the VM this is developed in.** Not 26.04: Dokku's installer
  refuses it and no `dokku` package is built for it. Don't work around that — see `D_host_os`, which
  names the two upstream things that must change first.
- **`[unverified]` in `RESEARCH.md` means exactly that.** Don't build a design on an unverified claim
  without saying so; the file's *Questions only a box can answer* is the punch list.
