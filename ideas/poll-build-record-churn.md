# `Q_poll_churn` — should `poll` pre-check the remote ref, so a no-op tick never enters `git:sync`?

**This is a v1 question, unlike the rest of `ideas/`** — `poll` is a v1 verb (`D_dokku_is_truth`) and
the `*/5` cron is settled in `SOLUTION.md`. Open as of 2026-09-10; nothing is decided.

**Measured on a box 2026-09-11** (punch-list 19; `ideas/http-probe-plan/findings.md` has the
transcripts). Every claim below held, one assumption in this note did not, and a fifth option appeared:

- **The three on-disk claims are confirmed.** Three no-op ticks → three records, `status=running` /
  `display_status=abandoned`, one 265-byte `.log` each. A real deploy then flipped all three to
  `failed` / `exit_code: -1`. 16 further ticks took the list to the retention cap and evicted a
  *successful* build. `builds:report` names the window: **`Builds computed retention: 20`**, so at 288
  ticks a day it holds **~100 minutes**.
- **"`wait-idle` is fine either way" was wrong, and it is the most important thing the box said.**
  `running_builds` filtered on `status`, not on a live PID — and an abandoned tick's `status` stays
  `running` forever. So `wait-idle` blocked until timeout and exited 1 on any box that had been up for
  five minutes. Fixed by keying off `display_status`, which *is* Dokku's liveness check on the recorded
  pid. **The churn was not cosmetic: it broke the verb that exists to make a reboot safe.** See BUG 2
  in the findings.
- **The records are not immediately destroyed.** `builds:list <app> --status succeeded` and
  `builds:output <app> <id>` still reached an evicted record — the cap is on the *default* listing.
  **Until `builds:prune` runs**: that deleted the four evicted `.log` files and put the successful
  build permanently out of reach, after which `builds:output` for its id silently returns the *current*
  build's output rather than erroring.

## The problem, in one paragraph

`dokku git:sync --build-if-changes` starts its build record *before* it fetches and before it compares
refs, and the no-change path returns without finalizing it. So each of the 288 daily ticks per app
leaves an orphan record plus a log file; nothing prunes them until a real deploy happens; that deploy
reaps them as `status=failed, exit_code=-1`; and retention then keeps the 20 newest, which is the build
that just ran plus ~95 minutes of poll noise. Every older build's log is deleted. The claim-by-claim
version, with source citations, is `RESEARCH.md` → *Build tracking*; the confirmation drill is punch-list
item 19. **What breaks is exactly the thing `D_dokku_is_truth` leaned on** — "Dokku records the build for
us, so the poll tees nothing and writes no log of its own" (`SOLUTION.md`, a poll tick, step 6). The
record set is still there; it is just no longer a *history*.

~~`wait-idle` is fine either way (`builds:list` with no app filters on a live PID), so this is about
build logs and nothing else.~~ **Disproved on the box** — see above. It filtered on `status`, and this
was never only about build logs.

## Why it is worth solving rather than accepting

The single question a build log answers is *"why did last night's deploy fail?"*, asked the next
morning. Under churn the log is gone after 19 further ticks — 95 minutes. That is the whole value of
build tracking, and it is what a failed build's `rebuild` retry is decided from.

## Options, none researched further than this note

1. **Pre-check the ref in `poll` and skip `git:sync` entirely when it has not moved.** The favourite.
   `git ls-remote <url> <deploy-branch>` gives the upstream sha; the app's side is
   `config:get <app> GIT_REV`, which Dokku writes with the resolved sha before each build
   (`RESEARCH.md` → *`git:sync`*). Equal means skip. Notes:
   - It is *cheaper* than the status quo, not more expensive: one `ls-remote` replaces a full fetch
     into the bare repo for 287 of 288 ticks.
   - `GIT_REV` is the last commit Dokku *started* building, so after a failed build it already equals
     upstream and the tick skips — which is `--build-if-changes` semantics anyway
     (`D_dokku_is_truth`: a failed build is not retried until upstream moves). No behaviour change.
   - It needs the deploy branch: `git:report <app> --git-deploy-branch`. One more report call per tick.
   - Costs: we now hold a *second* copy of the change-detection logic, which is the kind of
     Dokku-wrapping `CLAUDE.md` warns about. The defence is that it is not a wrapper — it is a guard
     *in front of* a command whose bookkeeping we cannot otherwise avoid.
   - Sharp edge to check when writing it: an app whose `GIT_REV` is unset (created but never built)
     must fall through to `git:sync`, not skip.
2. **Accept the noise, and stop treating the records as history.** Nothing to write, and honest: the
   README cheat sheet would say "use `builds:output` only while the build is fresh" and the
   `exit_code != -1` filter becomes the documented way to find a real failure. Rejected-ish because it
   trades the only build-log story we have for zero lines saved — but it is the fallback if option 1
   turns out to misfire.
3. **Keep our own log after all** — tee `git:sync`'s output per app. Straightforward, and exactly the
   glue `D_dokku_is_truth` was pleased to delete: log rotation, disk growth and a second place to look
   all come back. Only worth it if option 1 is impossible.
4. **Report it upstream.** The capture-before-check ordering looks like a plain bug — a record is
   started for a run that may never build, and the no-change path is the only exit that skips
   finalization. `CLAUDE.md`'s *Dokku stays upstream and unforked* makes a bug report the sanctioned
   move, and a fix upstream retires this whole note. Not exclusive with option 1: the guard is what we
   run in the meantime, and a fixed Dokku just makes the guard redundant rather than wrong.

5. **Raise the retention window, which nobody here knew was settable.** `builds:set` takes exactly one
   property and it is `retention`, globally or per app, and it reverts cleanly:

   ```bash
   dokku builds:set --global retention 200     # Builds computed retention: 200
   dokku builds:set hello retention 50         # per-app override wins over global
   dokku builds:set --global retention         # unset -> back to 20
   ```

   One line in `shepherd2-install` next to the other `--global` properties, no code, no second copy of
   Dokku's change detection, and it is *orthogonal* to option 1 rather than competing with it: at 200 a
   real build's log survives about 17 hours of idling, which covers "why did last night's deploy fail?"
   — the one question this note says matters. It does not make the history clean, only long enough.
   **The obvious v1 answer is 5 now and 1 later**, with 1 reduced from a fix to a tidy-up.

## What would settle it

~~Run punch-list item 19 on the throwaway VPS to confirm the three on-disk claims~~ — **done,
2026-09-11, all three confirmed.** What is left is the decision, and the field has changed: it is now
between **5** (one install line, available today) and **1** (the `ls-remote` guard), with 2 and 3 dead.
The deciding question for 1 is unchanged — whether the guard can be written without reimplementing
anything else Dokku does — but it is no longer urgent, because 5 buys the time. If it lands, this note graduates into a `D_` entry (the
decision plus the rejected options above), a line in `poll`'s script header, and the removal of the
caveat in `SOLUTION.md`'s poll flow; the Dokku-behaviour facts stay in `RESEARCH.md` where they already
are.
