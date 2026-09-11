# Upstream bug reports to file against `dokku/dokku`

Drafted 2026-09-11, **not filed** — the operator reviews first. Graduation: file them, put the issue
numbers into `D_poll_churn` (report #1) and `RESEARCH.md` → *Build tracking* (report #2), delete this
note. Nothing else waits on either: `D_poll_churn` ships the workaround regardless.

**Searched first, nothing on point.** `gh search issues --repo dokku/dokku` for `build-if-changes`,
`abandoned build record`, `builds:list retention`, `git:sync record` and `builds plugin` (open +
closed, PRs included) returns no report of either. Latest release is **v0.38.27** (2026-08-12), which
is what we pin and what the probe ran, and both defects are still present on `master` — line numbers
below are read from `master` on 2026-09-11.

---

## Report #1 — `git:sync` opens a build record it never closes when there is nothing to build

**Why this one matters more than it looks:** `--build-if-changes` is the flag whose entire purpose is
periodic polling, and it is the one path that leaves the record unfinalized. So the feature
systematically destroys the build history of every app that uses it, and the more reliably you poll the
faster it happens.

### Title

`git:sync --build-if-changes` leaves an unfinalized build record on every no-change run, which reaps as `failed`/`exit_code: -1` and evicts real build history

### Body

**Dokku version:** 0.38.27 (present on `master`)
**OS:** Ubuntu 24.04.5, Docker 29.1.3, herokuish builder

#### What happens

`cmd-git-sync` calls `dokku_setup_build_capture` *before* it fetches and before it compares refs, then
returns on the no-change path without ever finalizing the record it just started:

- `plugins/git/internal-functions`, `cmd-git-sync`: `dokku_setup_build_capture "$APP" "git:sync"` runs,
  then the clone/fetch, then `if [[ "$CURRENT_REF" == "$UPDATED_REF" ]]; then … return; fi`.
- `plugins/common/functions`, `dokku_setup_build_capture`: fires `builds-record-start` and redirects
  output into `$DOKKU_LIB_ROOT/data/builds/$APP/$DOKKU_BUILD_ID.log`.
- `builds-record-finalize` is triggered from exactly two places, `plugins/common/functions` (the deploy
  path) and `release_app_deploy_lock` — and the no-change `return` reaches neither.

The same leak affects a **plain `dokku git:sync <app> <remote>`** with no `--build*` flag at all:
`SHOULD_BUILD` stays `false`, the function falls off the end, and the record started at the top is
never finalized either. So this is not specific to `--build-if-changes`; that flag just makes it
happen 288 times a day.

#### Why it hurts

Three consequences, in the order they arrive:

1. **The records accumulate unboundedly while an app is idle.** `PruneAppBuilds` runs only from
   `builds-record-finalize`, so nothing prunes them in the meantime. Each carries a log file holding
   nothing but fetch chatter.
2. **The next real deploy rewrites them all as failures.** `ReapAbandonedBuilds` finalizes every
   dead-PID `running` record as `status: failed, exit_code: -1`. On disk that is indistinguishable
   from a build that really failed, so `builds:list <app> --status failed` stops selecting failures.
   `exit_code` is the only discriminator left, and it is not exposed as a filter.
3. **Retention then evicts the real history.** Survivors are the newest by `started_at` — the build
   that just finished plus the most recent no-op ticks. At a 5-minute poll and the default retention
   of 20, the window holds about 100 minutes, after which a real build's record *and* its log are
   deleted. "Go and read why last night's deploy failed" does not work.

There is a fourth, subtler effect: `builds:report <app>` names the newest record, so on any idle app it
reports the build status as `abandoned` rather than `succeeded`.

#### Reproduction

```bash
dokku apps:create demo
# …deploy it once, successfully, from a real repo…

# three polls with no upstream commit
for i in 1 2 3; do dokku git:sync --build-if-changes demo https://github.com/you/demo; done
dokku builds:list demo --format json
#   → three extra records, status=running / display_status=abandoned, exit_code absent,
#     one ~265-byte .log each, no finished_at

# now deploy for real
dokku git:sync --build demo https://github.com/you/demo
dokku builds:list demo --format json
#   → the three ticks are now status=failed, exit_code=-1, duration = time since each tick

# keep polling to the retention cap
for i in $(seq 16); do dokku git:sync --build-if-changes demo https://github.com/you/demo; done
dokku builds:list demo --format json | …
#   → 20 records, and the successful real deploy has been evicted
```

Measured on a real box on 2026-09-11; every step above is what it did.

#### Suggested fix

Finalize (or discard) the record on the no-change path before returning — the ref comparison already
has everything it needs, and `CURRENT_REF` is captured before the capture starts. Moving
`dokku_setup_build_capture` *after* the comparison would also work but loses the clone/fetch output
from the log, which is presumably why it sits where it does. The plain-`git:sync`-with-no-flag fall
through wants the same treatment.

A distinct status for "nothing to build" would be even better than a plain finalize: it would keep
`--status failed` meaning failed, which no filter can currently recover.

---

## Report #2 — `builds:output` never validates the build id and can exit 0 having printed nothing

Much smaller, and separable. File it second, or not at all if the maintainers would rather fold it in.

### Title

`builds:output <app> <unknown-id>` exits 0 with no output instead of reporting an unknown build

### Body

**Dokku version:** 0.38.27 (present on `master`)

`plugins/builds/subcommands.go`, `CommandOutput`: for a non-empty id that is not `current`, the
function stats the log path and, on `IsNotExist`, falls back to
`journalctl SYSLOG_IDENTIFIER=dokku-<id>`. Nothing on that path ever checks that the build id exists —
the record is read only *after* the log-file stat, and a missing record is explicitly tolerated
(`if err != nil && !os.IsNotExist(err)`).

So once a build has been pruned (`builds:prune`, or retention eviction followed by a prune) and
journald has rotated its copy away, `dokku builds:output <app> <that-id>` **prints nothing and exits
0** — indistinguishable from a build whose log was genuinely empty. A typo'd build id behaves the same
way.

Two ways out, either fine: check the record exists and return a "no such build for app" error, or have
the journald fallback report when it matched nothing.

#### Note on a related observation we could not explain

On a box, `builds:output <app> <pruned-id>` appeared to print the *current* build's output rather than
nothing. Reading `CommandOutput` afterwards does not explain that — the deploy-lock branch is only
reachable for an empty or `current` id — so it was most likely journald still answering for the pruned
id, and we are not reporting it as a claim. Mentioned only in case a maintainer recognises a path we
missed.
