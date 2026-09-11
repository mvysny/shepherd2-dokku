# Making a Vaadin build fast under herokuish

Opened 2026-09-10, as the one thing `D_builder` decided *around* rather than solved. Successor to
`ideas/builder-choice.md` and `ideas/build-cache.md`, both deleted on graduation.

**This is now a v2 note.** On 2026-09-10 the operator answered the question the whole file hung on
(punch-list 15, for this farm rather than in general): **every app on this box uses Vaadin's
pre-compiled production bundle**, so there is no npm and no Vite run to cache. Candidate 1 below is the
answer, and it costs the box nothing — the frontend half of the build cache is **deferred to v2**, and
candidates 2 and 3 are what v2 reaches for on the first app that needs a real frontend build.

**The state of play.** `D_builder` prohibits the Dockerfile builder and builds every app with
herokuish. That gives a per-app `cache-$APP` volume mounted at `/cache`, and the Heroku Java buildpack
puts `maven.repo.local` inside it — so **Maven is warm and per-project, enforced.** Both hard
requirements are met for the Java half, which is the half every app on this box exercises.

**Gradle apps are a different, better story, and it is already settled** (2026-09-11). The Heroku
Gradle buildpack puts `GRADLE_USER_HOME` *inside* the cache volume, so dependencies, the Gradle build
cache, the wrapper's distribution and the JDK all come back warm — see `RESEARCH.md` → *Build
caching*. Candidates 2 and 3 below are Maven's problem specifically. What Gradle does not fix is the
frontend: that buildpack deletes `${CACHE_DIR}/.gradle/nodejs` after every successful build, on
purpose, so a Node toolchain fetched under `GRADLE_USER_HOME` is never kept either.

**What is left, for the app that eventually needs it.** A Vaadin production build that *does* run its
frontend is not only Maven: `vaadin-maven-plugin` downloads its own Node into `~/.vaadin`, runs
`npm install` into `node_modules`, and runs Vite. None of that is cached, because during the Maven
build `$HOME` is the fresh source checkout — the Java buildpack exports `-Duser.home=${build_dir}`
**[src]** — and the node buildpack that *would* have cached it isn't running. So for such an app the
expectation is: **Maven warm, frontend cold, every poll.**

**Two facts settled on 2026-09-10 that shape every candidate below:**

- **`/cache` is writable by the build.** herokuish chowns `$cache_path` to the unprivileged build user
  and runs `bin/compile` as that user **[src]**, so anything the build wants to put in the per-app
  cache volume, it can.
- **Every fix here *can* live in the repo rather than on the box.** herokuish copies a committed `.env`
  into the build environment and the Java buildpack exports the ENV_DIR before running Maven **[src]**
  — so `npm_config_cache`, `MAVEN_CUSTOM_OPTS` and friends are all app-side settings, the same way
  `.buildpacks` is. Whether it *should* live there is now an open question of its own — see *The `.env`
  question* below.

**And two that close doors.** *Providing* a system Node is not reachable: Node is **not** in
`heroku/heroku:24-build` — the stack ships no language runtimes, only build tooling **[docs]** — the
`heroku/nodejs` buildpack writes no `export` file carrying `PATH` **[src]**, so a multi-buildpack
doesn't put it on Maven's `PATH` either, and we do not build the herokuish image (`D_dokku`: upstream,
unforked). And **Vaadin has no knob for where `~/.vaadin` lives** (checked against the Vaadin 24 docs,
2026-09-10): Node is installed into `~/.vaadin/node`, or found globally, or installed project-locally at
`<project>/node` by `frontend-maven-plugin` (project-local wins over both). `require.home.node` /
`requireHomeNodeExec` only *forces* the `~/.vaadin` choice; nothing relocates it, and the project-local
option is useless here because the project directory *is* the throwaway build directory. So `~/.vaadin`
has to be moved by moving `user.home`. That is candidate 3, and it is a one-liner.

## The candidates, best first

### 1. Don't build the frontend at all — Vaadin's pre-compiled production bundle

**This is v1's answer.** Vaadin 24.1+ ships a pre-compiled production bundle and **skips npm and Vite
entirely** when the app uses no add-ons with frontend customisations and no custom JS/TS **[docs]**.
Every app on this box is in that category, so the whole problem is absent rather than solved. For an app
that does customise, `src/main/bundles/` is committed to source control by Vaadin's own guidance — so
the compiled bundle can travel in the repo rather than being rebuilt on our box, which keeps even that
app off candidates 2 and 3.

The consequence worth writing in `README.md`: **staying on the default bundle is the recommendation, not
just the status quo.** It is the difference between a rebuild that resolves Maven from a warm volume and
one that re-downloads Node every five minutes.

### 2. Warm the npm cache — v2

```dotenv
# .env, committed
npm_config_cache=/cache/npm
```

`npm_config_*` env vars are npm configuration by definition, and `/cache` is the per-app volume. It
doesn't stop `npm install` running, but it stops it going to the network — the expensive half.
Punch-list 14, now a v2 measurement. Watch for:

- **pnpm.** If Vaadin is configured to use pnpm, the knob is its store, not `npm_config_cache`.
- **`.npmrc` is the tempting alternative and is worse here.** `cache=${CACHE_PATH}/npm` reads nicely
  and npm does expand `${VAR}` — but recent pnpm deliberately **stopped** expanding env vars in a
  repository-controlled `.npmrc` (v10.34.2 / v11.5.3) as a supply-chain fix **[docs]**, and Vaadin's
  own recommended `.gitignore` excludes `.npmrc` anyway.

### 3. Relocate `~/.vaadin` into the cache volume — v2, and the same trick again

```dotenv
# .env, committed
MAVEN_CUSTOM_OPTS=-DskipTests -Pproduction -Duser.home=/cache/home
```

The buildpack puts `-Duser.home=${build_dir}` in `MAVEN_OPTS` (real JVM args) and then appends
`MAVEN_CUSTOM_OPTS` on the Maven command line, so the whole question is whether a Maven CLI `-D`
wins for `System.getProperty("user.home")` — Maven's CLI does copy `-D` properties into system
properties, so it should. If it does, `~/.vaadin` lands in the per-app cache volume and the node
download happens once. Check it doesn't move the `settings.xml` lookup somewhere unhelpful.
Punch-list 16, now a v2 measurement.

**If that doesn't work**, the platform-side fallback is a second mount:
`dokku docker-options:add demo build '-v /var/cache/shepherd2/demo:/shepherd-cache'` — the herokuish
path passes build options to `docker container create` **unfiltered** **[src]**, so arbitrary bind
mounts work, the path is ours and per-app, and the isolation property `D_builder` bought is kept.
Costs `destroy-app` a directory to remove, and puts per-app knowledge back on the box, which is why
it is the fallback and not the plan.

## The `.env` question — where v2's two lines should actually live

Raised by the operator on 2026-09-10, and it is the one genuinely open design question left here: a
committed `.env` hardcodes `/cache`, a path that exists only on this platform. **Does that break a
developer's own machine, which has no `/cache`?**

The reasoning says no, and the reasoning is what needs checking on a box:

- **`.env` is not a thing npm or Maven read.** Neither has any notion of the file; it takes effect only
  because *herokuish* copies it into the build environment **[src]**. On a dev machine `mvn -Pproduction`
  and `npm install` see nothing from it, so both lines are inert.
- **Vite does read `.env`, and it is still inert.** Vite loads `.env` from the project root, but only
  exposes `VITE_`-prefixed keys (to `import.meta.env`); a non-prefixed key is not published to
  `process.env` `[unverified]`. And Vite installs no packages, so an npm cache path could not matter to
  it even if it were visible.
- **The real exposure is any *other* tool that loads `.env` into the environment** — `docker compose`,
  an IDE env-file plugin, a `dotenv` CLI wrapper, or a framework that reads it (Quarkus does; Vaadin
  Boot does not). Under one of those, `npm install` would try to create `/cache/npm` on a machine where
  `/` is not writable, and fail with `EACCES` rather than falling back. That is the failure mode to
  reproduce before recommending the file.

**The shape that removes the question entirely, and is probably v2's answer: set them box-side and
globally.**

```bash
dokku config:set --global npm_config_cache=/cache/npm
```

`/cache` is per-app even though the variable is global, so isolation is unaffected; the value is
uniform across every Vaadin app on the box, so it is not really per-app knowledge; the repo stays
platform-agnostic and no dev machine ever sees it. The one thing to verify is whether **global** config
vars reach the herokuish build's ENV_DIR — the `pre-build` trigger bundles the *app's* config vars
**[src]**, and Dokku has a merged view (`config:keys --merged`), but that the merge is what the build
sees is `[unverified]`. If it is, the committed-`.env` route is a fallback for a repo whose owner wants
to carry the setting, not the recommendation.

## Rejected: a `heroku/nodejs` + `heroku/java` multi-buildpack

The obvious idea, and it doesn't work — recorded here and in `D_builder` so it isn't re-derived:

- the node buildpack's cache bracket opens and closes inside **its own** compile, which runs before
  Maven, so anything Maven creates is saved by nobody;
- it **prunes devDependencies** at the end of that compile — removing exactly the Vite that Vaadin
  then reinstalls;
- it writes no `export` file beyond a pnpm-store line **[src]**, so `heroku-buildpack-multi`
  propagates no `PATH` and the Node it installed isn't visibly on `PATH` when Maven runs;
- and `heroku-buildpack-multi` **fails the whole build** if any listed buildpack's `detect` fails
  **[src]**, so it hard-requires a committed `package.json`.

What it *would* have bought — `node_modules` and the npm cache in `${CACHE_DIR}/node/cache/`, plus
arbitrary relative paths via `cacheDirectories` in `package.json` **[src]** — is real, and is why the
idea keeps looking attractive. The ordering is what kills it. If someone finds a way to run a cache
save *after* the Java buildpack, this comes back.

## Related, and easy to test at the same time

- **Capping build CPU may not be a gap.** Same unfiltered path as 3:
  `dokku docker-options:add demo build '--cpus 2'`. If it works, the gap the old feature survey
  recorded here was a Dockerfile-builder artefact. Punch-list 17, and unlike 14/16 this one is a **v1**
  question.
- **Name the buildpack, never trust detection.** herokuish detects `nodejs` before `java` **[src]**
  and Vaadin's own guidance says to commit `package.json` **[docs]**, so a stock Vaadin repo is a Node
  app unless something says `heroku/java` — either a `.buildpacks` in the repo or
  `create-app --buildpack`. Settled, not open — it is in `D_builder` and in the README's project
  contract. Listed here only because it will be the first thing to go wrong on the box, and a Node
  build of a Java repo looks exactly like a caching bug.

## Where this graduates to

- The v1 recommendation — *stay on the pre-compiled bundle* — is already in **`README.md`**; nothing
  else here belongs there until v2 needs it.
- Whatever the box says about 1–3 → **`RESEARCH.md`** → *Build caching*, for the Dokku/buildpack half
  only. The Vaadin half (no knob for `~/.vaadin`, the bundle behaviour) has no durable home in this
  repo and stays here until it lands in README's onboarding recipe.
- If a fix ever costs a `docker-options` line per app → **`create-app`'s comment header**, and a line in
  `D_builder`'s *Consequences*.
- If it turns out the frontend genuinely cannot be cached and rebuild times are unacceptable →
  that is a `D_builder` re-read, not a new decision: the escape hatch it names is pack in v2.
- Then delete this file. It survives v1 only because the `.env`-versus-`config:set --global` question
  above is a live fork with no decision yet.
