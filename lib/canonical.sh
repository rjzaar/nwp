#!/bin/bash
################################################################################
# lib/canonical.sh — canonicality phases + content-flow guards (nwp/ops#33)
#
# A site moves through canonicality phases; WHICH HOST IS CANONICAL governs
# where content may change and which way sync flows:
#
#   canonical: dev   — dev DB is the source of truth (no real audience yet).
#                      dev→live content pushes ALLOWED (dev overwrites live).
#   canonical: live  — live is the source of truth. Content changes on live
#                      only; dev receives a SANITIZED copy (live→dev).
#                      dev→live CONTENT pushes are REFUSED (would clobber the
#                      canonical source). Code/config-only deploys still flow.
#   canonical: prod  — prod is the source. live/dev are downstream sanitized
#                      copies; additionally code work is branch-only with a
#                      protected, CI-gated main (ADR-0024).
#
# The phase lives in the global nwp.yml per site (sites.<name>.canonical) and
# is ENFORCED here, not just documented: guard functions below are called by
# the deploy commands (stg2live, stg2prod, live2prod, dev2stg). Absent field
# defaults to "dev" (today's behavior); an unparseable value FAILS CLOSED —
# every guard allows only exact, known-safe phases.
#
# FAIL-CLOSED ON AN UNREADABLE *FILE*, NOT JUST AN UNREADABLE *VALUE*
# (2026-07-27, the same defect lib/pair.sh was fixed for in MR !211):
#   The paragraph above was true of the VALUE and false of the FILE. Until this
#   change both readers were `[ -f "$config" ] && raw=$(… || true)`, so a
#   corrupt, truncated or half-written nwp.yml made yq fail, made `raw` empty,
#   and empty is the branch that returns the WEAKEST setting. Every
#   `canonical: live` site read as `dev` — so canonical_guard_content_push
#   ALLOWED exactly the dev→live content overwrite it exists to stop — and every
#   `maturity: production` site read as `incubating`, so maturity_guard_deploy
#   stopped routing prod through the signed-bundle path. That refusal has no
#   override BY DESIGN, which made this fail-open the only way past it.
#
#   nwp.yml is never committed (CLAUDE.md) and `.gitignore:14` ignores `sites/*`,
#   so these guards' only inputs are files no reviewer and no CI job can see. A
#   guard that silently degrades on an invisible input cannot be observed to be
#   wrong. So "I could not read the config" is now its OWN answer, distinct from
#   "the config says dev", and it REFUSES:
#
#     canonical_get_phase → "cannot-verify:<reason>"   (guards refuse)
#     maturity_get_class  → "cannot-verify:<reason>"   (guards refuse)
#
#   Same vocabulary as lib/boundary.sh's rc 2 / `pl impact --honesty`: CANNOT
#   VERIFY is NOT a clean result. Escape hatch: NWP_CANONICAL_GATE_SOFT=true,
#   which downgrades to a loud warning and writes a ledger row — deliberately
#   NOT --override-canonical, which is a per-decision override and must not
#   double as a licence to deploy past a config nobody can read.
#
# ABSENT BY CONTEXT vs PRESENT BUT UNREADABLE — where the line is drawn, and why
#   `pl` runs from a fresh clone, from CI, and from ~40 linked worktrees, and in
#   those contexts nwp.yml legitimately does not exist (the worktrees are split:
#   some symlink it to the main tree, some have no copy at all). A fail-closed
#   that fires there would refuse ordinary work, get overridden or reverted, and
#   leave us worse off than the bug.
#
#   THE LINE IS DRAWN AT PARSEABILITY, NOT PRESENCE:
#     · config EXISTS and does not parse  → CANNOT VERIFY, refuse, always.
#       Nothing legitimate produces a corrupt nwp.yml. This is also the failure
#       that actually happens (an interrupted `pl canonical set`, a bad merge, a
#       half-written file), and it is the one that was silently downgrading real
#       `canonical: live` / `maturity: production` sites.
#     · config MISSING                    → today's defaults, as before.
#
#   The tempting stronger rule — "missing config + sites/<site>/ on disk ⇒
#   refuse" — was implemented, TESTED, AND WITHDRAWN, because it is not
#   supported by evidence and it broke a legitimate path:
#     · `pl moodle plugin deploy` resolves everything it needs from the per-site
#       sites/<site>/.nwp.yml, so a real, fully-configured Moodle site can be
#       deployed from a tree with no global nwp.yml at all. That is not a
#       corrupt install; it is a supported layout (tests/unit/
#       test-moodle-ops-verbs.bats builds exactly it), and the rule refused it.
#     · The one signal that WOULD justify refusing — evidence this site was
#       previously classified — is the ledger private/canonical/<site>.log. It
#       is empty in practice: the live fleet's phases were set by editing
#       nwp.yml directly, and the directory does not exist. A rule keyed on it
#       would be a false negative for every real site today.
#   With no evidence available to tell "the registry vanished" from "this
#   checkout never had one", refusing would be a guess. So the missing-config
#   case keeps its default AND SAYS SO OUT LOUD (rc 3 → _canonical_no_registry_warn):
#   the residual hole is real, but it is now visible instead of silent, and
#   silence was half the original defect.
#
# Transitions are explicit operator actions: `pl canonical set <site> <phase>`
# (scripts/commands/canonical.sh) records who/when in nwp.yml and appends to
# an append-only ledger in private/canonical/<site>.log.
################################################################################

# Requires: lib/ui.sh (print_*), lib/yaml-write.sh (yaml_get_site_field).
# Source yaml-write.sh ourselves if the caller hasn't (ui.sh has no such
# self-heal because every command sources it first thing).
_canonical_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! command -v yaml_get_site_field >/dev/null 2>&1; then
    # shellcheck source=yaml-write.sh
    source "$_canonical_lib_dir/yaml-write.sh"
fi

CANONICAL_PHASES="dev live prod"

# --- config legibility (shared by canonical + maturity) ----------------------
#
# _canonical_config_state <site> [config] — can this config be trusted to answer
# a question about <site>? Echoes a reason on the non-zero paths. States:
#   rc 0  legible          — the file exists and parses; ask it for fields
#   rc 1  absent-by-context— no config and no sites/<site>/ on disk: a fresh
#                            clone, a CI job, or a worktree. Silent default.
#   rc 2  CANNOT VERIFY    — the file EXISTS and does not parse. Guards refuse.
#   rc 3  absent-but-site-present — no config, yet sites/<site>/ is on disk.
#                            Default applies, but LOUDLY (see below).
#
# ⚠ NEVER call this (or the getters that wrap it) and expect a warning: rc 3's
# message must be printed by the GUARDS, because print_warning writes to stdout
# and the getters are consumed inside $( ).
_canonical_config_state() {
    local site="$1"
    local config="${2:-$(canonical_config_file)}"
    local root="${PROJECT_ROOT:-$HOME/nwp}"

    if [ ! -f "$config" ]; then
        if [ -n "$site" ] && [ -d "${root}/sites/${site}" ]; then
            printf "%s is missing, so '%s' fell back to the built-in defaults (canonical: dev, maturity: incubating) — those are the WEAKEST settings, and they were not read from anywhere\n" \
                "$config" "$site"
            return 3
        fi
        return 1
    fi

    # The file exists. It must PARSE, or every field read below silently returns
    # empty and empty is the permissive branch. yq-first; without yq the awk
    # fallback readers cannot detect corruption, so a yq-less host is itself a
    # legibility question — but refusing the whole fleet for a missing binary is
    # the wrong trade (same call lib/pair.sh's _pair_contract_side makes), so we
    # only verify parseability when we have a parser.
    local yq_bin; yq_bin="$(command -v yq || true)"
    [ -n "$yq_bin" ] || return 0
    if ! "$yq_bin" e '.' "$config" >/dev/null 2>&1; then
        printf "%s exists but does not parse as YAML, so the canonical phase and maturity class it declares cannot be read\n" "$config"
        return 2
    fi
    return 0
}

# _canonical_no_registry_warn <site> [config] — rc 3 handling. The defaults still
# apply (refusing here would break ordinary work — see the header), but the
# condition is announced instead of being silently indistinguishable from a
# real, read `canonical: dev`. Silence was half the original defect.
_canonical_no_registry_warn() {
    local site="$1"
    local config="${2:-$(canonical_config_file)}"
    local why; why=$(_canonical_config_state "$site" "$config"); [ $? -eq 3 ] || return 0
    print_warning "$why"
    print_warning "  If '$site' is meant to be canonical: live / maturity: production, this deploy is NOT being gated. Check your checkout."
    return 0
}

# _canonical_soft_ok <what> <site> <reason> — shared CANNOT-VERIFY handling.
# rc 0 ⇒ caller may PROCEED (NWP_CANONICAL_GATE_SOFT=true, audited);
# rc 1 ⇒ caller must REFUSE.
_canonical_soft_ok() {
    local what="$1" site="$2" reason="$3"
    if [ "${NWP_CANONICAL_GATE_SOFT:-false}" = "true" ]; then
        print_warning "$what: CANNOT VERIFY '$site' — NWP_CANONICAL_GATE_SOFT=true, proceeding:"
        print_warning "  - $reason"
        canonical_ledger_append "$site" "action=cannot-verify-soft-skip guard=$what reason=$reason"
        return 0
    fi
    print_error "REFUSED: cannot verify '$site' — $reason"
    print_error "This is NOT a clean result: the guard is allowing nothing because it could not look,"
    print_error "not because it looked and found nothing to enforce."
    print_info  "Fix the config, or run from a checkout that has it. To proceed anyway (audited):"
    print_info  "  NWP_CANONICAL_GATE_SOFT=true pl <cmd> ..."
    return 1
}

# Global nwp.yml (user config, never committed). NWP_YML override exists so
# tests can point at a fixture without cd-ing into a repo root.
canonical_config_file() {
    echo "${NWP_YML:-${PROJECT_ROOT:-$HOME/nwp}/nwp.yml}"
}

canonical_ledger_dir() {
    echo "${PROJECT_ROOT:-$HOME/nwp}/private/canonical"
}

canonical_actor() {
    echo "$(id -un)@$(hostname -s 2>/dev/null || hostname)"
}

# Echo the site's phase. Absent/unregistered → "dev" (back-compat default);
# present but not dev|live|prod → "invalid:<raw>" so guards fail closed;
# config unreadable → "cannot-verify:<reason>" so guards fail closed too.
# Always returns 0 (callers run under set -e); use canonical_phase_is_explicit
# to distinguish an explicit "dev" from the default.
canonical_get_phase() {
    local site="$1"
    local config="${2:-$(canonical_config_file)}"
    local why; why=$(_canonical_config_state "$site" "$config"); local st=$?
    if [ "$st" -eq 2 ]; then echo "cannot-verify:$why"; return 0; fi
    local raw=""
    if [ "$st" -eq 0 ] && [ -n "$site" ]; then
        raw=$(yaml_get_site_field "$site" "canonical" "$config" 2>/dev/null || true)
    fi
    case "$raw" in
        dev|live|prod) echo "$raw" ;;
        "")            echo "dev" ;;
        *)             echo "invalid:$raw" ;;
    esac
    return 0
}

# 0 if sites.<site>.canonical is present and valid in nwp.yml
canonical_phase_is_explicit() {
    local site="$1"
    local config="${2:-$(canonical_config_file)}"
    [ -f "$config" ] || return 1
    local raw
    raw=$(yaml_get_site_field "$site" "canonical" "$config" 2>/dev/null || true)
    case "$raw" in
        dev|live|prod) return 0 ;;
        *)             return 1 ;;
    esac
}

# Append-only transition/override ledger (private/, never committed)
canonical_ledger_append() {
    local site="$1"; shift
    local dir; dir="$(canonical_ledger_dir)"
    mkdir -p "$dir"
    echo "$(date -u +%FT%TZ) who=$(canonical_actor) $*" >> "$dir/${site}.log"
}

################################################################################
# Guards — called by nwp processes, not just documented
################################################################################

# Guard a CONTENT push toward <target>. Returns 0 = allowed, 1 = refused.
#   $1 site, $2 target (live|prod), $3 override (true|false), $4 cmd label
# Rules:
#   target=live: allowed only when canonical: dev (dev is the source).
#   target=prod: refused only when canonical: prod (content changes on prod
#                only); the live→prod push is the cutover path under dev/live.
# --override escape: proceeds with a loud warning + a ledger record of
# who/when/what — the clobber is then an audited operator decision.
canonical_guard_content_push() {
    local site="$1"
    local target="$2"
    local override="${3:-false}"
    local cmd="${4:-content-push}"

    local phase; phase=$(canonical_get_phase "$site")

    # CANNOT VERIFY is decided BEFORE the override, and before the per-target
    # rules: --override-canonical is a decision to clobber a phase you KNOW,
    # not a licence to deploy past a config nobody can read.
    if [ "${phase#cannot-verify:}" != "$phase" ]; then
        _canonical_soft_ok "canonical_guard_content_push ($cmd → $target)" \
            "$site" "${phase#cannot-verify:}" || return 1
        return 0
    fi
    _canonical_no_registry_warn "$site"

    case "$target" in
        live) [ "$phase" = "dev" ] && return 0 ;;
        prod) case "$phase" in dev|live) return 0 ;; esac ;;
        *) print_error "canonical_guard_content_push: unknown target '$target'"; return 1 ;;
    esac

    case "$phase" in
        invalid:*)
            print_error "Site '$site' has an unrecognized canonical phase in nwp.yml: '${phase#invalid:}'"
            print_error "Guards fail closed on unparseable phases. Fix it: pl canonical set $site <dev|live|prod>"
            ;;
    esac

    if [ "$override" = "true" ]; then
        echo "" >&2
        print_warning "════════════════════════════════════════════════════════════════"
        print_warning "CANONICAL OVERRIDE: pushing content to $target while '$site' is"
        print_warning "canonical: $phase — this OVERWRITES the canonical content source."
        print_warning "This action is recorded in private/canonical/${site}.log."
        print_warning "════════════════════════════════════════════════════════════════"
        echo "" >&2
        canonical_ledger_append "$site" "action=override cmd=$cmd target=$target phase=$phase"
        return 0
    fi

    print_error "REFUSED: '$site' is canonical: $phase — content changes belong on $phase."
    print_error "A $cmd content push would clobber the canonical $phase content."
    print_info  "The supported flow while canonical: $phase is a SANITIZED pull toward dev:"
    print_info  "  pl live2stg $site          # sanitized live → stg"
    print_info  "  pl import $site            # pull from the canonical host"
    if [ "$target" = "live" ]; then
        print_info "Code/config-only deploys are still allowed: re-run with --code-only."
    fi
    print_info  "To push content anyway (clobbers $phase): re-run with --override-canonical."
    return 1
}

# When canonical != dev, content authored on dev is throwaway — surface it.
canonical_warn_dev_content() {
    local site="$1"
    local phase; phase=$(canonical_get_phase "$site")
    if [ "${phase#cannot-verify:}" != "$phase" ]; then
        print_warning "'$site': CANNOT VERIFY the canonical phase — ${phase#cannot-verify:}"
        print_warning "Content authored on dev may be THROWAWAY; the deploy guards will refuse until this is fixed."
        return 0
    fi
    [ "$phase" = "dev" ] && return 0
    print_warning "'$site' is canonical: $phase — content authored on dev/stg is THROWAWAY."
    print_warning "It will be overwritten by the next sanitized $phase→dev refresh and can never be pushed to $phase."
    return 0
}

# canonical: prod ⇒ branch-only work + deploys from clean main (ADR-0024).
#   $1 site, $2 mode: "work" (dev2stg) | "deploy" (stg2live/stg2prod/live2prod)
#   work:   refuse UNCOMMITTED changes sitting on main (work belongs on a
#           branch); committed main state and feature branches are fine.
#   deploy: refuse anything that is not a CLEAN checkout of main/master —
#           deploys must come from the CI-gated protected main, not from an
#           unmerged branch or a dirty tree.
# If the site has no resolvable dev git repo the policy can't be evaluated:
# warn and allow (the content-push guard above remains the hard gate).
canonical_enforce_branch_policy() {
    local site="$1"
    local mode="${2:-deploy}"

    local phase; phase=$(canonical_get_phase "$site")
    # "not prod" must be something we LOOKED UP, not something we defaulted to
    # because the config was unreadable. This guard is unconditional on every
    # stg2live/stg2prod/live2prod (including --code-only), so it is the choke
    # point that makes an unreadable config refuse the whole deploy.
    if [ "${phase#cannot-verify:}" != "$phase" ]; then
        _canonical_soft_ok "canonical_enforce_branch_policy ($mode)" \
            "$site" "${phase#cannot-verify:}" || return 1
        return 0
    fi
    _canonical_no_registry_warn "$site"
    [ "$phase" = "prod" ] || return 0

    local dev_dir=""
    if command -v resolve_project >/dev/null 2>&1; then
        dev_dir=$(resolve_project "$site" "dev" 2>/dev/null || true)
    fi
    if [ -z "$dev_dir" ] || [ ! -d "$dev_dir/.git" ]; then
        print_warning "canonical: prod branch policy: no git repo found for '$site' dev — cannot verify branch-only rule."
        return 0
    fi

    local branch dirty=false
    branch=$(git -C "$dev_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
    [ -n "$(git -C "$dev_dir" status --porcelain 2>/dev/null)" ] && dirty=true

    if [ "$mode" = "work" ]; then
        if { [ "$branch" = "main" ] || [ "$branch" = "master" ]; } && [ "$dirty" = "true" ]; then
            print_error "REFUSED: '$site' is canonical: prod — main is protected; work on branches only."
            print_error "The dev repo ($dev_dir) has uncommitted changes directly on '$branch'."
            print_info  "Move the work to a branch: git -C $dev_dir switch -c <feature-branch>"
            return 1
        fi
        return 0
    fi

    # mode=deploy
    if [ "$branch" != "main" ] && [ "$branch" != "master" ]; then
        print_error "REFUSED: '$site' is canonical: prod — deploys must come from the CI-gated main."
        print_error "The dev repo ($dev_dir) is on branch '$branch'. Merge via MR (protected main), then deploy."
        return 1
    fi
    if [ "$dirty" = "true" ]; then
        print_error "REFUSED: '$site' is canonical: prod — deploys must come from a CLEAN main."
        print_error "The dev repo ($dev_dir) has uncommitted changes. Commit via a branch + MR, or stash."
        return 1
    fi
    return 0
}

################################################################################
# Manifest stamping — every backup/deploy records the phase it ran under
################################################################################

# Write a deploy manifest JSON stamped with the canonical phase.
#   $1 site, $2 action (stg2live|dev2stg|...), remaining args: key=value extras
# Output path: private/deploys/<site>/<action>-<utc-ts>.json (echoed).
canonical_deploy_manifest() {
    local site="$1"
    local action="$2"
    shift 2

    local dir="${PROJECT_ROOT:-$HOME/nwp}/private/deploys/${site}"
    mkdir -p "$dir"
    local ts; ts=$(date -u +%Y%m%dT%H%M%SZ)
    local file="$dir/${action}-${ts}.json"

    local nwp_sha=""
    if [ -d "${PROJECT_ROOT:-$HOME/nwp}/.git" ]; then
        nwp_sha=$(git -C "${PROJECT_ROOT:-$HOME/nwp}" rev-parse HEAD 2>/dev/null || true)
    fi

    # A cannot-verify verdict carries a whole sentence; keep the manifest honest
    # but JSON-safe by stamping the bare verdict. (Reaching here at all means a
    # guard let it through under NWP_CANONICAL_GATE_SOFT, which is ledgered.)
    local _mf_phase _mf_class
    _mf_phase="$(canonical_get_phase "$site")"; case "$_mf_phase" in cannot-verify:*) _mf_phase="cannot-verify" ;; esac
    _mf_class="$(maturity_get_class "$site")";  case "$_mf_class"  in cannot-verify:*) _mf_class="cannot-verify"  ;; esac

    {
        printf '{\n'
        printf '  "site": "%s",\n' "$site"
        printf '  "action": "%s",\n' "$action"
        printf '  "canonical_phase": "%s",\n' "$_mf_phase"
        printf '  "maturity": "%s",\n' "$_mf_class"
        printf '  "timestamp": "%s",\n' "$(date -u +%FT%TZ)"
        printf '  "by": "%s",\n' "$(canonical_actor)"
        printf '  "nwp_sha": "%s"' "$nwp_sha"
        local kv
        for kv in "$@"; do
            printf ',\n  "%s": "%s"' "${kv%%=*}" "${kv#*=}"
        done
        printf '\n}\n'
    } > "$file"

    echo "$file"
}

################################################################################
# Maturity classes — the CODE-flow axis beside canonical's content axis (P67)
#
#   incubating  (default) — direct pl stg2live allowed (A14 test tier);
#                agent-loop may work promoted issues; today's behavior.
#   stabilizing — code reaches live only from a clean checkout of main that is
#                fully merged to origin/main; direct pushes from a branch or
#                dirty tree are refused.
#   production  — direct SSH/rsync deploys refused outright; deploys go via
#                the signed-bundle path (pl build-server / server-pull /
#                server-apply) or the ADR-0024 protected runner once its
#                preconditions land. WebAuthn-gated merge is the authority.
#
# Same contract as the canonical phase: absent field = incubating (zero
# behavior change until the operator sets a class); unparseable values fail
# closed in every guard. Transitions via `pl maturity set` (ledgered).
################################################################################

MATURITY_CLASSES="incubating stabilizing production"

# Echo the site's maturity class. Absent/unregistered → "incubating";
# present but unrecognized → "invalid:<raw>" so guards fail closed; config
# unreadable → "cannot-verify:<reason>" so guards fail closed too.
# Always returns 0 (callers run under set -e).
maturity_get_class() {
    local site="$1"
    local config="${2:-$(canonical_config_file)}"
    local why; why=$(_canonical_config_state "$site" "$config"); local st=$?
    if [ "$st" -eq 2 ]; then echo "cannot-verify:$why"; return 0; fi
    local raw=""
    if [ "$st" -eq 0 ] && [ -n "$site" ]; then
        raw=$(yaml_get_site_field "$site" "maturity" "$config" 2>/dev/null || true)
    fi
    case "$raw" in
        incubating|stabilizing|production) echo "$raw" ;;
        "")                                echo "incubating" ;;
        *)                                 echo "invalid:$raw" ;;
    esac
    return 0
}

# 0 if sites.<site>.maturity is present and valid in nwp.yml
maturity_class_is_explicit() {
    local site="$1"
    local config="${2:-$(canonical_config_file)}"
    [ -f "$config" ] || return 1
    local raw
    raw=$(yaml_get_site_field "$site" "maturity" "$config" 2>/dev/null || true)
    case "$raw" in
        incubating|stabilizing|production) return 0 ;;
        *)                                 return 1 ;;
    esac
}

# Validate a (maturity, canonical) pair. The invalid corners (P67 §2):
#   incubating + canonical:prod  — prod content demands prod code discipline
#   production + canonical:dev   — a production site whose content source of
#                                  truth is a dev DDEV box is a contradiction
# Returns 0 = valid; 1 = invalid (prints why).
maturity_validate_pair() {
    local class="$1"
    local phase="$2"
    case "$class:$phase" in
        incubating:prod)
            print_error "Invalid pair: maturity 'incubating' with canonical 'prod' — prod content demands at least 'stabilizing' code discipline."
            return 1 ;;
        production:dev)
            print_error "Invalid pair: maturity 'production' with canonical 'dev' — a production site cannot have its content source of truth on a dev box."
            return 1 ;;
    esac
    return 0
}

# Guard a CODE deploy per the site's maturity class. Returns 0 allow, 1 refuse.
#   $1 site, $2 cmd label (stg2live|stg2prod|live2prod|...)
# incubating: allowed. stabilizing: only from a clean checkout of main that is
# fully merged to origin/main (nothing local-only). production: refused —
# points at the signed-bundle path. Invalid class: fail closed.
maturity_guard_deploy() {
    local site="$1"
    local cmd="${2:-deploy}"

    local class; class=$(maturity_get_class "$site")
    _canonical_no_registry_warn "$site"
    case "$class" in
        cannot-verify:*)
            # NOT the same as "incubating". maturity: production has no override
            # by design, so collapsing an unreadable config to the default was
            # the ONLY way past it.
            _canonical_soft_ok "maturity_guard_deploy ($cmd)" \
                "$site" "${class#cannot-verify:}" || return 1
            return 0 ;;
        incubating) return 0 ;;
        invalid:*)
            print_error "Site '$site' has an unrecognized maturity class in nwp.yml: '${class#invalid:}'"
            print_error "Guards fail closed on unparseable classes. Fix it: pl maturity set $site <incubating|stabilizing|production>"
            return 1 ;;
        production)
            print_error "REFUSED: '$site' is maturity: production — direct $cmd deploys are not allowed."
            print_info  "Production code ships via the signed-bundle path:"
            print_info  "  pl build-server && pl server-pull ... && pl server-apply ...   (ADR-0026)"
            print_info  "or the protected prod-deploy runner once ADR-0024's preconditions land."
            print_info  "To change the class (ledgered): pl maturity set $site stabilizing"
            return 1 ;;
    esac

    # stabilizing: require clean main, fully merged to origin/main
    local dev_dir=""
    if command -v resolve_project >/dev/null 2>&1; then
        dev_dir=$(resolve_project "$site" "dev" 2>/dev/null || true)
    fi
    if [ -z "$dev_dir" ] || [ ! -d "$dev_dir/.git" ]; then
        print_warning "maturity: stabilizing — no git repo found for '$site' dev; cannot verify the merged-main rule (allowing; the canonical guards still apply)."
        return 0
    fi

    local branch dirty=false ahead=0
    branch=$(git -C "$dev_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
    [ -n "$(git -C "$dev_dir" status --porcelain 2>/dev/null)" ] && dirty=true
    if git -C "$dev_dir" rev-parse --verify -q origin/main >/dev/null 2>&1; then
        ahead=$(git -C "$dev_dir" rev-list --count origin/main..HEAD 2>/dev/null || echo 0)
    fi

    if [ "$branch" != "main" ] && [ "$branch" != "master" ]; then
        print_error "REFUSED: '$site' is maturity: stabilizing — deploys only from main (repo is on '$branch')."
        print_info  "Merge via MR, then: git -C $dev_dir switch main && git pull"
        return 1
    fi
    if [ "$dirty" = "true" ]; then
        print_error "REFUSED: '$site' is maturity: stabilizing — the working tree has uncommitted changes."
        return 1
    fi
    if [ "${ahead:-0}" -gt 0 ]; then
        print_error "REFUSED: '$site' is maturity: stabilizing — main has $ahead commit(s) not on origin/main (unmerged/unpushed)."
        print_info  "Push + merge via MR first; deploys ship only reviewed, merged code."
        return 1
    fi
    return 0
}

################################################################################
# Branch-twin lineage (P67 §5b/§5c) — sites that are branches of another site
################################################################################

# Echo the parent site name if <site> is a branch twin, else nothing.
site_branch_parent() {
    local site="$1"
    local config="${2:-$(canonical_config_file)}"
    yaml_get_site_field "$site" "branch_of" "$config" 2>/dev/null || true
}

# Code delta of a repo vs origin/main: echoes "+<ahead>/-<behind>" (or "?" when
# no origin/main ref exists, or "=" when even).
site_code_delta() {
    local dev_dir="$1"
    [ -d "$dev_dir/.git" ] || { echo "?"; return 0; }
    if ! git -C "$dev_dir" rev-parse --verify -q origin/main >/dev/null 2>&1; then
        echo "?"
        return 0
    fi
    local counts behind ahead
    counts=$(git -C "$dev_dir" rev-list --left-right --count origin/main...HEAD 2>/dev/null) || { echo "?"; return 0; }
    behind=$(awk '{print $1}' <<< "$counts")
    ahead=$(awk '{print $2}' <<< "$counts")
    if [ "${ahead:-0}" -eq 0 ] && [ "${behind:-0}" -eq 0 ]; then
        echo "="
    else
        echo "+${ahead:-0}/-${behind:-0}"
    fi
    return 0
}

# Content provenance display: "canonical" for a site that owns its content,
# else "<source>@<MM-DD>" from the content_source/content_as_of stamps
# (written by pl branch / pl branch content), "?" when unstamped.
site_content_provenance() {
    local site="$1"
    local config="${2:-$(canonical_config_file)}"
    local parent
    parent=$(site_branch_parent "$site" "$config")
    local src as_of
    src=$(yaml_get_site_field "$site" "content_source" "$config" 2>/dev/null || true)
    as_of=$(yaml_get_site_field "$site" "content_as_of" "$config" 2>/dev/null || true)
    if [ -z "$src" ]; then
        if [ -z "$parent" ]; then
            echo "canonical"
        else
            echo "?"
        fi
        return 0
    fi
    local short=""
    [ -n "$as_of" ] && short="@$(cut -c6-10 <<< "$as_of")"
    echo "${src}${short}"
    return 0
}
