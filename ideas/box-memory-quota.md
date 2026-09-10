# `Q_quota` — is there an enforcement point for a box-wide memory quota that Dokku's state doesn't undermine?

**Deferred for v1 (2026-09-10): no quota at all.** This note is the v2 question and keeps the slug
`Q_quota`, which `SOLUTION.md` → *What v1 does not do* and `D_dokku_is_truth` cite.

What Shepherd used to do: refuse to create a project whose runtime + build memory would overflow what
the box has (`memoryQuotaMb`, checked in `ShepherdClient.validate`). Dokku has no counterpart — nothing
sums limits across apps, and nothing refuses a limit the box cannot honour.

**Why it was deferred rather than written.** The check itself is cheap: sum
`dokku resource:report --format json` across `apps:list` and refuse an over-commit — maybe 20 lines in
`create-app`. But `create-app` is the *only* place we can put it, and under `D_dokku_is_truth` a later
hand `dokku resource:limit` bypasses it entirely. A guard that holds only on the path the single
operator already controls did not earn its lines before the box exists.

**So the v2 question is the interesting one, and it is about the enforcement point, not the arithmetic:**
is there anywhere the check can live that Dokku's own state does not route around? Sketches, none
researched:

- A `post-app-create` / `pre-deploy` **plugin trigger** of our own that re-does the sum — moves the
  check off the `create-app` path, at the price of a plugin we maintain, which `CLAUDE.md`'s
  *Dokku stays upstream and unforked* rule allows only with a `D_` entry behind it.
- **Give up on refusing, and report instead**: a cron that sums the limits and complains when the box is
  over-committed. Not enforcement, but it survives every edit path — and it is roughly the same cron
  that option 1 in `ideas/web-admin-ui.md` would need anyway.
- **Reservations rather than limits.** `dokku resource:reserve` maps to Docker's
  `--memory-reservation`; whether letting the kernel arbitrate is a better answer than arithmetic on our
  side is unexplored. `RESEARCH.md` → *Resource limits* has the flag mapping.

Note that the thing a quota was protecting against got smaller: one build runs at a time
(`SOLUTION.md` → the poll's non-blocking lock), so the build figure is a box-wide peak rather than a
per-app multiplier, and the default limits are 256m runtime and 2g build.
