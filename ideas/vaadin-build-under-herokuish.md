# Making a Vaadin build fast under herokuish

Opened 2026-09-10, as the one thing `D_builder` decided *around* rather than solved. Successor to
`ideas/builder-choice.md` and `ideas/build-cache.md`, both deleted on graduation.

**The state of play.** `D_builder` prohibits the Dockerfile builder and builds every app with
herokuish. That gives a per-app `cache-$APP` volume mounted at `/cache`, and the Heroku Java buildpack
puts `maven.repo.local` inside it — so **Maven is warm and per-project, enforced.** Both hard
requirements are met for the Java half.

**What is left.** A Vaadin production build is not only Maven. `vaadin-maven-plugin` downloads its own
Node into `~/.vaadin`, runs `npm install` into `node_modules`, and runs Vite. None of that is cached,
because during the Maven build `$HOME` is the fresh source checkout — the Java buildpack exports
`-Duser.home=${build_dir}` **[src]** — and the node buildpack that *would* have cached it isn't
running. So today's expectation is: **Maven warm, frontend cold, every poll.**

Everything below is a candidate fix. None is verified; the box punch list is items 13–17 in
`RESEARCH.md`.

**Two facts settled on 2026-09-10 that shape every candidate below:**

- **`/cache` is writable by the build.** herokuish chowns `$cache_path` to the unprivileged build user
  and runs `bin/compile` as that user **[src]**, so anything the build wants to put in the per-app
  cache volume, it can.
- **Every fix here can live in the repo, not on the box.** herokuish copies a committed `.env` into
  the build environment and the Java buildpack exports the ENV_DIR before running Maven **[src]** — so
  `npm_config_cache`, `MAVEN_CUSTOM_OPTS` and friends are all app-side settings. That keeps
  `create-app` generic, the same way `.buildpacks` does. `dokku config:set` remains the override.

**And one that closes a door:** *providing* a system Node is not reachable. Node is **not** in
`heroku/heroku:24-build` — the stack ships no language runtimes, only build tooling **[docs]** — the
`heroku/nodejs` buildpack writes no `export` file carrying `PATH` **[src]**, so a multi-buildpack
doesn't put it on Maven's `PATH` either, and we do not build the herokuish image (`D_dokku`:
upstream, unforked). So Vaadin's "use the Node already on `PATH`" path is closed, and `~/.vaadin` has
to be *relocated* rather than made unnecessary. That is candidate 3, and it is a one-liner.

## The candidates, best first

### 1. Don't build the frontend at all — Vaadin's pre-compiled production bundle

Vaadin 24.1+ ships a pre-compiled production bundle and **skips npm and Vite entirely** when the app
uses no add-ons with frontend customisations and no custom JS/TS **[docs]**. For an app that stays on
the default bundle the whole problem evaporates, and for one that doesn't, `src/main/bundles/` is
committed to source control by Vaadin's own guidance — so the compiled bundle can travel in the repo
rather than being rebuilt on our box.

If most of the farm is default-bundle, this is the answer and 2–4 are contingency. **Find out first**
(punch-list 15) — it decides how much of the rest is worth doing.

### 2. Warm the npm cache — one line in the repo

```dotenv
# .env, committed
npm_config_cache=/cache/npm
```

`npm_config_*` env vars are npm configuration by definition, and `/cache` is the per-app volume. It
doesn't stop `npm install` running, but it stops it going to the network — the expensive half.
Punch-list 14. Watch for:

- **pnpm.** If Vaadin is configured to use pnpm, the knob is its store, not `npm_config_cache`.
- **`.npmrc` is the tempting alternative and is worse here.** `cache=${CACHE_PATH}/npm` reads nicely
  and npm does expand `${VAR}` — but recent pnpm deliberately **stopped** expanding env vars in a
  repository-controlled `.npmrc` (v10.34.2 / v11.5.3) as a supply-chain fix **[docs]**, and Vaadin's
  own recommended `.gitignore` excludes `.npmrc` anyway. Prefer `.env`.
- Hardcoding `/cache` couples the repo to this platform. That is a real cost of doing it app-side;
  `$CACHE_PATH` is the portable name but only usable where expansion happens.

### 3. Relocate `~/.vaadin` into the cache volume — the same trick again

```dotenv
# .env, committed
MAVEN_CUSTOM_OPTS=-DskipTests -Pproduction -Duser.home=/cache/home
```

The buildpack puts `-Duser.home=${build_dir}` in `MAVEN_OPTS` (real JVM args) and then appends
`MAVEN_CUSTOM_OPTS` on the Maven command line, so the whole question is whether a Maven CLI `-D`
wins for `System.getProperty("user.home")` — Maven's CLI does copy `-D` properties into system
properties, so it should. If it does, `~/.vaadin` lands in the per-app cache volume and the node
download happens once. Check it doesn't move the `settings.xml` lookup somewhere unhelpful.
Punch-list 16.

**If that doesn't work**, the platform-side fallback is a second mount:
`dokku docker-options:add demo build '-v /var/cache/shepherd2/demo:/shepherd-cache'` — the herokuish
path passes build options to `docker container create` **unfiltered** **[src]**, so arbitrary bind
mounts work, the path is ours and per-app, and the isolation property `D_builder` bought is kept.
Costs `destroy-app` a directory to remove, and puts per-app knowledge back on the box, which is why
it is the fallback and not the plan.

**Together, 2 and 3 are the whole fix, and both live in the app's repo** — `.buildpacks` picks the
buildpack, `Procfile` names the process, `system.properties` pins the JDK, `.env` points the two
caches at the volume Dokku already mounts. The box learns nothing per-app. Whether that is *enough*
— i.e. whether a second build is actually fast — is punch-list 13.

### 4. Rejected: a `heroku/nodejs` + `heroku/java` multi-buildpack

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

- **`F_build_cpu_limit` may not be a gap.** Same unfiltered path as 3:
  `dokku docker-options:add demo build '--cpus 2'`. If it works, the feature survey's `🕳️` was a
  Dockerfile-builder artefact. Punch-list 17.
- **Name the buildpack, never trust detection.** herokuish detects `nodejs` before `java` **[src]**
  and Vaadin's own guidance says to commit `package.json` **[docs]**, so a stock Vaadin repo is a Node
  app unless something says `heroku/java` — either a `.buildpacks` in the repo or
  `create-app --buildpack`. Settled, not open — it is in `D_builder` and in the README's project
  contract. Listed here only because it will be the first
  thing to go wrong on the box, and a Node build of a Java repo looks exactly like a caching bug.

## Where this graduates to

- Whatever the box says about 1–3 → **`RESEARCH.md`** → *Build caching* (Dokku/buildpack behaviour) and
  **`README.md`** (the onboarding recipe: which config vars a Vaadin app needs).
- If a fix costs a `docker-options` line per app → **`create-app`'s comment header**, and a line in
  `D_builder`'s *Consequences*.
- If it turns out the frontend genuinely cannot be cached and rebuild times are unacceptable →
  that is a `D_builder` re-read, not a new decision: the escape hatch it names is pack in v2.
- Then delete this file.
