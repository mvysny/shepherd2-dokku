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

## The candidates, best first

### 1. Don't build the frontend at all — Vaadin's pre-compiled production bundle

Vaadin 24.1+ ships a pre-compiled production bundle and **skips npm and Vite entirely** when the app
uses no add-ons with frontend customisations and no custom JS/TS **[docs]**. For an app that stays on
the default bundle the whole problem evaporates, and for one that doesn't, `src/main/bundles/` is
committed to source control by Vaadin's own guidance — so the compiled bundle can travel in the repo
rather than being rebuilt on our box.

If most of the farm is default-bundle, this is the answer and 2–4 are contingency. **Find out first**
(punch-list 15) — it decides how much of the rest is worth doing.

### 2. Warm the npm cache — one config var, no new machinery

`/cache` is the per-app volume and the build can write to it, so:

```bash
dokku config:set demo npm_config_cache=/cache/npm
```

Config vars reach the build through herokuish's ENV_DIR **[src]**, so this needs nothing else. It
doesn't stop `npm install` running, but it stops it going to the network — which is the expensive
half. Watch for: Vaadin choosing **pnpm** rather than npm (pnpm reads `store-dir` /
`PNPM_HOME`, not `npm_config_cache`), and npm's cache being useless if Vaadin passes `--no-cache`
anywhere. Punch-list 14.

### 3. Relocate `~/.vaadin` into the cache volume

The node download is the other recurring cost. Two ways in, both unverified (punch-list 16):

- `dokku config:set demo MAVEN_CUSTOM_OPTS="-DskipTests -Pproduction -Duser.home=/cache/home"` — the
  buildpack puts `-Duser.home=${build_dir}` in `MAVEN_OPTS` (JVM args) and then appends
  `MAVEN_CUSTOM_OPTS` on the Maven command line, so the question is simply whether a Maven CLI `-D`
  wins for `System.getProperty("user.home")`. If it does, `~/.vaadin` lands in the cache volume and
  this is a one-liner. Check it doesn't also move the `settings.xml` lookup somewhere unhelpful.
- A second mount: `dokku docker-options:add demo build '-v /var/cache/shepherd2/demo:/shepherd-cache'`.
  The herokuish path passes build options to `docker container create` **unfiltered** **[src]**, so
  arbitrary bind mounts work — and the path is set by us, per app, on the build command, so it keeps
  the isolation property `D_builder` bought. Costs `destroy-app` a directory to remove.

Vaadin also only *forces* `~/.vaadin/node` when `require.home.node=true`, which is false by default —
if a supported Node is already on `PATH`, Vaadin uses it and downloads nothing **[docs]**. Getting a
Node onto `PATH` without the node buildpack (see below) probably means installing one on the box, in
the herokuish image, which we don't build. Park it.

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
- **Pin the buildpack, never trust detection.** herokuish detects `nodejs` before `java` **[src]** and
  Vaadin's own guidance says to commit `package.json` **[docs]**, so a stock Vaadin repo is a Node app
  unless `create-app` runs
  `dokku buildpacks:set <app> https://github.com/heroku/heroku-buildpack-java`. This is settled, not
  open — it is in `D_builder` and belongs in `create-app`. Listed here only because it will be the
  first thing to go wrong on the box, and it looks exactly like a caching bug.

## Where this graduates to

- Whatever the box says about 1–3 → **`RESEARCH.md`** → *Build caching* (Dokku/buildpack behaviour) and
  **`README.md`** (the onboarding recipe: which config vars a Vaadin app needs).
- If a fix costs a `docker-options` line per app → **`create-app`'s comment header**, and a line in
  `D_builder`'s *Consequences*.
- If it turns out the frontend genuinely cannot be cached and rebuild times are unacceptable →
  that is a `D_builder` re-read, not a new decision: the escape hatch it names is pack in v2.
- Then delete this file.
