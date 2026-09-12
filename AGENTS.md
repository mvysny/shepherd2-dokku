# AGENTS.md

**An index, not a manual.** This file is loaded on every turn of every session, so it holds only
what you need *before* you have a reason to look anything up: the things you would break from a
distance, the map that says where to look, and the conventions you would otherwise guess. An
entry is a line or two — the rule, what goes wrong — plus a pointer (`See D_<slug>` / `R_<slug>`);
the explanation lives at the pointer and is never summarised here, because a summary is a third
copy that drifts. **Budget: 34 KB.** Over it, *move* content to its home (`design/`, a script's
comment header) rather than compress it. A directory earns its own `AGENTS.md` the moment you want
to list its files here; `ls */AGENTS.md` finds them — there are none today, and a nested one is
capped at 10 KB, loaded only when work touches its directory. `CLAUDE.md` is byte-exactly
the line `@AGENTS.md` and nothing else, here and beside any future nested file, so `/init` and the
`#` memory shortcut must never be allowed to write into it.

## What this is

**Shepherd2 is a homebrew Heroku replacement built on [Dokku](https://dokku.com).** It builds git
repos and deploys them as Docker containers at `https://PROJECTID.<domain>` on a single Linux box.
Dokku does the building, running, routing and TLS; this repo is the **glue** — host setup,
per-project registration, the periodic-rebuild trigger, the wildcard-certificate story, and
housekeeping. It is the third implementation of this product, after
[Vaadin Shepherd](https://github.com/mvysny/shepherd) (Kubernetes) and
[shepherd-traefik](https://github.com/mvysny/shepherd-traefik) (Docker + Traefik + Jenkins); both
stay readable on GitHub, so nothing is copied out of them — `design/decisions.md`'s preamble has
how to cite their decisions.

## Design docs

Rationale and reference live under `design/`; this file holds only what its header says it may.
Each file has one audience and *what it is allowed to own*; every file's preamble states its entry
shape and how to cite it. This section is the whole contract — nothing outside the repo is needed
to follow it.

| File | Owns | Loaded? |
|---|---|---|
| `README.md` | the operator at the front door: positioning, requirements, install, onboarding a project, troubleshooting, and the day-N cheat sheet — every common task as the exact command | — |
| `AGENTS.md` (this) | what you must not break from a distance; the script index; this table — its rules are in its header | **every turn** |
| `design/requirements.md` | what must hold of the box — `R_` entries, stated not argued, **owner-written**: an agent proposes, never edits | lazy |
| `design/solution.md` | **the spec** — the inventory, the install order, the CLI surface, the flows; **when it and the code disagree, the code is wrong** | lazy |
| `design/decisions.md` | why this and not that — `D_` entries, roads not taken | lazy |
| `design/research.md` | verified facts about **Dokku**, each claim `[docs]` / `[src]` / `[verified]` / `[unverified]` | lazy |
| `design/ideas/` | not yet decided — one file per idea, `ls` is the index, deleted on graduation | transient |
| each script's comment header | that script's arguments, env knobs and prerequisites, dense and standalone; it may defer *motivation* ("see `D_dokku`"), never *usage* | source of truth |

Rules that keep the split from drifting:

- **One home per fact; the others link.** A one-line restatement that saves a jump is fine —
  repeat the *fact*, defer the *explanation*. Compressing a `D_` entry into a bullet here is a
  third copy, not a summary.
- **`decisions.md` argues, `requirements.md` states, `research.md` is about *Dokku* not us,
  `solution.md` composes and never argues.** A paragraph explaining *why* in any file but
  `decisions.md` has drifted; move it and cite the `D_`.
- **A `D_` is earned by what happened, not by having had an alternative:** it shaped what the box
  is (reverse it and the README's first paragraph changes — the PaaS, the builder, the proxy, "no
  JVM anywhere"), or it cost research the next person would otherwise redo, and *Rejected:* then
  says what was **done** to rule the road out. A tool, a library among equals, the CI host, a
  version bump — a comment at the site of the choice, never an entry. Only decisions already taken;
  ideas, TODOs and open questions go to `design/ideas/`. A shipped decision that is reversed keeps
  its entry as a tombstone. Nothing about `design/` itself or its tooling is an entry: the layer's
  rules are its skill's, and this repo's local amendments are commented where they are wired
  (`design/verify_design_tripwires.sh`, `test/run`).
- **An `R_` is a promise the README's pitch makes, made an official rule — and the owner writes
  it.** An agent never adds, edits or retires one; it proposes, in conversation or as a drafted
  entry in `design/ideas/`. The owner's ruler: allow the opposite everywhere — is it still the
  pitched box? A rule about the box's *internals* that keeps a promise is an **invariant** — one
  line in this file, named in the promise's *Enforced by* — not an `R_`.
- **An invariant is one line here, and nothing more:** the rule, at most one clause of consequence,
  `T_<slug>` if tripwired, `See D_<slug>` only when a `D_` exists — no fork, no cite; the agent has
  the script. A line that will not fit belongs in that script's comment header.
- **Slugs:** `D_` decisions, `R_` requirements, `T_` tripwires (cited from a requirement's
  *Enforced by* or an invariant line here, defined by the check), `Q_` open questions inside
  `design/ideas/` only — a durable doc never cites a `Q_`. Underscores throughout, backticked in
  prose, cited by slug never by position; `grep '^## D_' design/decisions.md` is the index. There
  is no `F_` namespace and no feature-list file — don't reintroduce either. No CHANGELOG either:
  the deploy is a `git pull`, so git is the changelog.
- **`design/verify_design_tripwires.sh`** fails on any cited `D_` / `R_` without a heading, a `T_`
  without a check, an oversized `AGENTS.md`, or a `CLAUDE.md` that isn't the shim. Run it before
  committing a doc change.

### Ideas & their graduation

An idea graduates the moment it is acted on, and graduation is not done until its file (and any
sidecar folder `design/ideas/<name>/`) is gone. Where the lasting nuggets land:

- verified behaviour of **Dokku** or one of its plugins → `design/research.md`, with a provenance marker
- the choice made + the alternatives rejected → a `D_` entry in `design/decisions.md` if it passes
  the gate above; otherwise a comment at the site of the choice
- a promise the README's pitch makes that must hold from now on → a proposal for the owner, who
  writes the `R_` entry; the internal rule that *keeps* one → a one-line invariant in this file
- work deferred *as a consequence of a logged decision* → that entry's *Consequences*
- where a piece sits in the assembled box — an install step in sequence, a flow crossing several
  decisions, a fact about what the box holds → `design/solution.md`
- a new script, or one whose responsibility changed → one line in the *Script index* below
- an operator-facing setup step, requirement or troubleshooting recipe → `README.md`; a day-N task
  and the exact command for it → its *Day-to-day operations* cheat sheet
- the precise truth of one script — arguments, env knobs, prerequisites → that script's comment header
- a cross-cutting invariant ("never reintroduce a naming contract") → one line in this file: the
  rule, `T_<slug>` if tripwired, `See D_<slug>` if a `D_` exists

**The sidecar trap, sharpened for this repo:** most Dokku facts outlive the idea that prompted
looking them up, so a sidecar finding's default destination is `design/research.md`, not the bin.
Scan `ls design/ideas/<name>/` at graduation, not just the idea file.

*Layout seeded from the `design-docs` skill (mvysny, `~/.claude/skills`); this project needs
nothing from it.*

## Invariants — what breaks from a distance

- **Apps are built by buildpacks; the Dockerfile builder is prohibited box-wide.** Re-enabling it
  to "fix" a build makes per-project cache isolation unenforceable, which is the entire reason for
  the prohibition. See `R_cache_isolation`, `D_builder`.
- **Each project gets its own Docker network, and nothing has to re-attach anything.** If you find
  yourself writing a successor to `shepherd-traefik-connect-networks`, something else is wrong.
  See `R_no_second_component`, `D_isolation`.
- **Dokku's state is the only source of truth; there is no project descriptor.** A per-project file
  or a converger reintroduces the drift that killed both predecessors. See `R_no_second_component`,
  `D_dokku_is_truth`.
- **The API renders nothing and the front-end decides nothing about the box.** An `out:` in
  `shepherd2.rb`, or a `dokku` call in `shepherd2-cli`, has moved the boundary and costs the next
  front-end its verbs. See `D_api_surface`.
- **TLS is one wildcard certificate and nothing per app — and https is a *mode*.** Nothing outside
  `install` / `uninstall` may assume a certificate exists, and nothing anywhere may offer to convert
  a running box: HSTS makes the downgrade unrepairable. See `R_tls_mode_is_one_way`, `D_cert`.
- **Project ids beginning with `admin` are reserved.** A future admin surface needs that hostname
  under the wildcard, and a box that gave it away cannot take it back. See `D_admin_namespace`.
- **The proxy is Dokku's default host nginx, and it is not a container.** Don't set `proxy:type` or
  run `traefik:start`; measured, Traefik cannot reach a per-app network and the failure is a silent
  hang with empty logs, so switching proxies would take `D_isolation` with it. See `D_proxy`.
- **Dokku stays upstream and unforked.** A missing capability is answered by a wrapper script, a
  crontab line or a documented manual step — not a patch, a fork, or a plugin we maintain without a
  `D_` entry saying so. `dokku-global-cert` is the one third-party plugin we depend on
  (`R_no_second_component`, `D_cert`).
- **Shepherd2 never wraps a command Dokku already has.** `shepherd2 logs` is `shepherd-cli`
  reincarnated; `dokku logs` / `ps:restart` / `config:set` are used as they are, from the README
  cheat sheet. See `R_no_second_component`.
- **`stats` and `last-build` are the two exceptions, and their boundaries are load-bearing.**
  `stats` is a snapshot: a time axis makes it the status page in `design/ideas/web-admin-ui.md`
  (`D_stats`). `last-build` is deleted the day upstream fixes the build-record ordering
  (`D_poll_churn`).
- **Don't reintroduce what was deliberately removed:** Jenkins, Traefik-as-ours, the
  `shepherd_PROJECTID` / `shepherd/PROJECTID` / `PROJECTID.shepherd` naming contract,
  `docker-compose.yaml`, `/etc/shepherd/java/config.json`, the per-project JSON descriptor and its
  converger, every JVM component, and building from a project's own `Dockerfile` with
  `build.dockerFile` / `build.buildArgs`. See `D_dokku`, `D_retire_shepherd_java`, `D_builder`.
- **Anything the box must survive a reinstall of belongs in this repo**, not in a command someone
  typed once. The install is reproducible *from this repo* — that is the whole deliverable.

## Script index

A map, not a reference: a pointer plus what the thing is for, with **every script's own comment
header the authority** on its arguments, env knobs and prerequisites. Put new technical truth
*there*, not here.

| Script | What it is for |
|---|---|
| `shepherd2-install` | Bash. Vanilla Ubuntu 24.04 → a working box: Docker, Dokku, address pools, TLS mode, the CLI, cron. Re-runnable; every step guarded |
| `shepherd2-uninstall` | Bash. The inverse, driven by `SHEPHERD_TLS_MODE`. Destroys every project; `--keep-docker` / `--keep-pools` opt out of the two steps that reach past Shepherd2's own layer |
| `shepherd2.rb` | Ruby, the API: one method per verb, returning data and rendering nothing. Holds `Shepherd2::Dokku`, `::Docker`, `::Machine`, `::BuildLock` — its process-running seams and its test surface |
| `shepherd2-cli` | Ruby, the executable, installed as `/usr/local/bin/shepherd2` (a symlink). Argument parsing, every sentence the box prints, and the mapping from a verb's return value onto an exit code |
| `test/` | minitest, run as `ruby test/run`. `helper.rb` loads the *library* alone, which is the path a front-end that is not the CLI takes; `cli_test.rb` loads the executable on top |
| `design/verify_design_tripwires.sh` | the doc-layer checks: dangling `D_` / `R_` / `T_` slugs, the `AGENTS.md` caps, the `CLAUDE.md` shim |

## Conventions

- **The CLI is Ruby; the installers are Bash.** `shepherd2.rb` and `shepherd2-cli` hold every verb
  between them, standard library only — no `Gemfile`, no gems — against Ruby 3.2, which is what the
  box ships. `shepherd2-install` / `shepherd2-uninstall` and any future box script stay Bash with
  `set -euo pipefail`: they run before Ruby is guaranteed to exist and after it may be gone. A new
  file picks by which of the two it is. See `D_ruby`.
- **Tests are minitest from apt (`ruby-minitest`), dev-only, and there is no `Gemfile`.** See `D_testing`.
- **Prefer a Dokku command to a `docker` command** — `dokku ps:restart` over `docker restart`, the
  `--format json` reports over `docker inspect`. Reaching around Dokku is how state drifts out from
  under it; where a `docker` call is genuinely required, say why in the script header.
- **Pin Dokku's version**, never below v0.38.2, which carries security fixes (`design/research.md`).
- **The box is Ubuntu 24.04, and so is the VM this is developed in.** Not 26.04: Dokku's installer
  refuses it and no `dokku` package is built for it. Don't work around it — `D_host_os` names the
  two upstream things that must change first.
- **`mydomain.me` is the placeholder DNS domain throughout**; the operator replaces it, or adds
  `/etc/hosts` entries for a toy setup.
- **`[unverified]` in `design/research.md` means exactly that.** Don't build a design on one without
  saying so; that file's *Questions only a box can answer* is the punch list.

## Commands

```bash
ruby test/run                       # the doc tripwires, then the whole suite
ruby -Itest test/verbs_test.rb      # one file
design/verify_design_tripwires.sh   # the doc tripwires alone, after a doc-only change
shellcheck shepherd2-install shepherd2-uninstall design/verify_design_tripwires.sh
```

`test/run` runs the tripwires first and aborts on them, so a dangling `D_` / `R_` slug or an
oversized `AGENTS.md` trips in the session that caused it. CI is `.github/workflows/test.yml`: the
same two commands, in an `ubuntu:24.04` container so the suite runs on the box's own Ruby.

## Skills this project follows

- **Doc comments** carry the per-symbol what *and* why, complete standalone; the `writing-rdoc`
  skill has the rules.
- **`design/ideas/`** is a one-file-per-idea scratchpad, deleted on graduation and never given an
  index; the `ideas-folder` skill has the procedure, and *Ideas & their graduation* above says
  where this project's nuggets land.
