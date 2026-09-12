# Requirements as promises — a proposal for the owner

**For Martin to decide; an agent must not act on this unilaterally.** `design/requirements.md` is
owner-written, and this note is the proposal its preamble asks for.

The doc layer's `R_` definition tightened: an entry is a **promise `README.md`'s pitch makes**,
and the rule about the box's *internals* that keeps a promise is an **invariant** — an
`AGENTS.md` one-liner, named in the promise's *Enforced by*. The test is **who notices a
violation**: the operator/user → promise; only a maintainer → invariant. The six entries were
written before that split, lifted wholesale out of the old `CLAUDE.md` invariants, so most of
them sit on the invariant side — and each already has its `AGENTS.md` line, so retiring one
loses nothing.

The pitch's actual promises, from `README.md`'s opening bullets, are: **per-project build cache
isolation**; **a Procfile, not a Dockerfile**; **`PROJECTID.<domain>`, https or http as installed**;
**polling, so repos you don't own can be hosted**; **Dokku and nothing else — no web UI, no JVM**.

## Entry by entry

| Entry | Who notices | Proposal |
|---|---|---|
| `R_buildpack_only` | maintainer (the builder setting) | **Invariant.** The promise underneath it is the pitch's "one project can never resolve another's jars" — see the new entry proposed below, which would name `builder:set --global selected herokuish` under *Enforced by* |
| `R_network_per_project` | maintainer | **Invariant.** "Apps cannot reach each other" is not in the pitch today; if you want it as a promise, the pitch needs the sentence first |
| `R_dokku_is_truth` | maintainer | **Invariant.** The pitch line it serves is "Dokku and nothing else" — candidate promise: *nothing of ours runs on the box but one CLI and one cron file; no descriptor, no daemon, no converger* |
| `R_api_renders_nothing` | maintainer only | **Retire.** Nobody outside this repo can observe it. The `AGENTS.md` line plus `D_api_surface` carry it |
| `R_admin_reserved` | the operator who wanted `admin.<domain>` — years later | **Retire or keep, your call.** It is one guard in `create-app` with a test, not a whole-tree rule; `D_admin_namespace` and the `AGENTS.md` line hold it either way |
| `R_tls_mode_is_one_way` | the operator, immediately and irreparably | **Keep** — the closest thing here to a promise, and the parenthetical "or plain http, if that is how the box was installed" is where the pitch makes it |

## Promises the pitch makes that have no entry

- **`R_cache_isolation`** — *one project's build can never read or resolve another project's
  artifacts*. The README's first bullet, in bold, and the reason `D_builder` exists;
  `R_buildpack_only` and the `cache-$APP` volume are what enforce it.
- **`R_poll_not_push`** — *a project is hosted without push access to its repo, and without a
  webhook*. Bullet two, and the one capability the predecessors' Jenkins had to be built for.
- **`R_no_second_component`** — *the box runs Dokku, Docker and the OS; Shepherd2 adds one CLI
  and one cron file and nothing else*. "Built with off-the-shelf tools: Dokku and nothing else",
  plus "no web UI and no JVM anywhere".

Each is a promise by the ruler — allow the opposite everywhere and it is a different product —
and each is currently unstated.

## Also pending, whichever way the above goes

The six entries use **Why** (a paragraph of argument); the preamble now asks for **If violated**
(the observable failure, the argument left to the `D_`). Any entry that survives wants that pass.
