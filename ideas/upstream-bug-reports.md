# Upstream bug reports to file against `dokku/dokku`

Drafted 2026-09-11, **not filed** — the operator reviews first. Graduation: file them, put the issue
numbers into `D_poll_churn` (report #1) and `RESEARCH.md` → *Build tracking* (report #2), delete this
note. Nothing waits on either; `D_poll_churn` ships the workaround regardless.

**Searched first, nothing on point.** `gh search issues --repo dokku/dokku` for `build-if-changes`,
`abandoned build record`, `builds:list retention`, `git:sync record` and `builds plugin` — open and
closed, PRs included — returns no report of either defect. Latest release is **v0.38.27** (2026-08-12),
which is what we pin and what the probe ran, and both are still present on `master`. Every source link
below is pinned to **`aa39920`** (2026-09-10), the master tip when this was drafted.

## Before filing: one box run, and exactly what to capture

Dokku takes bug reports through an **issue form**, not a freeform body
(`.github/ISSUE_TEMPLATE/bug_report.yaml`), and three of its fields are *required*: **Description of
problem**, **Steps to reproduce**, and **the output of `dokku report $APP_NAME`**. The drafts below are
written to those fields — and the third is why this needs a box: the probe box was torn down on
2026-09-11 and no `dokku report` dump was kept in the sidecars. **Agreed 2026-09-11: bring the VM back
and re-run both repros.** Transcripts land in `ideas/upstream-bug-reports/`.

Three things the run gets us beyond the required field: a repro we can quote as *run on this version*,
the loose end at the bottom of this note settled, and the first-ever execution of
`builds:set --global retention 300` — the line `D_poll_churn` added to `shepherd2-install`, which no box
has run yet.

**Two traps, both of which the probe already paid for once.** The `*/5` poll cron must be off for the
duration or a scheduled tick lands mid-drill; and **retention has to be back at Dokku's default of 20
for the drill itself**, or the eviction step needs 300 ticks instead of 20 and the numbers in the report
stop being the ones a maintainer would see.

```bash
# Snapshot the VM from the KVM host first. http mode is cheap to redo, but the install is one-way
# per D_cert and this is a box we may want again.

# 1. Install — and confirm the new retention line fires.
cd /home/mavi/work/my/shepherd2-dokku
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

# 4. One app, and the cheapest one we know deploys unmodified from GitHub (probe item 20).
echo '127.0.0.1 demo.shepherd2.test' | sudo tee -a /etc/hosts
sudo shepherd2 create-app demo https://github.com/mvysny/karibu-helloworld-application \
     --owner mavi@vaadin.com --buildpack heroku/gradle

# 5. Report #1's repro, exactly as drafted below.
REPO=https://github.com/mvysny/karibu-helloworld-application
for i in 1 2 3; do sudo dokku git:sync --build-if-changes demo "$REPO"; done
sudo dokku builds:list demo --format json > ideas/upstream-bug-reports/records-3-ticks.json
sudo dokku git:sync --build demo "$REPO"                   # a real deploy, unchanged ref
sudo dokku builds:list demo --format json > ideas/upstream-bug-reports/records-after-deploy.json
for i in $(seq 16); do sudo dokku git:sync --build-if-changes demo "$REPO"; done
sudo dokku builds:list demo --format json > ideas/upstream-bug-reports/records-at-cap.json

# 6. The required field, plus the environment block both reports want.
sudo dokku report demo > ideas/upstream-bug-reports/dokku-report-demo.txt
{ dokku version; docker --version; lsb_release -ds; } \
  > ideas/upstream-bug-reports/environment.txt

# 7. Report #2, which needs no state at all.
sudo dokku builds:output demo not-a-real-build-id; echo "exit=$?"

# 8. The loose end — the only genuinely open question here. Find the evicted-but-not-pruned
#    successful deploy, prune, then ask for it again and check whether journald is what answers.
sudo dokku builds:list demo --status succeeded --format json   # note the id
sudo dokku builds:prune demo
sudo dokku builds:output demo <that-id>; echo "exit=$?"
sudo journalctl -t dokku-<that-id> --no-pager | head

# 9. Put it back.
sudo dokku builds:set --global retention 300
sudo sed -i 's|^#\*/5|*/5|' /etc/cron.d/shepherd2
```

---

## Report #1 — `git:sync` opens a build record it never closes when there is nothing to build

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
either. So this is not specific to `--build-if-changes`; that flag just makes it happen 288 times a day.

**What I expected:** a run that builds nothing leaves no build record, or leaves one marked as
"nothing to build". **What happens instead**, in the order it arrives:

1. **The records accumulate unboundedly while an app is idle.** `PruneAppBuilds` runs only from
   `builds-record-finalize`, so nothing prunes them in the meantime. Each carries a log file holding
   nothing but fetch chatter.
2. **The next real deploy rewrites them all as failures.** `ReapAbandonedBuilds` finalizes every
   dead-PID `running` record as `status: failed, exit_code: -1`, which on disk is indistinguishable
   from a build that really failed. `builds:list <app> --status failed` therefore stops selecting
   failures, and `exit_code` — the only discriminator left — is not exposed as a filter.
3. **Retention then evicts the real history.** Survivors are the newest by `started_at`: the build that
   just finished, plus the most recent no-op ticks. At a five-minute poll and the default retention of
   20, that window holds about 100 minutes, after which a real build's record *and* its log are gone.
   "Go and read why last night's deploy failed" does not work.

A fourth, quieter effect: `builds:report <app>` names the newest record, so on any idle app it reports
the build status as `abandoned` rather than `succeeded`.

### Steps to reproduce

```bash
dokku apps:create demo
dokku git:sync --build demo https://github.com/you/demo    # any buildpack app; deploys normally

# three polls with no upstream commit
for i in 1 2 3; do dokku git:sync --build-if-changes demo https://github.com/you/demo; done
dokku builds:list demo --format json
#  -> three extra records, status=running / display_status=abandoned, no exit_code, no finished_at,
#     one ~265-byte .log each

dokku git:sync --build demo https://github.com/you/demo    # now deploy for real
dokku builds:list demo --format json
#  -> the three ticks are now status=failed, exit_code=-1

# keep polling to the retention cap
for i in $(seq 16); do dokku git:sync --build-if-changes demo https://github.com/you/demo; done
dokku builds:list demo --format json
#  -> 20 records, and the successful real deploy has been evicted
```

Every step above is what a box did on 2026-09-11, on 0.38.27.

### `dokku report $APP_NAME`

*(Paste `ideas/upstream-bug-reports/dokku-report-demo.txt` from the box run — step 6.)*

### Additional information

A Vaadin/Java app on the herokuish builder with `heroku/java` pinned, but nothing about the app
matters: the leak is in `cmd-git-sync` before any builder is reached, and a plain `git:sync` with no
build flag leaks identically.

**Suggested fix.** Finalize (or discard) the record on the no-change path before returning — the ref
comparison already has what it needs, and `CURRENT_REF` is captured before the capture starts. Moving
`dokku_setup_build_capture` *after* the comparison would also work but loses the clone/fetch output
from the log, which is presumably why it sits where it does. The no-flag fall-through wants the same
treatment. A distinct status for "nothing to build" would be better still: it would keep `--status
failed` meaning failed, which no filter can currently recover.

*(Not blocking us — `builds:set --global retention 300` buys about a day, which is enough to read a
failed build the next morning.)*

---

## Report #2 — `builds:output` never validates the build id and can exit 0 having printed nothing

Much smaller and separable. File it second, or leave it for a box.

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

### `dokku report $APP_NAME`

*(Same paste as #1. Nothing in it is load-bearing here — any app name reproduces this.)*

### Additional information

Either fix works: check the record exists and return a "no such build" error, or have the journald
fallback report when it matched nothing.

---

## Loose end, ours not theirs — do not put this in either report

On the box, `builds:output <app> <pruned-id>` appeared to print the *current* build's output rather
than nothing. `CommandOutput` does not explain that: the deploy-lock branch is reachable only for an
empty or `current` id. Most likely journald was still answering for the pruned id and it was misread.
`RESEARCH.md` and the probe findings both carry it as `[unverified]`/unexplained.

**Step 8 of the box run settles it**, and there are only three outcomes:

- **journald answered** — the hypothesis, and then nothing is wrong beyond report #2's silent-empty
  case. Correct `RESEARCH.md` and the findings to say so and delete this section.
- **nothing was printed** — report #2 exactly as drafted, and the original observation was a misread.
- **the current build's output really was printed** — a sharper bug than #2, with a code path we have
  not found. That one gets its own issue, with the transcript as evidence, and `RESEARCH.md` gets the
  fact rather than the `[unverified]` hedge.
