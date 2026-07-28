# `classes/` — per-site class declarations (ADR-0036 / nwp/ops#153)

A site's **class** answers *"what IS this site, and therefore which data
invariants apply to it?"* It is the third per-site axis:

| Axis | Values | Question | Lives in |
|---|---|---|---|
| `canonical:` | `dev\|live\|prod` | where **content** is true | `nwp.yml` |
| `maturity:` | `incubating\|stabilizing\|production` | how carefully **code** moves | `nwp.yml` |
| **`class:`** | `member-paired\|member-standalone\|demo\|service` | **what the site IS** | **here (tracked)** |

## Why these declarations are tracked

`nwp.yml` is never committed and `sites/*` is gitignored. A claim that decides
whether the **Art.9 consent gate** applies to a live formation site has to be
reviewable in a merge request. So `classes/<site>.class.yml` is the
authoritative record; the `class:` keys in `sites/<site>/.nwp.yml` and `nwp.yml`
are *also honoured* purely as a cross-check, and a disagreement is
`contradictory:` and fails closed.

Same shape `lib/pair.sh` already uses for pair membership.

## The rule

> A class may **reclassify** a gate failure into an **evidenced exemption**.
> It may **never suppress** the scan that produces the failure.

`lib/moodle-gate.sh` consults the class in two ways, neither of which weakens
the scan. A fully-validated `posture: local` declaration **retargets** the
delegation requirement at the site's own consent source *before* the scan — a
call site is still mandatory, and delegating to the wrong source is refused
(so a local-posture declaration is the one class change that CAN newly refuse
an artifact, deliberately). The **exemption** path runs only after the scan has
failed: `none-stored` plus intact evidence reclassifies that failure, loudly and
ledgered. Nothing the class says can silence the scan or the evidence trail.

## Files

| File | What it is |
|---|---|
| `registry.yml` | the CLOSED set of four classes, the decision procedure, the invariant matrix, and the obligations attached to each Art.9 posture |
| `<site>.class.yml` | one site's declaration, plus the evidence backing any N/A it claims |

## Usage

```bash
pl class show                # every site's class + Art.9 posture
pl class check rgs           # which invariants apply, and what currently fails
pl class list                # the closed set and each class's invariants
pl class evidence rgs        # the evidence backing an exemption, re-checked now
pl class set <site> <class>  # declare (writes the tracked declaration)
```

Exit codes: `0` declared and consistent · `1` undeclared or an obligation broken
· `2` CANNOT-VERIFY — **never** treated as a pass.

## Adding a class to the closed set

Don't, unless the new class differs from all four in *which invariants apply* —
not merely in flavour. `public-readonly` and `internal` were considered and
merged into `service` for exactly this reason: identical invariant vectors.
`tests/unit/test-siteclass.bats` asserts the set is exactly four, so widening it
fails CI until the test is updated in the same reviewable change.
