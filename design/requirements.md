# Requirements

What must hold of the box — the promises `README.md`'s pitch makes, as official rules. One entry
per promise. A requirement *states*; it never argues: the fork behind it is the `D_` entry it
cites. Environment prerequisites — the Ubuntu version, the RAM, the DNS zone — are
`solution.md` steps and `README.md` requirements, not entries here.

- **Owner-written.** An agent never adds, edits or retires an entry here; it proposes one — in
  conversation, or as a drafted entry in `design/ideas/<slug>.md` — and the owner moves it in.
- The owner's ruler for a proposal: **allow the opposite everywhere — is it still the box the
  README pitches?** "Every app is reachable at `https://PROJECTID.<domain>` and nowhere else",
  "a project is registered with one command and never with a file" → not the same box → an entry.
  A rule about the box's *internals* that keeps a promise — "the API renders nothing", "the poll
  holds one lock box-wide" → an **invariant**: an `AGENTS.md` one-liner named below under
  *Enforced by*, not an entry here. One `requirements.md`, at the root beside the README that
  makes the promises.
- Cite by slug — `R_<slug>`. `grep '^## R_' design/requirements.md` is the index.
- Shape: `## R_<slug> — <the promise in its operational form, one sentence>`, then **Status**
  (Active, or Retired <date> — see `D_<slug>`), **If violated** (the observable failure, one or
  two sentences — not the argument, which is the `D_`'s), **Enforced by** (a test, a script step,
  a tripwire cited as `T_<slug>` — this line is that slug's home — or "review only"), **See** (the
  pitch passage and the `D_` entries behind it).
- A retired requirement stays as a tombstone. One that wants a *Rejected:* section is a decision
  — move it to `decisions.md`.
- **The first entry is the ruler**: later entries are trimmed to its length, never the other way
  round.

---

## R_cache_isolation — One project's build can never read or resolve another project's artifacts

**Status:** Active.
**If violated.** A build resolves a jar, a `node_modules` tree or a compiler cache that another
project put there. A stale or hostile artifact enters someone else's image silently, and neither
owner can see that it happened — the gap shepherd-traefik lived with, and the reason the README's
first bullet puts the per-project cache in bold.
**Enforced by.** `shepherd2-install` sets `builder:set --global selected herokuish`, so every build
uses the `cache-$APP` volume Dokku names per app; the `AGENTS.md` invariant *Apps are built by
buildpacks; the Dockerfile builder is prohibited box-wide* is what keeps it. Review otherwise —
nothing on the box re-checks the builder setting.
**See.** README, first bullet; `D_builder`, `D_isolation`.

## R_poll_not_push — A project is hosted without push access to its repo and without a webhook

**Status:** Active.
**If violated.** The box can only deploy repos whose remote the operator controls, which is the
constraint the predecessors needed a Jenkins to work around and the reason this one polls. A
commit pushed *somewhere else* stops going live on its own.
**Enforced by.** `/etc/cron.d/shepherd2` runs `shepherd2 poll` every five minutes, and the verb
calls `dokku git:sync --build-if-changes` per app; `verbs_test.rb#test_polls_only_apps_with_a_git_url`.
**See.** README, second bullet; `D_dokku`, `D_poll_churn`.

## R_no_second_component — The box runs Dokku, Docker and the OS; Shepherd2 adds one CLI and one cron file and nothing else

**Status:** Active.
**If violated.** "Built with off-the-shelf tools: Dokku and nothing else" stops being true, and the
box grows the thing both predecessors died of: a component of ours to keep running, upgrade and
converge. A daemon, a web UI, a JVM, a per-project descriptor or a network re-attacher each break
it on their own.
**Enforced by.** Review, and the `AGENTS.md` invariants that keep it — *Dokku's state is the only
source of truth*, *Dokku stays upstream and unforked*, *Shepherd2 never wraps a command Dokku
already has*, *Each project gets its own Docker network, and nothing has to re-attach anything*.
**See.** README opening, and "no web UI and no JVM anywhere"; `D_dokku`, `D_retire_shepherd_java`,
`D_dokku_is_truth`.

## R_tls_mode_is_one_way — The `http` / `https` choice is made once at install and nothing converts a running box

**Status:** Active.
**If violated.** An operator is offered a conversion that cannot be undone. The https mode sets
HSTS with a 182-day max-age, so once one app has been served over https the browsers that saw it
refuse plain http for half a year, and the box cannot repair itself.
**Enforced by.** Review only; every certificate step in `shepherd2-install` is guarded by
`SHEPHERD_TLS_MODE`, and `shepherd2-uninstall` branches on it rather than probing for a
certificate.
**See.** README *Installation* — "or plain http, if that is how the box was installed"; `D_cert`.
