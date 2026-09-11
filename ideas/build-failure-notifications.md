# `Q_build_notify` — who gets told when a build fails, and how does mail leave the box?

**Scheduled for v2** (operator, 2026-09-11): v1 ships with no notification of any kind, and a failed
build is found by going to look at it. Open as of 2026-09-11 is the *shape* — everything below.

One consequence to carry into v2 rather than re-argue there, **and it got easier on 2026-09-11**: the
worry was that a failing build's log is evicted within ~95 minutes, which would make the mail not an
alert but the only durable record that the failure ever happened. `D_poll_churn` raised the window to
about a day and gave the box `shepherd2 last-build`, so this is a **plain alert** again — the mail can
point at a build that will still be readable when it is opened, and carrying the log tail is a
convenience rather than the whole point. What has not changed is that the poll's churn is still there:
the record the mail names has to be found by the `exit_code != -1` filter, not by `builds:report`.

## The problem, in one paragraph

**Today a failed build is announced to nobody.** `poll` returns `EXIT_FAILURE` and writes the app's
error to stderr, and cron's default disposal of that is local mail to root — but the box installs no
MTA and `/etc/cron.d/shepherd2` sets no `MAILTO`, so the output goes nowhere. Two things are therefore
in scope here and they are separable: **who the recipient is**, and **how a mail gets off the box at
all**. The second is the one with real work in it.

Sharp edge for any "just set `MAILTO`" answer: `poll` says `polling <app>` for *every* app on stdout,
and cron mails on *any* output, not on exit status. So `MAILTO` as it stands would mail 288 times a
day per tick regardless of outcome. Quiet-on-success is a prerequisite for that route, and arguably
worth doing on its own.

## Who does GitHub notify? (the question that prompted this)

**Neither of the two candidates, strictly. GitHub notifies an *account*, not an address** — the actor
whose credentials triggered the run: *"You'll receive a notification when any workflow runs that you've
triggered have completed"*, with *"you can also choose to receive a notification only when a workflow
run has failed"* as a setting the recipient owns. Not the commit author, not the repo owner.

The interesting half is the **scheduled** case, which is ours: a cron-triggered run has no actor, so
GitHub falls back to a human who owns the *automation* — *"Notifications for scheduled workflows are
sent to the user who initially created the workflow"*, transferring to whoever later edits the cron
syntax, or to whoever re-enabled a disabled workflow. **So GitHub's own rule for a poll-shaped trigger
points at the project's owner, not at the commit.**
([docs](https://docs.github.com/en/actions/concepts/workflows-and-actions/notifications-for-workflow-runs))

The commit-author precedents are the older CI generation, and both gate on something we do not have:

- **Travis CI** mails the committer *and* the commit author by default — but "only if they have access
  to the repository the commit was pushed to", explicitly so that a fork cannot make Travis mail the
  upstream owners. The gate is a *forge account with repo access*.
- **Jenkins** `email-ext` has the `culprits` / `Developers` recipient providers — everyone who
  committed since the last good build — and synthesises the address from the SCM committer id plus a
  configured default suffix. The gate is Jenkins' own user registry. (shepherd-traefik had Jenkins and
  so could have had this for free; it went with Jenkins in `D_dokku`.)
- **GitLab** sends pipeline-status mail to the *pipeline creator*, plus an integration that takes a
  literal recipient list per project.

## The recommendation this note argues for

**`SHEPHERD_OWNER` is the recipient; the last commit author is at most an opt-in cc.** Reasons, in
descending weight:

1. **A commit's author email is untrusted, attacker-controlled data.** `user.email` is whatever the
   committer typed. Mailing it turns the box into a machine that sends mail to arbitrary addresses on
   the strength of a string in a git object — spam amplification with our domain on the envelope. Every
   system above that *does* notify the author first checks it against an account.
2. **The log tail is the payload, and build output leaks config.** A build prints what the buildpack
   prints; app config vars and tokens turn up there routinely. `SHEPHERD_OWNER` is an address the
   operator vouched for; a commit author is not. If the author is ever cc'd, they get *"your commit
   failed to build"*, the owner gets the log.
3. **The owner is who can act.** Fixing a failed build here means `shepherd2 rebuild`, raising a
   `resource:limit`, pinning a buildpack or reading `builds:output` — all of which need the box's SSH
   key. Under `D_single_operator` that is one person, and usually the same person who pushed.
4. **Bot addresses.** `…@users.noreply.github.com`, dependabot, a CI committer: a large share of real
   commits have an author address that is deliberately undeliverable or unread.

The counter-argument worth keeping: in a *team* project the owner is not the person who broke the
build, and mail to the owner is mail to the wrong human. That is the case for the opt-in cc — and it
becomes much safer at exactly the point `Q_multi_user` lands, because then there *is* a registry to
check an author address against. Both being v2 makes the ordering worth watching: if per-user ownership
arrives first, the cc stops being a spam hazard and may simply be the default.

## What Dokku gives us, and the edges

- **There is no failure hook.** None of Dokku's 180 plugin triggers fires on a failed build or deploy;
  `post-deploy`'s own doc example is literally *"notify an external service that a successful deploy has
  occurred"*, and the only failure-named triggers are `retire-container-failed` (old containers would
  not retire) and `scheduler-logs-failed`. Recorded in `RESEARCH.md` → *What Dokku does not do*.
  **Consequence: the notifier lives in the caller — `poll` — not in a plugin**, which also keeps us
  inside `CLAUDE.md`'s no-plugins-of-ours rule for free.
- **…so a plain `git push` deploy is not covered.** Acceptable, and it is GitHub's actor rule again:
  the human who pushed is watching the output stream. Same for `rebuild` and `create-app`, which are
  interactive — **the poll is the only path that should mail**, which is a pleasingly small surface.
- **The recipient may not exist.** `--owner` is optional: `create_app` sets `SHEPHERD_OWNER` only if
  the flag was passed. Either it becomes mandatory, or there is a box-level fallback — one more global
  `SHEPHERD_*` var per `D_dokku_is_truth` (`SHEPHERD_NOTIFY_TO`, alongside `SHEPHERD_TLS_MODE`).
  **Careful: `config:set --global` is injected into every app's environment.** An address there is
  harmless; SMTP credentials must never be one.
- **The commit, if we want it**, is `config:get <app> GIT_REV` — written *before* the build, so it
  survives a failure and names the commit that failed (`RESEARCH.md` → *`git:sync`*). The author then
  comes from the bare repo, `git -C ~dokku/<app> log -1 --format='%an <%ae>' "$GIT_REV"`. That is
  reaching around Dokku, sanctioned only because the build record has no SHA and no Dokku command
  exposes commit metadata at all. Two edges: git run as root against a `dokku`-owned repo trips
  *detected dubious ownership* (so `sudo -u dokku git …`), and **[unverified]** that the object is
  present and readable there after a build that failed early.
- **The log tail** is the two-step from `RESEARCH.md`: newest record whose `exit_code != -1` (the `-1`
  filter is what separates a real failure from a reaped no-op tick — `D_poll_churn`), then
  `builds:output <app> <id>`. Last ~50 lines is what a mail should carry. `shepherd2 last-build` already
  holds that selection in Ruby, so the notifier should call the same code rather than re-derive it —
  bearing in mind that verb is scheduled for deletion when upstream is fixed.
- **No debounce is needed.** `--build-if-changes` does not retry a failed build until upstream moves,
  so failures are naturally one mail per commit — no flap storm, nothing to rate-limit.
- **A "fixed" mail** (Travis's first-success-after-failure) would need us to remember the previous
  outcome, i.e. our first *mutable* per-app state — a `SHEPHERD_LAST_BUILD_STATUS` config var under
  `D_dokku_is_truth`. Probably not worth it; decide explicitly rather than by omission.

## Transport — the part that is actually work

Mail from a fresh box is the hard half, not the easy half. Outbound port 25 is blocked by most
providers, and mail with no SPF/DKIM/rDNS is dropped or spam-foldered silently — **a notification that
silently fails to arrive is worse than none**. So: relay through something with reputation, and put the
`From` on a domain we control (`shepherd2@mydomain.me`).

1. **`net/smtp` from the Ruby stdlib**, relaying through a provider with credentials in a root-only
   file. The favourite: no new package, no gem (`D_ruby` stays clean), and the credentials-file shape
   is already established by `D_cert`'s DNS token — root-only, unreadable to `dokku`.
2. **`msmtp` + `msmtp-mta` as `/usr/sbin/sendmail`.** One apt package, and it also makes `MAILTO` work
   for *every* cron job on the box, which is a genuine side benefit (lego renewals, `clearcache`).
   Costs an install step and a second config file.
3. **A provider's HTTP API** (Postmark / Mailgun / SES) over `net/http`. Also stdlib, better
   deliverability telemetry, but an account and an API key, and a vendor in the loop.
4. **Not email at all** — an ntfy / Slack / Telegram webhook. Sidesteps deliverability entirely and is
   ~15 lines, but it is not what was asked and it notifies *the operator*, never a per-project owner.
5. **Nothing; put it in the UI** — a red build in `ideas/web-admin-ui.md`. Rejected-ish: a dashboard
   nobody opens is not a notification.

Whatever wins, `install` grows a step and README grows a requirement, and there must be a
**`shepherd2 notify --test`**-shaped way to prove mail works at install time rather than discovering it
from the one failure that mattered.

## What would settle it

1. Confirm the box has an outbound path at all (provider blocks 25? is there a relay to hand?) — VM
   work, punch-list-shaped.
2. Decide `--owner`: mandatory, or a global fallback.
3. Decide the commit-author cc: no in the first cut, or opt-in per app with the log withheld — see the
   `Q_multi_user` ordering above.

**Graduation destinations**, when it lands: the choice plus the rejected transports → a `D_` entry; the
recipient rule and its reasoning → the same entry (this note's *recommendation* section is its draft);
the install step and the credentials file → `SOLUTION.md`'s inventory and `README.md`'s requirements;
the env knobs and the credentials-file path → `shepherd2`'s comment header; "how do I check mail still
works" → README's day-to-day cheat sheet. The Dokku no-failure-hook fact is already in `RESEARCH.md`,
so it does not travel with this note.
