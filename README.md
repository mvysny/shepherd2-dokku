# Shepherd2 (Dokku)

> **DESIGN PHASE — there is nothing to install yet.**
>
> This repo currently holds documentation only. The feature set is being agreed in
> [`ideas/features-to-preserve.md`](ideas/features-to-preserve.md); code follows after that.

Builds given git repos periodically and automatically deploys them to a Linux box running
[Dokku](https://dokku.com). Serves as a homebrew "replacement" for Heroku, to publish your own pet
projects. Built with off-the-shelf tools: **Dokku and nothing else.**

How this is meant to work:

* Each app is a Dokku app, built from the `Dockerfile` at the root of its git repo and run as a Docker
  container, published at `PROJECTID.<domain>` over https.
* Dokku **polls** each repo on a schedule rather than waiting for a push
  (`dokku git:sync --build-if-changes`), so Shepherd2 can host repos you don't own.
* Dokku's proxy terminates https and routes by hostname; Docker keeps the containers up and brings them
  back after a reboot.
* Administration is `ssh dokku@host …` — Dokku's own CLI. There is no web UI and no JVM anywhere.

The two predecessors of this project stay online and readable:
[Vaadin Shepherd](https://github.com/mvysny/shepherd) (Kubernetes) and
[shepherd-traefik](https://github.com/mvysny/shepherd-traefik) + [shepherd-java-client](https://github.com/mvysny/shepherd-java-client)
(Docker + Traefik + Jenkins + a Vaadin web admin). Why they were retired in favour of Dokku, and what
that cost: `D_dokku` and `D_retire_shepherd_java` in [DECISIONS.md](DECISIONS.md).

## Where things are documented

| If you want to… | Read |
|---|---|
| run, install or troubleshoot this box | this file (once there is something to run) |
| know what **Dokku** does — a command, a flag, a plugin, a gap | [RESEARCH.md](RESEARCH.md) |
| know *why* it's built this way, and what was rejected | [DECISIONS.md](DECISIONS.md) (`D_` entries) |
| see what's still being figured out | [`ideas/`](ideas/) — `ls` is the index |
| know which features are being preserved, glued or dropped | [`ideas/features-to-preserve.md`](ideas/features-to-preserve.md) |
| change things without breaking something remote | [CLAUDE.md](CLAUDE.md) |
| know whether some *other* PaaS should have been picked | [`COMPARISON.md` in shepherd-traefik](https://github.com/mvysny/shepherd-traefik/blob/main/COMPARISON.md) |

## Minimum requirements

Provisional — inherited from shepherd-traefik and Dokku's own documented minimums, not yet checked on a
real box.

* A VM with 8–16 GB of RAM; x86-64 or arm64. Ideally with a public IPv4 address.
  * Dokku's own documented minimum is 1 GB, but that is for Dokku, not for building JVM apps on the box.
* **Ubuntu 22.04 / 24.04, or Debian 11+** — Dokku supports these and nothing else. Ubuntu latest LTS is
  the target.
* A DNS domain with the IPv4 "A" record pointing at the VM. **Two records** are needed, `@` and `*`, so
  that wildcard subdomains work.
* Docker 24+ is wanted so BuildKit — and therefore build caching — is the default.

## Installation

Not written yet. Dokku's own install is two commands and is documented in
[RESEARCH.md](RESEARCH.md#versions-platform-install); everything Shepherd2 adds on top of it is what
this section will become.

## Adding your project

Not written yet. The contract Shepherd2 will expect from a project, unchanged from both predecessors:

1. A `Dockerfile` at the root of its git repo.
2. Buildable with `docker build -t test/xyz:latest .` and runnable with
   `docker run --rm -ti -p8080:8080 -m256m test/xyz`.

**Pay attention to `-m256m`** — that is the hard memory limit the container will run under. If the JVM
asks for more it is hard-killed by the Linux OOM killer with no warning and no log message (only the
host's `dmesg` records it). Run Java with `-Xmx` a little below the limit, so the app dies with an
`OutOfMemoryError` that shows up in the logs instead.

One Dokku-specific foot-gun already known: **`EXPOSE 8080` makes Dokku publish the app on port 8080**,
not on 443, so each app needs `dokku ports:set PROJECTID http:80:8080 https:443:8080`. Details in
[RESEARCH.md](RESEARCH.md#ports--the-expose-trap).
