# Requirements

What must hold of the box's behaviour, not of the environment it runs in. One entry per
requirement. A requirement *states*; it never argues: the fork behind it is the `D_` entry it
cites. Environment prerequisites — the Ubuntu version, the RAM, the DNS zone — are
`solution.md` steps and `README.md` requirements, not entries here.

- Cite by slug — `R_<slug>`. `grep '^## R_' design/requirements.md` is the index.
- Slug only what is referenced from elsewhere; `AGENTS.md` carries the one-liner, this file the
  full statement.
- Shape: `## R_<slug> — <the requirement, one sentence>`, then **Status** (Active, or Retired
  <date> — see `D_<slug>`), **Why** (one paragraph), **Enforced by** (a test, a script step, a
  tripwire cited as `T_<slug>` — this line is that slug's home — or "review only"), **See** (the
  `D_` entries behind it).
- A retired requirement stays as a tombstone. One that wants a *Rejected:* section is a decision
  — move it to `decisions.md`.
- **The first entry is the ruler**: later entries are trimmed to its length, never the other way
  round.

---

## R_buildpack_only — Every app is built by a buildpack; no app is ever built from a `Dockerfile`

**Status:** Active.
**Why.** The Dockerfile builder gives each build a shared BuildKit cache that no per-app boundary
can partition, so one project's build can resolve another's jars — the gap shepherd-traefik lived
with. Buildpacks build against the `cache-$APP` volume Dokku names per app, which makes the
isolation structural rather than a convention. The prohibition is box-wide and global, so a
committed `Dockerfile` is simply never read.
**Enforced by.** `shepherd2-install` sets `builder:set --global selected herokuish`; review
otherwise — nothing on the box re-checks it.
**See.** `D_builder`.

## R_network_per_project — Every app runs on its own Docker bridge network, re-applied by Dokku itself

**Status:** Active.
**Why.** Apps must not reach each other, and the repair job both predecessors needed
(`shepherd-traefik-connect-networks`) existed only because the attachment was ours to maintain.
`initial-network` is persisted app state Dokku re-applies at container creation, so nothing has to
re-attach anything after a rebuild or a reboot. If you find yourself writing a re-attacher,
something else is wrong.
**Enforced by.** `create_app_test.rb#test_network_is_set_before_the_first_build`.
**See.** `D_isolation`, `D_proxy`.

## R_dokku_is_truth — The only per-project state Shepherd2 owns is `SHEPHERD_*` config vars on the app

**Status:** Active.
**Why.** shepherd-java kept a per-project JSON descriptor and a control plane that converged
Docker onto it, because plain Docker persists no per-app configuration. Dokku does, so a second
store on top of it could only drift: a project fact is read from `dokku *:report --format json`,
and a fact of ours is a `SHEPHERD_GIT_URL` / `SHEPHERD_OWNER` config var — plus one box-level
`SHEPHERD_TLS_MODE` — or it does not exist. No file, no database, no re-applier.
**Enforced by.** Review only; `verbs_test.rb#test_polls_only_apps_with_a_git_url` pins the read path.
**See.** `D_dokku_is_truth`.

## R_api_renders_nothing — A verb in `shepherd2.rb` returns data and never touches stdout, stderr or stdin

**Status:** Active.
**Why.** Every sentence the box prints and every exit code it returns is written in
`shepherd2-cli`, so that a second front-end — a TUI, a status page — gets the same verbs without
scraping text. The library reports progress through `on_event` and asks through `confirm`; a verb
that returns a sentence, or an `out:` parameter in the library, has moved the boundary. One
crossing is sanctioned: a verb may hand the terminal to Dokku through the `Dokku` seam.
**Enforced by.** `stats_test.rb#test_the_snapshot_carries_no_rendered_text`; `helper.rb` loads the
library alone, so anything printing would have no renderer to lean on.
**See.** `D_api_surface`.

## R_admin_reserved — `create-app` refuses any project id beginning with `admin`

**Status:** Active.
**Why.** A future admin surface needs a hostname under the wildcard certificate, and the only way
to guarantee one is free is to refuse it from the first day — a box with `admin.mydomain.me`
already taken by someone's app cannot get it back without destroying that app.
**Enforced by.** `create_app_test.rb#test_admin_ids_are_refused_before_anything_is_mutated`.
**See.** `D_admin_namespace`.

## R_tls_mode_is_one_way — The `http` / `https` choice is made once at install and nothing converts a running box

**Status:** Active.
**Why.** The https mode sets HSTS with a 182-day max-age, which browsers remember; once one app
has been served over https, downgrading the box to http is unrepairable from the box. So nothing
outside `install` / `uninstall` may offer the conversion, and nothing anywhere may assume a
certificate exists — every certificate step is guarded by `SHEPHERD_TLS_MODE`.
**Enforced by.** Review only; `shepherd2-uninstall` branches on `SHEPHERD_TLS_MODE` rather than
probing for a certificate.
**See.** `D_cert`.
