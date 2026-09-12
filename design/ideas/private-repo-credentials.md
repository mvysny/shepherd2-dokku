# `Q_credentials` — are per-project git credentials a real requirement, or a Jenkins artifact?

**Deferred for v1 (2026-09-10): the box holds no git credential at all**, and every hosted repo must be
publicly cloneable. This note is the v2 question, `Q_credentials`; `solution.md`
→ *What v1 does not do* points here, and `README.md` → *What the repo needs* states the v1
requirement to the operator.

What Shepherd used to do: one credential per project, out of Jenkins' credentials store
(`gitRepo.credentialsID`), so each project's clone authenticated as itself.

**The gap is the *shape*, not the feature.** Dokku's mechanism is `dokku git:auth <host> <user> <token>`,
which writes a netrc entry — **per host, not per app**. So one GitHub token would cover the whole box,
and any app could then be pointed at any private repo that token can read. On a single-operator box
(`D_single_operator`) that may be perfectly acceptable; the question is whether per-project scoping was
ever a requirement of *ours* or just what having a credentials store made free.

Open, in the order it needs answering:

- Is a **per-host token** actually good enough? If every private repo lives in one GitHub account the
  operator owns, the blast radius of the shared token is that account's repos — which the operator can
  already read. That would close this question with a `git:auth` line in the install and nothing else.
- If not: do **per-project deploy keys** work under `git:sync`? A deploy key is per repo, which is the
  scoping we want, but it needs the right key selected per clone — an SSH config or `GIT_SSH_COMMAND`
  per app, and whether `git:sync` leaves room for either is **`[unverified]`**.
- Either way, **where does the secret live**, and does it stay unreadable to the `dokku` user the way
  the DNS token does (`D_cert`)? `git:auth` writes netrc as root but the clone runs as `dokku`, so the
  answer is probably "no", and that is worth knowing before promising per-project isolation.

Whichever way it goes, it grows a `create-app` flag or it does not exist — there is no project file to
put a credential in (`D_dokku_is_truth`).
