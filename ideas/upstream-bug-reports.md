# Upstream bug reports to file against `dokku/dokku`

**Both filed, 2026-09-11:** [dokku/dokku#9030](https://github.com/dokku/dokku/issues/9030) (the
`git:sync` record leak, cited in `D_poll_churn`) and
[dokku/dokku#9031](https://github.com/dokku/dokku/issues/9031) (`builds:output`, cited in
`RESEARCH.md` → *Build tracking*). What keeps this note alive is the **unsanitised build id** below,
which is not an issue to file publicly and needs the operator's decision. Once that is settled the
note goes, and the evidence in `ideas/upstream-bug-reports/` goes with it — so anything durable must
be in `RESEARCH.md` by then.

**Searched first, nothing on point.** `gh search issues --repo dokku/dokku` for `build-if-changes`,
`abandoned build record`, `builds:list retention`, `git:sync record` and `builds plugin` — open and
closed, PRs included — returns no report of either defect. Latest release is **v0.38.27** (2026-08-12),
which is what we pin and what the probe ran, and both are still present on `master`. Every source link
below is pinned to **`aa39920`** (2026-09-10), the master tip when this was drafted.

## The box run happened: 2026-09-11, Dokku 0.38.27

A fresh Ubuntu 24.04 VM, installed from `shepherd2-install --mode http`, app `demo` =
`heroku/node-js-getting-started` on `heroku/nodejs`. Everything the drafts need is captured in
`ideas/upstream-bug-reports/` — transcripts, the record dumps, `dokku-report-demo.txt` (the issue
form's required field), `environment.txt`, and `prompt.txt`, which is what drove the session that
produced the rest. **Both reports reproduce.** What the run *changed*:

- **Report #1's third consequence was wrong about the mechanism, and is now right.** Records are not
  evicted by polling: `builds:list` merely **caps its output at the retention count**, while the files
  accumulate on disk untouched — the box reached **41 records against a retention of 20**, and setting
  retention back to 300 made all 41 reappear in the listing (`accumulation.txt`). The history is
  destroyed later and elsewhere: `PruneAppBuilds` runs from `builds-record-finalize`, so it is **the
  next real deploy** that deletes the older real build's `.json` *and* `.log` while keeping the no-op
  ticks (`transcript-prune-on-finalize.txt`). The draft's "keep polling and the deploy is evicted" step
  did not do what it claimed, and a maintainer would have found that out.
- **Two details sharpened.** A tick's log is **244 bytes**, not ~265. And reaping does not merely
  relabel: it stamps `finished_at` with the reap moment, so a one-second no-op is recorded as a
  **1m29s** failed build.
- **One consequence added.** The leak is not confined to the no-change path: a `git:sync --build` whose
  *clone* fails leaks an unfinalized record the same way. The box produced one by accident — the first
  `create-app` omitted the ref, Dokku defaulted to `master`, and the resulting pathspec error left
  record `mtwy43mte1do5q` `running`, later reaped to `failed / exit_code -1`.
- **The loose end is settled: journald answered.** See the bottom of this note.
- **Ours, not theirs, both first runs on a box:** `shepherd2-install`'s
  `builds:set --global retention 300` fires (`install.log`), and `shepherd2 last-build` works against
  real Dokku output — all three of its unverified assumptions hold. It also found a hole in the verb,
  logged here at first as "not a defect" and since fixed: it read the unfiltered listing and so
  inherited the retention cap. See *Our two pieces* below.

### The sequence that was run

Corrected against the box — the original omitted `create-app`'s ref argument, without which Dokku
defaults to `master` and the first deploy fails.

```bash
# 0. Clone and take the branch the retention line and `last-build` live on.
git clone git@github.com:mvysny/shepherd2-dokku.git /home/mavi/work/my/shepherd2-dokku
cd /home/mavi/work/my/shepherd2-dokku
git checkout poll-churn-retention-and-last-build
[[ -r ~/.ssh/id_ed25519.pub ]] || ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519

# 1. Install — and confirm the new retention line fires.
mkdir -p ideas/upstream-bug-reports
sudo ./shepherd2-install --domain shepherd2.test --mode http \
     --ssh-key /home/mavi/.ssh/id_ed25519.pub --yes 2>&1 \
  | tee ideas/upstream-bug-reports/install.log
grep -i retention ideas/upstream-bug-reports/install.log   # expect: build record retention: 300

# 2. Poll cron off for the duration.
sudo sed -i 's|^\*/5|#*/5|' /etc/cron.d/shepherd2

# 3. Stock retention, so the report's arithmetic is Dokku's and not ours.
sudo dokku builds:set --global retention                   # unset -> back to 20
sudo dokku builds:report --global | grep -i retention

# 4. One app. The REF ARGUMENT IS REQUIRED: this sample's default branch is `main`, and without it
#    `git:sync` defaults to `master` and the first deploy dies on `pathspec 'master' did not match`.
echo '127.0.0.1 demo.shepherd2.test' | sudo tee -a /etc/hosts
sudo shepherd2 create-app demo https://github.com/heroku/node-js-getting-started main \
     --owner mavi@vaadin.com --buildpack heroku/nodejs

# 5. Report #1's repro.
REPO=https://github.com/heroku/node-js-getting-started
for i in 1 2 3; do sudo dokku git:sync --build-if-changes demo "$REPO"; done
sudo dokku builds:list demo --format json > ideas/upstream-bug-reports/records-3-ticks.json
sudo dokku git:sync --build demo "$REPO"                   # a real deploy, unchanged ref
sudo dokku builds:list demo --format json > ideas/upstream-bug-reports/records-after-deploy.json
for i in $(seq 16); do sudo dokku git:sync --build-if-changes demo "$REPO"; done
sudo dokku builds:list demo --format json > ideas/upstream-bug-reports/records-at-cap.json
# ... and then, because the listing is capped rather than pruned, count the DISK and deploy again:
sudo ls /var/lib/dokku/data/builds/demo/*.json | wc -l     # 22, against a retention of 20
sudo dokku git:sync --build demo "$REPO"                   # its finalize is what deletes history
sudo ls /var/lib/dokku/data/builds/demo/*.json | wc -l     # 20 — and the first deploy's log is gone

# 6. The required field, plus the environment block both reports want.
sudo dokku report demo > ideas/upstream-bug-reports/dokku-report-demo.txt
{ dokku version; docker --version; lsb_release -ds; } \
  > ideas/upstream-bug-reports/environment.txt

# 7. Report #2, which needs no state at all.
sudo dokku builds:output demo not-a-real-build-id; echo "exit=$?"

# 8. The loose end. NOTE: `builds:prune` only trims to the retention count, so on an app already at
#    the cap it is a no-op — the subject has to be a build some earlier deploy's finalize deleted.
sudo dokku builds:output demo <an-id-whose-.log-is-gone>; echo "exit=$?"
sudo journalctl -t dokku-<that-id> --no-pager -o cat | diff - <(previous output)

# 9. Put it back.
sudo dokku builds:set --global retention 300
sudo sed -i 's|^#\*/5|*/5|' /etc/cron.d/shepherd2
```

---

## Report #1 — FILED as [dokku/dokku#9030](https://github.com/dokku/dokku/issues/9030)

*Our framing, not for the body:* `--build-if-changes` is the flag whose entire purpose is periodic
polling, and it is the one path that leaves the record unfinalized — so the feature systematically
destroys the build history of every app that uses it, faster the more reliably you poll.

### Title

`git:sync` never finalizes the build record it starts when there is nothing to build

### Description of problem

`cmd-git-sync` starts a build record *before* it fetches and before it compares refs, then returns on
the no-change path without ever finalizing it:

- [`cmd-git-sync` calls `dokku_setup_build_capture`](https://github.com/dokku/dokku/blob/aa39920cc78726ef51252d5ac6c543c40a27983d/plugins/git/internal-functions#L285)
  at the top, before the clone/fetch and before `CURRENT_REF` is compared to `UPDATED_REF`.
- [`dokku_setup_build_capture`](https://github.com/dokku/dokku/blob/aa39920cc78726ef51252d5ac6c543c40a27983d/plugins/common/functions#L889)
  fires `builds-record-start` and redirects output into `data/builds/$APP/$DOKKU_BUILD_ID.log`.
- [the no-change path returns](https://github.com/dokku/dokku/blob/aa39920cc78726ef51252d5ac6c543c40a27983d/plugins/git/internal-functions#L300-L303)
  — and `builds-record-finalize` is triggered from exactly two places,
  [the deploy path](https://github.com/dokku/dokku/blob/aa39920cc78726ef51252d5ac6c543c40a27983d/plugins/common/functions#L707)
  and [`release_app_deploy_lock`](https://github.com/dokku/dokku/blob/aa39920cc78726ef51252d5ac6c543c40a27983d/plugins/common/functions#L939),
  neither of which that `return` reaches.

The same leak affects a **plain `dokku git:sync <app> <remote>`** with no `--build*` flag: `SHOULD_BUILD`
stays `false`, the function falls off the end, and the record started at the top is never finalized
either. It is not specific to `--build-if-changes`; that flag is simply the one people put on a timer,
and a five-minute timer means 288 of these a day per app. A `--build` whose *clone* fails leaks
identically — a wrong `deploy-branch` produced one here.

**What I expected:** a run that builds nothing leaves no build record, or leaves one marked as
"nothing to build". **What happens instead**, in the order it arrives:

1. **The records accumulate without bound while an app is idle.** `PruneAppBuilds` runs only from
   `builds-record-finalize`, so nothing prunes them in the meantime. Each carries a 244-byte log file
   holding nothing but fetch chatter. This is invisible from the CLI, because `builds:list` caps its
   output at the retention count: my `demo` app showed 20 rows while holding **41 records on disk**.
2. **The next real deploy rewrites them all as failures.** `ReapAbandonedBuilds` finalizes every
   dead-PID `running` record as `status: failed, exit_code: -1`, which on disk is indistinguishable
   from a build that really failed. `builds:list <app> --status failed` therefore stops selecting
   failures, and `exit_code` — the only discriminator left — is not exposed as a filter. Reaping also
   stamps `finished_at` with the moment of reaping, so a one-second no-op is recorded with a
   `duration` of `1m29s` and reads, in the table, exactly like a real build that ran and failed.
3. **The same deploy's finalize then prunes the real history away.** `PruneAppBuilds` keeps the newest
   records by `started_at` — which after an idle stretch are the no-op ticks plus the build that just
   finished. The earlier successful deploy's record *and* its log are deleted outright. On my box the
   deploy that pruned kept 20 records, of which 19 were no-op ticks. At a five-minute poll and the
   default retention of 20 that window is about 100 minutes, so "go and read why last night's deploy
   failed" does not work.

A fourth, quieter effect: the app report is computed from the newest record alone —
[`reportBuildStatus`](https://github.com/dokku/dokku/blob/aa39920cc78726ef51252d5ac6c543c40a27983d/plugins/builds/report.go#L82-L88)
takes `builds[0]` and returns its `DisplayStatus()` — so on an idle app `dokku builds:report <app>`
shows `Build status: abandoned` however long ago the app last built successfully.

### Steps to reproduce

```bash
dokku apps:create demo
dokku git:sync --build demo https://github.com/heroku/node-js-getting-started main

# three polls with no upstream commit
for i in 1 2 3; do dokku git:sync --build-if-changes demo https://github.com/heroku/node-js-getting-started; done
dokku builds:list demo --format json
#  -> three extra records, status=running / display_status=abandoned, no exit_code,
#     no finished_at, one 244-byte .log each

dokku git:sync --build demo https://github.com/heroku/node-js-getting-started   # deploy for real
dokku builds:list demo --format json
#  -> the three ticks are now status=failed, exit_code=-1, and their duration has grown from
#     ~1s to the interval between their start and the moment they were reaped
dokku builds:list demo --status failed
#  -> lists only the no-op ticks; the filter no longer selects failures

# poll past the retention cap
for i in $(seq 20); do dokku git:sync --build-if-changes demo https://github.com/heroku/node-js-getting-started; done
ls /var/lib/dokku/data/builds/demo/*.json | wc -l
#  -> 25: nothing is pruned while the app is only polled
dokku builds:list demo --format json | jq length
#  -> 20: the listing is capped at the retention count, so the growth is not visible here

# the NEXT real deploy is what destroys the history
dokku git:sync --build demo https://github.com/heroku/node-js-getting-started
ls /var/lib/dokku/data/builds/demo/*.json | wc -l
#  -> 20, and the earlier successful deploy's .json and .log are both gone;
#     the survivors are 19 no-op ticks and the build that just finished
```

Run on 0.38.27 on 2026-09-11, Ubuntu 24.04, Docker 29.1.3.

### `dokku report $APP_NAME`

*(Paste `ideas/upstream-bug-reports/dokku-report-demo.txt` from the box run — step 6.)*

### Additional information

Reproduced with `heroku/node-js-getting-started` on the herokuish builder, `heroku/nodejs` pinned —
but nothing about the app matters: the leak is in `cmd-git-sync` before any builder is reached, a plain
`git:sync` with no build flag leaks identically, and so does a `--build` that fails to clone.

**Suggested fix.** Finalize (or discard) the record on the no-change path before returning — the ref
comparison already has what it needs, and `CURRENT_REF` is captured before the capture starts. Moving
`dokku_setup_build_capture` *after* the comparison would also work but loses the clone/fetch output
from the log, which is presumably why it sits where it does. The no-flag fall-through wants the same
treatment. A distinct status for "nothing to build" would be better still: it would keep `--status
failed` meaning failed, which no filter can currently recover.

*(Not blocking us. We raise `builds:set --global retention 300` so the last real build stays visible in
the listing for about a day of ticks, and read it back with a filtered listing — `builds:list <app>
--kind build`, which skips the cap — rather than the default one. Neither addresses the leak itself.)*

---

## Report #2 — FILED as [dokku/dokku#9031](https://github.com/dokku/dokku/issues/9031)

### Title

`builds:output` does not validate the build id and can exit 0 printing nothing

### Description of problem

In [`CommandOutput`](https://github.com/dokku/dokku/blob/aa39920cc78726ef51252d5ac6c543c40a27983d/plugins/builds/subcommands.go#L360-L398),
a non-empty id that is not `current` skips the deploy-lock branch, and the log path is then stat'd —
on `IsNotExist` it
[falls back to `journalctl SYSLOG_IDENTIFIER=dokku-<id>`](https://github.com/dokku/dokku/blob/aa39920cc78726ef51252d5ac6c543c40a27983d/plugins/builds/subcommands.go#L382-L404).
Nothing on that path checks that the build id exists: the record is read only *after* the stat, and a
missing record is explicitly tolerated (`if err != nil && !os.IsNotExist(err)`).

So for a build whose log has been pruned and whose journald copy has rotated away — and equally for a
typo'd id — `dokku builds:output <app> <id>` **prints nothing and exits 0**, indistinguishable from a
build whose log was genuinely empty. I expected `no such build <id> for app <app>`.

### Steps to reproduce

```bash
dokku builds:output demo not-a-real-build-id ; echo "exit=$?"
#  -> no output, exit=0
```

Verified on 0.38.27, 2026-09-11.

### `dokku report $APP_NAME`

*(Same paste as #1. Nothing in it is load-bearing here — any app name reproduces this.)*

### Additional information

Either fix works: check the record exists and return a "no such build" error, or have the journald
fallback report when it matched nothing.

---

## Settled: `builds:output` on a pruned id prints journald's copy

The probe's unexplained observation — that a pruned id seemed to print the *current* build's output —
was a misread. `journalctl` is what answers, exactly as `CommandOutput` says it should.

Subject: `mtwy4os7reupqs`, the box's first successful deploy, whose `.json` and `.log` were deleted by
a later deploy's `PruneAppBuilds`. Its own container id is `ef1d5e418137`; the current build's is
`551cdf90b402`.

```
$ dokku builds:output demo mtwy4os7reupqs
exit=0
bytes printed: 4087
```

Byte-identical to `journalctl -t dokku-mtwy4os7reupqs --no-pager -o cat` (4087 bytes, zero diff lines);
contains its own container id three times and the current build's not at all. Full transcript in
`ideas/upstream-bug-reports/transcript-pruned-id-output.txt`.

So nothing is wrong beyond report #2's silent-empty case, which is what happens once journald has
rotated the id away. `RESEARCH.md` has been corrected to state this rather than hedge it.

---

## Not for a public issue: the build id is not sanitised before it becomes a path

**Operator's call, and the reason it was cut out of report #2.** The box tried a traversal-shaped id
"for completeness" and got nothing printed, exit 0, and this note first concluded "no file outside the
builds directory is read, so it is a usability defect and not a disclosure one." **That conclusion was
wrong**, and it is the kind of wrong that should not be published either way:

```go
func LogPathFor(appName, buildID string) string {
	return filepath.Join(AppDataDir(appName), buildID+".log")
}
```

`buildID` comes straight from argv with no validation anywhere on the path (`CommandOutput` verifies
the *app* name and nothing else). `filepath.Join` cleans the result, so a `../`-laden id does leave the
app's builds directory — the probe's empty output was the appended `.log` suffix failing to match a
real file, not sanitisation doing its job.

What is and is not established:

- **Established from source:** the id is interpolated into a path unvalidated, and reads are therefore
  constrained only by the `.log` suffix and by the permissions of the `dokku` user.
- **Not established:** whether this crosses a privilege boundary in practice. It plausibly does where
  the ACL plugin scopes users to their own apps, since one app's `builds:output` could name another
  app's log — but we run `D_single_operator`, one keyholder with root, so this box has no boundary to
  cross and we cannot demonstrate the interesting case.

**Recommended route: the private one, not an issue.** Dokku takes GitHub Security Advisories and has
published five CVEs through them (`github.com/dokku/dokku/security/advisories/new`), and a path
built from unvalidated input belongs there rather than in a public thread — describe the class, not a
working path, and let the maintainers judge the boundary question we cannot test. Nothing here is
urgent for us: on a `D_single_operator` box the caller is already root.

## Our two pieces, both run on a box for the first time

- **`shepherd2-install` sets retention.** `install.log` carries `=====> Setting retention to 300` and
  `build record retention: 300 per app (~a day of poll ticks)`. The line fires.
- **`shepherd2 last-build` works, and all three of its unverified assumptions hold.**
  `builds:list <app> --format json` returns a **JSON array**, not an app-keyed hash; `duration` is a
  string (`"1m7s"`, `"1s"`); `log_path` is absolute. Every path was exercised — after the deploy, after
  three no-op ticks, 16 ticks deep, `--log`, the no-argument all-projects form, and the fallback once
  the real build fell outside the window. Transcript: `transcript-last-build.txt`.

  Two things worth knowing. **The first was recorded here as "not a defect" and that judgement was
  wrong** — it is fixed in the source now:

  - The verb's reach was the **retention value**, because it read the unfiltered `builds:list`, which
    caps its output there — not the number of records on disk. At the stock 20 the real build fell out
    after 20 ticks and `last-build` printed `no real build in the retained window` with 41 records
    present; `retention 300` made it visible again. Read as "the workaround, confirmed end to end", it
    is really a hole: at 300 the same thing happens to **any project idle more than ~25 hours**, which
    is the normal state of most of the farm, and the build it cannot see is sitting on disk. Dokku
    skips the cap for any *filtered* listing (`plugins/builds/subcommands.go`:
    `if statusFilter == "" && kindFilter == ""`), so `last-build` now asks for `--kind build` — which
    `git:sync` records always are — and reads past arbitrarily deep churn. The message it prints when
    there genuinely is no real build has changed to `no real build on record` to match.
  - `real_build?`'s documented blind spot is real and was hit on the very first try: the box's failed
    first deploy (the `master` pathspec error) is reaped to `exit_code -1` and is therefore
    indistinguishable from churn, so `last-build` skipped it. The rdoc already says so.

  One cosmetic inaccuracy: the rdoc's worked example shows `started 2026-09-11T10:05:30Z`, but Dokku
  emits nanosecond precision — the real line reads
  `started 2026-09-11T12:42:21.234433548Z`. Corrected in the source.
