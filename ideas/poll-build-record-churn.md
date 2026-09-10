# `Q_poll_churn` — should `poll` pre-check the remote ref, so a no-op tick never enters `git:sync`?

**This is a v1 question, unlike the rest of `ideas/`** — `poll` is a v1 verb (`D_dokku_is_truth`) and
the `*/5` cron is settled in `SOLUTION.md`. Open as of 2026-09-10; nothing is decided.

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

`wait-idle` is fine either way (`builds:list` with no app filters on a live PID), so this is about build
logs and nothing else.

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

## What would settle it

Run punch-list item 19 on the throwaway VPS to confirm the three on-disk claims, then decide between 1
and 2 — the deciding question being whether an `ls-remote`-based guard can be written without
reimplementing anything else Dokku does. If it lands, this note graduates into a `D_` entry (the
decision plus the rejected options above), a line in `poll`'s script header, and the removal of the
caveat in `SOLUTION.md`'s poll flow; the Dokku-behaviour facts stay in `RESEARCH.md` where they already
are.
