#!/bin/bash
################################################################################
# lib/moodle-policy.sh — the tool_policy site-policy-handler invariant (ops#174).
#
# THE FAIL-OPEN THIS CLOSES
# -------------------------
# On 2026-08-01 the live Saint School Moodle (site `ss`, docroot /var/www/ssc,
# DB ssc; the live FQDN is deliberately not written here — see .gitleaks.toml /
# P61, resolve it with `pl status`) was found publishing FIVE tool_policy
# documents, every one of them audience=0 (everyone) and optional=0
# (mandatory) — while `$CFG->sitepolicyhandler` was `''`. With an
# empty handler Moodle falls back to core's `default_handler`, whose
# `is_defined()` keys off `$CFG->sitepolicy` (also `''`), so the site-policy
# branch in require_login() never fires.
#
# Net effect: five documents that declare themselves mandatory were presented to
# nobody, and `mdl_tool_policy_acceptances` held ZERO rows. The site asserted
# terms no member had ever agreed to. Nothing was broken, nothing errored, and
# no check anywhere said a word — which is exactly the shape of defect this
# programme exists to make loud.
#
# WHY A STANDING CHECK AND NOT JUST A ONE-OFF SET
# -----------------------------------------------
# `sitepolicyhandler` is a single `mdl_config` row. Restoring a DB snapshot from
# before the fix, reinstalling, or rebuilding the site silently reverts it, and
# the reverted state is INDISTINGUISHABLE from the fixed state without asking.
# There is no live-Moodle core-config provisioning path in this repo to hang it
# off (lib/moodle-promote.sh REFUSES live/prod by design; lib/install-moodle.sh
# is the ddev/dev installer), so the durable mechanism is: an idempotent verb
# that sets it, plus a verdict that goes non-green the moment it is lost.
#
# THE VACUOUS-PASS RULE
# ---------------------
# "I could not see any policies" must NEVER render as "there is no gap". The
# verdict below has a distinct UNKNOWN state for exactly that case, and UNKNOWN
# is not success. This mirrors the ops#137 plugin-drift rule ("found fewer than
# two copies to compare" is an error, not an OK).
#
# EVIDENCE SOURCES (deliberately narrow)
#   Both inputs come from Moodle's own `admin/cli/cfg.php`, which is already the
#   only remote PHP `pl moodle cli` will run. No new remote-execution surface,
#   no raw SQL, no DB credentials:
#     * core `sitepolicyhandler`                      — the handler that is armed
#     * local_nwc_copyright_sync `policyid_<slug>` rows — the estate's own record
#       of which legal documents it has published to this Moodle
#
#   The pointer set is a PROXY for "documents are published", not a count of
#   them, and the verdict says so. Its known failure mode is the ops#174 root
#   cause itself (a cold pointer), which is why an empty pointer set yields
#   UNKNOWN rather than OK.
#
# PURE + unit-testable: no ssh, no network, no secrets. The caller supplies the
# two already-collected strings.
################################################################################

# --- soft-dep messaging (works standalone or with lib/ui.sh) -----------------
if ! declare -F _mpol_err >/dev/null 2>&1; then
    _mpol_err()  { if command -v print_error   >/dev/null 2>&1; then print_error   "$*"; else printf 'ERROR: %s\n' "$*" >&2; fi; }
    _mpol_warn() { if command -v print_warning >/dev/null 2>&1; then print_warning "$*"; else printf 'WARN: %s\n'  "$*" >&2; fi; }
    _mpol_info() { if command -v print_info    >/dev/null 2>&1; then print_info    "$*"; else printf '%s\n'        "$*"; fi; }
fi

# The only handler Moodle ships that can present tool_policy documents.
MOODLE_POLICY_HANDLER="${MOODLE_POLICY_HANDLER:-tool_policy}"

# The component whose `policyid_<slug>` config rows record what the estate has
# published to a Moodle (nwp/ss-moodle-plugins).
MOODLE_POLICY_SYNC_COMPONENT="${MOODLE_POLICY_SYNC_COMPONENT:-local_nwc_copyright_sync}"

################################################################################
# moodle_policy_pointer_count <cfg-listing>
#
# Count `policyid_<slug>` rows in the tab-separated output of
#   admin/cli/cfg.php --component=local_nwc_copyright_sync
# Echoes an integer. An empty/absent listing is 0 — the CALLER must not read 0
# as "no policies"; see moodle_policy_verdict.
################################################################################
moodle_policy_pointer_count() {
    local listing="${1:-}"
    [ -n "$listing" ] || { echo 0; return 0; }
    printf '%s\n' "$listing" | grep -cE '^[[:space:]]*policyid_[A-Za-z0-9_]+[[:space:]]' || true
}

################################################################################
# moodle_policy_verdict <handler> <pointer-count>
#
# The whole judgement, in one pure function.
#
#   OK       handler == tool_policy — documents are armed and acceptance records.
#   GAP      handler != tool_policy AND >=1 published document — mandatory legal
#            text exists that is presented to nobody. This is the ops#174 defect.
#   UNKNOWN  handler != tool_policy AND no published document is VISIBLE. Could
#            genuinely be a Moodle with no policies (ssd/ss2/sso), or could be a
#            cold `policyid_<slug>` pointer hiding real ones (the ops#174 root
#            cause). Not provable from config alone, so not a pass.
#
# Echoes the verdict. Exit status: 0 OK, 1 GAP, 3 UNKNOWN — so a caller can
# branch on status without parsing text, and UNKNOWN is distinguishable from a
# hard failure.
################################################################################
moodle_policy_verdict() {
    local handler="${1:-}" pointers="${2:-0}"
    if [ "$handler" = "$MOODLE_POLICY_HANDLER" ]; then
        echo "OK"; return 0
    fi
    if [ "${pointers:-0}" -gt 0 ] 2>/dev/null; then
        echo "GAP"; return 1
    fi
    echo "UNKNOWN"; return 3
}

################################################################################
# moodle_policy_explain <verdict> <handler> <pointer-count>
#
# Plain-English rendering of a verdict — the "not a full terminal guy"
# affordance the rest of this codebase uses. Prints to stdout; returns the same
# status as moodle_policy_verdict would.
################################################################################
moodle_policy_explain() {
    local verdict="${1:-}" handler="${2:-}" pointers="${3:-0}"
    local shown="${handler:-(empty)}"
    case "$verdict" in
        OK)
            echo "  handler:  ${shown}  — tool_policy documents ARE presented and acceptance is recorded."
            return 0
            ;;
        GAP)
            echo "  handler:  ${shown}  — core default_handler is active, keyed on \$CFG->sitepolicy."
            echo "  published: ${pointers} document(s) recorded by ${MOODLE_POLICY_SYNC_COMPONENT}."
            echo ""
            echo "  GAP: this site publishes legal documents that are presented to NOBODY."
            echo "       Mandatory (optional=0) tool_policy documents are never shown at login and"
            echo "       no acceptance is ever recorded, so the site asserts terms nobody agreed to."
            return 1
            ;;
        UNKNOWN)
            echo "  handler:  ${shown}  — core default_handler is active."
            echo "  published: no ${MOODLE_POLICY_SYNC_COMPONENT} policyid_<slug> pointers visible."
            echo ""
            echo "  UNKNOWN — NOT a pass. Config alone cannot prove this Moodle has no policy"
            echo "       documents: a cold policyid_<slug> pointer is precisely the ops#174 root"
            echo "       cause, and it hides documents that DO exist. Confirm against the DB"
            echo "       before treating this site as clear."
            return 3
            ;;
        *)
            _mpol_err "moodle_policy_verdict: unknown verdict '${verdict}'"
            return 2
            ;;
    esac
}

################################################################################
# moodle_policy_set_cmd <handler>
#
# The admin/cli argument vector that arms (or disarms) the handler, for the
# caller to hand to `pl moodle cli ... --`. Kept here so the one place that
# knows the setting name is the one place that documents it.
#
# Passing an empty handler emits `--set=` (value ''), which is the FAITHFUL
# inverse of arming it: ss/ssc had a `sitepolicyhandler` row present with an
# empty value before the change. `--unset` deletes the row and is NOT the same
# state, so it is deliberately not offered.
################################################################################
moodle_policy_set_cmd() {
    local handler="${1-}"
    printf 'admin/cli/cfg.php --name=sitepolicyhandler --set=%s\n' "$handler"
}
