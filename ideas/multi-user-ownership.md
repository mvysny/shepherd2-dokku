# `Q_multi_user` — how does per-user project ownership come back in v2?

**Answered for v1: it doesn't.** One keyholder, who can do everything to every app — `D_single_operator`.
This note is the **v2** question, and it keeps the slug `Q_multi_user` because `D_retire_shepherd_java`,
`D_single_operator`, `D_dokku_is_truth` and `SOLUTION.md` all cite it.

What Shepherd used to do: an admin adds users; each user sees, creates, edits and deletes only *their
own* projects (`UserRoles.USER`/`ADMIN`, the project list filtered on `owner.email`). Nothing in core
Dokku is that.

## Why this is really the question "who else gets an SSH key?"

**SSH keys are not access control, and `D_retire_shepherd_java`'s "access control becomes SSH keys"
understates it.** In core Dokku the *only* privilege distinction is the substring `admin` in a key name,
which grants adding further keys; every other key may run every command against every app,
`apps:destroy` on someone else's project included. Dokku's maintainer states this is by design — the
product assumes a personal or fully-trusted-team box, and anyone with real SSH access bypasses added
restrictions anyway. So a second keyholder is not a second *user*: they are a second root.
`RESEARCH.md` → *Users and access control* has the detail.

## The three candidates

1. **Our own `user-auth` hook.** `SHEPHERD_OWNER` already names an owner per app
   (`D_dokku_is_truth`), so the check is "is `$SSH_NAME` the app's owner" — one `config:get`, a small
   Bash hook, no third-party dependency, and squarely *the answer is a wrapper script*. Buys per-user
   push / restart / logs. Still no self-service and no SSO, and we would own a security-critical hook.
   **This is the cheap favourite**, and `D_single_operator`'s *Consequences* names the one thing v1 must
   get right for it: store the owner in a form the hook can match against `$SSH_NAME`.
2. **`dokku-acl`.** More features than we'd write, but: last commit 2024-01, written against 0.32 (six
   minors behind our pin), self-described as not security-audited — and that last commit was *adapting
   to a trigger rename*, i.e. the failure mode when Dokku moves is that the hook stops being invoked at
   all and enforcement silently disappears. That is `D_retire_shepherd_java`'s component-death-rate
   argument again, except in the authorization path. It also does not give Shepherd's model without
   glue: ACLs cannot be edited over SSH, creating an app does not add the creator to its ACL, and
   `apps:create` is all-users-or-none. `RESEARCH.md` → *`dokku-acl`* has the rest.
3. **Dokku Pro.** Teams, `users:create`, reverse-proxy SSO — the only real mirror of Shepherd, and
   already rejected in `D_retire_shepherd_java` for being paid and proprietary.

## Coupled to the UI question

Password / Google-SSO login is *dropped*, not deferred: nothing short of Dokku Pro provides it and
there is no browser UI left to log in to. The single route that brings it back is option 3 in
`ideas/web-admin-ui.md` — the reworked Vaadin admin — which carries its own user registry. So if that
option ever wins, this question is answered inside it rather than beside it.

One practical consequence for whoever picks this up: the remote form `ssh dokku@host <command>` reaches
only `dokku`, never `shepherd2`. A second keyholder therefore cannot register or destroy a project
without a shell on the box, which is a boundary worth exploiting rather than fixing.
