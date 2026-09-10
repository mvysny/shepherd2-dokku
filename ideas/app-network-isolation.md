# `Q_isolation` — which rung of app network isolation

Scratchpad for `Q_isolation` / `F_network_isolation` in `ideas/features-to-preserve.md`.

**Effectively answered 2026-09-10: one bridge network per app (`P_per_app`), as in both predecessors.**
The mechanics are researched (see *Networking and app isolation* in `RESEARCH.md`) and none of them
forbid anything; the operator then withdrew the one objection that made this a three-way choice (see
*The pool, withdrawn*), which leaves `P_icc_off` strictly dominated. Still in `ideas/` rather than
`DECISIONS.md` for one reason only: **it is contingent on `Q_proxy` picking nginx** — see *The one live
gate*. Promote both together.

The sibling repo answered the same question for Dokploy in
[`ideas/app-network-isolation.md`](https://github.com/mvysny/shepherd2-dokploy) (n+1 overlay networks).
**That answer does not transfer**, because the two boxes have different physics — the whole point of
this note is which parts of its reasoning survive.

## The requirement, on the same three axes as the sibling

| Axis | Mechanism here | Status |
|---|---|---|
| **app ↔ app**, non-public ports | network membership (`initial-network`), *or* a firewall rule — both are available here | **`P_per_app`**, below |
| **app → admin plane** | nothing to do: no dashboard, no control-plane container, no control-plane DB. Dokku is a host binary plus a git remote | **mostly moot** — collapses into the next row |
| **app → the host and the underlay** | a `DOCKER-USER` rule; unchanged by whichever rung we pick | **V2**, but it is the axis that now carries the admin-plane worry |

The reason for wanting any of this is unchanged from both predecessors: these are other people's example
projects and addons, mutually untrusted, on one box.

## Why the sibling's answer does not transfer

Its argument was that per-app networks are *forced* — Swarm has no `NetworkPolicy`, and intra-overlay
traffic never reaches the host's `FORWARD` chain, so a firewall cannot see app↔app traffic at all. Here
the second half is false: **a Dokku app's bridge lives in the root network namespace**, and Docker's own
`icc` handling and `DOCKER-ISOLATION-STAGE-1/2` chains are *implemented* in `FORWARD`. So the rung the
sibling proved impossible is available to us — which is why this was a real three-way choice here rather
than a forced move, and why it needed arguing rather than inheriting.

Everything else moves in our favour too — the three gates that note left open are all closed here:

- **its gate 1** (can a managed database leave the shared network?) — **yes, first-party**:
  `postgres:create -N|--initial-network`, plus `post-create-network` / `post-start-network`. An app and
  its own Postgres share a per-project network. `F_network_isolation` and `F_postgres` are not in
  tension. (One residue: `postgres:link` adds a legacy `--link`; punch-list item 9.)
- **its gate 2** (the proxy re-attachment outage, and the reconciler cron it forces) — **does not
  exist**: nginx is a host process dialling container IPs, and `dokku-event-listener` rebuilds config
  when an IP changes. No proxy sits on N networks. No eighth script.
- **its gate 3** (DNS on a joined network) — moot for routing, and satisfied anyway by Dokku's automatic
  `APP.PROC_TYPE` aliases.
- **its policy-vs-topology leak** (a project owner un-ticking isolation in the UI) — **no surface**:
  `network:set` needs `dokku` access, which is box ownership. See `Q_multi_user`; core Dokku has no
  per-app authorization to leak through.

### The pool, withdrawn

The one thing that moved against us was the address pool: bridge networks draw on Docker's *local* pool
(~30 before it walls) where Swarm overlays draw on 65 536. **Withdrawn as a concern by the operator,
2026-09-10** — it is raised at install time exactly as shepherd-traefik already raises it, so it is a
`daemon.json` stanza with precedent, not a design constraint. It stays worth *writing down* only
because it is install-time work (a daemon restart) that a later fix cannot retrofit cheaply.

This matters beyond bookkeeping: the pool was the only cost `P_icc_off` avoided. Without it, that rung
has no advantage left over `P_per_app` and several disadvantages, so the choice collapses.

## The three rungs

| | Mechanism | Cost | Kills app↔app? |
|---|---|---|---|
| `P_accept` | leave every app on the default bridge | none | **no** — a container IP is enough. Only discovery is harder (no DNS on the default bridge) |
| **`P_per_app`** ✅ | `network:create app-<id>` + `network:set <app> initial-network`, and `-N` on its Postgres | 2–3 converger lines per project; `daemon.json` pool enlargement at install | **yes**, topologically |
| `P_icc_off` | one shared network created with `enable_icc=false`, app↔app dropped in `FORWARD` | ~~no pool tax~~, no per-project state — but the network is ours to create, since `network:create` passes no driver options | **yes**, by filter |

**`P_per_app`**, for three reasons that are about kind rather than cost (and, since the pool objection
was withdrawn, with no counterweight left at all):

1. It is what both predecessors did (`D_network_per_project` in shepherd-traefik), so it is the option
   that needs no argument to preserve.
2. It is expressed entirely in Dokku's own vocabulary, which is this repo's standing bias
   (*Prefer a Dokku command to a `docker` command*). `P_icc_off` requires a hand-made
   `docker network create -o …` that Dokku will not make for us, i.e. a piece of box state that exists
   outside Dokku's model and must be re-created on reinstall.
3. Topology beats filtering when the thing you are protecting is other people's untrusted code: under
   `P_per_app` app A cannot *address* app B, so there is nothing left to filter and nothing to get
   wrong. `P_icc_off` is one iptables rule away from being silently off, and nothing in Dokku would
   notice.

`P_accept` should be rejected explicitly rather than by default, because it is the only rung that gives
up a feature both predecessors shipped.

`P_icc_off` is worth keeping in the record as a road not taken, since it is genuinely available here and
was structurally impossible on the Dokploy side. It only comes back if `P_per_app` hits something on the
box we have not predicted — and punch-list item 10 would have to pass first, since Dokku may not even
accept a network it did not create.

## The one live gate

**`Q_proxy` can foreclose this, and nothing else can.** The Traefik plugin contains no
network-attachment logic — no `docker network connect`, no read of the app's network properties `[src]`
— so under Traefik an app isolated on its own network is plausibly unreachable, and repairing that is
`shepherd-traefik-connect-networks` reincarnated as ours. Under nginx the question cannot arise, because
a host process needs no membership.

So: **nginx keeps `P_per_app` free; Traefik makes it cost either the feature or the script.** That is
punch-list item 12, ten minutes on the first box, and it is why this note should graduate at the same
time as `Q_proxy` rather than before it.

What Dokku does manage, and is worth stating in the `D_` entry because it is the whole reason the
predecessor's repair script has no successor: `initial-network` is a **persisted app property**
re-applied on every container creation, not a live `docker network connect` that a re-create discards.
Deploys, `ps:restart`, rebuilds and reboots all keep it, and `network:rebuild` re-asserts it on demand.
The converger re-asserting it every pass is therefore belt-and-braces rather than the mechanism — the
opposite of the Dokploy side, where re-assertion *is* the mechanism because the config surface is
user-editable.

## What no rung buys

- **The L7 front door stays open.** Any app can reach nginx by the bridge gateway IP and ask for another
  app's vhost with a `Host:` header. Unavoidable and harmless — that surface is public anyway. What
  isolation protects is *unpublished* ports: an app's own Postgres on 5432, a debug endpoint, an
  actuator.
- **The host stays reachable.** Every container keeps a route to its gateway regardless of membership,
  so sshd and anything else bound on the box are reachable from every app. This is the axis worth a
  `DOCKER-USER` rule, and it is where the sibling's admin-plane concern lands here.
- **Egress is unfiltered.**

So the honest wording of the requirement is **"no app can reach another app's non-public ports"** —
`F_network_isolation` says "or the admin plane", which is now a phrase about a thing that does not
exist.

## Where this lands on graduation

- The Dokku/Docker mechanics — three attachment phases, `network:create`'s lack of driver options, the
  datastore network flags, bridge-vs-overlay netfilter visibility, the local address pool → **already
  landed in `RESEARCH.md`** (*Networking and app isolation*, and the Traefik section's fourth
  restriction), along with punch-list items 2, 3, 9, 10, 11 and 12.
- `P_per_app`, with `P_accept` and `P_icc_off` as roads not taken → a **`D_isolation`** entry, citing
  `D_network_per_project` in shepherd-traefik as the inherited position, and **written together with
  `Q_proxy`'s entry** since it depends on nginx. *Consequences* to record: the `daemon.json` pool
  enlargement as an install step (with the daemon restart), per-project Postgres needing `-N` at
  `postgres:create` time, membership being Dokku-managed so no reconciler script exists, and the
  app→host axis staying open until the V2 `DOCKER-USER` rule.
- The `default-address-pools` edit and the app-count ceiling it lifts → **`README.md`** requirements /
  install steps.
- The reworded `F_network_isolation` → **`features-to-preserve.md`** while it lives.
