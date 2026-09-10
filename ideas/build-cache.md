# Build cache — what `Q_cache` still has to decide

Split out of `ideas/features-to-preserve.md` on 2026-09-10 so that `Q_cache` stops being a five-way
menu nobody wants to pick from. **Nothing here is decided.** When it is, the pick becomes a `D_` entry
(probably `D_build_cache`), the Dokku facts below that survive verification go to `RESEARCH.md` →
*Build caching*, the operator recipe goes to `README.md`, and this file is deleted.

**Everything below assumes the Dockerfile builder, and that assumption is now itself in question** —
see `ideas/builder-choice.md`, which asks which of Dokku's seven builders we should standardise on.
Two of its findings land directly here: per-project cache isolation is *enforceable* under
herokuish/pack/nixpacks/railpack and only *conventional* under the Dockerfile, and position **B**
below (empty mounts every build) is now ruled out because a warm dependency cache has been promoted
to a hard requirement. Settle `builder-choice.md` first; if the Dockerfile survives it, resume here.

Background that is *not* restated here: `D_no_shared_cache` in shepherd-traefik (the two hazards,
corruption vs pollution, and why the `mvn install` path is the one that bites), and `RESEARCH.md` →
*Build caching* / *`docker-options` and its sharp edges* (the allowlist, the buildpack builders'
`cache-$APP` volume, buildkitd GC).

## What is already settled and should not be re-argued

- **Corruption is fixed by serial builds.** `shepherd2 poll` is one loop under a lock file
  (`F_build_serial`), so two builds never touch one mount at once. Only *pollution* is left.
- **The buildpack builder is out.** It is the only thing that closes the gap completely (Dokku names the
  cache volume, the app cannot) but it costs `F_build_dockerfile`. Road not taken, keep it in the `D_`.
- **The prune cron stays weekly, not nightly** — the purge cadence is the cache's real lifetime.

## 1. The five positions are a false menu

With a Dockerfile builder, **nothing on the original list enforces mount isolation**:

| position | what it actually is |
|---|---|
| 1 status quo, `id=` convention | convention |
| 2 layer cache only, no mounts | convention — nothing stops an app writing an unkeyed `RUN --mount=type=cache` |
| 3 Nexus / repo proxy | cooperation too: each app's `settings.xml` must point at it, and Central is https so it cannot be forced (`D_no_shared_cache` says exactly this) |
| 4 buildpack builder | enforced, but costs the Dockerfile — out |
| 5 accept and document | convention, stated honestly |

So 1, 2 and 5 are the same lever set to different recipes, 3 is a later scaling answer rather than an
isolation answer, and 4 is gone. **The one enforcing move that was not on the list:**

> the poll loop runs `docker buildx prune --filter type=exec.cachemount -f` between builds, so every
> build's cache mounts start empty.

That is position 2 made real by the platform instead of by the recipe. The app may write any mount it
likes; it is always cold. The per-project layer cache still carries a `COPY pom.xml` +
`mvn dependency:go-offline` layer, so Maven re-downloads only on a pom change. What it costs is the
npm/node half of a Vaadin production build (`~/.vaadin`, `node_modules`), which re-downloads every
build because it depends on `src`. *(`exec.cachemount` as a `--filter type=` value is from memory —
**verify on the box**.)*

**So the real fork is two-way:**

- **A. Convention + honest README.** `create-app` emits `--build-arg CACHE_ID=<app>`; the README
  Dockerfile recipe says `--mount=type=cache,id=m2-$CACHE_ID,target=/root/.m2`; the README states
  plainly that cache mounts are shared box-wide and projects are not isolated at the artifact level.
  Zero glue beyond one `docker-options:add` line. Gap stays open, as today.
- **B. Empty mounts every build.** One prune line in `poll`. Gap closed by the platform. Slower on
  dependency changes; makes Dokku's own documented "BuildKit directory caching" recipe a no-op on our
  box, which will surprise an operator who reads Dokku's docs.

Two inputs that did not exist when `D_no_shared_cache` was written, both pushing towards **A**:

- **`D_single_operator`.** The operator reads every Dockerfile at `create-app` time — creation is a
  hand-run script. A convention policed at onboarding by one person is much stronger than the same
  convention in a self-service farm, which is the setting the predecessor's "cooperation, never a
  boundary" was written for. The accidental `mvn install` case is *fully* fixed by `id=` on repos we own;
  the hostile case was accepted the day we chose to host arbitrary Dockerfiles at all.
- **BuildKit's default GC policy** targets exactly `type==exec.cachemount` (plus `source.local` and
  `source.git.checkout`) with `keepDuration = 48h`. *(From memory of the buildx default policy —
  **verify**; `RESEARCH.md` currently carries the softer "reported ~48 h".)* If the poll is weekly,
  mounts are evicted between every two polls **today**, unless the install sets a GC policy. Under A
  that GC step is mandatory or the feature is a placebo; under B it is moot.

Current lean: **A**, with B recorded in the `D_` as the road not taken *and* as the one-line emergency
lever if pollution is ever observed. But not decided.

## 2. Do we want per-project `--cache-to type=local` dirs at all?

`features-to-preserve.md` celebrates that the per-app `--cache-to`/`--cache-from` migrates verbatim.
It does, but ask whether it is *wanted*, because the reason it existed is not the reason it is being
kept:

- **The layer cache is content-keyed**, so sharing the daemon's single builder cache between projects is
  safe. A hit needs identical parent digest + instruction + copied-file digests, at which point the two
  builds are the same build. Per-project layer dirs are **not an isolation measure**; `D_no_shared_cache`
  itself says the layer cache is content-keyed, and its enforcement argument is really about mounts.
- What the per-project dirs *do* buy: **purge granularity** (clear one project's cache) and **immunity
  from box-wide GC / prune** (one project's churn cannot evict another's layers).
- What they cost:
  - **The containerd image store must be enabled** — the default `docker` driver refuses `--cache-to`
    export otherwise ("Cache export is not supported for the docker driver"). That is why
    shepherd-traefik's `install` turned `containerd-snapshotter` on. Whether Dokku 0.38 is happy on that
    store is **`[unverified]`** and is really *Questions only a box can answer* #1 in `RESEARCH.md`.
    Note the failure mode is an **error**, not a silent no-op, which is at least kind.
  - `destroy-app` must delete a root-owned directory under `/var/cache/shepherd2/<app>/` (symmetry).
  - `type=local` dirs are never GC'd by buildx — old blobs stay when a new index is written — so they
    grow without bound and force the weekly wipe.
  - `mode=max` vs `min`, and the dir location, are two more knobs nobody wants.

**The alternative:** emit no cache flags at all. Set a `builder.gc` policy in `/etc/docker/daemon.json`
with `defaultKeepStorage` sized to the box and a mount `keepDuration` longer than the poll interval;
prune weekly with a storage floor rather than a full wipe. Fewer moving parts, no containerd-store
dependency, and punch-list #1 evaporates.

Decide this **on the box, not on paper**: build one Vaadin app twice through `git:sync` with no cache
flags and see whether the second build is warm; then repeat after a `docker system prune` to see what
the per-project dir would have saved.

## 3. Pin the poll interval first

Every cadence answer depends on a number that is not written down anywhere yet:

- BuildKit's mount `keepDuration` must exceed it, or mounts are always cold (see §1).
- `shepherd2-clearcache` weekly + `shepherd2 poll` weekly: if the wipe lands right before the poll,
  **every build is cold every time**. Either order the two crons deliberately or prune with
  `--keep-storage` / `--reserved-space` instead of wiping.
- `builds:set --global retention 20` was judged "right for a weekly poll" in `Q_build_history`.

The predecessor's Jenkins poll cadence is the starting point; look it up rather than assume weekly.

## Small things that fall out regardless

- The README recipe **must override Dokku's own documented example**, which mounts `$HOME/.m2`
  unkeyed. An operator following upstream docs produces the shared mount.
- `--build-arg CACHE_ID` expanding inside `--mount id=` — long broken
  ([moby/buildkit#2909](https://github.com/moby/buildkit/issues/2909)), reported fixed; **verify on the
  box**, and treat a silently unexpanded `id` as the failure to look for. Load-bearing for A.
- `--builder` is on the Dockerfile builder's allowlist, which looks like "one buildx builder per
  project" — the enforcing option `D_no_shared_cache` rejected on disk cost. **Dead here anyway**: a
  `docker-container` builder needs `--load` / `--output` to land the image in the daemon, neither is on
  the allowlist, and they would be dropped silently. Only the default `docker` driver builder exists.
  *(Reasoning, not tested.)* Worth one line in `RESEARCH.md` so nobody spots `--builder` and repeats it.
- `DOKKU_GLOBAL_BUILD_ARGS` is appended to every build after the per-app options — a box-wide place a
  cache-related flag could live if it turns out to be the same for every app.

## Box punch list (adds to `RESEARCH.md` → *Questions only a box can answer*)

1. Does `docker buildx prune --filter type=exec.cachemount` exist and do what §1-B needs?
2. What is the box's actual default builder GC policy (`docker buildx du` after a week of polls)?
3. Does a second `git:sync --build` of the same app hit the daemon's layer cache **without** any
   `--cache-from`? If yes, §2's alternative is live.
4. Does `--cache-to type=local` work at all on Dokku's Docker as installed, or does it demand the
   containerd image store? Does Dokku misbehave on that store?
5. Does `$CACHE_ID` expand inside `--mount=type=cache,id=…`?
6. The two-app `1.0-SNAPSHOT` pollution drill (already #6 in `RESEARCH.md`), run once under A and once
   under B.
