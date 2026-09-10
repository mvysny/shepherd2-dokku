# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

**Shepherd2 is a homebrew Heroku replacement built on [Dokku](https://dokku.com).** It builds git repos
and deploys them as Docker containers at `https://PROJECTID.<domain>` on a single Linux box. Dokku does
the building, running, routing and TLS; this repo is the **glue** — host setup, per-project
convergence, the periodic-rebuild trigger, the wildcard-certificate story, and housekeeping.

**Status: design phase.** There is no code yet. The current work is agreeing the feature set
(`ideas/features-to-preserve.md`) before anything is written. Don't add scripts ahead of that.

**It is the third implementation of the same product.** The predecessors, and what each one's decisions
were:

| | Runtime | Where its decisions live |
|---|---|---|
| [Vaadin Shepherd](https://github.com/mvysny/shepherd) | Kubernetes | `D_kubernetes` in shepherd-traefik |
| [shepherd-traefik](https://github.com/mvysny/shepherd-traefik) + [shepherd-java-client](https://github.com/mvysny/shepherd-java-client) | Docker + Traefik + Jenkins + a Vaadin web admin | `D_docker_traefik`, `D_network_per_project`, `D_poll_scm`, `D_no_shared_cache` in shepherd-traefik |
| **Shepherd2** (this repo) | Dokku on plain Docker | `D_dokku`, `D_retire_shepherd_java` here |

Both predecessors stay readable on GitHub, so **nothing is copied out of them**. Cite an inherited
decision by slug *with the repo named* — "see `D_no_shared_cache` in shepherd-traefik". A `D_` heading
in this repo's `DECISIONS.md` is always a Shepherd2 decision. The product survey that chose Dokku over
Coolify/Dokploy/CapRover is
[`COMPARISON.md` in shepherd-traefik](https://github.com/mvysny/shepherd-traefik/blob/main/COMPARISON.md)
and is not restated here either; `D_dokku` links to it.

**What is deliberately gone** (don't reintroduce): Jenkins, Traefik-as-ours, the
`shepherd_PROJECTID` / `shepherd/PROJECTID` / `PROJECTID.shepherd` naming contract, `docker-compose.yaml`,
`/etc/shepherd/java/config.json`, and every JVM component. See `D_dokku` and `D_retire_shepherd_java`.

## Documentation targets

This repo's prose lives in five places, each with a distinct audience and *what it is allowed to own*.
Match the target before writing a line — the failure mode is a fact explained twice, which then drifts.

| Target | Audience | Scope & length | Owns |
|---|---|---|---|
| **README.md** | the operator at the front door | thin: positioning, requirements, install, troubleshooting, how to onboard a project | *how to run this box* — and routing the reader onward |
| **CLAUDE.md** (this file) | a contributor / coding agent | invariant-focused; pointers, not reference | what you must not break *from a distance*, the doc map, and the index of whatever code appears |
| **DECISIONS.md** | someone asking "why is it like this?" | one coherent, mutable entry per live decision *already made* (`D_` slugs) | the *why-we-chose*, including the roads not taken |
| **RESEARCH.md** | someone asking "what does Dokku actually do?" | a reference on the upstream product, claim-by-claim | verified Dokku behaviour, each claim marked `[docs]` / `[src]` / `[unverified]` |
| **`ideas/*.md`** | us, mid-thought | a scratchpad per idea; deleted on graduation | nothing durably — see *Ideas & their graduation* |

Once there is code, a sixth target opens: **each script's comment header**, dense and standalone, owning
that script's arguments, env knobs and prerequisites. `shepherd-traefik-connect-networks` in the old
repo is the model for what one should look like. A script header may defer *motivation* ("see
`D_dokku`"), never *usage*.

Rules that make five targets survivable:

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
- **Enumerated items get slugs, not numbers** — `D_dokku`, `F_wildcard_https`, underscores throughout,
  backticked in prose. Stable once published; rename only with a sweep of every reference. `F_` slugs
  currently live in `ideas/features-to-preserve.md`; when that idea graduates they move to wherever the
  feature set lands.
- There is deliberately **no CHANGELOG** (the deploy is a `git pull`, so git *is* the changelog) and no
  glossary.

## Ideas & their graduation

`ideas/*.md` is transient — a one-file-per-idea scratchpad where rationale is born, not held to this
repo's doc-quality rules, because it is going to be deleted. `ls ideas/` is the index; don't add a
README or ToC there. An idea that accumulates real research gets a same-stem sidecar folder
(`ideas/<name>/`), which lives and dies with it. See the `ideas-folder` skill for the procedure; **this
section is the authority on where nuggets land in Shepherd2**:

- verified behaviour of **Dokku** (or a Dokku plugin) → **RESEARCH.md**, with a `[docs]`/`[src]`/`[unverified]` marker
- the choice made + the alternatives rejected → **DECISIONS.md** (a `D_` entry)
- work deferred *as a consequence of a logged decision* → that entry's *Consequences*
- an operator-facing setup step, requirement or troubleshooting recipe → **README.md**
- a cross-cutting invariant ("never reintroduce a naming contract") → **CLAUDE.md**
- the precise truth of one script — arguments, env knobs, prerequisites → **that script's comment header**

As pieces land, cut them from the note; a fully-graduated note is *deleted*, not left as a stub. Only a
standalone open topic with no decision yet keeps a note alive.

**The sidecar trap, sharpened for this repo:** because most of our research is about Dokku and most
Dokku facts outlive the idea that prompted looking them up, the default destination for a sidecar
finding is `RESEARCH.md`, not the bin. Scan `ls ideas/<name>/` at graduation, not just the idea file.

## Script index

Nothing yet. When scripts land, this table becomes a map — not a reference: each entry a pointer plus
what the thing is for, with **every script's own comment header the authority** on its arguments, env
knobs and prerequisites. Put new technical truth *there*, not here.

## Conventions when editing

- **Dokku stays upstream and unforked.** If something is missing, the answer is a wrapper script, a
  crontab line or a documented manual step — not a patched Dokku, not a fork, not a plugin we maintain
  unless there is a `D_` entry saying so.
- **The proxy is Dokku's default host nginx, and it is not a container.** Don't install the Traefik
  plugin or set `proxy:type` on an app; per-app ingress tuning is `nginx:set`. See `D_proxy` — and note
  that `D_isolation` *depends* on this, so switching proxies is not a local change.
- **Each project gets its own Docker network, and nothing has to re-attach anything.** `initial-network`
  is persisted app state that Dokku re-applies at container creation, so there is no successor to
  `shepherd-traefik-connect-networks` — if you find yourself writing one, something else is wrong. See
  `D_isolation`.
- **Prefer a Dokku command to a `docker` command.** `dokku ps:restart` over `docker restart`; the
  reports (`--format json`) over `docker inspect`. Reaching around Dokku to the daemon is how state
  drifts out from under it. Where a `docker` call is genuinely required, say why in the script header.
- **Scripts are Bash with `set -euo pipefail`.** Same as the predecessor.
- **Anything the box must survive a reinstall of belongs in this repo**, not in a command someone once
  typed. The install is reproducible *from the guide* — that is the whole deliverable.
- `mydomain.me` is the placeholder DNS domain throughout; the operator replaces it (or adds
  `/etc/hosts` entries for a toy setup).
- **Pin Dokku's version, and remember it is pinned twice** — the `bootstrap.sh` URL path *and*
  `DOKKU_TAG`. Never below v0.38.2, which carries security fixes. See `RESEARCH.md`.
- **`[unverified]` in `RESEARCH.md` means exactly that.** Don't build a design on an unverified claim
  without saying so; the file's *Questions only a box can answer* is the punch list.
