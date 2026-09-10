# Harden container egress — the axis `D_isolation` deferred

Split out of the app-network-isolation note when it graduated into `D_isolation` (2026-09-10). That
decision walls app off from app; **this note is the axis it left open**, and it is the one that still
has no decision.

## The problem

Network membership does not hide the host. Every container keeps a route to its bridge gateway
(`172.17.0.1` or the per-app network's equivalent), so from inside any app:

- **the host's own ports are reachable** — sshd, and anything an operator ever binds to `0.0.0.0`;
- **the underlay is reachable** — a `10.x` private network the VM sits on, other VMs of the provider,
  the provider's metadata endpoint;
- **the internet is reachable**, unrestricted, outbound.

None of this changes with per-app networks, because none of it is about membership. It is also where the
Dokploy sibling's "app → admin plane" axis lands here: Dokku has no dashboard to unpublish, so what is
left of that concern is exactly "what can a hosted container reach that is not another app".

Egress being open is *mostly fine and partly the point* — apps fetch dependencies at build time and call
third-party APIs at runtime. So this is not "block egress", it is "block the parts that are not the
internet".

## The mechanism, and why it is available here

A `DOCKER-USER` rule. Docker inserts that chain into `FORWARD` ahead of its own rules specifically so an
operator can filter container traffic without fighting the daemon, and rules there survive a daemon
restart in a way that hand-edited `FORWARD` rules do not.

This works because a Dokku app's bridge lives in the **root network namespace**, so container egress
traverses the host's `FORWARD` chain. (The same fact that made `enable_icc=false` a real option in
`D_isolation`. On the Swarm sibling, intra-overlay traffic is invisible to host netfilter — but *egress*
through `docker_gwbridge` is not, so the rule shape transfers even though the app↔app reasoning does
not.)

Rough shape, to be argued with rather than copied:

```
# in DOCKER-USER, before the RETURN
-i <bridge> -d 169.254.169.254/32 -j DROP     # cloud metadata endpoint
-i <bridge> -d 10.0.0.0/8         -j DROP     # the underlay
-i <bridge> -d <host gateway ip>  -j DROP     # the box itself — but see the caveats
```

## Open questions

- **What is the interface match**, given `D_isolation` creates a bridge per project? `-i br-*` is not a
  thing iptables understands as a glob in every version; the alternatives are matching on the *source*
  subnet (which the enlarged `default-address-pools` makes predictable) or generating one rule per
  network in the converger (which puts firewall state on the per-project path — unattractive).
  **Probably the pool subnet, which is an argument for choosing that pool deliberately** rather than
  letting Docker pick.
- **Does dropping traffic to the gateway IP break anything Dokku needs?** DNS is the obvious risk: if
  the box runs a resolver on the gateway address, and containers are handed it in `/etc/resolv.conf`,
  a blanket gateway DROP breaks name resolution for every app. This is the caveat the sibling's note
  flagged and never resolved. Likely answer: drop per-port rather than per-host, or allow 53.
- **Does it break `dokku-postgres` or any linked service?** Those are container-to-container, so they
  should not touch `DOCKER-USER` at all — but the `--link` residue in `postgres:link` is already
  `[unverified]` (`RESEARCH.md` punch-list item 9) and this is a second reason to pin it down.
- **Where does the rule live so a reinstall reproduces it?** `iptables-save`/`iptables-restore` state is
  not in this repo. Options: a `shepherd2-install` step writing an `iptables-persistent` rules file, or
  a tiny systemd unit. Whichever — *"anything the box must survive a reinstall of belongs in this repo"*
  (`CLAUDE.md`), so it cannot stay a command someone typed once.
- **Is it worth it at all**, given the threat model is "someone's demo app is compromised"? The honest
  case for yes is the metadata endpoint: on a cloud VM that single address can hand out credentials for
  the whole account, and it is one rule.

## Punch list additions

For `RESEARCH.md` → *Questions only a box can answer*, once these are sharp enough to be worth a box's
time (they are not yet — every one of them is a question about *our* configuration rather than about
Dokku, so several may belong nowhere near that file):

- What does a container's `/etc/resolv.conf` actually contain on a Dokku box — the gateway, or an
  upstream resolver? Decides whether the gateway DROP is safe.
- Does `bootstrap.sh` or Dokku install any `DOCKER-USER` rules of its own that ours must not clobber?

## Where this lands on graduation

- The rule, its interface/subnet match and the reinstall mechanism → a **`D_egress`** entry, plus the
  step itself in **`README.md`** and in `shepherd2-install`'s comment header.
- Anything learned about Docker's or Dokku's own netfilter behaviour → **`RESEARCH.md`**.
- If it is decided *against*: a one-line road-not-taken inside `D_isolation`'s *Consequences*, where the
  open axis is already named — not a `D_` of its own.
