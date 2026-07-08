# P62: Documentation-Truth Gate

**Status:** PROPOSED
**Created:** 2026-05-11
**Author:** Robert Karsten Zaar (with AI assistance)
**Priority:** Medium (does not gate the public release; catches drift between central docs and machine reality)
**Depends On:** None (this proposal is independent of P61, F32–F34)
**Breaking Changes:** No (additive; nightly cron job + report file)
**Estimated Effort:** ~4 phases; one weekend
**Architecture decision records:** none yet (sibling concern to [ADR-0021](../decisions/0021-public-only-repo-scope.md))

> **Why this proposal exists.** [P61](P61-leakage-hygiene-ci.md) prevents *secret* drift from the private layer into the public layer; P62 prevents *truth* drift between the private central index and the machines it describes. The two are cousins: same shape (rule set + scan + gate), different target. P62 is a defensive measure against the failure mode that surfaced during the SD ITD ep-4 transcription resumption on 2026-05-10/11, where `~/central/INDEX.md §5.3 sd` was host-ambiguous and `~/sd/scripts/sync_transcripts.sh` named a stale remote — both because nothing automatically verifies that what central claims is still true.

---

## 1. Executive Summary

A `central-verify` script (Bash or Python; lives at `~/central/bin/central-verify`) walks every `~/central/<project>.md` file and confirms its assertions hold against the machines listed therein. Assertions checked:

1. **Host pin.** Each `<project>.md` declares one or more canonical hosts in its `## Cluster placement` section. The script SSHs to each named host and confirms the project's root path exists.
2. **Script paths.** Every fenced or table-listed script path (e.g. `ai-host:$HOME/sd/scripts/build_best.py`) resolves to an existing, readable file.
3. **Sync-target sanity.** Any `rsync`/`scp` source referenced in a `<project>.md` or in a script under `~/<project>/scripts/` resolves to a host that *currently* hosts the named directory. Stale rsync targets (e.g. `ci-host` for SD) are flagged.
4. **Status freshness.** If a `<project>.md` declares "active" status, the project's root directory shows a `git log` (or filesystem mtime) within the last 90 days. Otherwise flag as "claimed active, likely stale".

Findings are written to `~/central/drift_<date>.md` and (optionally) to `~/.local/state/central-verify.json` for programmatic consumption.

The script is run nightly by a systemd timer on `ai-host` (`ai-host` is always on and reaches both `ci-host` and the laptop over Headscale). On finding any new drift, a notification is emitted via the same channel as P61's CI failures (operator's email or Pushover, per existing tooling).

## 2. Goals

- **G1.** Every `<project>.md` in `~/central/` is auditable in under 5 seconds by `central-verify`.
- **G2.** The script reads from the per-project files; no truth state lives in the verifier itself. Adding a project means adding a `<project>.md`; the verifier discovers it automatically.
- **G3.** Findings are categorised: **DRIFT** (claim false), **STALE** (claim possibly false), **OK** (verified).
- **G4.** False positives are silenced via `~/central/.verify-ignore` (one path per line, with rationale comment), not by editing the verifier itself.
- **G5.** Nightly run; drift report archived to `~/central/drift_<date>.md` so historical drift is reviewable.
- **G6.** The verifier itself runs locally on whichever machine it is invoked on; it does not require the operator's prod credentials.

## 3. Non-Goals

- P62 does **not** fix drift; it only reports it. Fixes are operator-driven (edit the project file or fix the machine).
- P62 does **not** verify content correctness (e.g. that a script *does* what its header claims). That is review work, not gate work.
- P62 does **not** replace P61's leakage gate. They are complementary: P61 protects the public boundary; P62 protects the private index's accuracy.
- P62 does **not** verify across the public-private boundary into NWP-deployed infrastructure (i.e. it does not SSH to prod). `ver` is the only path to prod and the verifier never touches it.

## 4. Architecture

### 4.1 The verifier script

`~/central/bin/central-verify` walks `~/central/*.md` (skipping `INDEX.md`, `README.md`, `WHAT-TO-DO.md`, `PUBLIC-PRIVATE-STRATEGY.md`, `NWP-TIERED-ARCHITECTURE.md`, `public_private_split_recommendations.md`, and anything under `central/copyright/`, `central/public/`). For each remaining file it parses:

- The `## Identity` section's path hints
- The `## Canonical docs` table column 1 (paths and `host:/abs/path` URIs)
- The `## Cluster placement` table column 2 (host names)
- Any fenced ```bash``` block containing `rsync`, `scp`, or `ssh <host>` lines

Then for each parsed assertion it runs one of:

- `[ -d "$PATH" ]` (locally) for laptop-rooted paths
- `ssh "$HOST" '[ -d "$PATH" ]'` for remote host paths
- `ssh "$HOST" '[ -f "$PATH" ] && [ -r "$PATH" ]'` for remote script paths
- `git -C "$ROOT" log --since="90 days ago" --max-count=1 --format=%H` to check freshness on "active" projects

Each assertion → one line in `~/central/drift_<date>.md`:

```
[OK]    sd.md       ai-host:$HOME/sd                        (path exists)
[DRIFT] sd.md       ci-host rsync source                    (path missing — ci-host $HOME/sd/transcripts/whisper_large_fp16/itd/ does not exist)
[STALE] hwp.md      dormant project last touched 2025-12-04 (>90d; status says "active")
```

### 4.2 The host vocabulary

Hosts named in `<project>.md` files use the role labels established by [F34](F34-role-label-proposal-rewrite.md) where possible: `authoring`, `ci-host`, `ai-host`, `build-host`. The verifier maps role labels to operator-bound hostnames via the same `instance-manifest.yml` that [F33](F33-repository-topology-refactor.md) introduces (`~/nwp-instances/_global/instance-manifest.yml`). If the manifest is missing, the verifier falls back to a hard-coded short table binding each role label to its host (e.g. `authoring → localhost`, the rest to their Headscale addresses).

### 4.3 Output format

`~/central/drift_<date>.md` follows the same shape as a P61 leakage report so the operator gets a uniform review experience:

```markdown
# central-verify report — 2026-05-11

## Summary
- OK:    47
- STALE: 3
- DRIFT: 1

## Drift
| Project | File | Assertion | Why |
|---------|------|-----------|-----|
| sd      | sd.md       | rsync source `ci-host:$HOME/sd/transcripts/whisper_large_fp16/itd/` | host has no such dir |

## Stale
... (table)

## OK
... (collapsed by default)
```

### 4.4 The nightly cron

A systemd user-timer on **`ai-host`** (because `ai-host` is always on and reaches everyone over Headscale) runs the verifier at 02:00 local. The timer unit and service unit are sketched at `~/cod/entries/central-verify/`. Drift reports older than 30 days are pruned.

## 5. Implementation Plan

### Phase 1 — Author the parser and runner (½ day)

Write `~/central/bin/central-verify` in Bash (Python if the parsing grows). Walk `~/central/*.md`, parse the four sections listed in §4.1, emit one assertion per line to a structured log. **No remote calls yet** — Phase 1 just lists what *would* be checked. Useful even without remote checks because it exposes the shape of every claim.

### Phase 2 — Add remote probes (½ day)

Wire each assertion to its corresponding probe (`ssh`/`[ -d ]`/`git log`). Cache SSH connections via `ControlMaster` (already configured in `~/.ssh/config` for `ci-host`/`ai-host`) to keep the run under 5s.

### Phase 3 — Allowlist + report format (½ day)

Add `~/central/.verify-ignore` parsing. Emit Markdown report per §4.3. Add a `--json` flag for programmatic consumption (CI gate; future Stream C automation).

### Phase 4 — Schedule + notification (½ day)

Install the systemd user-timer on `ai-host`. Pipe drift findings to the operator's existing notification channel (the one P61 uses). Document one-shot manual invocation in `~/central/README.md`.

## 6. Risks

| Risk | Severity | Mitigation |
|------|----------|------------|
| Verifier becomes a maintenance burden (parser breaks when a `<project>.md` deviates from the shape) | Medium | Loud-fail on parse error rather than silent skip; the README §3c pattern is the canonical shape |
| False positives (claim is true, verifier wrong) | Medium | `.verify-ignore` provides a per-assertion escape valve with rationale |
| SSH credential drift (`ai-host`'s key expires from a host) | Low | The verifier surfaces this as DRIFT; operator notices |
| The nightly cron generates noise the operator doesn't read | Medium | Drift report empty → no email; only DRIFT/STALE rows trigger notification |
| Verifier reaches prod accidentally | Low | Hard-coded refusal to SSH to any host outside `[ci-host, ai-host, authoring]`; `ver` is unreachable from `ai-host` anyway |

## 7. Cross-references

- [P61](P61-leakage-hygiene-ci.md) — the sibling proposal protecting the public boundary
- [F33](F33-repository-topology-refactor.md) — `instance-manifest.yml` provides the host-vocabulary mapping
- [F34](F34-role-label-proposal-rewrite.md) — role-label vocabulary used by `<project>.md` files
- [ADR-0021](../decisions/0021-public-only-repo-scope.md) — establishes the public/private boundary that P62 verifies (the central-side claims about private machines)
- `~/central/README.md §3c` — the canonical `<project>.md` shape this proposal assumes

## 8. Open Questions

- **OQ-1.** Should P62 also verify *backwards* — that every project on disk has a `<project>.md`? Or only forwards (every `<project>.md` is true)? *Default: forwards only.* Backwards verification adds churn and a `<project>.md` is opt-in by README §3c policy.
- **OQ-2.** Run nightly on `ai-host`, or run on every `cd ~/central`? *Default: nightly on `ai-host`.* On-demand is noisy; cached drift is fine.
- **OQ-3.** Format: Markdown report (human-readable) vs structured JSON (machine-readable)? *Default: both — Markdown primary, JSON sidecar.*
