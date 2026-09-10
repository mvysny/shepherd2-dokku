# Which builder should Shepherd2 standardise on?

Opened 2026-09-10. **Nothing here is decided.** The question: Dokku can build an app seven different
ways, we have only ever considered one (`F_build_dockerfile`), and the Dockerfile is precisely the
option that hands the *app* control of the build cache. So: what is the menu, what is actually used
out there, what does each one cost — and should one of them become recommended, or the Dockerfile be
prohibited outright?

**Relationship to `ideas/build-cache.md`:** that file asks "given the Dockerfile builder, what do we do
about cache mounts?" and its answer set (A convention / B empty mounts) is *conditional on the builder*.
This file asks the question one level up. If a non-Dockerfile builder wins here, most of `build-cache.md`
is moot; if the Dockerfile survives, `build-cache.md` resumes exactly where it is. Don't merge them —
graduate this one first.

Sourcing convention as in `RESEARCH.md`: **[docs]** upstream documentation, **[src]** read from source
(Dokku at **v0.38.27**, matching our pin), **[unverified]** hypothesis.

---

## 1. The two requirements that actually decide this

Stated by the operator, 2026-09-10, and they are hard:

- **`R_warm_deps`** — a scheduled rebuild must **not** re-download the Maven dependency tree from
  Central. A cold `~/.m2` on every poll is not acceptable.
- **`R_cache_per_project`** — that cache must be **per project**, so one project's
  `mvn install` of `com.example:my-app:1.0-SNAPSHOT` can never be resolved by another project's build.
  This is `D_no_shared_cache` in shepherd-traefik, restated as a requirement rather than a known gap.

Secondary, from `ideas/features-to-preserve.md` — carried, not up for negotiation here:
`F_build_args` (a build-time Vaadin offline key), `F_poll_rebuild` (we rebuild on a schedule, from
repos **we do not own and cannot edit at will**), `F_build_mem_limit`, `F_build_history`.

**The finding that reframes the whole question:**

> Whether `R_cache_per_project` is *enforced* or merely *conventional* is decided by the **builder**,
> because the builder decides **who names the cache — the repo or the platform.**

| | who names the dependency cache | `R_cache_per_project` |
|---|---|---|
| Dockerfile | the app's own `RUN --mount=type=cache,id=…` | convention only |
| herokuish | Dokku (`cache-$APP` volume) | **enforced** |
| pack (CNB) | pack, from the image ref — or us via `--cache` | **enforced** |
| nixpacks | us, via `--cache-key` on the build command | **enforced** (and mandatory, see §4.4) |
| railpack | us, via `--cache-key` on the build command | **enforced** |
| null / prebuilt image | nobody on this box — the cache lives in CI | **moot** |

That table is the reason this file exists. `build-cache.md` §1 concluded that nothing available to
the Dockerfile builder enforces mount isolation, and that the only enforcing move
("switch to a buildpack builder") was "almost certainly not worth it" because it costs
`F_build_dockerfile`. With `R_cache_per_project` promoted from *known gap* to *requirement*, that
trade has to be re-priced rather than waved off.

---

## 2. The full menu

Seven builders ship in core at v0.38.27 — `ls plugins/` in the Dokku tree — plus two routes that skip
building on the box entirely. **[src]**

| builder | plugin | triggered by | extra binary on the box? |
|---|---|---|---|
| `dockerfile` | `builder-dockerfile` | `Dockerfile` at repo root | no |
| `herokuish` | `builder-herokuish` | `.buildpacks`, `BUILDPACK_URL`, or nothing else matching | no (ships in the herokuish image) |
| `pack` | `builder-pack` | `project.toml` at repo root | **yes** — `pack` CLI |
| `nixpacks` | `builder-nixpacks` | `nixpacks.toml` at repo root | **yes** — `nixpacks` CLI |
| `railpack` | `builder-railpack` | `railpack.json` at repo root | **yes** — `railpack` CLI **and a privileged buildkit daemon container** |
| `lambda` | `builder-lambda` | `lambda.yml` at repo root | yes — irrelevant to us, see §4.6 |
| `null` | `builder-null` | never auto-detected; explicit only | no |

Note the docs' *Builder Management* page still says "five built-in builders" and omits nixpacks and
railpack, both of which have their own docs pages and their own plugin directories. **[docs]** vs
**[src]** — trust the tree.

Not builders, but the same question from the other end:

- **`dokku git:from-image <app> <image>`** / **`git:load-image`** — deploy an image built elsewhere. **[docs]**
- **`dokku git:from-archive <app> <url>`** — deploy from a tarball. **[docs]**

---

## 3. How Dokku picks one, and how we would prohibit a Dockerfile

All **[src]**, `plugins/git/functions` and `plugins/builder/triggers.go` at v0.38.27:

```bash
BUILDER="$(plugn trigger builder-detect "$APP" "$TMP_WORK_DIR" | head -n1 || true)"
if [[ -z "$BUILDER" ]]; then
  BUILDER="herokuish"
  # …unless arm64 and herokuish is not allowed, then "pack"
fi
```

Four consequences worth having in writing:

1. **`head -n1` + alphabetical plugin order.** `plugn` runs the trigger for every plugin; the *first*
   line wins. The plugin named plain `builder` sorts before every `builder-*`, and its
   `TriggerBuilderDetect` prints the per-app `selected` property, then the `--global` one. So an
   explicit selection always beats detection. **[src]**
2. **The Dockerfile builder's deliberate hack.** `builder-dockerfile/builder-detect` force-runs the
   *herokuish* and *pack* detects first and stays silent if either claims the app — the comment in
   the source calls it a hack and says "such is life". It does **not** defer to nixpacks, railpack or
   lambda. So a repo with both a `Dockerfile` and a `nixpacks.toml` builds as **dockerfile**
   (alphabetical: `builder-dockerfile` < `builder-nixpacks`), while a repo with both a `Dockerfile`
   and a `project.toml` builds as **pack**. **[src]**
3. **Herokuish is the fallback**, not merely a detected builder — a repo matching nothing at all is
   built by herokuish, which then runs its own buildpack detection and fails there if nothing fits. **[src]**
4. **Prohibiting the Dockerfile is one command**, and it is the same command whichever builder wins:

   ```bash
   dokku builder:set --global selected herokuish   # every app, regardless of repo contents
   dokku builder:set <app> selected dockerfile     # …and the per-app escape hatch, if we want one
   ```

   A global `selected` short-circuits detection entirely, so a committed `Dockerfile` is simply never
   looked at. **[src]** Whether we *want* the per-app escape hatch is a real question — it is the
   difference between "recommended" and "prohibited", and it is one `PropertyGet` either way.

Also useful, all builders: `dokku builder:set <app> build-dir <subdir>` for monorepos, and
`dokku builder:report <app>` to see what was detected. **[docs]**

---

## 4. The options, one at a time

### 4.1 `B_dockerfile` — what we have today

The incumbent. `F_build_dockerfile`, `F_custom_dockerfile`, and everything in `build-cache.md`.

**Example** (the recipe `build-cache.md` position A would put in the README):

```dockerfile
FROM maven:3.9-eclipse-temurin-21 AS build
ARG CACHE_ID
WORKDIR /src
COPY . .
RUN --mount=type=cache,id=m2-${CACHE_ID},target=/root/.m2 \
    mvn -B -Pproduction -DskipTests package
FROM eclipse-temurin:21-jre
COPY --from=build /src/target/*.jar /app.jar
CMD ["java","-jar","/app.jar"]
```

```bash
dokku docker-options:add demo build '--build-arg CACHE_ID=demo'
dokku docker-options:add demo build '--cache-to type=local,dest=/var/cache/shepherd2/demo,mode=max'
dokku docker-options:add demo build '--cache-from type=local,src=/var/cache/shepherd2/demo'
```

- **`R_warm_deps`:** yes, and it is the *fastest* of all the options, because the app can cache-mount
  anything — `~/.m2`, `~/.vaadin`, `node_modules`, the lot.
- **`R_cache_per_project`:** **no — convention only.** `id=` lives in the app's Dockerfile; drop the
  `id=` and you are back on the box-wide `/root/.m2` mount. Nothing on the build command can remap it,
  and `--builder` is a dead end (`build-cache.md`, *Small things*).
- Other shortcomings: no build CPU limit (`F_build_cpu_limit`, allowlist has `--memory` and no
  `--cpus`); config vars are **not** available at build time, so `F_build_args` needs an explicit
  `--build-arg` per project; and the app's Dockerfile is arbitrary root-privileged build code, which
  is the widest attack surface of any option here (cf. `ideas/harden-container-egress.md`).
- Upside nothing else matches: it is what the projects **already have**, and it is the only option
  where a weird build (a native-image step, a custom base) is expressible at all.

### 4.2 `B_herokuish` — Heroku v2a buildpacks, Dokku's default

The strongest candidate on the two requirements, and the biggest change in feel.

The app ships **no build instructions**. Dokku runs the `gliderlabs/herokuish` image (based on
`heroku/heroku:24-build` **[src]**, so a current stack), which detects a buildpack and compiles.
Bundled buildpacks, in detection order: `multi, ruby, nodejs, clojure, python, java, gradle, scala,
php, go, static, null` — pinned, e.g. `heroku/heroku-buildpack-java v81`, `heroku-buildpack-nodejs v366`. **[src]**

**Example** — a Vaadin/Spring Boot app, three files in the repo:

```properties
# system.properties
java.runtime.version=21
```
```procfile
# Procfile
web: java -Dserver.port=$PORT -jar target/my-app-1.0-SNAPSHOT.jar
```
```bash
dokku apps:create demo
dokku builder:set demo selected herokuish
# the Vaadin production profile — and note MAVEN_CUSTOM_GOALS defaults to "clean dependency:list install"
dokku config:set demo MAVEN_CUSTOM_GOALS="clean package" MAVEN_CUSTOM_OPTS="-DskipTests -Pproduction"
dokku config:set demo VAADIN_OFFLINE_KEY=…        # available at build time, no --build-arg needed
dokku git:sync --build demo https://github.com/owner/repo main
dokku repo:purge-cache demo                        # nukes exactly this project's cache, nothing else
```

- **`R_warm_deps`: yes, and by a mechanism we cannot break.** `heroku-buildpack-java`'s `lib/maven.sh`
  sets `MAVEN_OPTS=… -Dmaven.repo.local=${cache_dir}/.m2/repository`, and `cache_dir` is Heroku's
  `CACHE_DIR`. **[src]**
- **`R_cache_per_project`: enforced.** Dokku creates one Docker volume per app and mounts it as the
  cache: `docker volume create cache-$APP`, then
  `docker container create … -v "cache-$APP:/cache" --env=CACHE_PATH=/cache …`. The app never learns
  the volume's name and has no Dockerfile in which to open a different mount. **[src]**
  `dokku repo:purge-cache <app>` is literally `docker volume rm -f cache-<app>` — per-app purge
  granularity for free. **[src]**
- **The pleasing detail:** the Heroku Java buildpack's *default* goals are
  `clean dependency:list install` **[src]** — i.e. the exact `mvn install` that `D_no_shared_cache`
  identifies as the poisoning path is what this builder does by default, and it is safe here because
  the local repo it installs into is the app's own volume.
- **`F_build_args` gets simpler, not harder.** `builder-herokuish/pre-build` bundles every app config
  var into an ENV_DIR (`/tmp/env`) inside the build ("Adding BUILD_ENV to build environment…"), so
  `dokku config:set` is enough. **[src]** Flip side: every *runtime* secret is then visible to the
  build too.
- **Shortcomings, and they are real:**
  - **Costs `F_build_dockerfile` outright.** Every hosted project needs a `Procfile` (and usually a
    `system.properties`) — and we host repos we do not own. Onboarding stops being "point at the repo".
  - **Node/Vaadin is the sharp edge.** Only `.m2` lands in the cache: the buildpack runs Maven with
    `-Duser.home=${build_dir}` **[src]**, and `build_dir` is a fresh checkout every build, so
    `~/.vaadin` (Vaadin's downloaded node) and `node_modules` are **cold every time**. `R_warm_deps`
    is satisfied for Maven and *not* for the frontend half. Possible outs — `npm_config_cache` set to
    a path under `/cache` via `config:set`, or a `.buildpacks` pairing `heroku/nodejs` with
    `heroku/java` — are both **[unverified]** and belong on the punch list.
  - **Detection order bites Vaadin**: `nodejs` is detected *before* `java` **[src]**, so a repo with a
    committed root `package.json` is built as a Node app. Fix is an explicit `.buildpacks` or
    `BUILDPACK_URL`, i.e. more per-repo edits.
  - Disabled by default on arm64 (irrelevant on our box, but that is why the `pack` fallback exists). **[docs]**

### 4.3 `B_pack` — Cloud Native Buildpacks

The modern successor to herokuish; Heroku's own future (Fir-generation apps use CNB; Cedar got CNB as
an opt-in on 2026-09-03, still defaulting to classic). **[docs]**

**Example:**

```toml
# project.toml in the repo root — also what triggers auto-detection
[build]
[[build.env]]
name = "BP_MAVEN_BUILD_ARGUMENTS"
value = "-Pproduction -DskipTests package"
```
```bash
dokku builder:set demo selected pack
dokku buildpacks:set-property demo stack heroku/builder:24     # default; paketobuildpacks/builder-jammy-base also works
dokku docker-options:add demo build '--cache type=build;format=volume;name=shepherd2-cache-demo'
dokku git:sync --build demo https://github.com/owner/repo main
```

- **`R_warm_deps`:** yes — both the Paketo and Heroku JVM buildpacks keep the Maven repository in a
  cached layer.
- **`R_cache_per_project`: enforced, twice over.** By default `pack` names its volume
  `pack-cache-<sanitized image ref>-<sha256(imageRef+key)[:6]>.build` **[src, buildpacks/pack
  `pkg/cache/volume_cache.go`]**, and Dokku builds the image as `dokku/<app>`, so it is per-app by
  construction. And `--cache` is on Dokku's pack-arg allowlist, so we can name it ourselves.
- **The docs are wrong in our favour.** The Dokku page says specific buildpacks "cannot currently be
  specified" and there is "no way to inject extra `pack` CLI arguments" **[docs]** — but
  `builder-pack/builder-build` allowlists `-b/--buildpack`, `--buildpack-registry`, `--cache`,
  `--cache-image`, `--volume`, `--env`, `--extension`, `--network`, `--pull-policy`, `--run-image`,
  `--clear-cache`, `--trust-builder` and more, and appends them to
  `pack build "$IMAGE" --builder "$DOKKU_CNB_BUILDER" --path … --default-process web`. **[src]**
  Worth a `RESEARCH.md` line regardless of what we choose.
- **Shortcomings:** costs `F_build_dockerfile` the same as herokuish, plus needs the `pack` CLI
  installed and version-managed on the box (not a Dokku dependency) **[docs]**;
  `repo:purge-cache` has no effect here **[docs]** — confirmed by source, since it only removes
  `cache-<app>` — so per-app cache purging needs `docker volume rm` of a hash-named volume, which is
  the one place this option reaches around Dokku; and the Vaadin node story is the same unknown as
  §4.2.

### 4.4 `B_nixpacks` — Railway's zero-config builder

Popular in the Coolify/Dokploy world; a Dokku core plugin, but the CLI is not shipped. **[docs]**

**Example:**

```toml
# nixpacks.toml — triggers detection; omit it and select the builder explicitly instead
[phases.build]
cmds = ["mvn -B -Pproduction -DskipTests package"]
[start]
cmd = "java -jar target/my-app-1.0-SNAPSHOT.jar"
```
```bash
dokku builder:set demo selected nixpacks
dokku docker-options:add demo build '--cache-key demo'      # NOT optional — see below
dokku docker-options:add demo build '--env VAADIN_OFFLINE_KEY'
```

- **`--cache-key` is load-bearing and almost certainly mandatory on Dokku.** Nixpacks' default cache
  identifier is *a hash of the absolute path of the build directory* **[docs]**, and Dokku builds in
  `mktemp -d "/tmp/dokku-${DOKKU_PID}-…XXXXXX"` **[src]** — a fresh random path every single build.
  So **out of the box every nixpacks build on Dokku should be cache-cold**, failing `R_warm_deps`
  silently and looking like "nixpacks is slow". Setting `--cache-key <app>` fixes that *and* delivers
  `R_cache_per_project` in the same stroke, because the flag sits on the build command where the app
  cannot reach it. **[unverified]** — this is inference from two sourced facts, and it is punch-list
  item #1 for this file.
- Nixpacks generates BuildKit cache mounts for the provider's own directories and wipes them from the
  final image. **[docs]** Whether a `nixpacks.toml`-declared `cacheDirectories` entry also gets the
  `--cache-key` prefix — i.e. whether the enforcement is airtight or just the default path — is
  **[unverified]**.
- **Shortcomings:** an extra CLI to install and pin; upstream has visibly slowed (last release
  v1.41.0, 2025-10-24, while Railway itself moved to railpack); Java support exists but is far less
  battle-tested than the Heroku Java buildpack; and `nixpacks.toml` is another file we would have to
  get into repos we do not own.

### 4.5 `B_railpack` — Railway's replacement for nixpacks

Same family, newer, actively developed (v0.39.0, 2026-09-03). A BuildKit frontend rather than a
Dockerfile generator; caches `~/.gradle` and `.m2/repository` for Java, detected from `pom.xml` or
`gradlew`, JDK 21 by default. **[docs]**

**Example:**

```bash
# one-time, on the box
docker run --rm --privileged -d --name buildkit moby/buildkit
echo "export BUILDKIT_HOST='docker-container://buildkit'" >> /etc/default/dokku

dokku builder:set demo selected railpack
dokku docker-options:add demo build '--cache-key demo'
```

- **`R_warm_deps`:** yes, by design — layer cache plus mount caches, all BuildKit backends supported. **[docs]**
- **`R_cache_per_project`:** `--cache-key` is documented as "unique id to prefix to cache keys" **[docs]**
  and is on Dokku's railpack arg allowlist **[src]**, so the platform sets the prefix. Same enforcement
  shape as nixpacks. Without it, **cache keys are unprefixed and therefore box-wide** — the same
  pollution hazard as an unkeyed `RUN --mount`, which is worth stressing because it is invisible.
- **The disqualifying cost, probably:** it requires a **long-running privileged `moby/buildkit`
  container** and a global `BUILDKIT_HOST`. **[docs]** That is a second build daemon with its own
  cache store and its own GC to reason about, a privileged container on a box whose whole
  isolation story is `D_isolation`, and a global switch that would affect railpack apps only but sits
  in `/etc/default/dokku` for everyone. Hard to square with "Dokku stays upstream and unforked, one
  moving part per problem".
- Also: newest and least proven of the lot; nobody's default yet (Coolify shipped it as beta and kept
  nixpacks first).

### 4.6 `B_lambda` — not for us

Detected on `lambda.yml`; builds AWS Lambda deployment artifacts. One line so nobody re-researches it:
irrelevant to a long-running web app on our box. **[src]**

### 4.7 `B_offbox` — don't build here at all (`null` builder + a prebuilt image)

```bash
# CI (GitHub Actions / Codeberg CI) builds and pushes; the box only pulls
dokku git:from-image demo registry.example.com/owner/demo:abc1234
```

- **Both requirements become moot on this box**, because there is no build here: the Maven cache is
  CI's problem, and CI already isolates per repo.
- **But it is a different product.** It kills `F_poll_rebuild` as we mean it (the box no longer rebuilds
  from source on a schedule; something else must, and must push), needs a registry and per-project CI
  credentials, and every hosted project needs a working pipeline — the exact thing Shepherd exists to
  spare them. It also contradicts the framing in `D_dokku` that the box builds git repos.
- Keep it on the list as the honest bottom of the menu and as the road not taken in whatever `D_` lands.

---

## 5. Which of these do people actually use?

Hard numbers, GitHub, 2026-09-10:

| project | stars | last release | note |
|---|---|---|---|
| `dokku/dokku` | 32.1k | — | for scale |
| `railwayapp/nixpacks` | 3.6k | v1.41.0, 2025-10-24 | 10 months without a release |
| `buildpacks/pack` (CNB) | 3.0k | v0.40.9, 2026-08-09 | CNCF, active |
| `gliderlabs/herokuish` | 1.5k | rolling | pushed 2026-09-09; Dokku's own dependency |
| `railwayapp/railpack` | 1.2k | v0.39.0, 2026-09-03 | very active, launched ~2026 |

Who defaults to what:

- **Dokku itself defaults to herokuish** — both as the documented default stack and, in code, as the
  fallback when nothing is detected. **[src]** It is the most-trodden path on *this* platform, which
  matters more to us than ecosystem-wide counts.
- **Heroku** has moved to CNB for Fir-generation apps and offers CNB on Cedar since 2026-09-03; classic
  (v2a, what herokuish implements) remains supported but is the legacy line. **[docs]** So herokuish is
  the safe choice today and the slowly-declining one.
- **Coolify** ships nixpacks as its default and added railpack as a *beta, second-in-the-dropdown*
  option in v4.1.0 (2026-05-18); **Railway** itself has switched to railpack. Neither nixpacks nor
  railpack is any major self-hosted PaaS's default-with-confidence, months after railpack's launch.
- **Dockerfile** is not in this comparison because it is not a competing ecosystem — it is what people
  reach for when the buildpack does not fit, and it is what all of our projects already have.

**Reading:** popularity points at *herokuish or pack* for a Java box, with nixpacks the popular-but-
stalling option and railpack the interesting-but-early one. Neither Railway-family builder brings
anything on our two requirements that pack/herokuish do not, and both bring an extra binary.

---

## 6. Scorecard

`R_warm_deps` is scored for a **Vaadin** build (Maven **and** the frontend), because that is the build
we actually have.

| | `R_warm_deps` (Maven) | `R_warm_deps` (Vaadin/npm) | `R_cache_per_project` | keeps `F_build_dockerfile` | new box dependency |
|---|---|---|---|---|---|
| `B_dockerfile` | ✅ best | ✅ | ⚠️ convention only | ✅ | none |
| `B_herokuish` | ✅ | ❌ cold (`user.home` = build dir) | ✅ enforced | ❌ | none |
| `B_pack` | ✅ | ❓ unverified | ✅ enforced | ❌ | `pack` CLI |
| `B_nixpacks` | ✅ *only with* `--cache-key` | ❓ | ✅ enforced | ❌ | `nixpacks` CLI |
| `B_railpack` | ✅ *only with* `--cache-key` | ❓ | ✅ enforced | ❌ | CLI **+ privileged buildkitd** |
| `B_offbox` | n/a (CI's problem) | n/a | n/a | ✅ (in CI) | registry + CI |

**Nothing on this list satisfies both requirements *and* keeps the Dockerfile.** That is the shape of
the decision, and it is worth stating in the `D_` in exactly those words. Either

- **we keep the Dockerfile and `R_cache_per_project` stays a convention** — i.e. `build-cache.md`
  position A, with the operator reading every Dockerfile at `create-app` time
  (`D_single_operator`) as the enforcement mechanism, or
- **we keep the Dockerfile and buy enforcement by making mounts useless** — `build-cache.md`
  position B, which trades `R_cache_per_project` against `R_warm_deps` and therefore now
  **fails a hard requirement**; B should probably be struck from that file, or
- **we give up the Dockerfile** for herokuish/pack and get both requirements enforced by the
  platform — at the price of a `Procfile` in every hosted repo, a cold frontend build, and no escape
  hatch for a project whose build does not fit a buildpack.

## 7. Current lean

**Recommend, don't prohibit — and the recommendation is `B_herokuish`, per app, while
`B_dockerfile` stays the default and the fallback.** Reasoning, to be argued with:

- The one thing that would justify prohibiting the Dockerfile is `R_cache_per_project`, and
  `builder:set --global selected herokuish` buys that *only* by also breaking every project whose
  build a buildpack cannot express. On a demo farm of forks-of-the-same-starter that is probably
  most of them, but "probably" is not good enough to brick onboarding.
- A per-app `builder:set demo selected herokuish` is a one-word change in `create-app`, is visible in
  `builder:report`, and needs no new file in this repo. That makes "recommended" cheap and reversible
  in a way "prohibited" is not.
- The Vaadin frontend cache is the thing that could sink this. If a Vaadin production build under
  herokuish re-downloads node and `node_modules` every poll, herokuish fails `R_warm_deps` in
  practice even though it passes it for Maven — and then the answer is `B_dockerfile` + position A
  after all. **Do not decide this on paper.**
- `B_pack` is the strategically better bet (CNB is where Heroku went) and the tactically worse one
  (extra CLI, `repo:purge-cache` broken, docs that understate it). Revisit if herokuish's Java
  buildpack ever stops tracking JDK releases.
- `B_railpack` and `B_nixpacks`: record as roads not taken, with the `--cache-key`-is-mandatory
  finding preserved in `RESEARCH.md` — it is exactly the sort of silent trap that would eat a day.

## 8. Box punch list (adds to `RESEARCH.md` → *Questions only a box can answer*)

1. Does a nixpacks build on Dokku really start cold every time (temp-dir-derived cache key), and does
   `docker-options:add … build '--cache-key <app>'` fix it? — the §4.4 inference.
2. Build the same Vaadin app twice under `B_herokuish`. Is the second Maven resolve warm? Is the
   frontend (`~/.vaadin`, `node_modules`) warm, or re-downloaded? **This is the question that picks
   the winner.**
3. If the frontend is cold: does `dokku config:set demo npm_config_cache=/cache/npm` (plus whatever
   Vaadin honours for its node download) warm it, or does a `.buildpacks` with `heroku/nodejs` +
   `heroku/java` do it?
4. Does a Vaadin repo with a committed root `package.json` get mis-detected as a Node app under
   herokuish, and does `.buildpacks` reliably override it?
5. Under `B_pack`, confirm the cache volume name is per-app, and confirm `--cache … name=…` is
   honoured through `docker-options` (the docs deny the flag exists).
6. Does `builder:set --global selected herokuish` really make a committed `Dockerfile` inert — no
   warning, no partial detection?
7. Re-run the two-app `1.0-SNAPSHOT` pollution drill (`RESEARCH.md` #6) under `B_herokuish`; it should
   be impossible by construction, and that is worth demonstrating once.

## 9. Where this graduates to

- Detection order, the `head -n1` rule, the dockerfile-detect hack, the herokuish fallback, the
  `cache-$APP` volume, `repo:purge-cache` = `docker volume rm`, the pack arg allowlist (docs are
  wrong), the nixpacks temp-dir cache key, railpack's privileged-buildkitd requirement → **`RESEARCH.md`**,
  a new *Builders* subsection under *Deploying: builders and git*.
- The pick, and every road not taken above → **`DECISIONS.md`**, one entry (`D_builder`?), which
  `build-cache.md`'s eventual `D_build_cache` then depends on.
- "Your project needs a `Procfile` / here is how to onboard a Vaadin app" → **`README.md`**.
- `builder:set … selected` in `create-app` → **that script's comment header**.
- Then delete this file. If `B_dockerfile` wins, say so in the `D_` explicitly — "we looked at all
  seven and kept the Dockerfile" is a decision, and it is the one that stops this being re-opened.
