#!/usr/bin/env bash
#
# lib/operating-model.sh — INJECTION BECOMES PROJECTION (ops#319, F2 / Tranche 2)
#
# THE FAILURE THIS EXISTS TO MAKE IMPOSSIBLE
# ------------------------------------------
# `~/central/nwc-internal/OPERATING-MODEL.md` is the single most-injected
# document in this estate: a UserPromptSubmit hook re-reads it into context on
# EVERY prompt that mentions an `ops#N` issue. It is also the stalest. On
# 2026-08-09/10 it still asserted, in a banner headed "read first":
#
#     "⚠️ The loop is **paused** (`.loop-paused`, since 2026-05-22)"
#     "live queue runs to **ops#53**"
#
# Both were false. The agent-loop was armed and running on the ai-host, and the
# queue was past ops#332. Because the file is injected, those two sentences were
# re-asserted to the AI with the authority of ground truth on every single ops
# turn — the estate's most authoritative surface was also its least verified.
#
# The document had already noticed its own disease and treated it the wrong way:
# its top is a stack of "⇢ STATE UPDATE" banners, each correcting the body below
# without fixing it, and the 2026-07-08 banner partially corrects the 2026-07-01
# banner. Correction-by-accretion: every layer rots, and the reader must know
# which layer wins.
#
# THE FIX IS THE ESTATE'S OWN PRECEDENT, NOT A NEW IDEA
# ----------------------------------------------------
# `.nwp-review-mode` is a GENERATED PROJECTION of `approvers:` — CLAUDE.md says
# so, and there is deliberately no verb to hand-set it. This file does the same
# thing for operating state: the parts of the injected document that are FACTS
# ABOUT THE CURRENT WORLD are generated from the world, between DO-NOT-EDIT
# markers, each figure carrying the command that produced it and the moment it
# was read. Doctrine — the north star, the session-start protocol, the RAG
# contract, the trust model — stays hand-written prose, because a sentence about
# what we intend does not change when the fleet does.
#
# THREE RULES, ALL LOAD-BEARING
# -----------------------------
#  1. NEVER A STALE LITERAL. A section that cannot be measured renders
#     `CANNOT VERIFY` with the reason. "I could not look" and "there is nothing
#     there" are opposite facts (lib/session.sh's BLIND contract, same words).
#  2. EVERY FIGURE CARRIES ITS MEASUREMENT TIME. A number with no timestamp is
#     a claim; a number with one is a reading.
#  3. THE BLOCK REFUSES TO LOOK AUTHORITATIVE WHEN IT CANNOT DEMONSTRATE
#     CURRENCY. Past the horizon, the injector does not inject the block: it
#     injects a banner saying the state is stale and must be regenerated.
#     Fail-closed to LESS information, never to stale-as-fresh.
#
# WHERE THIS CHAINS (the F6 admission test: a mechanism that chains to no fixed
# point is decorative). Two chains, both real:
#   * INJECTION TIME — `pl operating-model inject`, run by the UserPromptSubmit
#     hook, on every ops-related prompt. Stronger than a daily cron: it fires at
#     the exact moment the knowledge is about to be used.
#   * EVERY MR — the bats suite (tests/unit/test-operating-model.bats) runs in
#     `test:unit`, and `pl doc-truth --projection` is this library's lint face.
#
# Dependency-light on purpose: `ui.sh` is optional, so the injector hook can
# source this on a bare shell inside a 10-second hook timeout.

[ -n "${_NWP_OPERATING_MODEL_SOURCED:-}" ] && return 0
_NWP_OPERATING_MODEL_SOURCED=1

_OM_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OM_PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$_OM_LIB_DIR/.." && pwd)}"

# The document being projected into. Overridable so the whole mechanism is
# testable on a fixture instead of only on the operator's private tree.
OM_DOC="${NWP_OPERATING_MODEL_FILE:-$HOME/central/nwc-internal/OPERATING-MODEL.md}"

# How long a generated state block may claim currency. 24 h by default: the
# estate's own oversight cadence is daily (`pl rag`, the audit cron), so a block
# older than a day is older than the freshest thing it could have measured.
OM_HORIZON_MIN="${NWP_OPERATING_MODEL_HORIZON_MIN:-1440}"

# Total wall-clock budget for a full regeneration. The injector runs inside a
# hook timeout, so every probe below is individually clamped and the sum is
# bounded. A probe that overruns renders CANNOT VERIFY — it never blocks the
# turn and it never guesses.
OM_BUDGET_SEC="${NWP_OPERATING_MODEL_BUDGET_SEC:-25}"

OM_BEGIN='<!-- BEGIN GENERATED STATE — pl operating-model sync — DO NOT EDIT BY HAND -->'
OM_END='<!-- END GENERATED STATE -->'

OM_OPS_PROJECT="${NWP_OPS_PROJECT_ID:-21}"

# WHICH HOST OWNS THE AGENT-LOOP — DECLARED, NEVER DEFAULTED TO A NAME.
#
# There is no literal fallback here, for the same reason `pl decisions` has none
# for the forge domain: a "generic" tool with one estate's machine name baked in
# has quietly hardcoded that estate (and the gitleaks `internal-bare-hostname`
# rule fails the commit — it caught exactly this line on first writing). The
# declaration lives beside the one `lib/oversight-freshness.sh` already reads:
#
#     settings:
#       loop:
#         host: <role-label>          # who runs the FIX loop (this one)
#         oversight_host: <role-label>  # who runs rag-sync — a DIFFERENT fact
#
# `oversight_host` is deliberately NOT used as a fallback. The two halves have
# been split across machines before (ops#304 moved oversight to the workstation
# while the fix loop stayed on the ai-host), and answering "is the loop running"
# by probing the oversight host would be a confident answer about the wrong
# machine — the exact shape of the bug this file exists to end.
#
# Undeclared ⇒ the section is BLIND ("I do not know which machine to ask"),
# which is the honest answer and is visibly different from "the loop is fine".
_om_yaml_host() {
  local cfg="${NWP_DIR:-$OM_PROJECT_ROOT}/nwp.yml" v=""
  [ -f "$cfg" ] && command -v yq >/dev/null 2>&1 || return 0
  v="$(yq e '.settings.loop.host // ""' "$cfg" 2>/dev/null)"
  [ "$v" = "null" ] && v=""
  printf '%s' "$v"
}
OM_LOOP_HOST="${NWP_OPERATING_MODEL_LOOP_HOST:-$(_om_yaml_host)}"
# Hosts that run a checkout of this code, i.e. where "deployed" is a real
# question distinct from "merged". Space-separated role labels; defaults to the
# loop host, because that is the machine whose staleness has actually bitten.
OM_CODE_HOSTS="${NWP_OPERATING_MODEL_CODE_HOSTS:-$OM_LOOP_HOST}"

om_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
_om_epoch() { date -u +%s; }

# JSON string escape for one-line values (same idiom as lib/session.sh).
_om_jstr() { printf '%s' "${1:-}" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/ /g' | tr '\n' ' '; }

# ─────────────────────────────────────────────────────────────────────────────
# THE MEASUREMENTS
#
# Each section prints ONE json object:
#   {"section":..,"provenance":{"source":..,"at":..,"blind":..}, <fields> }
# `blind` non-empty ⇒ the section could not be measured ⇒ it renders
# CANNOT VERIFY, and every rule that depends on it stands down (a lint that
# fires on a measurement it failed to take is the "swallowed verdict" defect
# this whole programme exists to kill).
# ─────────────────────────────────────────────────────────────────────────────

# ---- 1. the agent-loop -------------------------------------------------------
# PROBED, NOT READ OFF A FLAG FILE. The stale banner's specific error was to
# quote `.loop-paused` — a sentinel in the AUTHORING host's tree — as the state
# of a loop that runs on the ai-host. `pl loop --host <role> status` ssh's to
# the host that actually owns the loop and reads ITS sentinel and ITS crontab.
# Unreachable is UNKNOWN, never "fine": an unreachable loop host is not a
# healthy one (the verb's own words, and its exit 3).
om_section_loop() {
  local pl="${NWP_PL:-$OM_PROJECT_ROOT/pl}" out rc=0 blind="" state="" cron="" oversight=""
  local host="$OM_LOOP_HOST" budget="${1:-12}"
  if [ -z "$host" ]; then
    blind="no loop host declared (settings.loop.host in nwp.yml) — nobody to ask, so the loop state is UNKNOWN"
  elif [ ! -x "$pl" ]; then
    blind="no executable pl at $pl"
  else
    out=$(timeout "$budget" "$pl" loop --host "$host" status 2>&1) || rc=$?
    if [ "$rc" -eq 124 ]; then
      blind="pl loop --host $host status timed out after ${budget}s — the loop host could not be interrogated"
    elif [ "$rc" -ne 0 ] && ! printf '%s' "$out" | grep -q 'loop:'; then
      blind="pl loop --host $host status exited $rc — this is NOT 'the loop is fine'"
    else
      case "$out" in
        *"loop:       PAUSED"*|*"loop: PAUSED"*) state=paused ;;
        *"loop:       armed"*|*"loop: armed"*)   state=armed ;;
        *) blind="could not parse a loop state out of 'pl loop --host $host status'" ;;
      esac
      case "$out" in
        *"cron:       armed"*) cron=armed ;;
        *"cron:       ABSENT"*) cron=absent ;;
        *) cron=unknown ;;
      esac
      case "$out" in
        *"oversight:  last completed run"*)
          oversight="$(printf '%s\n' "$out" | grep -m1 'oversight:' | sed 's/.*oversight: *//')" ;;
        *"oversight:  NO completed"*) oversight="NO completed rag-sync run" ;;
        *) oversight="" ;;
      esac
    fi
  fi
  cat <<EOF
{"section":"loop","provenance":{"source":"pl loop --host $host status","at":"$(om_now)","blind":"$(_om_jstr "$blind")"},
 "host":"$host","state":"$state","cron":"$cron","oversight":"$(_om_jstr "$oversight")"}
EOF
}

# ---- 2. the issue queue ------------------------------------------------------
# THE HIGH-WATER MARK IS THE POINT. A hand-written "issue map" is stale the day
# after it is written and cannot say so; the highest iid ever created plus the
# open count are two numbers that make any hand-written map falsifiable at a
# glance. Read with the walled ops_note_token in a 0600 curl config, `-f` so a
# 404 from a token that cannot see the project is an ERROR and not an empty
# queue (the ops#281 shape: unreadable rendering as clean).
_om_ops_token() {
  yq e '.gitlab.ops_note_token // .gitlab.api_token // ""' \
      "${NWP_SECRETS_FILE:-$OM_PROJECT_ROOT/.secrets.yml}" 2>/dev/null | grep -v '^null$'
}
_om_ops_host() {
  local h="${NWP_GITLAB_HOST:-}"
  [ -n "$h" ] || h=$(yq e '.gitlab.server.domain // ""' \
      "${NWP_SECRETS_FILE:-$OM_PROJECT_ROOT/.secrets.yml}" 2>/dev/null | grep -v '^null$')
  printf '%s' "$h"
}
# $1 = query string · $2 = "headers" to emit response headers instead of body.
_om_api() {
  local q="$1" want="${2:-body}" tok cfg host rc out
  tok=$(_om_ops_token); host=$(_om_ops_host)
  [ -n "$tok" ] && [ -n "$host" ] || return 2
  cfg=$(mktemp); chmod 600 "$cfg"
  { printf 'silent\nshow-error\nfail\nconnect-timeout = 6\nmax-time = 15\n'
    printf 'header = "PRIVATE-TOKEN: %s"\n' "$tok"
  } > "$cfg"
  tok=""
  if [ "$want" = headers ]; then
    out=$(curl -K "$cfg" -D - -o /dev/null "https://${host}/api/v4/projects/${OM_OPS_PROJECT}/issues?${q}" 2>/dev/null); rc=$?
  else
    out=$(curl -K "$cfg" "https://${host}/api/v4/projects/${OM_OPS_PROJECT}/issues?${q}" 2>/dev/null); rc=$?
  fi
  rm -f "$cfg"
  printf '%s' "$out"
  return $rc
}
_om_xtotal() { printf '%s' "$1" | grep -i '^x-total:' | head -1 | tr -d '\r' | awk '{print $2}'; }

om_section_issues() {
  local blind="" high="" open="" dec="" raw hdr rc=0
  if ! command -v yq >/dev/null 2>&1; then
    blind="no yq — cannot read the forge route out of .secrets.yml"
  elif [ -z "$(_om_ops_host)" ] || [ -z "$(_om_ops_token)" ]; then
    blind="no forge host/token readable on this machine — the queue is UNKNOWN, not empty"
  else
    raw=$(_om_api "per_page=1&state=all&order_by=created_at&sort=desc") || rc=$?
    if [ "$rc" -ne 0 ]; then
      blind="the forge refused the issue list (curl rc=$rc) — UNKNOWN, not empty"
    else
      high=$(printf '%s' "$raw" | grep -oE '"iid":[0-9]+' | head -1 | cut -d: -f2)
      [ -n "$high" ] || blind="no iid in the forge response — cannot establish a high-water mark"
      hdr=$(_om_api "per_page=1&state=opened" headers) && open=$(_om_xtotal "$hdr")
      hdr=$(_om_api "per_page=1&state=opened&labels=decision%3A%3Awanted" headers) && dec=$(_om_xtotal "$hdr")
    fi
  fi
  cat <<EOF
{"section":"issues","provenance":{"source":"GET /projects/$OM_OPS_PROJECT/issues (high-water, open, decision::wanted)","at":"$(om_now)","blind":"$(_om_jstr "$blind")"},
 "high_water":"${high:-}","open_total":"${open:-}","decisions_open":"${dec:-}"}
EOF
}

# ---- 3. canonical phase per site --------------------------------------------
# The estate rule is that guards key off the per-site canonical phase and never
# off a site's name (CLAUDE.md). A projection of that table is what lets the
# next reader see, without asking, that PROD DOES NOT EXIST YET — the single
# fact most likely to be mis-remembered in the direction that blocks real work.
om_section_phases() {
  local pl="${NWP_PL:-$OM_PROJECT_ROOT/pl}" out rc=0 blind="" total=0 explicit="" prod=0 live=0
  if [ ! -x "$pl" ]; then
    blind="no executable pl at $pl"
  else
    out=$(timeout "${1:-15}" "$pl" canonical 2>&1) || rc=$?
    if [ "$rc" -ne 0 ]; then
      blind="pl canonical exited $rc — the phase table is UNKNOWN"
    else
      # Rows look like:  <site> <phase|(phase)> <set-by> <set-at>
      while read -r site phase _rest; do
        case "$site" in ''|SITE|---*|INFO:*) continue ;; esac
        case "$phase" in
          dev|live|prod)
            total=$((total+1)); explicit="${explicit}${explicit:+, }${site}=${phase}"
            [ "$phase" = prod ] && prod=$((prod+1))
            [ "$phase" = live ] && live=$((live+1)) ;;
          \(*\)) total=$((total+1)) ;;
        esac
      done < <(printf '%s\n' "$out" | sed 's/\x1b\[[0-9;]*m//g')
      [ "$total" -gt 0 ] || blind="pl canonical produced no parseable rows"
    fi
  fi
  cat <<EOF
{"section":"phases","provenance":{"source":"pl canonical","at":"$(om_now)","blind":"$(_om_jstr "$blind")"},
 "sites":"$total","prod":"$prod","live":"$live","explicit":"$(_om_jstr "$explicit")"}
EOF
}

# ---- 4. ADR status inventory -------------------------------------------------
# Cheap, local, and the source of a live falsehood: the injected document called
# NWP-ADR-0024 "Proposed" in its body and "ACCEPTED" in a banner three screens
# above. Which one a reader believes depended on how far they scrolled. The
# status line is machine-readable BY DECREE (`pl doc-truth`'s adr-hygiene check
# fails any ADR without exactly one), so it can simply be counted.
om_section_adrs() {
  local d="$OM_PROJECT_ROOT/docs/decisions" f s blind="" acc=0 prop=0 sup=0 oth=0 proposed=""
  if [ ! -d "$d" ]; then
    blind="no docs/decisions under $OM_PROJECT_ROOT"
  else
    for f in "$d"/[0-9][0-9][0-9][0-9]-*.md; do
      [ -e "$f" ] || continue
      s=$(grep -m1 '^\*\*Status:\*\*' "$f" 2>/dev/null | sed 's/^\*\*Status:\*\*[[:space:]]*//')
      case "$s" in
        Accepted*|accepted*) acc=$((acc+1)) ;;
        Proposed*|proposed*) prop=$((prop+1))
          proposed="${proposed}${proposed:+, }ADR-$(basename "$f" | cut -c1-4)" ;;
        Superseded*|superseded*|Deprecated*|Rejected*) sup=$((sup+1)) ;;
        *) oth=$((oth+1)) ;;
      esac
    done
    [ $((acc+prop+sup+oth)) -gt 0 ] || blind="docs/decisions holds no numbered ADR files"
  fi
  cat <<EOF
{"section":"adrs","provenance":{"source":"grep '^**Status:**' docs/decisions/NNNN-*.md","at":"$(om_now)","blind":"$(_om_jstr "$blind")"},
 "accepted":"$acc","proposed":"$prop","superseded":"$sup","other":"$oth","proposed_list":"$(_om_jstr "$proposed")"}
EOF
}

# ---- 5. deployed vs merged ---------------------------------------------------
# THE DRIFT THAT BIT THREE TIMES ON 2026-08-09/10: a fix merged to `main` is not
# a fix that is running. The agent-loop host runs its own checkout; between a
# merge and that host's next pull, `main` and the machine disagree, and every
# session that reasons from "it's merged" reasons about code nobody is running.
# Measured, not assumed: the remote HEAD sha, and how many merged commits it is
# missing. Unreachable ⇒ UNKNOWN.
om_section_deploy() {
  local budget="${1:-15}" blind="" rows="" host dest sha behind ahead merged
  if ! git -C "$OM_PROJECT_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    blind="$OM_PROJECT_ROOT is not a git checkout — 'merged' has no meaning here"
  else
    # `git fetch` may fail offline; say so rather than comparing against a stale
    # origin/main and calling the answer a measurement.
    git -C "$OM_PROJECT_ROOT" fetch origin --quiet 2>/dev/null || \
      blind="git fetch origin failed — origin/main below may itself be stale"
    merged=$(git -C "$OM_PROJECT_ROOT" rev-parse --short origin/main 2>/dev/null)
    [ -n "$merged" ] || blind="no origin/main in this checkout"
    if [ -n "$merged" ] && [ -z "$OM_CODE_HOSTS" ]; then
      blind="no code host declared (settings.loop.host in nwp.yml) — 'deployed' cannot be measured against any machine"
    elif [ -n "$merged" ] && [ -f "$_OM_LIB_DIR/host-capture.sh" ]; then
      # host-capture reads PROJECT_ROOT to find servers/ — set it for the source
      # and put it back. An assignment PREFIX on `.` persists (it is a special
      # builtin), which would silently repoint whatever sourced us; doc-truth
      # scans a tree chosen by PROJECT_ROOT, so that would not stay harmless.
      local _om_saved_root="${PROJECT_ROOT:-}"
      PROJECT_ROOT="$OM_PROJECT_ROOT"
      # shellcheck source=/dev/null
      . "$_OM_LIB_DIR/host-capture.sh" 2>/dev/null || true
      PROJECT_ROOT="$_om_saved_root"
      for host in $OM_CODE_HOSTS; do
        dest="$(host_resolve_dest "$host" 2>/dev/null)" || { rows="${rows}${host}=UNRESOLVED;"; continue; }
        sha=$(timeout "$budget" bash -c 'eval "$1" "git -C \${NWP_ROOT:-\$HOME/nwp} rev-parse HEAD 2>/dev/null"' _ "$dest" 2>/dev/null | tr -d '[:space:]')
        if [ -z "$sha" ]; then rows="${rows}${host}=UNREACHABLE;"; continue; fi
        if git -C "$OM_PROJECT_ROOT" cat-file -e "$sha^{commit}" 2>/dev/null; then
          behind=$(git -C "$OM_PROJECT_ROOT" rev-list --count "$sha..origin/main" 2>/dev/null)
          ahead=$(git -C "$OM_PROJECT_ROOT" rev-list --count "origin/main..$sha" 2>/dev/null)
          rows="${rows}${host}=${sha:0:7} behind=${behind:-?} ahead=${ahead:-?};"
        else
          rows="${rows}${host}=${sha:0:7} (commit unknown here — cannot compare);"
        fi
      done
    elif [ -n "$merged" ]; then
      blind="lib/host-capture.sh missing — cannot ask any host what it is running"
    fi
  fi
  cat <<EOF
{"section":"deploy","provenance":{"source":"git rev-parse origin/main + 'git rev-parse HEAD' on each code host","at":"$(om_now)","blind":"$(_om_jstr "$blind")"},
 "merged_head":"${merged:-}","hosts":"$(_om_jstr "$rows")"}
EOF
}

# ─────────────────────────────────────────────────────────────────────────────
# RENDERING
# ─────────────────────────────────────────────────────────────────────────────

_om_j() { printf '%s' "$1" | "${YQ:-yq}" e -p=json ".$2 // \"\"" - 2>/dev/null; }
_om_blind() { _om_j "$1" 'provenance.blind'; }

# One section header + its provenance line, and — when the section is blind —
# the CANNOT VERIFY paragraph in place of any figure. This is the whole
# fail-closed contract in four lines: no measurement, no number.
_om_hdr() {
  local sec="$1" name="$2" b; b=$(_om_blind "$sec")
  printf '\n#### %s\n' "$name"
  printf '_measured by `%s` at %s_\n' "$(_om_j "$sec" 'provenance.source')" "$(_om_j "$sec" 'provenance.at')"
  if [ -n "$b" ]; then
    printf '\n> ⛔ **CANNOT VERIFY — %s**\n> This is UNKNOWN, not "nothing to report". Do not substitute a remembered value.\n' "$b"
    return 1
  fi
  return 0
}

# om_collect_sections — run every probe once, into globals, inside the budget.
om_collect_sections() {
  local per=$(( OM_BUDGET_SEC / 3 )); [ "$per" -lt 5 ] && per=5
  OM_S_LOOP=$(om_section_loop "$per")
  OM_S_ISSUES=$(om_section_issues)
  OM_S_PHASES=$(om_section_phases "$per")
  OM_S_ADRS=$(om_section_adrs)
  OM_S_DEPLOY=$(om_section_deploy "$per")
}

om_render_json() {
  om_collect_sections
  printf '{"generated":"%s","horizon_min":%s,"sections":[%s,%s,%s,%s,%s]}\n' \
    "$(om_now)" "$OM_HORIZON_MIN" \
    "$OM_S_LOOP" "$OM_S_ISSUES" "$OM_S_PHASES" "$OM_S_ADRS" "$OM_S_DEPLOY"
}

# om_render_body — the markdown BETWEEN the markers, without the meta line
# (which carries the checksum OF this body and therefore cannot be inside it).
om_render_body() {
  [ -n "${OM_S_LOOP:-}" ] || om_collect_sections
  local gen; gen=$(om_now)

  cat <<EOF
### Current state — GENERATED, not asserted

Every figure below was **measured** at the time shown beside it. Nothing here is
remembered, and nothing here is edited by hand: this block is regenerated by
\`pl operating-model sync\`. If a sentence elsewhere in this document disagrees
with a figure here, **the figure is right and the sentence is a bug** —
\`pl doc-truth --projection\` fails on exactly that disagreement.

A section that could not be measured says **CANNOT VERIFY**. That is not a
formality: "I could not look" and "there is nothing there" are opposite facts,
and this block is forbidden from rendering the second when it means the first.
EOF

  if _om_hdr "$OM_S_LOOP" "Agent-loop"; then
    local st; st=$(_om_j "$OM_S_LOOP" state)
    printf '\n| host | loop | cron | oversight |\n|---|---|---|---|\n'
    printf '| `%s` | **%s** | %s | %s |\n' \
      "$(_om_j "$OM_S_LOOP" host)" "$st" "$(_om_j "$OM_S_LOOP" cron)" "$(_om_j "$OM_S_LOOP" oversight)"
    if [ "$st" = armed ]; then
      printf '\nThe loop is **ARMED** on that host — it wakes on its own schedule and opens MRs.\n'
    elif [ "$st" = paused ]; then
      printf '\nThe loop is **PAUSED** on that host (its kill sentinel is present).\n'
    fi
  fi

  if _om_hdr "$OM_S_ISSUES" "Issue queue (nwp/ops)"; then
    printf '\n| highest issue ever opened | open now | open `decision::wanted` |\n|---|---|---|\n'
    printf '| **ops#%s** | %s | %s |\n' \
      "$(_om_j "$OM_S_ISSUES" high_water)" "$(_om_j "$OM_S_ISSUES" open_total)" "$(_om_j "$OM_S_ISSUES" decisions_open)"
    printf '\nThere is deliberately **no issue map here**. A hand-listed map of "the\nopen highlights" is stale the day after it is written and cannot say so;\nthe high-water mark makes any such map falsifiable at a glance. For the\nlive list: `pl issue ls` · for what is waiting on you: `pl decisions`.\n'
  fi

  if _om_hdr "$OM_S_PHASES" "Canonical phase (ops#33 — guards key off THIS, never off a site name)"; then
    printf '\n| sites | phase `prod` | phase `live` | explicitly set |\n|---|---|---|---|\n'
    printf '| %s | **%s** | %s | %s |\n' \
      "$(_om_j "$OM_S_PHASES" sites)" "$(_om_j "$OM_S_PHASES" prod)" "$(_om_j "$OM_S_PHASES" live)" \
      "$(_om_j "$OM_S_PHASES" explicit)"
    [ "$(_om_j "$OM_S_PHASES" prod)" = "0" ] && \
      printf '\n**No site is in canonical phase `prod`.** Prod does not exist yet; the live\ntier holds no real user data and may be worked on freely (CLAUDE.md).\n'
  fi

  if _om_hdr "$OM_S_ADRS" "Decisions of record (ADR status)"; then
    printf '\n| Accepted | Proposed | Superseded/Deprecated/Rejected | other |\n|---|---|---|---|\n'
    printf '| %s | %s | %s | %s |\n' \
      "$(_om_j "$OM_S_ADRS" accepted)" "$(_om_j "$OM_S_ADRS" proposed)" \
      "$(_om_j "$OM_S_ADRS" superseded)" "$(_om_j "$OM_S_ADRS" other)"
    local pl_list; pl_list=$(_om_j "$OM_S_ADRS" proposed_list)
    [ -n "$pl_list" ] && printf '\nStill **Proposed** (not decided): %s\n' "$pl_list"
  fi

  if _om_hdr "$OM_S_DEPLOY" "Deployed vs merged"; then
    printf '\n| merged (`origin/main`) | running, per code host |\n|---|---|\n'
    printf '| `%s` | %s |\n' \
      "$(_om_j "$OM_S_DEPLOY" merged_head)" "$(_om_j "$OM_S_DEPLOY" hosts | sed 's/;[[:space:]]*$//; s/;/ · /g')"
    printf '\n**Merged is not deployed.** A host with `behind>0` is running code without\nthe newest merges — reason about what that host RUNS, not about `main`.\n'
  fi

  printf '\n_Generated %s. Horizon %s min: past that, `pl operating-model inject`\nrefuses to present this block as current._\n' "$gen" "$OM_HORIZON_MIN"
}

# The block body's checksum lives in the meta line ABOVE the body, so a hand
# edit anywhere inside the markers is detectable. Same reasoning as
# `.nwp-review-mode`'s pre-commit hook: a generated projection that somebody can
# quietly hand-edit is just prose again, with a machine's authority attached.
_om_sha() { printf '%s' "$1" | sha256sum | awk '{print $1}'; }

om_render_block() {
  local body meta
  body="$(om_render_body)"
  meta="<!-- nwp:om-state v1 generated=$(om_now) horizon_min=${OM_HORIZON_MIN} sha256=$(_om_sha "$body") -->"
  printf '%s\n%s\n%s\n%s\n' "$OM_BEGIN" "$meta" "$body" "$OM_END"
}

# ─────────────────────────────────────────────────────────────────────────────
# THE STALENESS GATE
#
# om_status <file> — sets OM_VERDICT / OM_AGE_MIN / OM_REASON, returns:
#   0 FRESH · 1 STALE · 2 MISSING|TAMPERED|UNREADABLE (CANNOT VERIFY)
#
# The direction is deliberate and matches `.nwp-review-mode`'s: an unreadable
# document, an absent block or a broken checksum is NOT treated as fine. The
# tempting default (assume fresh, warn quietly) is the permissive one, and the
# permissive direction is how a document goes on being injected as ground truth
# after it stopped being true.
# ─────────────────────────────────────────────────────────────────────────────
om_status() {
  local file="${1:-$OM_DOC}" meta gen sha body now_epoch gen_epoch
  OM_VERDICT=""; OM_AGE_MIN=""; OM_REASON=""; OM_HORIZON_SEEN="$OM_HORIZON_MIN"
  if [ ! -r "$file" ]; then
    OM_VERDICT=UNREADABLE; OM_REASON="not readable: $file"; return 2
  fi
  if ! grep -qF "$OM_BEGIN" "$file" || ! grep -qF "$OM_END" "$file"; then
    OM_VERDICT=MISSING
    OM_REASON="no generated state block in $file — every state claim in it is hand-written prose nobody re-verified"
    return 2
  fi
  meta=$(grep -m1 '^<!-- nwp:om-state ' "$file")
  if [ -z "$meta" ]; then
    OM_VERDICT=TAMPERED; OM_REASON="block present but its provenance line is gone — cannot date or checksum it"; return 2
  fi
  gen=$(printf '%s' "$meta" | sed -n 's/.*generated=\([^ ]*\).*/\1/p')
  sha=$(printf '%s' "$meta" | sed -n 's/.*sha256=\([0-9a-f]*\).*/\1/p')
  OM_HORIZON_SEEN=$(printf '%s' "$meta" | sed -n 's/.*horizon_min=\([0-9]*\).*/\1/p')
  [ -n "$OM_HORIZON_SEEN" ] || OM_HORIZON_SEEN="$OM_HORIZON_MIN"
  body=$(om_block_body "$file")
  if [ -z "$gen" ] || [ -z "$sha" ]; then
    OM_VERDICT=TAMPERED; OM_REASON="provenance line has no generated= / sha256="; return 2
  fi
  if [ "$(_om_sha "$body")" != "$sha" ]; then
    OM_VERDICT=TAMPERED
    OM_REASON="the block was edited by hand (checksum mismatch) — a generated projection somebody hand-edits is prose wearing a machine's authority. Regenerate: pl operating-model sync"
    return 2
  fi
  gen_epoch=$(date -u -d "$gen" +%s 2>/dev/null) || gen_epoch=""
  if [ -z "$gen_epoch" ]; then
    OM_VERDICT=TAMPERED; OM_REASON="unparseable generated= timestamp: $gen"; return 2
  fi
  now_epoch=$(_om_epoch)
  OM_AGE_MIN=$(( (now_epoch - gen_epoch) / 60 ))
  if [ "$OM_AGE_MIN" -gt "$OM_HORIZON_SEEN" ]; then
    OM_VERDICT=STALE
    OM_REASON="state generated ${OM_AGE_MIN} min ago; horizon is ${OM_HORIZON_SEEN} min"
    return 1
  fi
  OM_VERDICT=FRESH; OM_REASON="state generated ${OM_AGE_MIN} min ago (horizon ${OM_HORIZON_SEEN} min)"
  return 0
}

# The body between the meta line and the END marker (what the checksum covers).
om_block_body() {
  local file="${1:-$OM_DOC}"
  awk -v b="$OM_BEGIN" -v e="$OM_END" '
    index($0,b)==1 { inb=1; next }
    inb && /^<!-- nwp:om-state / { next }
    index($0,e)==1 { inb=0 }
    inb { print }
  ' "$file" | awk 'BEGIN{n=0} {lines[n++]=$0} END{ while(n>0 && lines[n-1]=="") n--; for(i=0;i<n;i++) print lines[i] }'
}

# Everything OUTSIDE the markers — the hand-written doctrine. This is the corpus
# the contradiction lint reads: a hand-written claim may not disagree with a
# generated one.
om_doc_prose() {
  local file="${1:-$OM_DOC}"
  awk -v b="$OM_BEGIN" -v e="$OM_END" '
    index($0,b)==1 { inb=1; next }
    index($0,e)==1 { inb=0; next }
    !inb { printf "%d:%s\n", NR, $0 }
  ' "$file"
}

# om_sync <file> — splice a freshly generated block into the document.
# Creates it at the end if no markers exist yet; replaces it in place otherwise.
om_sync() {
  local file="${1:-$OM_DOC}" block tmp
  [ -w "$file" ] || { printf 'operating-model: not writable: %s\n' "$file" >&2; return 2; }
  block="$(om_render_block)"
  tmp=$(mktemp)
  if grep -qF "$OM_BEGIN" "$file" && grep -qF "$OM_END" "$file"; then
    awk -v b="$OM_BEGIN" -v e="$OM_END" -v blk="$block" '
      index($0,b)==1 { print blk; inb=1; next }
      index($0,e)==1 { inb=0; next }
      !inb { print }
    ' "$file" > "$tmp"
  else
    cat "$file" > "$tmp"
    printf '\n---\n\n%s\n' "$block" >> "$tmp"
  fi
  cat "$tmp" > "$file"; rm -f "$tmp"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# THE CONTRADICTION LINT (the face `pl doc-truth --projection` wears)
#
# om_lint <file> — emits one `kind|file:line|detail` per finding.
#
# FOUR RULES. Three of them are CONDITIONAL ON A MEASUREMENT, and that is the
# design: a rule that fires on a literal it never measured is itself a stale
# literal. If the loop is genuinely paused, the sentence "the loop is paused" is
# CORRECT and this lint says nothing. If the probe is blind, the rule STANDS
# DOWN and the blindness is reported — never converted into a finding.
#
#   projection-contradiction  a hand-written claim disagrees with a measurement
#   state-banner              a "STATE UPDATE"-style banner corrects the body
#                             (if a banner has to exist, the body should have
#                             been regenerated — correction-by-accretion)
#   unprojected-state         the document has no generated block at all
#   stale-state / hand-edited-state  the gate's verdict, surfaced as a finding
# ─────────────────────────────────────────────────────────────────────────────

# Lines of hand-written prose as `<docline>:<text>`, minus the ones that are
# teaching the rule itself (`<!-- doc-truth:projection-ok -->`, the same
# per-line, invisible-when-rendered escape hatch doc-truth already uses: a
# document must be able to quote the stale sentence in order to explain it).
#
# NOTE ON `grep -n`: it is deliberately NOT used downstream. om_doc_prose
# already carries the real document line number, and grep would prepend the
# FILTERED-STREAM number on top of it — which happens to coincide today (no
# markers ⇒ every line is prose) and would silently start lying the moment the
# generated block exists. A line number that is right by coincidence is the
# same class of defect as everything else here.
_om_prose_lines() {
  om_doc_prose "$1" | grep -v 'doc-truth:projection-ok'
}

om_lint() {
  local file="${1:-$OM_DOC}" ln text n found=0
  [ -r "$file" ] || { printf 'projection-blind|%s|not readable\n' "$file"; return 2; }

  # ---- rule: state-banner (unconditional) ---------------------------------
  # The document's own top was TWO stacked "⇢ STATE UPDATE" banners, the later
  # one partially correcting the earlier one. Each said "read first —
  # supersedes the claims below", which is a document telling its reader that
  # its own body is wrong. That is not a fix; it is a note that the fix was
  # skipped. A banner is admissible for a DECISION ("operator ruling, this
  # supersedes ADR-x"); it is not admissible for STATE, which is what the
  # generated block is for.
  while IFS=: read -r ln text; do
    [ -n "$ln" ] || continue
    printf 'state-banner|%s:%s|%s\n' "$file" "$ln" "$(printf '%s' "$text" | cut -c1-90)"
    found=1
  done < <(_om_prose_lines "$file" | grep -iE 'STATE.?UPDATE|supersedes (the )?(banners|stale claims|§)|read this first — supersedes' || true)

  # ---- rule: projection-contradiction, loop state --------------------------
  local st blind
  st=$(_om_j "${OM_S_LOOP:-}" state); blind=$(_om_blind "${OM_S_LOOP:-}")
  if [ -n "$blind" ]; then
    printf 'projection-blind|%s|loop state unmeasured: %s\n' "$file" "$blind"
  elif [ "$st" = armed ]; then
    while IFS=: read -r ln text; do
      [ -n "$ln" ] || continue
      printf 'projection-contradiction|%s:%s|claims the loop is paused; measured ARMED on %s\n' \
        "$file" "$ln" "$(_om_j "$OM_S_LOOP" host)"
      found=1
    done < <(_om_prose_lines "$file" | grep -iE 'loop is[^.]{0,40}paused|\.loop-paused|loop[^.]{0,30}(switched off|is off|dark)' || true)
  elif [ "$st" = paused ]; then
    while IFS=: read -r ln text; do
      [ -n "$ln" ] || continue
      printf 'projection-contradiction|%s:%s|claims the loop is running; measured PAUSED on %s\n' \
        "$file" "$ln" "$(_om_j "$OM_S_LOOP" host)"
      found=1
    done < <(_om_prose_lines "$file" | grep -iE 'loop is[^.]{0,40}(armed|running|live|unpaused)' || true)
  fi

  # ---- rule: projection-contradiction, issue high-water --------------------
  # A hand-written issue map that stops below the highest issue ever opened is,
  # by construction, out of date. Bounded to lines that are actually CLAIMING
  # the queue's extent, so ordinary prose citing an issue is untouched.
  local high; high=$(_om_j "${OM_S_ISSUES:-}" high_water)
  blind=$(_om_blind "${OM_S_ISSUES:-}")
  if [ -n "$blind" ]; then
    printf 'projection-blind|%s|issue queue unmeasured: %s\n' "$file" "$blind"
  elif [ -n "$high" ]; then
    while IFS=: read -r ln text; do
      [ -n "$ln" ] || continue
      # highest ops#N asserted on that line
      n=$(printf '%s' "$text" | grep -oE 'ops#[0-9]+|#[0-9]+' | tr -d 'ops#' | sort -n | tail -1)
      [ -n "$n" ] || continue
      if [ "$n" -lt "$high" ]; then
        printf 'projection-contradiction|%s:%s|issue map stops at #%s; highest issue opened is ops#%s\n' \
          "$file" "$ln" "$n" "$high"
        found=1
      fi
    done < <(_om_prose_lines "$file" | grep -iE 'issue map|queue runs to|live queue|backlog runs to|session/issue map' || true)
  fi

  # ---- rule: projection-contradiction, ADR status --------------------------
  # "NWP-ADR-0024 (**Proposed**)" in the body while the ADR itself says Accepted.
  blind=$(_om_blind "${OM_S_ADRS:-}")
  if [ -n "$blind" ]; then
    printf 'projection-blind|%s|ADR statuses unmeasured: %s\n' "$file" "$blind"
  else
    local adr num real claimed
    while IFS=: read -r ln text; do
      [ -n "$ln" ] || continue
      for adr in $(printf '%s' "$text" | grep -oE '(ADR-)?0[0-9]{3}' | sort -u); do
        num="${adr#ADR-}"
        compgen -G "$OM_PROJECT_ROOT/docs/decisions/${num}-*.md" >/dev/null 2>&1 || continue
        real=$(grep -m1 -h '^\*\*Status:\*\*' "$OM_PROJECT_ROOT/docs/decisions/${num}-"*.md 2>/dev/null \
               | sed 's/^\*\*Status:\*\*[[:space:]]*//' | awk '{print $1}')
        claimed=""
        printf '%s' "$text" | grep -qiE '\*\*proposed\*\*|\(proposed' && claimed=Proposed
        printf '%s' "$text" | grep -qiE '\*\*accepted\*\*|\(accepted'  && claimed=Accepted
        [ -n "$claimed" ] || continue
        if [ "$claimed" != "$real" ]; then
          printf 'projection-contradiction|%s:%s|calls ADR-%s %s; its Status line says %s\n' \
            "$file" "$ln" "$num" "$claimed" "$real"
          found=1
        fi
      done
    done < <(_om_prose_lines "$file" | grep -iE '(ADR-)?0[0-9]{3}' || true)
  fi

  # ---- rule: the gate's own verdict ---------------------------------------
  om_status "$file" || true
  case "$OM_VERDICT" in
    MISSING)   printf 'unprojected-state|%s|%s\n' "$file" "$OM_REASON"; found=1 ;;
    TAMPERED)  printf 'hand-edited-state|%s|%s\n' "$file" "$OM_REASON"; found=1 ;;
    STALE)     printf 'stale-state|%s|%s\n' "$file" "$OM_REASON"; found=1 ;;
  esac

  [ "$found" -eq 0 ]
}
