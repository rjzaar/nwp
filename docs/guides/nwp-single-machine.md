# nwp on one machine — the AI-free core as the simplest way in

> **Status:** REFRAMING + an open scope decision. The AI-free `nwp-server` build
> already exists (see [`ver-setup.md`](ver-setup.md)); this guide reframes *what it
> is for* and surfaces one decision for the operator, **not** a shipped feature.
> **Date:** 2026-07-01
> **Audience:** an operator who wants to run nwp on a single box, and the operator
> deciding the build's scope.

## The reframing

The AI-free `nwp-server` artifact was designed as the **prod-agent / `ver`** build
target — the minimal, separately-signed thing that runs on a production host or the
offline custodian (ADR-0022 / ADR-0024). But look at what it actually *is*: a
self-contained set of commands that can **verify, apply, roll back, publish, and
back up** a Drupal site, with **no AI, no fleet, no SaaS, and no control plane**.

That is also **the simplest possible way to use nwp**: one machine, offline-friendly,
nothing to trust but a signature. The same build that exists for threat-model reasons
at the top of the stack is also the natural **entry point** at the bottom of it.

So it is worth stating plainly: **the AI-free build is both the prod-trust floor and
the newcomer's front door.** They are the same artifact viewed from two ends.

## nwp as concentric tiers

Think of nwp as three rings you add outward, each optional:

```
        ┌─────────────────────────────────────────────────────────┐
        │  (c) AI self-healing loop + fleet                        │
        │      pl status 🔴 → pl issue → agent-loop (issue→MR)     │
        │      → human merge approval → signed bundle → prod       │
        │      pulls+verifies+applies → re-test. Multi-host.       │
        │   ┌───────────────────────────────────────────────────┐ │
        │   │  (b) Oversight                                    │ │
        │   │      pl status · pl rag · pl todo · pl issue ·    │ │
        │   │      pl audit — one "what needs attention" view.  │ │
        │   │   ┌─────────────────────────────────────────────┐ │ │
        │   │   │  (a) Single-machine AI-free CORE            │ │ │
        │   │   │      verify · apply · rollback · publish ·  │ │ │
        │   │   │      backup + local status.                 │ │ │
        │   │   │      No AI. No fleet. No SaaS.              │ │ │
        │   │   └─────────────────────────────────────────────┘ │ │
        │   └───────────────────────────────────────────────────┘ │
        └─────────────────────────────────────────────────────────┘
```

### (a) The single-machine AI-free core — the entry point

The `nwp-server` capability set on one box (see [`ver-setup.md`](ver-setup.md) §1):

- **verify** a signed bundle (`lib/minisign.sh`, `lib/bundle-verify.sh`);
- **apply** it with maintenance mode and fail-rollback (`pl rollback …`);
- **rollback** to the previous release/DB;
- **publish** a sanitized artifact behind a **fail-closed PII gate**
  (`pl publish`, `lib/pii-gate.sh`);
- **backup** (raw restic snapshot, ADR-0025) with `pl server-backup`;
- **local status** (JSON) — *the one verb still to be added to the artifact*.

Build it with `pl build-server`; the deny-scan guarantees the AI/CI/SaaS code is
simply **not present**. This is the whole install — nothing else required.

### (b) Add oversight

Layer the read-only oversight commands on top when one site becomes several:

- `pl status` — per-site table, per-cell health;
- `pl rag` — per-site 🔴/🟠/🟢 rollup (🔴 = security, 🟠 = needs work, 🟢 = clear),
  unified JSON envelope;
- `pl todo` — one priority-ranked work queue;
- `pl audit` — read-only composer-advisory awareness per site;
- `pl issue` — read/write CLI against the ops issue tracker.

These *observe and rank*; they do not touch prod. See
[`using-nwp.md`](using-nwp.md) for the full command map.

### (c) Add the AI self-healing loop + fleet

Only at the outer ring do the AI / CI / SaaS-touching pieces appear: the agent-loop
(issue → MR), multi-host deploys, and the control loop of
[OPERATING-MODEL concepts](using-nwp.md#the-self-driving-loop). Human merge approval
is the boundary (ADR-0024 / decision A14). A single-machine operator never needs this
ring.

## The open decision: how wide should the single-machine build be?

Here is the honest tension, surfaced as a **decision, not a fait accompli**:

The `prod-agent` build is deliberately **narrow** — five (soon six) capabilities and
nothing else — because on a production host *every extra verb is extra attack surface*
(ADR-0024's success metric is literally "the capability set is exactly these verbs —
no `install`, no `ai *`, no SaaS"). That narrowness is a **feature** for prod.

But a **single-machine newcomer** plausibly wants more of the ordinary local
lifecycle than a hardened prod agent does — for example `pl install`, `pl backup`,
`pl restore`, `pl status` as first-class local commands, so they can stand a site up
and manage it without the full AI/fleet `nwp`.

So the scope question is real:

> **Open decision (operator):** Should "single-machine nwp" be
> **(1)** exactly the prod-agent artifact (narrowest; the newcomer uses full `nwp`
> for install/day-2 and only adopts the AI-free build for the deploy/backup path), or
> **(2)** a slightly wider AI-free build that adds local `install` / `backup` /
> `restore` / `status` for a self-contained one-box experience?

This is a **build/include decision**: option (2) means adding those command scripts
to `build/nwp-server.include` (and keeping the deny-scan green — some, like
`scripts/commands/status.sh`, currently carry a SaaS block that must be split first;
see the note at the top of `build/nwp-server.include`). It is *mechanically* the
same lever as everything else in that allowlist.

**Recommendation (for discussion, not decided):** keep the *prod-agent* target
narrow and unchanged (its narrowness is load-bearing for the threat model), and if a
one-box experience is wanted, express it as a **separate, slightly wider build
target** (e.g. `nwp-solo`) driven by its own include file — so the newcomer's
convenience never widens the prod agent's attack surface. Whether that second target
is worth maintaining is the operator's call.

## Related

- [`ver-setup.md`](ver-setup.md) — the artifact, its build, and its capabilities in detail
- [`using-nwp.md`](using-nwp.md) — the whole-system map and command surface
- [ADR-0022](../decisions/0022-nwp-verifier-binary-split.md) · [ADR-0024](../decisions/0024-self-deploying-prod-agent.md) — why the build is narrow and AI-free
- `build/nwp-server.include` — the allowlist that defines the artifact's scope
