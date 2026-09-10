# RESEARCH.md — what we know about Dokku

Everything this project has established about **Dokku**, the upstream product it is built on. This is
the reference: when a design argument needs "does Dokku do X?", the answer belongs here and gets cited
from wherever it is used, rather than re-derived.

**Why a separate file.** Dokku is a dependency we do not own, so its behaviour is neither a decision of
ours (`DECISIONS.md`) nor an operator instruction (`README.md`) nor a scratchpad note (`ideas/`). Facts
about it need one durable home that survives the idea that prompted the lookup — see `D_research_md`.

**How to read it.** Every claim is either **[docs]** (stated in Dokku's own documentation), **[src]**
(read out of a repository), or **[unverified]** (inferred, or reported by a third party, and *not yet
run on a box*). Treat `[unverified]` as a hypothesis: the whole point of marking it is that the
first thing the box does is turn those into facts. Checked **2026-09-09** against Dokku **v0.38.27**
unless noted; re-check before relying on a version-sensitive claim.

---

## Versions, platform, install

- **Current line: v0.38.x**, latest v0.38.27 (2026-08-12). MIT licence, ~32.1k GitHub stars. **[docs]**
- **Supported OS:** Ubuntu 22.04 / 24.04, or Debian 11+, on amd64 or arm64. **[docs]**
- **Ubuntu 26.04 is not usable yet** (checked 2026-09-10). Four separate findings, because only the
  first is the one people expect:
  - `bootstrap.sh` sources `/etc/os-release` and hard-exits unless `VERSION_ID` is in
    `22.04 24.04 10 11 12 13`: *"Unsupported Linux distribution. Only the following versions are
    supported: …"*. **[src]**
  - **packagecloud builds no `dokku` package for the `resolute` dist.** It carries the satellite
    packages there — herokuish 0.11.17, plugn, sshcommand, gliderlabs-sigil, procfile-util, netrc,
    lambda-builder, docker-container-healthchecker, docker-image-labeler, `dokku-update`,
    `dokku-event-listener` — but `dokku` itself stops at `noble` (0.38.27). **[verified against the
    dist package indexes]**
  - …**which the installer would paper over**: for any unrecognised Ubuntu codename it falls back to
    `OS_ID=noble`, so a whitelist patch alone installs the *noble* deb on 26.04. Its dependencies do all
    resolve there — the distro ones (`apache2-utils`, `netcat`, `parallel`, `man-db`, `cron`,
    `net-tools`, `rsync`, `dos2unix`, `unzip`) are in 26.04, and the packagecloud ones are published for
    `resolute` at or above the required versions. Docker is not a blocker either — 26.04 carries the
    same `docker.io` 29.1.3 as 24.04 does, and `download.docker.com` publishes a `resolute` dist for
    anyone taking the other route. **[src + verified]**
  - **bash 5.3, which 26.04 ships, is the substantive risk.** It turned a tolerated pattern into a
    *hard error* in four builder plugins' `core-post-extract` (dokku/dokku #8566, fixed by #8578, which
    is an ancestor of v0.38.27). Dokku is largely bash and its CI runs 22.04/24.04, so that class of
    bug surfaces through users. **[src]**
  - Upstream tracking: issue #8768 (2026-06-23) and PR #8791 (2026-07-03, a one-line whitelist change),
    both open and untouched, no maintainer response. **Watch for both the PR merging and a `dokku` deb
    appearing in the `resolute` dist** — the first without the second only unlocks the noble package.
    We run 24.04 until then; see `D_host_os`.
- **Minimum memory:** 1 GB for the Docker scheduler (2 GB per node for the k3s scheduler, which we do
  not use). No documented disk minimum. **[docs]**
- **Install is two commands**, as root: **[docs]**

  ```bash
  wget -NP . https://dokku.com/install/v0.38.27/bootstrap.sh
  sudo DOKKU_TAG=v0.38.27 bash bootstrap.sh
  ```

  Takes 5–10 minutes. It installs Docker itself if missing. **The version is pinned in two places** —
  the URL path and `DOKKU_TAG` — so an upgrade means editing both. **[docs]** (Shepherd2 does not use
  this path; see the breakdown below and `D_install_apt`.)
- **What `bootstrap.sh` actually does** — read at v0.38.27, because it decides whether the script is
  worth running at all (`D_install_apt`). **It builds nothing**: it is a wrapper that adds an apt
  repository and installs a package. On the Ubuntu + `DOKKU_TAG` path, in order: **[src]**
  1. reads `ID` and `VERSION_ID` from `/etc/os-release`; exits unless the version is in
     `22.04 24.04 10 11 12 13`;
  2. requires `hostname -f` to resolve (hard failure), warns if `MemTotal` is under ~1 GB;
  3. installs `gpg-agent` and `software-properties-common`, runs `add-apt-repository -y universe`;
  4. if `dokku` is not already installed, prints that the install **empties nginx's `sites-enabled`**
     and sleeps 10 seconds;
  5. installs Docker via `wget -O- https://get.docker.com | sh` **only if `docker` is absent**;
  6. resolves the apt codename from `lsb_release -cs`, **falling back to `noble`** for any Ubuntu
     codename that is not `jammy` or `noble` (`bookworm` for Debian/Raspbian);
  7. writes packagecloud's key to `/etc/apt/trusted.gpg.d/dokku.asc` — trusted for *every* repository
     on the box, not scoped with `signed-by=` — and adds
     `deb https://packagecloud.io/dokku/dokku/<distro>/ <codename> main`;
  8. preseeds five debconf answers *if* the matching environment variables are set:
     `dokku/vhost_enable`, `dokku/hostname`, `dokku/skip_key_file`, `dokku/key_file`,
     `dokku/nginx_enable`;
  9. `apt-get install dokku=<version>`, then `dokku plugin:install-dependencies --core`;
  10. runs `/etc/update-motd.d/99-dokku` if present.

  Everything else in the file is other distributions, the `make install` source path, and version
  branches back to 0.3.13. **[src]**
- **What the `dokku` deb depends on, and how Ubuntu satisfies it** (0.38.27, checked 2026-09-10 —
  it decides whether Docker has to come from Docker's own repository, and it does not):
  **[src — the package's `Depends`; versions from the Ubuntu archive]**

  | Dokku's alternation | Ubuntu 24.04 provides |
  |---|---|
  | `docker-engine-cs \| docker-engine \| docker-io \| docker.io (>= 19.03.0) \| docker-ce \| docker-ee \| moby-engine` | **`docker.io` 29.1.3** (`noble-updates`; the release pocket is older) |
  | `docker-buildx-plugin \| moby-buildx \| docker-buildx` | **`docker-buildx` 0.30.1** |
  | `docker-compose-plugin \| moby-compose \| docker-compose` | **`docker-compose-v2` 2.40.3**, which declares `Provides: docker-compose` |

  The trap is in the third row: **`docker-compose` is also a real package** in Ubuntu — the obsolete
  Python v1, 1.29.2 — so apt resolving that alternation on its own installs the legacy tool rather than
  the v2 package that merely provides the name. Install `docker-compose-v2` explicitly first. Note also
  that 24.04's *release* pocket ships `docker-compose-v2` 2.24.6 **without** the `Provides`; the
  declaration arrived with 2.40.3 in `noble-updates`.

  The rest of `Depends` is ordinary distro fare — `apache2-utils`, `locales`, `git`, `cpio`,
  `cron | cron-daemon`, `curl`, `logrotate`, `man-db`, `netcat`, `net-tools`, `parallel`, `rsync`,
  `dos2unix`, `unzip`, `util-linux` — plus the packagecloud satellites `sshcommand`, `netrc`,
  `procfile-util`, `docker-container-healthchecker`, `docker-image-labeler`, `lambda-builder`.
  `herokuish`, `dokku-update`, `dokku-event-listener` and `bash-completion` are **Recommends**, not
  Depends — so an install with `--no-install-recommends` would omit the builder image's package. **[src]**
- **Post-install, two steps:** authorise an admin SSH key and set the global domain. **[docs]**

  ```bash
  cat ~/.ssh/authorized_keys | sudo dokku ssh-keys:add admin
  dokku domains:set-global dokku.me
  ```

- **Docker version:** not documented as a hard requirement. Relevant anyway because BuildKit is the
  default only from Docker Engine 24+ (below). **[docs]**
- **Security floor: 0.38.2 or later.** 0.38.2 bundled four security fixes — app-name restriction against
  command injection, archive-extraction symlink hardening, 0600 on the `.netrc`, and openresty include
  sanitisation — and all 0.38.x users are told to upgrade. Never pin below it. **[docs]**
- **0.38.0 was a migration release:** a batch of `DOKKU_*` config environment variables became
  namespaced plugin properties (auto-migrated on first run, originals unset), and the global/per-app ENV
  file paths moved to a consolidated config path. Anything written against pre-0.38 docs or blog posts
  may name variables that no longer exist. **[docs]**

## Deploying: builders and git

### The builders, and how one is chosen

**Seven builders ship in core** at v0.38.27 — `plugins/builder-{dockerfile,herokuish,lambda,nixpacks,null,pack,railpack}`. **[src]**
The docs' *Builder Management* page still says "five built-in builders" and omits nixpacks and
railpack, both of which have their own docs pages and their own plugin directories. **[docs]** vs **[src]**

| builder | auto-detected by | extra binary on the box |
|---|---|---|
| `dockerfile` | `Dockerfile` at repo root | none |
| `herokuish` | `.buildpacks`, a `BUILDPACK_URL`, or **nothing else matching** (it is the fallback) | none — ships in the herokuish image |
| `pack` | `project.toml` at repo root | `pack` CLI |
| `nixpacks` | `nixpacks.toml` at repo root | `nixpacks` CLI |
| `railpack` | `railpack.json` at repo root | `railpack` CLI **and a privileged `moby/buildkit` container** + a global `BUILDKIT_HOST` |
| `lambda` | `lambda.yml` at repo root | yes; builds AWS Lambda artifacts, irrelevant to a long-running web app |
| `null` | never auto-detected — explicit only | none |

Selection, from `plugins/git/functions` and `plugins/builder/triggers.go`: **[src]**

```bash
BUILDER="$(plugn trigger builder-detect "$APP" "$TMP_WORK_DIR" | head -n1 || true)"
if [[ -z "$BUILDER" ]]; then
  BUILDER="herokuish"   # …unless arm64 and herokuish is not allowed, then "pack"
fi
```

- **`head -n1` plus alphabetical plugin order decides ties.** The plugin named plain `builder` sorts
  before every `builder-*`, and its `TriggerBuilderDetect` prints the per-app `selected` property and
  then the `--global` one — so an explicit selection always wins, and setting it **short-circuits
  detection entirely**. `dokku builder:set --global selected <name>` is therefore a hard box-wide
  override, not a default. **[src]**
- **The Dockerfile detect defers to two builders only.** `builder-dockerfile/builder-detect` force-runs
  the *herokuish* and *pack* detects first and stays silent if either claims the app — the source
  comment calls it a hack and says "such is life". It does **not** defer to nixpacks, railpack or
  lambda, and `builder-dockerfile` sorts before all three. So `Dockerfile` + `nixpacks.toml` builds as
  **dockerfile**, while `Dockerfile` + `project.toml` builds as **pack**. **[src]**
- **herokuish is the fallback**, not merely one detected option: a repo matching nothing at all is
  handed to herokuish, which then runs its own buildpack detection and fails *there* if nothing fits. **[src]**
- Other `builder` properties: `build-dir <subdir>` for monorepos, `skip-cleanup`, and
  `builder:report <app>` to see what was detected. **[docs]**

### The herokuish builder

Heroku v2a buildpacks, run inside the `gliderlabs/herokuish` image, which is built `FROM
heroku/heroku:24-build` **[src]** — a current stack. The app supplies **no build instructions**.

- **Bundled buildpacks, in detection order:** `multi, ruby, nodejs, clojure, python, java, gradle,
  scala, php, go, static, null`, each pinned — e.g. `heroku/heroku-buildpack-java v81`,
  `heroku/heroku-buildpack-nodejs v366`, `dokku/heroku-buildpack-multi v1.2.0`. **[src]**
  **Note `nodejs` is detected before `java`**, so a Java repo with a committed root `package.json`
  is built as a Node app unless the buildpack is pinned.
- **Four ways to name the buildpack, in this precedence** — from `getBuildpacks` and the `buildpacks`
  plugin's `post-extract` trigger, which materialises the winner as a `.buildpacks` file inside the
  *extracted source* before the build runs. **[src]** The function's own doc comment states the
  reverse order and is **stale**; the code checks the property first.

  1. the **app property** — `dokku buildpacks:set <app> <url>` (also `:add --index N`, `:remove`,
     `:clear`, `:list`, `:report`). Overwrites whatever the repo committed.
  2. an app deployed from an image (`git:from-image`) — `git-get-property source-image` non-empty
     short-circuits to *no* buildpacks.
  3. **`app.json`'s `buildpacks[].url`**, read from the repo. Also overwrites `.buildpacks`.
  4. **`.buildpacks` at the repo root**, one entry per line. Kept, but rewritten in place with every
     line validated: `heroku/java` shorthand expands to
     `https://github.com/heroku/heroku-buildpack-java.git`, `heroku-community/x` is rewritten to
     `heroku/x`, blank and `#` lines are skipped, and **an unparseable line fails the build** rather
     than being ignored. **[src]**

  Below all four sits herokuish's own detection order (above), which is what runs when none of them
  is set.
- **`BUILDPACK_URL`** — a config var, or one in a committed `.env` — is honoured by herokuish *inside*
  the build and "always overrides a `.buildpacks` file or the buildpacks plugin". **[docs]**
- **`.buildpacks` with exactly one entry is treated as `BUILDPACK_URL`**, bypassing
  `heroku-buildpack-multi` entirely; two or more entries go through multi. `BUILDPACK_URL` always
  wins over both. **[src]**
- **`heroku-buildpack-multi` runs each buildpack's `bin/compile` with the same `BUILD_DIR CACHE_DIR
  ENV_DIR`**, sources each buildpack's `export` file afterwards if it has one, and **exits the whole
  build if any listed buildpack fails to detect**. **[src]**
- **A buildpack entry can be pinned to a ref**: `<url>#<ref>`, where multi does a full `git clone`
  and then `git checkout "$ref"` — so a commit SHA works, not just a branch. **[src]** The bundled
  buildpacks are already pinned inside the herokuish image; a third-party URL is not, unless pinned
  this way.
- **The build runs unprivileged, and `/cache` is writable.** herokuish chowns `$app_path`,
  `$build_path`, `$cache_path`, `$env_path` and `$buildpack_path` to the unprivileged user (default
  `herokuishuser`) and invokes `bin/compile` through `unprivileged`. The build container is created
  with no `--privileged`, no Docker socket and no special network. **[src]**
- **Config vars are available at build time.** `builder-herokuish/pre-build` bundles every app config
  var into an ENV_DIR at `/tmp/env` inside the build ("Adding BUILD_ENV to build environment…"). **[src]**
  This is the opposite of the Dockerfile builder, where config vars are runtime-only.
- **Build-phase `docker-options` are genuine container options here, unfiltered.** The trigger output
  is split and passed straight to `docker container create` with **no allowlist** — unlike the
  Dockerfile builder, which filters against a flag list. So `-v`, `--cpus` and anything else
  `docker container create` accepts reach the build. **[src]** This is what the docs' warning that
  "`build` options are container options" is actually describing.

### The pack (Cloud Native Buildpacks) builder

- **Default stack is `heroku/builder:24`**, overridable with
  `dokku buildpacks:set-property <app> stack <image>`; the invocation is
  `pack build "$IMAGE" --builder "$DOKKU_CNB_BUILDER" --path … --default-process web`. **[src]**
- **The docs understate it.** They say specific buildpacks "cannot currently be specified" and there is
  "no way to inject extra `pack` CLI arguments" **[docs]** — but `builder-pack/builder-build`
  allowlists `-b/--buildpack`, `--buildpack-registry`, `--cache`, `--cache-image`, `--volume`,
  `--env`, `--env-file`, `--extension`, `--network`, `--platform`, `--pull-policy`, `--run-image`,
  `--previous-image`, `--clear-cache`, `--trust-builder`, `--uid`/`--gid`, `--workspace` and more. **[src]**
- **`pack` is not installed by Dokku** and must be installed and version-managed separately. **[docs]**
- `dokku repo:purge-cache` "currently has no effect" with this builder. **[docs]** — confirmed by
  source, since that command only removes `cache-<app>`.

### nixpacks and railpack

Both are Railway's; both are core Dokku plugins whose CLI must be installed separately. **[docs]**
Neither passes `docker-options` to `docker`: each has its own allowlist translating them into *its
own* CLI's flags. **[src]**

- **nixpacks' default cache identifier is a hash of the absolute build-directory path** **[docs]**,
  and Dokku builds in `mktemp -d "/tmp/dokku-${DOKKU_PID}-…XXXXXX"` **[src]** — a fresh random path
  per build. The consequence, which nothing in either set of docs states: **a nixpacks build on Dokku
  should be cache-cold every time unless `--cache-key` is passed** through
  `docker-options:add <app> build '--cache-key <app>'`. **[unverified]** — inference from two sourced
  facts, not yet run.
- **railpack requires a long-running privileged `moby/buildkit` container** plus
  `BUILDKIT_HOST='docker-container://buildkit'` in `/etc/default/dokku`. **[docs]** Its `--cache-key`
  is documented as "unique id to prefix to cache keys" **[docs]**, so without it cache keys are
  unprefixed and therefore box-wide.
- Railpack's Java support detects `pom.xml` or `gradlew`, defaults to JDK 21, and caches `~/.gradle`
  and `.m2/repository`. **[docs]**

### The Dockerfile builder

**Prohibited on this box** — see `D_builder`; the install sets `builder:set --global selected
herokuish`, which means the detection below never runs. Kept here because it is what both predecessors
used and what a reader coming from Dokku's own docs will expect.

- **Auto-detected** when a `Dockerfile` exists at the repo root — but only if `herokuish` and `pack`
  builders do not claim the app first. **[docs]**
- **Dockerfile path is settable**, relative only: **[docs]**

  ```bash
  dokku builder-dockerfile:set node-js-app dockerfile-path .dokku/Dockerfile
  ```

- **BuildKit** is on by default on Docker Engine 24+. Below that, enable it in `/etc/default/dokku`:
  **[docs]**

  ```bash
  echo "export DOCKER_BUILDKIT=1" | sudo tee -a /etc/default/dokku
  echo "export BUILDKIT_PROGRESS=plain" | sudo tee -a /etc/default/dokku
  ```

- **Cache mounts are documented and supported** ("BuildKit directory caching"), with a worked example.
  Dokku's own example is apt, and it names `$HOME/.m2` as the Maven path. **[docs]**
- **Build args** go through `docker-options`, and the documented form passes the *name only*, taking the
  value from the environment the build runs in: **[docs]**

  ```bash
  dokku docker-options:add node-js-app build '--build-arg NODE_ENV'
  ```

  The explicit `--build-arg NAME=value` form works as well, though the docs never show it: the builder
  allowlists the `--build-arg` *flag* and appends it together with its value to `docker image build`
  without inspecting either (see the allowlist under *`docker-options`*, below). That is how a
  per-project secret like a Vaadin offline key gets to a build. **[src]**
- **`DOKKU_GLOBAL_BUILD_ARGS` is appended to every app's build options**, after the per-app ones — a
  box-wide escape hatch, and a thing to check when a build behaves unexpectedly. **[src]**

### `docker-options` and its sharp edges

Three phases — `build`, `deploy`, `run`: **[docs]**

```bash
dokku docker-options:add    [--process PROC...] <app> <phase(s)> OPTION
dokku docker-options:remove [--process PROC...] <app> <phase(s)> OPTION
dokku docker-options:clear  [--process PROC...] <app> [<phase(s)>...]
dokku docker-options:report [<app>] [<flag>] [--format json|stdout]
```

- **`run` is not `docker run`.** "The `run` phase does *not* correspond 1-to-1 to `docker run` … Specifying
  a container option at the `run` phase will only be invoked on containers created by the `run` plugin
  and cron tasks." Deployed processes take `deploy`. **[docs]**
- **What the `build` phase means depends on the builder** — and the docs' blanket warning that "`build`
  options are container options … the `dockerfile` builder does not support mounted volumes" describes
  the *herokuish* path, not the Dockerfile one. Both builders read the same `docker-args-build`
  trigger and then use its output completely differently. Read at **v0.38.27**: **[src]**
  - `plugins/builder-dockerfile/builder-build` concatenates the `docker-args-build` and
    `docker-args-process-build` trigger output with `DOKKU_GLOBAL_BUILD_ARGS`, splits it through
    `fn-docker-args-split`, filters it against a **flag allowlist**, and appends the survivors to
    `docker image build`. Value-taking flags keep their value (`DOCKERFILE_ARGS+=("--cache-to");
    DOCKERFILE_ARGS+=("$2"); shift 2`); anything off the list is silently dropped, with no warning.
  - `plugins/builder-herokuish/builder-build` hands the same options to `docker container create`
    instead. *There* they are genuinely container options — which is what the doc note is about.
- **The allowlist, verbatim at v0.38.27:** `--add-host`, `--allow`, `--annotation`, `--attest`,
  `--build-arg`, `--builder`, `--cache-from`, **`--cache-to`**, `--call`, `--cgroup-parent`, `--label`,
  `--memory`/`-m`, `--memory-swap`, `--network`, `--platform`, `--progress`, `--provenance`, `--sbom`,
  `--secret`, `--shm-size`, `--ssh`, `--tag`, `--target`, `--ulimit`, `--check`, `-D`/`--debug`,
  `--no-cache`. **[src]**

  Two things follow from reading it. `--cache-to`/`--cache-from` are on it, so a per-project build
  cache *is* reachable per app — see *Build caching*. And there is **no `--cpus`/`--cpu-quota` on it
  while `--memory` is**, which is the mechanism behind the documented `✗` for build CPU limits: the
  flag would be dropped on the floor rather than rejected.

### Build caching

**Which mechanism you get is a property of the builder, and so is whether the *platform* or the *app*
names the cache.** That is the fact `D_builder` turns on.

| builder | cache mechanism | named by |
|---|---|---|
| herokuish | Docker volume `cache-$APP`, mounted at `/cache`, `CACHE_PATH=/cache` | **Dokku** |
| pack | `pack-cache-<sanitized image ref>-<sha256[:6]>.build` volume; or `--cache …` | **pack**, or us |
| nixpacks / railpack | BuildKit mount caches keyed by `--cache-key` | **us**, if we pass it |
| dockerfile | `RUN --mount=type=cache,id=…` in the repo; plus `--cache-to`/`--cache-from` | **the app**, for mounts |

#### The herokuish cache volume — what this box actually uses

- `fn-builder-herokuish-ensure-cache` runs `docker volume create … cache-$APP` (labelled
  `com.dokku.app-name` / `com.dokku.builder-type=herokuish`), and the build container is created with
  `-v "cache-$APP:/cache" --env=CACHE_PATH=/cache`. Buildpacks receive it as Heroku's `CACHE_DIR`.
  The app never learns the volume's name, and with no Dockerfile it has no syntax in which to open a
  different mount. **[src]**
- **`dokku repo:purge-cache <app>` is literally `docker volume rm -f cache-<app>`** **[src]** — per-app
  purge granularity, and the only cache lever needed under herokuish. Documented as scoped to
  buildpack builds; a no-op under `pack`, which names its volume differently.
- **The Heroku Java buildpack puts the Maven repository inside that volume**: `lib/maven.sh` exports
  `MAVEN_OPTS="… -Duser.home=${build_dir} -Dmaven.repo.local=${cache_dir}/.m2/repository"`, and caches
  `.m2/wrapper` and the downloaded Maven under `${cache_dir}/.maven`. Its **default goals are
  `clean dependency:list install`** and default opts `-DskipTests`, overridable with
  `MAVEN_CUSTOM_GOALS` / `MAVEN_CUSTOM_OPTS`; `MAVEN_SETTINGS_PATH` / `MAVEN_SETTINGS_URL` supply a
  `settings.xml`. **[src]**
- **Note what `-Duser.home=${build_dir}` implies:** during the Maven build `~` is the fresh source
  checkout, not the cache volume — so anything a build writes under `$HOME` other than `.m2`
  (Vaadin's `~/.vaadin`, for instance) is **not** cached. **[src]**
- **The Heroku Node.js buildpack caches into the same `CACHE_DIR`** — npm/pnpm/yarn caches and
  `node_modules`, under `${CACHE_DIR}/node/cache/`, plus any relative paths listed in the app's
  `package.json` `cacheDirectories`. It skips `node_modules` if that directory is checked into source
  control, and honours `NODE_MODULES_CACHE=false`. It **prunes devDependencies** at the end of its
  own compile. **[src]**
- **Nothing garbage-collects this volume.** Unlike a BuildKit mount cache it has no TTL and no GC
  policy; it grows until `repo:purge-cache` or a volume prune removes it.
- **The CNB equivalent, for when `pack` is revisited:** Heroku's CNB Maven buildpack creates a
  `CachedLayerDefinition` named `repository`, points `-Dmaven.repo.local` at it and restores it with
  `KeepLayer` **[src, heroku/buildpacks-jvm]**. Paketo's Java buildpack, by contrast, does **not**
  cache Maven dependencies between builds and documents bind-mounting `$HOME/.m2` instead **[docs]** —
  so "CNB caches Maven" is true of the stack, not of CNB.

#### The Dockerfile-builder mechanisms (not in use here — see `D_builder`)

The short version of why they lost: **Dokku lets the platform name a per-app *layer* cache, but not a
per-app *mount* cache.**

- **Cache mounts** — `RUN --mount=type=cache,target=…` in the app's own Dockerfile, documented by Dokku
  under *BuildKit directory caching*. Zero glue, and it survives changes that invalidate every layer.
  But the mount's `id` defaults to its `target`, so unkeyed mounts from every app on the box resolve to
  the same directory: shared and unkeyed unless each Dockerfile opts into an `id=`. Since the app writes
  its own Dockerfile, that is cooperation, never a boundary — the argument is `D_no_shared_cache` in
  shepherd-traefik. **[docs]**
- **Per-app `--cache-to` / `--cache-from`** — both are on the Dockerfile builder's allowlist (above), so
  they reach `docker image build` as one `docker-options:add` per app: **[src]**

  ```bash
  dokku docker-options:add myapp build '--cache-to type=local,dest=/var/cache/shepherd2/myapp,mode=max'
  dokku docker-options:add myapp build '--cache-from type=local,src=/var/cache/shepherd2/myapp'
  ```

  The flag sits on the *build command*, not in the repo, so the app cannot name another project's
  cache. This is the same mechanism `shepherd-build` uses today, and it covers the **layer** cache
  only — the `RUN --mount` half above stays the app's business.
- **The hinge is `docker image build` routing to buildx**, which is where `type=local` export comes
  from. That holds on Docker Engine 23+, but it is a property of the *engine*, not of Dokku, and it has
  not been run on our box. **[unverified]**
- **buildkitd runs its own GC**, independently of Dokku and of any prune cron; the defaults are
  reported to evict unused entries after roughly 48 h, so a cache mount is not a durable store. **[unverified]**
  Moot under herokuish, whose cache is a plain Docker volume with no TTL — but the thing to re-read
  if a BuildKit-based builder is ever revisited.
- **`--builder` is on the allowlist but is a dead end**: a `docker-container` driver builder needs
  `--load` or `--output` to land the image in the daemon, neither is allowlisted, and both would be
  dropped silently. Only the default `docker` driver builder is reachable. *(Reasoning, not tested.)*
  Recorded so nobody spots `--builder` and re-derives "one buildx builder per project".

### `git:sync` — the SCM poll

The command that replaces Jenkins. **[docs]**

```bash
dokku git:sync [--build|--build-if-changes] [--skip-deploy-branch] <app> <repository> [<git-ref>]
dokku git:sync node-js-app https://github.com/heroku/node-js-getting-started.git main
```

- Clones or fetches from a remote URL; takes an optional branch, tag or commit SHA.
- `--build` always builds; **`--build-if-changes` builds only when the fetch moved the ref** — exactly
  the poll-SCM semantics.
- The app must already exist (`apps:create`).
- **It is fully synchronous, and its exit code is the build's.** `cmd-git-sync` ends in
  `plugn trigger receive-app`, and `plugn trigger` runs each hook as an ordinary child and waits
  **[src]** — so that one call covers build, release *and* deploy: `receive-app` → `git_receive_app` →
  `git_build` → `dokku_receive` → `release_and_deploy`, which prints `Application deployed:` last.
  `git:sync` returns only once the new container is up and the old one is gone. The status propagates
  the whole way out — `release_and_deploy` returns the build's exit code, `plugn`'s bash environment
  runs under `set -eo pipefail`, so does `plugins/git/subcommands/sync`, and the `dokku` entrypoint
  invokes the subcommand directly under its own. **[src]** So a caller branches on `$?` and needs no
  other progress signal.
- **The app's deploy lock is taken `exclusive`, meaning non-waiting.** A second deploy of the same app
  while one is in flight does not queue — it fails immediately with *"currently has a deploy lock in
  place. Exiting…"* and points at `apps:unlock`. **[src]** Deploys of *different* apps don't contend.
- **Its output is captured** like any other deploy — a build record plus a log file per run, no
  redirection needed in the crontab line. See *Build tracking* — including the sharp edge that the
  capture starts *before* the change check, so a no-op tick leaves a record behind too.

**What `git:sync` persists** — it remembers more than the command's shape suggests, which matters for
`D_dokku_is_truth`:

- **The remote URL lands in `apps:report <app> --app-deploy-source-metadata`**, alongside
  `--app-deploy-source` = `git-sync`. The flags are documented, the metadata described as "free-form
  (commit sha, image ref, URL)". **[docs]** For `git:sync` the value is `<url>#<sha>` — the ref resolved
  to a commit, not the branch name — written by the `deploy-source-set` trigger. **[src]**
- **…but only after a build that got as far as `receive-app`.** The trigger fires *after* the build,
  so a first `git:sync --build` whose build fails leaves the deploy source empty; the app has a cloned
  repo and no recorded URL. **[src]** This is the edge that rules out deriving the poll list from it.
- **The branch persists separately**, as `git:report --git-deploy-branch`: syncing a branch ref sets
  `deploy-branch` to it unless `--skip-deploy-branch`. **[docs]** A later `git:sync` with no ref fetches
  the deploy branch. **[src]** So a poll never needs to carry the ref, only the URL.
- **The built commit also lands in a config var.** Before building, `git_build` writes the resolved sha
  to the app's `rev-env-var` — `GIT_REV` unless `git:set <app> rev-env-var` changes it — via
  `config_set --no-restart`. **[src]** So `dokku config:get <app> GIT_REV` answers "which commit did
  Dokku last start building" without touching the bare repo, and unlike `deploy-source-metadata` it
  survives a failed build, because it is written *before* the build rather than after. The flip side of
  the same ordering: it is the last *attempted* commit, not the running one.
- `--build-if-changes` compares the deploy branch's commit before and after the fetch and builds only if
  it moved — so **a failed build is not retried until upstream has a new commit**, same as Jenkins
  poll-SCM. **[src]**
- The bare repo under `~dokku/<app>` also keeps `origin` (from the first clone) and a `remote` remote
  (re-added on every fetch) pointing at the URL. **[src]** Readable with `git remote get-url`, but that
  is reaching around Dokku; the report flag is the sanctioned reader.

Related git commands: **[docs]**

```bash
dokku git:set [--global] <app> <key> <value>   # deploy-branch (default master), keep-git-dir,
                                               # rev-env-var (default GIT_REV), archive-max-files/-size
dokku git:report [<app>] [<flag>|--format json]
dokku git:initialize <app>                     # create the pre-receive hook
dokku git:from-image [--build-dir DIR] <app> <docker-image> [user] [email]
dokku git:from-archive [--archive-type TYPE] <app> <archive-url> [user] [email]
dokku git:allow-host <host>                    # add to known_hosts
dokku git:generate-deploy-key                  # ed25519 keypair
dokku git:public-key                           # print it, to install as a deploy key upstream
dokku git:auth <host> [<username> <password>]  # netrc auth; password can come from stdin
dokku git:auth-status <host> [...]             # since 0.38.0; exit 0 match / 1 none / 2 mismatch
```

**Private repos** are handled either by an SSH key in `/home/dokku/.ssh/` installed as a deploy key
upstream, or by a `.netrc` entry via `git:auth`; Dokku recommends a personal access token on a bot
user. `git:auth` writes credentials **per host, not per app** — one GitHub token for the whole box —
which is a coarser grain than one credential per project. **[docs]**

### There is no built-in scheduler for rebuilds

Dokku's `cron` plugin (`app.json` `cron` array) runs commands **inside the app's existing image** in a
one-off `run` container: **[docs]**

```json
{ "cron": [ { "command": "npm run send-email", "schedule": "@daily" } ] }
```

```bash
dokku cron:list <app>       dokku cron:report [<app>]     dokku cron:run <app> <cron_id>
dokku cron:suspend/resume <app> <cron_id>                 dokku cron:set ...
```

It **cannot trigger a build** — it executes the deployed image, so it is useless for periodic rebuild.
Also: only `PATH` and `SHELL` are set in the cron template, the command is exec'd directly so `;`,
`&&`, `|` and `>` are *not* interpreted, tasks are reaped at 24 h, and schedules run in the host
timezone (usually UTC). **[docs]**

**Consequence: periodic rebuild is a host crontab line calling `dokku git:sync --build-if-changes`.**
Not an in-product feature.

## Ports — the `EXPOSE` trap

**This whole section is a *Dockerfile-builder* problem, and `D_builder` removes it from our box.**
Both buildpack builders end their build with
`plugn trigger ports-set-detected "$APP" "http:<proxy-port>:5000"` **[src]**, and the buildpack tells
the app to listen on `$PORT`. So a buildpack app is wired correctly with no `ports:set` at all; what
follows applies to a `Dockerfile` app and is kept because the commands are still the ones to reach for
when a mapping *is* wrong.

```bash
dokku ports:list <app>
dokku ports:add   <app> <scheme>:<host-port>:<container-port>
dokku ports:set   <app> <scheme>:<host-port>:<container-port>   # replaces all mappings
dokku ports:remove <app> <host-port>
dokku ports:clear <app>
dokku ports:report [<app>]
```

Schemes: `http`, `https`, `grpc`, `grpcs` (nginx). **[docs]**

- **Default for buildpack apps and Dockerfile apps with no `EXPOSE`:** a listener on 80 (and 443 with
  SSL) proxying to container port **5000**. **[docs]**
- **With `EXPOSE` in the Dockerfile, Dokku creates listeners on the *exposed* ports**, proxying to the
  matching container port. So a `Dockerfile` with `EXPOSE 8080` — Shepherd's contract — lands the app on
  **`app.domain:8080`**, not on 443. **[docs]**
- Fix, once per app: **[docs, syntax]**

  ```bash
  dokku ports:set myapp http:80:8080 https:443:8080
  ```

- **The default is computed once and never revisited:** "this default behavior **will not** be
  automatically changed on subsequent pushes". And don't set `PORT` by hand — port mappings manage it.
  **[docs]**
- The Traefik plugin **only supports `http:80` and `https:443` mappings**, so under Traefik the fix-up
  above is not optional. **[docs]**

## Proxies

```bash
dokku proxy:set --global type nginx|caddy|haproxy|traefik|openresty
dokku proxy:set <app> type <impl>            # per-app override; computed-type is the effective one
dokku proxy:build-config [--parallel count] [--all|<app>]
dokku proxy:enable|disable [--parallel count] [--all|<app>]
dokku proxy:clear-config <app>|--all         # since 0.27.0
dokku proxy:report [<app>] [<flag>]
```

Five first-party implementations; **nginx is the default**. Properties: `type`, `proxy-port`,
`proxy-ssl-port` (app + global), `disabled` (app only); app beats global. "Changing the proxy does not
stop or start any given proxy implementation" — each has its own start procedure. Custom proxy plugins
must be named `*-vhosts` for the scheduler integration to work. **[docs]**

### nginx (the default) — and why it is architecturally different

- **nginx runs on the host as a system service installed by apt, not in a container.** **[docs]**
- It reaches app containers via **`.DOKKU_APP_<PROCESS_TYPE>_LISTENERS`** — "a list of IP:PORT pairs for
  the respective app containers" — i.e. it dials the container's IP directly. **[docs]**
- **Therefore nginx does not need to share an app's Docker network.** This deletes shepherd-traefik's
  network-sharing gotcha outright (a host process can route into any bridge network the daemon created),
  which is the single biggest architectural difference between the two designs. **[docs, inference —
  the docs never state the negative, but a host-side proxy dialling container IPs cannot need an
  attachment]**
- **`dokku-event-listener` runs in the background**, watches container state and rebuilds proxy config
  when a web process's IP changes. That is the in-product equivalent of
  `shepherd-traefik-connect-networks`. **[docs]**
- **Per-app ingress tuning is first-class** — `nginx:set`, app or global scope, app beating global then
  Dokku's default: **[docs]**

  | Property | Default |
  |---|---|
  | `client-max-body-size` | `1m` |
  | `proxy-read-timeout` | `60s` |
  | `x-forwarded-for-value` | `$remote_addr` |
  | `x-forwarded-port-value` | `$server_port` |
  | `x-forwarded-proto-value` | `$scheme` |
  | `x-forwarded-ssl` | (empty; `on`/`off`) |
  | `hsts` | `true` |
  | `hsts-include-subdomains` | `true` |
  | `hsts-max-age` | `15724800` |
  | `hsts-preload` | `false` |
  | `bind-address-ipv4` | `0.0.0.0` |
  | `bind-address-ipv6` | `[::]` |

- **The https-only half of that table is conditional on a certificate, which is what makes a plain-http
  box possible.** An app with no cert gets an http-only vhost: the `hsts*` properties have no listener
  to attach to, and the http→https redirect Dokku emits for an SSL-enabled app has nothing to redirect
  to. Both are `[unverified]` readings of the template rather than documented statements — punch-list
  item 18 — and they matter twice over: they are why the http-only install mode needs no Dokku flag, and why
  `D_cert` treats the mode as one-way. `hsts` is `true` by default with a **182-day** `max-age` and
  `includeSubdomains`, so a domain that has once served https over it cannot be walked back from the
  box.
- Escape hatch: a per-app **`nginx.conf.sigil`** template, with `{{ .APP }}`, `{{ .PROXY_PORT }}`,
  `{{ .APP_SSL_PATH }}` and the listener variables. `nginx:show-config` and `nginx:validate-config`
  inspect and check the generated file. **[docs]**
- **Since 0.38.0, an undeployed app still gets a minimal nginx config returning 502** — so its domain
  resolves and monitoring sees a non-200 rather than a connection failure. Replaced by the real config
  on first successful deploy. **[docs]**

### Traefik (official plugin)

Label-driven, exactly like shepherd-traefik — so existing Traefik knowledge transfers. **[docs]**

```bash
dokku proxy:set node-js-app type traefik
dokku ps:rebuild node-js-app

dokku traefik:set --global letsencrypt-email automated@dokku.sh
dokku traefik:set --global challenge-mode dns            # dns | http | tls (default tls)
dokku traefik:set --global dns-provider cloudflare
dokku traefik:set --global dns-provider-cf_api_email user@example.com

dokku traefik:labels:add    node-js-app traefik.directive value
dokku traefik:labels:remove node-js-app traefik.directive
dokku traefik:labels:show   node-js-app
dokku traefik:show-config <app>
dokku traefik:start | traefik:stop | traefik:report [app] | traefik:logs [--num N] [--tail]
```

Other global properties: `image`, `log-level`, `api-enabled`, `dashboard-enabled`,
`basic-auth-username`, `basic-auth-password`, `http-entry-point`, `https-entry-point`. **All
`traefik:set` properties are global-only** — there is no per-app Traefik setting, so per-app ingress
tuning has to go through `traefik:labels:add`. **[docs]**

Three restrictions, quoted: **[docs]**

- "Only `web` containers have Traefik labels injected by the plugin".
- "The traefik plugin only supports automatic ssl certificates from it's letsencrypt integration.
  Managed certificates provided by the `certs` plugin are ignored" — **this rules out `dokku-global-cert`
  and the `certs` plugin entirely under Traefik.**
- Only `http:80` and `https:443` port mappings are supported.

A fourth restriction, not quoted because the docs never mention it: **the plugin does nothing about
Docker networks.** `plugins/traefik-vhosts/internal-functions` templates a compose file and reads global
properties; there is no `docker network connect`, no `--network`, and no read of the app's
`initial-network` / `attach-*` properties (read 2026-09-10). Since Traefik here *is* a container, an app
isolated on its own network is plausibly unreachable by it. See *Nobody has to re-attach anything* under
*Networking and app isolation*. This is one of the reasons `D_proxy` chose nginx, and it is why
`D_isolation` depends on that choice. **[src for the absence; unverified for the 502]**

DNS-01 mode is documented as being "for wildcard certificates or when port 443 is not accessible" —
but nothing in the plugin declares a wildcard SAN, so per-app ACME *orders* remain unless `tls.domains`
labels are added by hand with `traefik:labels:add`. **[docs for the mode; unverified for the wildcard
workaround]**

## TLS: three routes to a wildcard certificate

`D_cert` takes route 1. Two facts about Let's Encrypt itself frame all three routes: **a wildcard
certificate can only be issued over the DNS-01 challenge** — HTTP-01 and TLS-ALPN-01 "cannot be used to
issue wildcard certificates" **[docs]** — and a `*.example.com` certificate does **not** cover the apex
`example.com`, which has to be requested as a second name on the same certificate. **[docs]**

### Route 1 — nginx + `dokku-global-cert` (community)

The exact model shepherd-traefik uses: **one** cert for the whole box. **[docs]**

```bash
dokku plugin:install https://github.com/josegonzalez/dokku-global-cert.git global-cert

global-cert:set [--force] CRT KEY      # add / update are aliases
global-cert:apply <app>...             # overwrite an app's own cert with the global one
global-cert:remove
global-cert:generate                   # key + CSR + self-signed cert
global-cert:show <crt|key|csr>
global-cert:report [<app>|--global] [<flag>]
```

"Allows setting a global certificate, which is imported for all new applications and applied to every
existing application that does not already have its own certificate." On update: "re-applies it to every
application that currently uses it, so renewals (for example a rotated wildcard certificate) propagate to
existing applications and are served immediately." Apps with their own cert are "left untouched unless
`--force` is passed". **[docs]**

Caveats: the README declares support for **Dokku 0.7.0+ / Docker 1.12.x** and the install URL still
points at `josegonzalez/`, while the live repo is `dokku-community/dokku-global-cert` (20★, MIT, last
active 2026-07-20) — a low-profile plugin, genuinely maintained but thin. **We own issuance and renewal**
(an ACME client on the host → `global-cert:set`). **[docs + repo metadata]**

There is also a rawer official variant: drop `server.crt` / `server.key` into `/home/dokku/tls` and
uncomment the `ssl_certificate` lines in `/etc/nginx/conf.d/dokku.conf`. **[docs]** Whether that covers
app vhosts or only the default server was not investigated.

**The ACME client on the host — lego vs certbot.** Read 2026-09-10 for `D_cert`:

- **Traefik "relies internally on Lego for ACME"**, and its DNS-provider list *is* lego's. So a `lego`
  command on the host with the same provider credentials is the same code path that renews
  shepherd-traefik's certificate today. **[docs — Traefik]**
- **lego's `godaddy` provider** takes `GODADDY_API_KEY` / `GODADDY_API_SECRET`; the documented example is
  literally our case: `lego run --dns godaddy -d '*.example.com' -d example.com`. Its page carries the
  provider's own warning: "GoDaddy has recently (2024-04) updated the account requirements … Management
  and DNS APIs: Limited to accounts with 10 or more domains and/or an active Discount Domain Club plan."
  **[docs — lego]**
- **`lego renew`** takes `--days N` (renew when fewer than N days remain) and `--renew-hook CMD`, and "the
  hook is executed only when the certificates are effectively renewed"; the hook sees `LEGO_CERT_DOMAIN`,
  `LEGO_CERT_PATH`, `LEGO_CERT_KEY_PATH` (and `LEGO_ISSUER_CERT_PATH`, `LEGO_CERT_PEM_PATH`,
  `LEGO_CERT_PFX_PATH`). Certificates land under `.lego/certificates/`, a wildcard as `_.example.com.crt`
  / `.key`. A `--dynamic` renewal window (⅓ of lifetime) exists in 4.x and is the default from v5.
  **[src — `cmd/cmd_run_renew.go`, `cmd/hook.go`; docs for the file layout]**
- **lego ships no timer**; the daily `lego renew` is the operator's cron line. **[docs]**
- **Ubuntu packages lego in universe: 4.1.3 on 22.04, 4.9.1 on 24.04**, against upstream **v5.4.1** — a
  major version behind. **[docs — packages.ubuntu.com, GitHub releases, 2026-09-10]**
- **certbot** ships a renewal timer with the distro package and a `--deploy-hook` (run after a successful
  renewal, with `$RENEWED_LINEAGE`), but its **first-party DNS plugins are thirteen** — Cloudflare,
  DigitalOcean, DNSimple, DNS Made Easy, Gehirn, Google, Linode, LuaDNS, NS1, OVH, RFC 2136, Route53,
  Sakura Cloud — and **GoDaddy is not among them**; `certbot-dns-godaddy` is a third-party pip package.
  **[docs — certbot]**

### Route 2 — nginx + `dokku-letsencrypt` (official plugin)

```bash
sudo dokku plugin:install https://github.com/dokku/dokku-letsencrypt.git
sudo dokku letsencrypt:cron-job --add

dokku letsencrypt:set --global email admin@example.com
dokku letsencrypt:set --global dns-provider namecheap
dokku letsencrypt:set --global dns-provider-NAMECHEAP_API_USER user
dokku letsencrypt:set --global dns-provider-NAMECHEAP_API_KEY key
dokku letsencrypt:enable <app>
dokku letsencrypt:disable <app>   letsencrypt:list   letsencrypt:revoke <app>
dokku letsencrypt:cron-job --add|--remove
```

- 1118★, MIT, active (2026-09-01). Email is **mandatory** for ACME registration; set it `--global` to
  avoid repeating. **[docs]**
- Provider credentials are lego env var names under the `dns-provider-*` property prefix, global or
  per-app. **[docs]**
- **Renewal is solved:** `letsencrypt:auto-renew` runs daily (06:24 via Dokku's cron plugin, or `@daily`
  from the user crontab), with a 30-day-before-expiry grace period. **[docs]**
- A single ACME account is shared: "the plugin stores a single ACME account in
  `${DOKKU_LIB_ROOT}/data/letsencrypt/--global/accounts`" for apps with the same email and server config.
  **[docs]**
- **But issuance is per app** (`letsencrypt:enable <app>`), so every new app performs its own ACME
  order — the "https works" half of the requirement, not the "no per-app round-trip" half. **[docs]**
- **And the app must exist on the wire first:** "The app needs to already be deployed and reachable on
  the public internet over HTTP before a certificate can be issued." An app whose first builds fail has no
  certificate until `enable` is re-run after a green build. **[docs]**
- **The challenge type is per app.** `dns-provider` is settable globally or per app; a per-app value
  overrides the global one, and `none` forces HTTP-01 for that app. This is what would let it coexist
  with a global cert in v2: enabled only on apps carrying a foreign domain. **[docs]**
- **Wildcard status is muddier than the README suggests.** The README says DNS-01 "is the only way to
  obtain wildcard certificates", while issue #189 carries the note: *"As of 0.12.0, dokku-letsencrypt
  will be in a position to add dns-01 challenge support. That said, it'll still need work to enable the
  environment variable support needed. Until someone volunteers or sponsors the work, wildcard support
  is not officially supported by this plugin."* Whether a `*.domain` cert can be requested **and shared
  across apps** on a current version is **[unverified]** and is a box question.

### Route 3 — Traefik plugin with `challenge-mode dns`

See *Traefik* above. Renewal is Traefik's problem (as today), at the cost of per-app ACME orders and
losing the `certs` / `global-cert` plugins.

## Networking and app isolation

```bash
dokku network:create <network>          # attachable bridge network
dokku network:destroy <network>
dokku network:list [--format text|json] [--dokku-managed]
dokku network:exists <network>          # exit 0 if it does
dokku network:info <network> [--format text|json]
dokku network:set [--global] <app> <key> (<value>)
dokku network:report [<app>] [<flag>]
dokku network:rebuild <app>   dokku network:rebuildall
```

**The plugin owns membership, Docker does the enforcing.** `network:create` is a thin wrapper: it
shells out to `docker network create --attachable --label dokku.network.name=<name> <name>` and accepts
**no other arguments** — no `--driver`, no `-o/--opt`, no `--subnet`, no extra labels. **[src]** So
Dokku contributes no isolation primitive of its own (no ACLs, no per-port policy, no egress rules); it
contributes *which* network a container joins and *when*, and the boundary is whatever a Docker bridge
network gives you. Everything below follows from that split.

`network:set` properties: **[docs]**

| Property | Meaning |
|---|---|
| `initial-network` | "Network attached at container creation time." |
| `attach-post-create` | "Networks attached to a container immediately after creation, before the deploy phase." |
| `attach-post-deploy` | "Networks attached to a container after it passes healthchecks." |
| `bind-all-interfaces` | default `false`; binds to `0.0.0.0` instead of the Docker network address |
| `static-web-listener` | app-only; static `host:port` override for proxy templates when nothing is running |
| `tld` | custom TLD appended to network aliases |

**The three attachment phases are not interchangeable, and only one of them isolates.** **[docs]**

| Property | Container state | Phases it applies to | What it is for |
|---|---|---|---|
| `initial-network` | `created` | build, deploy, run | **isolation** — the app is *only* ever on this network |
| `attach-post-create` | `created` | build, deploy, run | joining an *additional* shared network the app needs at boot; the inter-app-communication tutorial's recommended property |
| `attach-post-deploy` | `running` | deploy only | joining an additional network once healthchecks pass, "when other containers need to access this one" |

`attach-post-deploy` carries a documented warning: *"If the attachment fails during the `running`
container state, this may result in your application failing to respond to proxied requests."* **[docs]**
The `attach-*` properties **add** networks, so an app with only an `attach-*` set is still on the
default bridge — they cannot deliver isolation, only reachability. Isolation is `initial-network`.

**The default is not isolated.** "Apps will default to being associated with the default bridge network
or a network specified by the `initial-network` network property" — so out of the box **every Dokku app
shares Docker's default bridge and can reach every other app**. Getting shepherd-traefik's
one-network-per-app property means creating a network per app and setting `initial-network` on it.
**[docs + third-party corroboration; the per-app recipe is unverified]**

The one mitigation on the shared default bridge is weak and worth naming so nobody mistakes it for a
boundary: *"Containers on the default bridge network can only access each other by IP addresses, unless
you use the `--link` option, which is considered legacy"* — so app-to-app there needs a container IP
rather than a name, while on any non-default network containers get automatic aliases `APP.PROC_TYPE`
(`http://node-js-app.web:5000`), optionally suffixed by the `tld` property. Discovery is harder on the
shared bridge; reachability is unchanged. **[docs]**

**Datastore plugins take the same three phases, which is what makes per-app isolation usable.**
`dokku-postgres` exposes `-N|--initial-network`, `-P|--post-create-network` and
`-S|--post-start-network` on `postgres:create` (comma-separated lists for the latter two), and the same
values are settable afterwards with e.g. `dokku postgres:set <service> post-create-network <net>`.
**[docs]** So an app and its own Postgres can share one per-project network with no raw-Docker escape
hatch — see *Services: Postgres*. Note `postgres:link` "will use native docker links via the
docker-options plugin", i.e. it adds a `--link`, which is a *legacy default-bridge* mechanism; what the
link flag does to a container whose `initial-network` is a user-defined bridge is **[unverified]**.

`network:rebuild <app>` / `network:rebuildall` re-apply network config to running containers — a
first-party re-assert, so keeping isolation true after drift does not need a tool of ours. **[docs]**

### What a Docker bridge network does and does not buy

Load-bearing for the isolation design, and it is Docker's behaviour rather than Dokku's:

- **Bridge membership is a real boundary.** *"Using a user-defined network provides a scoped network in
  which only containers attached to that network are able to communicate"*; containers on two different
  user-defined bridges have no route to each other. **[docs]**
- **But unlike a Swarm overlay, the host's firewall can see this traffic.** A bridge lives in the root
  network namespace, so container-to-container packets traverse the host's `FORWARD` chain — which is
  how Docker implements both inter-network isolation (`DOCKER-ISOLATION-STAGE-1/2`) and the `icc`
  setting in the first place. **Consequence: "one shared network plus a firewall rule" is a shape that
  can exist here**, and it is the rung that Swarm structurally denies the Dokploy sibling (there,
  intra-overlay traffic never reaches host netfilter). **[docs for the chains and the `enable_icc`
  driver option; the claim that an `icc=false` bridge plus links is a *workable* Shepherd2 topology is
  `[unverified]`; we chose per-app networks over it — see `D_isolation`]**
- **We cannot ask Dokku for a non-default bridge, though.** `enable_icc=false`, `--internal` and an
  explicit `--subnet` are all `docker network create` driver options, and `network:create` passes none
  of them **[src]**. A hand-made `docker network create -o …` referenced by name may work — the
  `network:list --dokku-managed` *filter* implies unmanaged networks are visible to the plugin — but
  that network then becomes ours to create and maintain. **[unverified]**
- **`--internal` would break builds anyway**, if anyone reaches for it: `initial-network` applies to the
  build phase too, so an egress-less initial network takes the build's package downloads with it.
  **[docs + inference]**
- **Per-app networks do not hide the host.** Every container keeps a route to its bridge gateway, so an
  app can reach anything bound on the box (sshd included) no matter which network it is on. That is a
  `DOCKER-USER` rule, not a membership question, and it is the whole of what the Dokploy sibling's
  "app → admin plane" axis becomes here — Dokku's control plane is a host binary and a git remote, with
  no dashboard container and no control-plane database to move off the wire. **[inference from the
  bridge model; unverified on a box]**

**The address-pool ceiling is an install-time line, not a design constraint.** Per-app networks are
*bridge* networks, i.e. Docker's **local**-scope pool: `172.17.0.0/12` at size 16 plus `192.168.0.0/16`
at size 20, so ~31 networks total, minus `docker0` — call it **~30 apps** on a stock daemon before
allocation fails. Enlarging `default-address-pools` in `/etc/docker/daemon.json` lifts it, and
shepherd-traefik already does exactly this, so it is precedent rather than a new cost: one stanza in
`shepherd2-install` and a `README.md` requirement. The only property worth remembering is *when* — it
needs a daemon restart, so it belongs in the install, not in a later fix. Dokku's bootstrap is not
documented as writing `daemon.json`. **[docs for the pools; unverified — whether bootstrap.sh touches
daemon.json needs reading or a box]**

(For the record, since the number moved twice: the `~29` that used to sit in this file was this same
local pool, miscounted with a `docker_gwbridge` that a non-Swarm box does not have. Swarm's
*global*-scope overlay pool, which shepherd2-dokploy draws on, is a different pool entirely —
`10.0.0.0/8` at mask 24, 65 536 subnets — so that repo has no equivalent line to write.)

### Nobody has to re-attach anything — and why that is two facts, not one

The predecessor's `shepherd-traefik-connect-networks` existed for one reason (a *proxy container* had to
join every app network and lost those attachments whenever it was re-created) and was made worse by
another (nothing re-asserted the app side either). Both halves are answered here, but by different
mechanisms, and they have different futures:

- **The app side is managed state.** `initial-network` is a persisted app property, not a one-shot
  `docker network connect`: Dokku re-applies it every time it creates a container, so it survives
  deploys, `ps:restart`, rebuilds and a host reboot. `network:rebuild` / `network:rebuildall` re-apply
  it on demand. Nothing outside Dokku has to re-assert it. **[docs]**
- **The proxy side needs nothing at all — but only because the default proxy is not a container.**
  nginx is a host process dialling `IP:PORT` (see *nginx — and why it is architecturally different*), so
  there is no proxy membership to maintain, and `dokku-event-listener` rewrites the config when a
  container IP changes.

**The second half is a property of the proxy choice, not of Dokku.** Under the Traefik plugin the proxy is a
container again, and the plugin's code contains no network-attachment logic — no `docker network
connect`, no read of the app's network properties (`plugins/traefik-vhosts/internal-functions`,
read 2026-09-10) **[src]**. So a per-app `initial-network` plausibly leaves Traefik unable to reach the
app at all, and repairing that is `shepherd-traefik-connect-networks` returning, this time as ours.
**Traefik would therefore cost either the per-project network isolation or a reconciler script** — which is one of
the reasons `D_proxy` chose nginx, and why `D_isolation` names `D_proxy` as a dependency rather than a
neighbour. **[src for the absence; unverified — whether Traefik + `initial-network` actually 502s needs
a box]**

## Resource limits

```bash
dokku resource:limit   [--process-type PROC] [--cpu N] [--memory N] [--memory-swap N] \
                       [--network N] [--network-ingress N] [--network-egress N] [--nvidia-gpu N] <app>
dokku resource:reserve  [same flags] <app>
dokku resource:limit-clear <app>      dokku resource:reserve-clear <app>
dokku resource:report [<app>]

dokku resource:limit --memory 100 node-js-app
dokku resource:limit --memory 4g --process-type build node-js-app
dokku resource:limit --cpu clear node-js-app
```

Mapping to Docker flags (docker-local scheduler): `cpu` → `--cpus`, `memory` → `--memory` (b/k/m/g
suffixes), `memory-swap` → `--memory-swap`, `nvidia-gpus` → `--gpus`; reservations: `memory` →
`--memory-reservation`. **[docs]**

**Build-time limits exist but are builder-dependent** — the special `build` process type, added in
0.38.0, applied via the `docker-args-process-build` trigger, and "only limits explicitly set against the
`build` process type are applied at build time": **[docs]**

| Builder | cpu | memory | memory-swap | nvidia-gpu |
|---|---|---|---|---|
| herokuish | ✓ | ✓ | ✓ | ✓ |
| **dockerfile** | **✗** | **✓** | **✓** | ✗ |
| pack, nixpacks, railpack, lambda | ✗ | ✗ | ✗ | ✗ |

**So with the Dockerfile builder, build *memory* can be capped and build *CPU* cannot.** That is a
direct, documented regression against shepherd-traefik, which limits both.

## Processes, restarts and reboot

```bash
dokku ps:report [<app>]      dokku ps:inspect <app>
dokku ps:scale node-js-app web=1 worker=1   [--skip-deploy|--replace|--clear|--format stdout|json]
dokku ps:start|ps:stop|ps:restart [<app>|--all] [--parallel N]
dokku ps:rebuild [<app>|--all] [--parallel N]      # rebuild from source
dokku ps:restore                                   # start previously-running apps, e.g. after reboot
dokku ps:set [--global] <app> <key> <value>
```

- **`restart-policy` defaults to `on-failure:10`**; allowed values `always`, `no`, `unless-stopped`,
  `on-failure`, `on-failure:N`. To match shepherd-traefik's `restart: always`:
  `dokku ps:set --global restart-policy always`. **[docs]**
- **Reboot:** `ps:restore` runs automatically from the init service after a Docker daemon restart — it
  starts linked services, clears generated proxy config, and restarts each app unless it was manually
  stopped. Per-app opt-out: `dokku ps:set node-js-app restore false`. **[docs]**
- The docker-local scheduler injects an init process (`--init`) by default, disableable via
  `scheduler-docker-local:set`. `parallel-schedule-count` (default 1) controls how many *process types*
  deploy in parallel, web first — this is about deploys, **not** about concurrent builds. **[docs]**
- **Container naming is not documented** on the scheduler page. shepherd-traefik's naming contract has
  no counterpart here; whatever Dokku names containers is Dokku's business, which is the point of
  retiring the contract. **[unverified]**

## Config, env vars and app metadata

```bash
dokku config:show  (<app>|--global)
dokku config:get   (<app>|--global) KEY
dokku config:set   [--encoded] [--no-restart] (<app>|--global) KEY=VALUE [KEY2=VALUE2 ...]
dokku config:unset [--no-restart] (<app>|--global) KEY [KEY2 ...]
dokku config:export (<app>|--global) [--format <format>]
dokku config:clear (<app>|--global)
dokku config:keys  (<app>|--global) [--merged]
dokku config:bundle (<app>|--global) [--merged]
```

- Global vars are sourced before app vars, so **app beats global**. **[docs]**
- `--encoded` takes base64, for values with newlines. `--no-restart` avoids the restart, for scripting.
  **[docs]**
- **For Dockerfile deploys, config vars are runtime-only** — "variables available *only* during runtime",
  deliberately, per Docker's own recommendation. Build-time values must go through build args. (Buildpack
  apps get them at both build and run time.) **[docs]**

App/domain management: **[docs]**

```bash
dokku apps:create <app>      dokku apps:destroy <app>     dokku apps:rename <old> <new>
dokku apps:clone <old> <new> dokku apps:list [--format stdout|json]
dokku apps:report [<app>] [<flag>]                dokku apps:exists <app>
dokku apps:lock <app> | apps:unlock <app> | apps:locked <app>
dokku apps:set [--global] <app> <key> (<value>)   # ONLY disable-autocreation, global-only — see below

dokku domains:set-global <domain> [<domain> ...]
dokku domains:add <app> <domain> [...]   dokku domains:set <app> <domain> [...]
dokku domains:clear <app>                dokku domains:enable|disable <app>
dokku domains:report [<app>|--global] [<flag>]
```

- Default app hostname is `subdomain.domain.tld`, subdomain inferred from the app name, TLD from the
  global domain — i.e. `PROJECTID.<domain>` comes for free. **[docs]**
- **An app named as an FQDN takes that FQDN**: "the global virtualhost will be ignored and the resulting
  vhost URL for that application will be `dokku.org`" — the mechanism for publishing one project on the
  apex domain. **[docs]**
- Whether a **wildcard** app domain (`domains:add app '*.example.com'`) is accepted is not documented.
  **[unverified]**
- **There is no user-settable per-app metadata slot.** `apps:set` accepts exactly one key,
  `disable-autocreation`, and only globally; every other `apps:report` field (`deploy-source`,
  `deploy-source-metadata`, `created-at`, …) is read-only and system-written. **[docs + src]** Anything
  of ours that must live *in* Dokku per app therefore goes through `config:set` — with the price that a
  config var is injected into the container's environment (`--no-restart` avoids the restart on write).
  This is what `D_dokku_is_truth` relies on.
- `apps:set --global disable-autocreation` requires an explicit `apps:create` before a deploy can land —
  worth having on a box that hosts other people's repos. **[docs]**

## Services: Postgres

```bash
sudo dokku plugin:install https://github.com/dokku/dokku-postgres.git --name postgres

dokku postgres:create <service> [--create-flags...]   # image version, env, memory limit
dokku postgres:link   <service> <app> [--link-flags...]
dokku postgres:unlink <service> <app>
dokku postgres:info   <service> [--single-info-flag]
dokku postgres:export <service>   dokku postgres:import <service>
dokku postgres:backup-auth <service> <aws-access-key-id> ...
dokku postgres:backup <service> <bucket-name> [--use-iam]
dokku postgres:backup-schedule <service> <schedule> <bucket-name>
dokku postgres:upgrade <service> [--upgrade-flags...]
```

`postgres:link` sets **`DATABASE_URL`** on the app and restarts it; the DSN looks like
`postgres://lollipop:SOME_PASSWORD@dokku-postgres-lollipop:5432/lollipop`, reachable only from inside
containers unless `expose`d. Major-version upgrades are export → new service → import. Scheduled S3
backups are built in. **[docs]**

**The service container takes the same network properties an app does** — `postgres:create -N|--initial-network`,
`-P|--post-create-network`, `-S|--post-start-network`, and `postgres:set <service> post-create-network`
after the fact. That is what lets a project's app and its own database share one isolated network; see
*Networking and app isolation* for the isolation design and for the `--link` caveat that `postgres:link`
drags in. **[docs]**

This is strictly more than shepherd-traefik has today (a README TODO) and more than shepherd-java's
fixed `postgres-service` with a hardcoded password.

## Observability

- **Logs are first-class:** **[docs]**

  ```bash
  dokku logs <app> [-t|--tail] [-n|--num N] [-q|--quiet] [-p|--ps process]
  dokku logs node-js-app -t -p web
  dokku logs:failed <app>|--all      # last failed deploy only
  dokku logs:report [<app>]
  dokku logs:set [--global|<app>] max-size 20m     # default 10m
  ```

  `logs:failed` under the docker-local scheduler keeps logs "only until the next deploy or garbage
  collection". **[docs]**
- **Log shipping via Vector** is an option, not a requirement: `logs:vector-start` / `-stop` /
  `-logs`, sinks as `SINK_TYPE://?SINK_OPTIONS` (`console://`, `http://`, `file://`, `loki://`).
  **[docs]**
- **No metrics, by design.** Dokku does not manage monitoring. Because apps are plain Docker
  containers with stable names, `docker stats`, `lazydocker` (52.8k★, MIT) or `ctop` (17.8k★, MIT)
  cover it for zero code. **[docs for the stance]**
- **Event log:** Dokku writes events to `/var/log/syslog` and `/var/log/dokku/events.log`, with
  `dokku events [-t]`, `events:list`, `events:on`, `events:off`. (A separate third-party
  `alessio/dokku-events` logs to `/var/log/dokku.log` — don't confuse the two.) **[docs]**
- **Build history is first-class** — see *Build tracking* below. Discussion #5114 ("deploy history with
  Git SHAs isn't tracked … it was considered as part of a builds plugin effort that has stalled") is
  **superseded**: the effort landed in 0.38.0. Only its git-SHA half still holds.

### Build tracking — the `builds` plugin

**New as of 0.38.0**, core (nothing to install), and present in every 0.38.x tag including our pinned
v0.38.27. **Every deploy is recorded**, whatever triggered it: `git push`, `ps:rebuild`, `ps:restart`,
`ps:start`, `config:set`, `deploy`, and `git:sync` / `git:from-archive` / `git:from-image` /
`git:load-image`. **[docs]**

```bash
dokku builds:list [<app>] [--format json] [--kind build|deploy] [--status <status>]
dokku builds:info <app> <build-id> [--format json]
dokku builds:output <app> [<build-id>|current]   # tail -f while live, cat once finished
dokku builds:cancel <app>                        # SIGQUIT to the deploy's process group
dokku builds:prune <app> [--all-apps]
dokku builds:report [<app>] [<flag>]
dokku builds:set [--global|<app>] retention <N>  # `retention` is the only property
```

- **On disk, per build:** `/var/lib/dokku/data/builds/<app>/<build-id>.json` (the record) and
  `<build-id>.log` (the captured stdout+stderr). The output is *also* tagged into syslog as
  `dokku-<build-id>`, but the file is the durable copy — `builds:output` falls back to
  `journalctl -t dokku-<build-id>` only when the file is missing. **[docs]**
- **The record** is `id, app, kind, pid, started_at, finished_at, status, source, exit_code`; `--format
  json` adds a computed `display_status`, `duration` and `log_path`. `kind` is `build` (paths that
  produce an image) or `deploy` (paths that re-deploy one); `source` names the originating command,
  `git:sync` among them; `status` is `running|succeeded|failed|canceled` on disk, plus a display-only
  `abandoned` computed for a `running` record whose PID is dead. **[src]**
- **Retention is by count, not age: 20 records per app** by default (minimum 1), a per-app override
  cascading to a `--global` one. Pruning removes the record *and* its log, runs at the end of every
  deploy, and never touches a live build. Deleting the app deletes its build data; renaming moves it.
  **[src]**
- **No git SHA in the record.** "Which commit was that build?" is still answerable only from the events
  log. That is the half of discussion #5114 that survives. **[src]**
- `builds:list` **with no app** lists the builds running box-wide — which is a cheaper
  "is it safe to reboot?" than watching a lock file. **[docs]**

**The capture is trigger-independent by construction**, which is the property that matters here:
`dokku_setup_build_capture` in `plugins/common/functions` generates the id, writes the record, and then
redirects the *entire* deploy — **[src]**

```bash
exec &> >(tee -a "$LOG" >(logger -i -t "dokku-${DOKKU_BUILD_ID}"))
```

`plugins/git/internal-functions` calls it with source `git:sync`, so **the rebuild cron gets its build
log for free**: no redirection of our own in the crontab line, and no glue to write. What it does *not*
get for free is a usable record set — see the next edge.

**Sharp edge, and it is the one that bites a periodic poll: a `--build-if-changes` tick that finds
nothing still writes a record.** `cmd-git-sync` calls `dokku_setup_build_capture` *before* it fetches
and before it compares refs, then `return`s on the no-change path without ever reaching
`builds-record-finalize`. **[src]** So every no-op tick leaves a `running` record — dead PID, so
display status `abandoned` — plus its log file, holding the fetch chatter. Three consequences, in the
order they arrive: **[src]**

1. **Nothing prunes them in the meantime.** `PruneAppBuilds` runs *only* from
   `builds-record-finalize`, so they accumulate at one per tick per app, unboundedly, for as long as
   the app is not deployed.
2. **The next real deploy rewrites them as failures.** `PruneAppBuilds` begins with
   `ReapAbandonedBuilds`, which finalizes every dead-PID `running` record as **`status=failed`,
   `exit_code=-1`**. `abandoned` is computed for display and never stored, so what lands on disk is
   indistinguishable from a build that really failed.
3. **Then retention evicts the real history.** The `retention` survivors are the newest by
   `started_at`: the build that just finished plus the most recent no-op ticks. At a 5-minute poll and
   the default 20, that window is **~95 minutes**, and every older build's record *and* log file is
   deleted.

For anything reading these records that means `builds:list <app>` is mostly poll noise, `--status
failed` no longer selects failures (`--status succeeded` is the one filter that still means what it
says), and a build log is reliably present only until 19 further ticks have passed — so "go and read
why last night's build failed" does not work. Raising `builds:set retention` buys minutes, not
fidelity. **`builds:list` with no app is unaffected**, and so is anything built on it:
it goes through `FetchRunningBuilds`, which requires a live PID, so a dead record can never make a
box-wide "is anything building?" check block. **[src]** The fix is on the caller's side — don't enter
`git:sync` at all unless the ref moved; that is `Q_poll_churn` in `ideas/poll-build-record-churn.md`.

**Sharp edge: bare `builds:output <app>` does not mean "the last build".** Given no build id (or the
literal `current`) it resolves one from the app's `.deploy.lock`, so on an idle app it prints
`App not currently deploying` rather than the failure you came for. `builds:list` is sorted
newest-first and emits `id`, so the two-step scripts: **[src]**

```bash
dokku builds:output myapp "$(dokku builds:list myapp --status failed --format json | jq -r '.[0].id')"
```

That recipe assumes `--status failed` means something, which under a periodic poll it does not — the
newest "failed" record will be a reaped no-op tick (previous edge). **`exit_code` is what separates
them**: a reaped record always carries `-1`, a build that really failed carries the builder's own
positive code, and `kind` does not help because `git:sync` maps to `build` either way. **[src]** So
`… --status failed --format json | jq -r '[.[] | select(.exit_code != -1)][0].id'` while `Q_poll_churn`
is open. The one case it mislabels is a real build the box killed (reboot mid-build), which is reaped
as `-1` too.

## Admin interface

- **The CLI is the primary and only official interface, and it is remote over SSH.** Users authenticate
  as the `dokku` system user by SSH public key; `ssh dokku@host <command>` is the sanctioned remote
  form. Who may run what is *Users and access control* below. **[docs]**
- **There is no HTTP API.** **[docs, by absence]**
- **Reports are machine-readable**, which makes command-and-parse a structured interface rather than
  screen-scraping: `--format json` on `*:report`, `apps:list`, `network:list`, `ps:scale`; and
  single-value flags return one bare value, e.g. `dokku docker-options:report node-js-app
  --docker-options-build`. **[docs]**
- **The official web UI is Dokku Pro: proprietary, paid.** Debian/RPM packages, a JWT-authenticated JSON
  API, HTTPS git-push endpoints, and a web UI for apps, datastores and SSH keys; licence validated
  against the public internet (offline support by enquiry). No open-source version. **[docs]**
- **Third-party web UIs have a demonstrated death rate.** `palfrey/wharf` (262★, AGPL-3.0, active
  2026-09-03) is the one live option and is single-maintainer; `ledokku` (642★, MIT — and the one Dokku
  itself endorsed in 2021) died 2023-10, `cywio/atlas` 2022-01, `HarborJS` 2018-05, `intercity-next`
  2019-04. Pruvon advertises AGPLv3 but no public repo was locatable on 2026-09-09. **[repo metadata]**
- **wharf's scope is day-to-day, not provisioning.** Its README claims "most features you'll need
  day-to-day": apps, env vars, domains, Postgres/Redis links, deploy and sync, runtime logs, build
  output. Nothing for resource limits, `docker-options` or networks. It is a pure client — talks to
  Dokku over SSH with a key of its own (optionally the `dokku-daemon` socket) and authenticates its own
  users with a single `ADMIN_PASSWORD` — so adopting it costs nothing if it dies: no server-side state
  lives in it. **[docs]** (its README, read 2026-09-10)
- **Other clients Dokku lists** (*Community contributions* on the clients page): `dokku-toolbelt`
  (Node), `dokku-cli` (Ruby gem, 184★, updated 2026-04, "makes your Dokku even more Heroku") and
  `Dockland` (Ruby). All are sugar over the SSH commands. **No Dokku TUI was found** on the GitHub topic
  page or the clients page. **[repo metadata]** (web search was unavailable on 2026-09-10; the topic
  page and Dokku's clients page were read directly)

## Users and access control

The one-line version: **an SSH key is the whole identity model, and every key is effectively root over
every app.** There is no user registry, no password, no OAuth, and nothing to log in *to*.

- **A "user" is a named public key** in `~dokku/.ssh/authorized_keys`. The key name reaches plugin hooks
  as `$NAME` / `$SSH_NAME`; the system user is always `dokku`. **[docs]**

  ```bash
  dokku ssh-keys:add <name> [/path/to/key]     # or by pipe
  dokku ssh-keys:list [--format text|json]
  dokku ssh-keys:remove <name>|--fingerprint <fp>
  cat ~/.ssh/id_rsa.pub | ssh root@dokku.me dokku ssh-keys:add KEY_NAME
  ```

  Keys are stored with `no-agent-forwarding,no-user-rc,no-X11-forwarding,no-port-forwarding`. **[docs]**
- **The only privilege distinction in core is the substring `admin` in a key name**, which grants the
  right to add further keys remotely. **[docs]**
- **There is no app ownership and no per-user authorization.** Any authorised key may run any command
  against any app, `apps:destroy` on someone else's project included. **[docs, by absence]** The
  maintainer's stated position is that this is by design: Dokku assumes a personal or fully-trusted-team
  box, granular team access "is not part of Dokku's core offering", and anyone with real SSH access to
  the host bypasses restrictions anyway. **[docs]** (discussion #4927)
- **No password, no SSO, no OIDC**, in any form — a consequence of there being no HTTP API to attach a
  provider to. **[docs, by absence]**
- **The extension point is the `user-auth` plugin trigger**, called with `$SSH_USER $SSH_NAME $COMMAND
  $ARGS`; a non-zero exit denies the command. `user-auth-app` is the per-app variant. The docs
  recommend `user-auth` over `git-pre-pull` for authentication because it also covers
  `git-upload-archive`. **[docs]** This is what any multi-user story here has to be built on.

### `dokku-acl` — the community multi-tenancy plugin

[dokku-acl](https://github.com/dokku-community/dokku-acl) (MIT, 66★) implements per-app and per-service
ACLs on the `user-auth` trigger. It is the only open-source answer, and it is **stale**: last commit
**2024-01-16**, README still claiming "dokku 0.32.0+, docker 1.8.x", and its own README says it *"has not
been extensively audited for security"*. The staleness is not cosmetic — that final commit is
`fix: adapt to new trigger naming`, so a Dokku trigger rename makes it stop enforcing. **[src]**

```bash
acl:add <app> <user>      acl:remove <app> <user>      acl:list <app>      acl:allowed <user>
acl:add-service <type> <service> <user>                # …and the service-scoped equivalents
```

Global knobs live in `~dokku/.dokkurc/acl`: `DOKKU_SUPER_USER` (always allowed; when set, nobody else
may push to an app with an empty ACL), `DOKKU_ACL_ALLOW_COMMAND_LINE`, and four command whitelists —
`DOKKU_ACL_USER_COMMANDS` (any user, any time), `DOKKU_ACL_PER_APP_COMMANDS`,
`DOKKU_ACL_PER_SERVICE_COMMANDS`, `DOKKU_ACL_LINK_COMMANDS`. With none set, the plugin is inert and all
users can run everything. **[src]**

Four behaviours matter more than the command list, because they are what a Shepherd-shaped model would
run into: **[src]**

1. **ACLs cannot be edited over SSH.** `fn-acl-check-app` fails with *"You can only modify ACL using
   local dokku command on target host"* whenever `$NAME` is set. Every grant is the operator, on the box.
2. **Creating an app does not add the creator to its ACL.** There is no auto-ownership hook; a
   user-created app is owned by nobody until someone runs `acl:add` locally.
3. **`apps:create` takes no app argument**, so it can only sit in `DOKKU_ACL_USER_COMMANDS` — all users
   or none, with no per-user scope or quota. `apps:destroy` does take an app, so per-app delete works.
4. **Repos are readable by default.** Any user can `git clone` any app unless `git-upload-pack` and
   `git-upload-archive` are added to the per-app whitelist.

### Dokku Pro

The paid product is where the team model lives, and it is the only thing in the Dokku world resembling a
user registry with logins: **[docs]**

- **Teams** grant members a whitelisted set of commands against a set of apps (`*` allowed) and
  services; **Admins** is a special team with full access; **Owners** administer membership without
  inheriting it. Nothing is permitted until whitelisted, and some commands are admin-only.
- `users:create <username> [password]` — with no password, a reset URL is printed for the user to set
  their own. Users are automatically mapped to the matching key from `ssh-keys:add`.
- **Reverse-proxy authentication since Pro 1.4.0**: a trusted identity-aware proxy (oauth2-proxy,
  Tailscale Serve) sets a configured header naming the user and Pro issues a session with no login form.
  This is the only route to Google SSO anywhere in the Dokku ecosystem. Fails closed; must be scoped to
  trusted proxies.
- Pricing seen 2026-09-09: **$849 lifetime**, 1 production + 2 pre-production servers. **[unverified]**
  (vendor marketing, not read off an invoice)

## What Dokku does *not* do

The honest gap list, for the feature discussion:

| Missing | Detail |
|---|---|
| **Isolation of *cache mounts*** | The per-app **layer** cache is fine — `--cache-to`/`--cache-from` go through per app (*Build caching*). What no builder can scope is a `RUN --mount=type=cache` written by the app: its `id` defaults to `target`, so unkeyed mounts share one directory box-wide. |
| **Build CPU limit (Dockerfile builder)** | Documented `✗`. Memory yes, CPU no. |
| **Periodic rebuild** | `app.json` cron runs the deployed image, never a build. Host crontab required. |
| **A git SHA per build** | Build history itself is covered (*Build tracking*), but the record has no commit field — only the events log notes the SHA attempted/deployed. |
| **Box-wide resource quota** | `resource:limit` is per app. Nothing sums them or refuses an over-committing app. |
| **App isolation by default** | Default bridge is shared; isolation is opt-in per app, via `initial-network`. |
| **Any isolation primitive finer than membership** | No per-port ACLs, no egress policy. And `network:create` passes no driver options, so `enable_icc=false` / `--internal` / an explicit subnet are not reachable through Dokku at all. |
| **Wildcard-cert-once-for-all-apps** | Not in core. `dokku-global-cert` does the *propagation*; issuance and renewal need an ACME client on the host and a cron line of ours (`D_cert`). See *TLS* above. |
| **Metrics** | Explicitly out of scope for the project. |
| **A single declarative project descriptor** | Project state is spread over `apps`/`config`/`resource`/`domains`/`ports`/`network`/`git`/`builder-dockerfile` properties — but it is all *there*, reportable as `--format json`, and `git:sync` even records its URL (*`git:sync`* above). The genuinely missing pieces are a per-app **metadata slot** (`apps:set` takes one global key) and a URL that survives a failed first build; `config:set` stands in for both. |
| **A one-shot "create a project" command** | `apps:create` makes an empty app. Limits, ports, network, build options, database and the first `git:sync` are each their own command; `apps:create`, `network:create` and `postgres:create` are not idempotent. |
| **Open-source web UI** | Pro is paid; third-party is a graveyard with one survivor. |
| **HTTP API** | None. SSH is the transport. |
| **App ownership / per-user access** | An authorised key may do anything to any app. Buildable on the `user-auth` trigger; `dokku-acl` is the stale community attempt, teams are a Pro feature. |
| **Any login that is not an SSH key** | No password, no SSO, no OIDC. Pro's reverse-proxy auth is the only door. |
| **Graceful "safe to reboot"** | No equivalent of shepherd-cli's `shutdown`. |
| **Per-project git credentials** | `git:auth` is per host, not per app. |

## Questions only a box can answer

The `[unverified]` claims above, plus the ones that decide the design. This is the punch list for the
first throwaway VPS:

1. ~~Does the box's Docker route `docker image build` to buildx, so that a `--cache-to type=local`
   passed through `docker-options` actually *exports* a cache?~~ **Moot** — `D_builder` prohibits the
   Dockerfile builder, so no `--cache-to` is ever passed. Number retained so existing references
   don't shift.
2. Does `network:create` + `network:set <app> initial-network` actually isolate apps *and* leave
   host-nginx routing intact? Concretely, from inside app A's container: can it reach app B's
   unpublished port by container IP before the change, and not after; and does `curl` through nginx
   still work for both apps after it.
3. Does anything in the install write `/etc/docker/daemon.json` before we do — Docker's own package
   being the candidate, since `bootstrap.sh` never runs (`D_install_apt`) — and does what it writes
   survive our enlarged `default-address-pools`?
   - And confirm the wall it protects against: `network:create` ~30 times on a stock box and watch for
     the allocation failure, so we know the real number rather than the arithmetic.
4. **The `D_cert` chain, end to end:** `lego run --dns godaddy` succeeds with the current GoDaddy key
   and secret on Ubuntu's packaged 4.9.1; `global-cert:set` with the result serves https on an existing
   app; a *renewal* (`lego renew --days 3650 --renew-hook …` to force one) re-applies to every app and
   reloads nginx without dropped connections; and an app created but never deployed serves the global
   cert on its first successful deploy. (The earlier question here — whether `dokku-letsencrypt` can
   issue and share a wildcard — is moot for v1 and only matters if custom domains return.)
5. ~~Are cache mounts, and a per-app `type=local` cache directory, preserved across `git:sync --build`
   runs, and for how long?~~ **Superseded by 13** — under `D_builder` the cache is the `cache-$APP`
   Docker volume, which has no TTL and no GC.
6. **The two-build timing drill** from `COMPARISON.md`'s *How to settle it*: install, deploy one real
   Vaadin-Boot app, commit trivially, redeploy — timed. Then deploy a second app sharing Maven
   coordinates with the first and check whether it resolves the first one's `1.0-SNAPSHOT` jar. Under
   `D_builder` this should be **impossible by construction** (each app's `.m2` is its own
   `cache-$APP` volume); run it anyway, once, as the demonstration.
7. What does Dokku name app containers, and do `lazydocker` / `ctop` show them usefully?
8. Does a buildpack app get `http:80:5000` wired automatically, with nothing in `ports:set`, and does
   it survive a rebuild? (Was: does `EXPOSE 8080` + `ports:set` behave as documented — a
   Dockerfile-builder question, moot under `D_builder`.)
9. **(v2 — a managed database is deferred, so nothing here blocks v1.) Does `postgres:link` still work when
   the app is on a per-app network?** The link is a legacy
   default-bridge `--link`; on a user-defined bridge the app resolves the service by DNS name
   (`dokku-postgres-<svc>`), so it plausibly works *because* both sit on the per-app network rather than
   because of the link. Check that `postgres:create -N app-<id>` + `postgres:link` leaves `DATABASE_URL`
   connectable, and whether the `--link` flag errors, warns, or is silently inert.
10. **Can `initial-network` point at a network Dokku did not create** — one made with
    `docker network create -o com.docker.network.bridge.enable_icc=false` — and does the app still
    deploy and route? Only matters if `D_isolation` is ever revisited — it decides whether that entry's
    rejected shared-network-plus-firewall rung is reachable through Dokku at all. Lowest priority here.
11. **(v2, but cheap.) What can an app reach on the host?** From inside a container, on both a shared
    and a per-app network: `curl http://<gateway-ip>:22`, and nginx by gateway IP with a `Host:` header
    for another app. Sizes the `DOCKER-USER` rule that is all that is left of the sibling's "unpublish
    :3000" axis — and that rule is deferred to v2 (`ideas/harden-container-egress.md`), so this is
    measured not to unblock v1 but to decide whether v2 should bother. Worth the ten minutes while
    item 2 is being run anyway. Add `curl http://169.254.169.254/` to it: the metadata endpoint is the
    one answer with a genuinely bad worst case.
12. **Does `proxy:set <app> type traefik` still route an app whose `initial-network` is its own
    network?** The plugin has no attachment logic `[src]`, so the expectation is a 502. Worth ten
    minutes on the same box as item 2, because it is the evidence under `D_proxy`'s strongest reason and
    the thing to re-check if anyone ever proposes switching proxies.
13. **Does a Vaadin app's second build come back warm under herokuish?** Deploy one, commit trivially,
    `git:sync --build` again, and split the timing: is Maven resolving from `/cache/.m2/repository`
    (expected yes), and is the *frontend* half — `~/.vaadin` node download, `node_modules`, npm
    fetches — re-done from scratch (expected yes, and this is the question that decides items 14–16).
14. **(v2.) Does `dokku config:set <app> npm_config_cache=/cache/npm` actually warm npm across
    rebuilds?** It should: config vars reach the build via the ENV_DIR `[src]` and `/cache` is the
    per-app volume. Confirm npm honours it under whatever package manager Vaadin picks (npm vs pnpm —
    pnpm reads `store-dir`, not `npm_config_cache`). And the variant that would keep the setting off
    the app's repo entirely: does a **`config:set --global`** var reach the build's ENV_DIR too? The
    `pre-build` trigger bundles the *app's* config `[src]`, and whether that is the merged view
    (`config:keys --merged`) is `[unverified]`.
15. **Does Vaadin's pre-compiled production bundle skip the frontend build entirely** for an app with
    no custom frontend and no add-ons (Vaadin 24.1+)? **Answered for this farm on 2026-09-10, not on a
    box**: the operator confirms every app here uses that bundle, so items 13, 14 and 16 stop mattering
    in v1 and the recipe is "keep apps on the default bundle" rather than "cache node". Still worth one
    measurement whenever an app does customise its frontend.
16. **(v2.) Can `~/.vaadin` be relocated into the cache volume?** During the Maven build `$HOME` is the
    source checkout, because the Java buildpack sets `-Duser.home=${build_dir}` `[src]`, and Vaadin
    offers no property for that directory's location — `require.home.node` only forces the app to use
    it `[docs]`. Two things to try: `MAVEN_CUSTOM_OPTS="… -Duser.home=/cache/home"` (does a Maven CLI
    `-D` override the `MAVEN_OPTS` one for `System.getProperty`?), and a build-phase
    `docker-options:add <app> build '-v …'` bind mount, which the herokuish path passes to
    `docker container create` unfiltered `[src]`.
17. **Does `--cpus` work at build time under herokuish?** Same unfiltered path as 16 —
    `docker-options:add <app> build '--cpus 2'`. If it does, capping build CPU is not a gap after
    all, and the gap the feature survey recorded was a Dockerfile-builder artefact.
18. **What exactly does an app look like on a box with no certificate?** The http-only install mode
    (`D_cert`) is defined by *absence* — no lego, no `global-cert` — so what needs confirming is that
    absence behaves: an app on a `domains:set-global`'d box serves plain http on port 80, emits **no**
    `Strict-Transport-Security` header, and does **not** redirect to https. Both halves are
    `[unverified]` inferences from the nginx template (see *nginx*), and the second is the one that
    would make the mode useless if wrong. While there: check that `nginx:set <app> hsts` is genuinely
    inert without a certificate, since that is why the mode is one-way.
19. **The no-op-tick record drill** — cheap, and it decides `Q_poll_churn`. On a deployed app, run
    `git:sync --build-if-changes` three times with no upstream commit and check
    `builds:list <app> --format json`: three extra records, `status` `running` / display `abandoned`,
    one `.log` each. Then deploy for real and re-list: the three should have become `failed` with
    `exit_code: -1`, and the *previous* real build's record should be gone once enough ticks have
    accumulated. All three claims are `[src]`-derived (*Build tracking*), so this is a confirmation,
    not an open question — worth the five minutes because a whole design choice hangs off it.

## Sources

Dokku documentation (dokku.com, read 2026-09-09):
[Installation](https://dokku.com/docs/getting-started/installation/) ·
[Git deployment](https://dokku.com/docs/deployment/methods/git/) ·
[Dockerfile builder](https://dokku.com/docs/deployment/builders/dockerfiles/) ·
[docker-options](https://dokku.com/docs/advanced-usage/docker-options/) ·
[Port management](https://dokku.com/docs/networking/port-management/) ·
[Proxy management](https://dokku.com/docs/networking/proxy-management/) ·
[nginx proxy](https://dokku.com/docs/networking/proxies/nginx/) ·
[Traefik proxy](https://dokku.com/docs/networking/proxies/traefik/) ·
[Network management](https://dokku.com/docs/networking/network/) ·
[Resource management](https://dokku.com/docs/advanced-usage/resource-management/) ·
[Process management](https://dokku.com/docs/processes/process-management/) ·
[Scheduled cron tasks](https://dokku.com/docs/processes/scheduled-cron-tasks/) ·
[docker-local scheduler](https://dokku.com/docs/deployment/schedulers/docker-local/) ·
[Application management](https://dokku.com/docs/deployment/application-management/) ·
[Domains](https://dokku.com/docs/configuration/domains/) ·
[Environment variables](https://dokku.com/docs/configuration/environment-variables/) ·
[Repository management](https://dokku.com/docs/advanced-usage/repository-management/) ·
[Application management](https://dokku.com/docs/deployment/application-management/) (`apps:report` flags, `apps:set` keys) ·
[Community clients](https://dokku.com/docs/community/clients/) ·
[Log management](https://dokku.com/docs/deployment/logs/) ·
[Build tracking](https://dokku.com/docs/advanced-usage/builds/) ·
[Event logs](https://dokku.com/docs/advanced-usage/event-logs/) ·
[User management / ssh-keys](https://dokku.com/docs/deployment/user-management/) ·
[Plugin triggers](https://dokku.com/docs/development/plugin-triggers/) (`user-auth`, `user-auth-app`) ·
[Pro: team management](https://pro.dokku.com/docs/features/team-management/) ·
[Pro: user management](https://pro.dokku.com/docs/features/user-management/) ·
[Pro 1.4.0 — reverse-proxy auth](https://dokku.com/blog/2026/pro-release-1.4.0/) ·
[SSL configuration](http://dokku.viewdocs.io/dokku/configuration/ssl/) ·
[Dokku Pro](https://github.com/dokku/dokku/blob/master/docs/enterprise/pro.md) ·
[0.38.0 release notes](https://dokku.com/blog/2026/dokku-0.38.0/).

Plugins: [dokku-letsencrypt](https://github.com/dokku/dokku-letsencrypt) (and
[issue #189](https://github.com/dokku/dokku-letsencrypt/issues/189); README re-read 2026-09-10 for the
deployed-first requirement and per-app `dns-provider`) ·
[dokku-global-cert](https://github.com/dokku-community/dokku-global-cert) (README re-read 2026-09-10) ·
[dokku-postgres](https://github.com/dokku/dokku-postgres).

TLS tooling, read 2026-09-10 for `D_cert`:
[Let's Encrypt challenge types](https://letsencrypt.org/docs/challenge-types/) ·
[Traefik ACME reference](https://doc.traefik.io/traefik/reference/install-configuration/tls/certificate-resolvers/acme/) ("relies internally on Lego") ·
[lego GoDaddy provider](https://go-acme.github.io/lego/dns/godaddy/) ·
[lego — obtain a certificate](https://go-acme.github.io/lego/obtain/) (file layout) ·
[`cmd/cmd_run_renew.go`](https://github.com/go-acme/lego/blob/master/cmd/cmd_run_renew.go) and
[`cmd/hook.go`](https://github.com/go-acme/lego/blob/master/cmd/hook.go) (renew flags, hook semantics, hook env) ·
[lego on packages.ubuntu.com](https://packages.ubuntu.com/search?keywords=lego&searchon=names&exact=1&suite=all&section=all) ·
[certbot user guide](https://eff-certbot.readthedocs.io/en/stable/using.html) (DNS plugin table, `--deploy-hook`, timers).

Gaps and third parties: [deploy history — discussion #5114](https://github.com/dokku/dokku/discussions/5114),
**superseded by the `builds` plugin in 0.38.0 except for its git-SHA half** ·
[monitoring stance — discussion #5681](https://github.com/dokku/dokku/discussions/5681) ·
[security model / multi-tenancy — discussion #4927](https://github.com/dokku/dokku/discussions/4927) ·
[dokku-acl](https://github.com/dokku-community/dokku-acl) (`README.md`, `user-auth` and
`internal-functions` read on 2026-09-09; repo metadata for the last-commit date) ·
[wharf](https://github.com/palfrey/wharf) · [ledokku](https://github.com/ledokku/ledokku) ·
[lazydocker](https://github.com/jesseduffield/lazydocker) · [ctop](https://github.com/bcicen/ctop).

Dokku source, read at **v0.38.27** on 2026-09-09 (the `[src]` claims about the build-option allowlist,
the per-app buildpack cache volume, and build tracking):
[`plugins/builder-dockerfile/builder-build`](https://github.com/dokku/dokku/blob/v0.38.27/plugins/builder-dockerfile/builder-build) ·
[`plugins/builder-herokuish/builder-build`](https://github.com/dokku/dokku/blob/v0.38.27/plugins/builder-herokuish/builder-build) ·
[`plugins/builds/builds.go`](https://github.com/dokku/dokku/blob/v0.38.27/plugins/builds/builds.go) (retention, record schema, pruning) ·
[`plugins/builds/subcommands.go`](https://github.com/dokku/dokku/blob/v0.38.27/plugins/builds/subcommands.go) (the `builds:output` deploy-lock resolution) ·
[`plugins/common/functions`](https://github.com/dokku/dokku/blob/v0.38.27/plugins/common/functions) (`dokku_setup_build_capture`) ·
[`plugins/git/internal-functions`](https://github.com/dokku/dokku/blob/v0.38.27/plugins/git/internal-functions) (`git:sync` calls it; re-read 2026-09-10 for `cmd-git-sync`, `fn-git-clone`, `fn-git-fetch` — what the sync persists) ·
[`plugins/git/deploy-source-set`](https://github.com/dokku/dokku/blob/v0.38.27/plugins/git/deploy-source-set) and
[`plugins/apps/triggers.go`](https://github.com/dokku/dokku/blob/v0.38.27/plugins/apps/triggers.go) (`TriggerDeploySourceSet` writes `deploy-source` / `deploy-source-metadata`) ·
[`plugins/apps/subcommands.go`](https://github.com/dokku/dokku/blob/v0.38.27/plugins/apps/subcommands.go) (`CommandSet`: `disable-autocreation` is the only key) ·
[`plugins/git/subcommands/set`](https://github.com/dokku/dokku/blob/v0.38.27/plugins/git/subcommands/set) (`git:set` valid keys) ·
[`plugins/network/subcommands.go`](https://github.com/dokku/dokku/blob/master/plugins/network/subcommands.go)
(read on 2026-09-10: `network:create` takes a name and nothing else) ·
[`plugins/traefik-vhosts/internal-functions`](https://github.com/dokku/dokku/blob/master/plugins/traefik-vhosts/internal-functions)
(read on 2026-09-10: no network attachment logic anywhere in it).

Networking, read 2026-09-10 (*Network management* above re-read the same day for the three attachment
phases):
[Inter-app communication tutorial](https://dokku.com/tutorials/network/inter-app-communication/) ·
[dokku-postgres README](https://github.com/dokku/dokku-postgres/blob/master/README.md) (`--initial-network`,
`post-create-network`, `post-start-network`, "native docker links") ·
[Docker bridge driver](https://docs.docker.com/engine/network/drivers/bridge/) (scoped networks,
default-bridge IP-only access, the `com.docker.network.bridge.enable_icc` option) ·
[Docker packet filtering and firewalls](https://docs.docker.com/engine/network/packet-filtering-firewalls/) ·
[legacy container links](https://docs.docker.com/engine/network/links/).

Build-cache background (carried over, not re-verified here):
[buildx mount caches vs per-project `type=local`](https://mvysny.github.io/docker-build-cache/) ·
[BuildKit `RUN --mount=type=cache` reference](https://docs.docker.com/reference/dockerfile/#run---mounttypecache) ·
[buildkitd's own GC evicting unused entries](https://www.loopwerk.io/articles/2026/docker-buildkit-cache-coolify/).

The product survey that chose Dokku over Coolify, Dokploy and CapRover is
[`COMPARISON.md` in shepherd-traefik](https://github.com/mvysny/shepherd-traefik/blob/main/COMPARISON.md);
`D_dokku` in `DECISIONS.md` links to it rather than restating it.
