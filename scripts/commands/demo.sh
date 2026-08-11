#!/bin/bash
set -euo pipefail
################################################################################
# scripts/commands/demo.sh — daily-reset demo tier (ops#133 Phase 1)
#
# The nwd demo pair's operational surface (DAILY-DEMO-TIER-PROPOSAL-2026-07-25,
# decisions §4): capture a golden image, reset the site back to it nightly
# (activity-guarded), and manage the hashed invite-code registry the
# nwc_demo_access module redeems against.
#
#   pl demo golden <site>                     capture current state as golden
#   pl demo reset  <site> [--if-idle 30m]     verified restore + reseed + cr
#   pl demo nightly <site>                    scheduled entrypoint (retry loop)
#   pl demo status <site>                     last reset/skips, golden, codes
#   pl demo codes  <site> list|issue|revoke|rotate|sync|drift
#   pl demo invite <site> [--bundles a,b] [--expiry 14d] [--all]
#                                             copy-ready invite email, one
#                                             fresh code per level (0600 draft)
#   pl demo schedule <site> [--remove]        install the 01:00 Melbourne cron
#
# GUARDS (fail-closed):
#   * reset prints a COMPUTED fate manifest before it destroys anything
#     (lib/impact.sh, nwp/ops#47): what is erased, what replaces it (golden
#     sha256 + capture time + age), what survives. `-y`/cron skip the PROMPT,
#     never the REPORT — the manifest is rendered and logged on every run,
#     including the unattended ones. --dry-run prints it and stops.
#   * reset only proceeds when the golden manifest names THIS site and both
#     artifacts pass sha256 verification (demo_golden_verify).
#   * reset is tier-scoped: dev|stg act on the local DDEV pair, live acts on
#     the remote demo host over ssh (Phase 2). --tier=prod is always REFUSED.
#     A LIVE reset additionally requires the remote site to report
#     demo_mode=true, and re-verifies the uploaded golden ON the remote host
#     BEFORE dropping anything — so a bad upload can never leave a wiped host
#     with nothing to restore.
#   * --if-idle treats a failed/garbled sessions query as ACTIVE (never
#     green-lights a wipe on bad data); "active" exits DEMO_EXIT_ACTIVE (3),
#     distinct from errors, so the nightly wrapper can retry.
#   * codes are hashed (sha256) before they ever touch disk or the site;
#     `issue`/`rotate` print the plaintext exactly ONCE and never store it.
#   * a code verb REFUSES on a host that cannot deliver to the named tier
#     (demo_require_delivery, nwp/ops#173). The registry has ONE writable home
#     per tier — the host that can reach that tier — and everywhere else it is
#     a read-only replica. `pl demo codes <site> drift` compares the three
#     numbers that must agree and leaves the record pl todo/pl rag grade.
################################################################################

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"
PROJECT_ROOT="${PROJECT_ROOT:-$REPO_ROOT}"

source "$REPO_ROOT/lib/ui.sh"
source "$REPO_ROOT/lib/common.sh"
# shellcheck source=/dev/null
source "$REPO_ROOT/lib/demo-smoke.sh"
source "$REPO_ROOT/lib/impact.sh"        # ops#47 impact contract (fate manifest)
source "$REPO_ROOT/lib/demo.sh"
source "$REPO_ROOT/lib/demo-pair.sh"     # paired golden/reset (ops#133 Phase 2)
source "$REPO_ROOT/lib/demo-live-moodle.sh"  # Moodle half of the LIVE tier (ops#170)
source "$REPO_ROOT/lib/demo-box-status.sh"   # the BOX's own reset record (ops#198)
source "$REPO_ROOT/lib/demo-walkthrough.sh"  # walkthrough target catalogue (ops#328 t5)
source "$REPO_ROOT/lib/canonical.sh"     # canonical_get_phase — the PROD-PHASE guard
source "$REPO_ROOT/lib/deploy-gate.sh"   # deploy_gate_require (live tier only)

# Names of the golden artifacts inside sites/<site>/demo-golden/.
GOLDEN_DB="golden.db.sql.gz"
GOLDEN_FILES="golden.files.tar.gz"

show_help() {
    cat <<EOF
${BOLD}NWP Demo — daily-reset demo tier (ops#133 Phase 1 + Phase 2 pairing)${NC}

${BOLD}USAGE:${NC}
    pl demo <subcommand> <site> [options]

${BOLD}SUBCOMMANDS:${NC}
    golden <site> [--with-pair] [--no-stage]
                                  Capture the current state as the golden image
                                  AND stage it to the box (sha256-verified there)
                                  so the nightly reset restores THIS capture.
                                  --no-stage captures locally only — the box
                                  keeps its previous image and the verb says so.
                                  (verified DB dump + files tar + manifest under
                                  sites/<site>/demo-golden/). REFUSES to capture
                                  a site whose own modules' shipped config was
                                  never installed — see --allow-config-gaps.
                                  With a demo PAIR (pairs/<consumer>.pair-
                                  contract.yml carrying demo.enabled: true)
                                  BOTH halves are captured back-to-back and
                                  bound into one "cut" (pair.cut.json) —
                                  pairing is AUTOMATIC when the partner has an
                                  instance at this tier; --with-pair demands
                                  it, --no-pair suppresses. At --tier=live an
                                  "instance" is a configured live HOST, pairing
                                  is OPT-IN (pass --with-pair; a bare live
                                  capture stays single-site), and the cut is
                                  written into demo-golden-live/ carrying
                                  tier=live — a dev cut can never authorise a
                                  live restore.
    reset <site> [--if-idle 30m] [--force] [--yes] [--skip-seed] [--dry-run]
          [--no-pair]
                                  Prints a FATE MANIFEST (what is destroyed,
                                  what replaces it, what survives — all
                                  measured live), then: pre-wipe error harvest
                                  (watchdog → spool, fail-open), verified
                                  restore of the golden image, drush
                                  nwc:seed-demo, code re-sync, cache rebuild.
                                  --if-idle: skip (exit 3) if any session was
                                  active within the window. --dry-run: print
                                  the manifest and stop, touching nothing.
                                  PAIRED (default when the contract opts in):
                                  verifies BOTH goldens AND that they are still
                                  one cut, idle-guards BOTH, harvests BOTH into
                                  one spool, restores provider-first, then
                                  re-asserts the consumer's OIDC wiring, demo
                                  posture and course catalogue. Naming EITHER
                                  half runs the paired reset; --no-pair is the
                                  explicit single-site override and warns.
                                  AT --tier=live THE PAIRED RESET IS OPT-IN:
                                  it runs only with an explicit --with-pair.
                                  Without it, a live reset of a coupled half
                                  REFUSES and names the flag — it never quietly
                                  falls back to wiping one host. The live paired
                                  reset also: takes the box's own nightly-wrapper
                                  pair lock plus a local one-writer lock,
                                  pre-flights BOTH hosts (reachable + demo_mode)
                                  before destroying anything, stages BOTH goldens
                                  on the box and re-verifies them there first,
                                  and — if the second half still fails — RECORDS
                                  the split pair in sites/<provider>/demo-pair-
                                  INCONSISTENT.json, prints the repair command
                                  and exits non-zero. Re-running repairs it.
    nightly <site>                Scheduled entrypoint: reset --if-idle 30m,
                                  retrying every 30 min until the 04:00
                                  ${DEMO_TZ} floor, then skip + log.
    nightly <site> --tier=live --via-key [--host <[user@]ip>] [--dry-run]
                                  THE ARMED NIGHTLY (met). Hands the wipe to
                                  the box's restricted forced command — same
                                  key, same action word, same box-resident
                                  golden as the bare ssh line it replaces, and
                                  still no admin key and no root on the box.
                                  What it adds is the OTHER two legs (ops#315):
                                  BEFORE the wipe it asks the box's own
                                  feedback-sync action word to push pending
                                  tester feedback (falling back to a local
                                  drush transport where the box wrapper is
                                  older or its token is not yet staged, and
                                  LOGGING the gap when neither exists); after
                                  the reset it drains the box's pre-wipe error
                                  digests (read-only, evidence copy kept here)
                                  and asks the box's harvest-post word to file
                                  them as nwp/ops issues, box-side dedup via
                                  posted/. Every leg fail-OPEN: none can
                                  change the reset's exit code.
                                  --dry-run sends the box's 'dry-run' word and
                                  syncs nothing. Never enters cmd_reset, so the
                                  paired-half refusal does not apply — the pair
                                  invariant is held by the box's own pair lock.
    harvest-pull <site> --tier=live
                                  Drain the LIVE box's spooled pre-wipe error
                                  digests into the local spool. Read-only on the
                                  box and deduplicated locally, so re-running is
                                  free. Pair with harvest-post; without this the
                                  box's digests age out and are lost.
    smoke <site> --tier=live      Assert the invite email's PROMISES against what
                                  the site actually serves: every route it sends
                                  testers to, the SSO button on the partner half,
                                  and that the site names ITSELF and not its
                                  partner. Read-only (GET only), so it is safe
                                  against live and runnable from CI.
    status <site>                 Golden capture info, recent resets/skips,
                                  invite-code summary.
    seal-status <site> [--tier=live] [--json]
                                  What will tonight's reset restore? Reads the
                                  BOX-STAGED golden's capture time (the number
                                  that decides — ops#269), the box's last-reset
                                  stamp and the reset window. Fail-closed:
                                  unreachable box / unreadable manifest is exit
                                  2 CANNOT VERIFY, never "no golden". Feeds the
                                  console demo tab's seal banner (ops#328).
    walkthrough <site> [--verify] [--json] [--tier=live]
                                  Every place the operator can jump into on
                                  this demo pair — guilds (with the site's OWN
                                  group ids), stream, about, the guild tools,
                                  every feedback/triage queue — on BOTH halves,
                                  plus whether each one still resolves. Feeds
                                  the console's Visuals ▸ walkthrough subtab
                                  (ops#328 t5). Reads are cheap; --verify
                                  MEASURES (one \`drush route\` read for the
                                  provider — the router is the only instrument
                                  that can prove a route is ABSENT, since both
                                  halves theme their own 404s — plus one HTTP
                                  probe per distinct consumer path) and records
                                  the verdict under private/demo-walkthrough/.
                                  A target nobody measured is UNKNOWN, never
                                  verified. --verify is refused on a site whose
                                  canonical phase is prod.
    codes <site> list [--json]    List codes (hashes only — never plaintext).
                                  --json: structured rows with computed state
                                  (live|revoked|expired) + per-state counts;
                                  an ABSENT registry is ok:true/empty, an
                                  UNREADABLE one is exit 2 ok:false (ops#328).
                                  Each row also carries \`recoverable\`: can its
                                  PLAINTEXT still be found in an invite pack on
                                  this host? true/false/null, and null (no
                                  readable pack dir) NEVER collapses to false.
    codes <site> issue <bundle> [--expires=14d]
                                  Issue a code; plaintext printed ONCE.
    codes <site> reveal <id> [--json]
                                  Show ONE code's plaintext again (ops#328 t4).
                                  The registry stays hash-only: this hashes the
                                  plaintext in sites/<site>/demo-invites/ and
                                  matches the sha256 already stored. Printed
                                  once; written nowhere. An ACCESS record (id +
                                  who, never the value) goes to the demo log.
                                  Home-guarded — the packs live with the
                                  registry (operator ruling 2026-08-11). No
                                  pack directory / an unreadable pack is exit 2
                                  CANNOT VERIFY, never "no such code"; scanned-
                                  and-absent is a named exit-1 NOT RECOVERABLE.
    codes <site> packs inventory|relocate [--apply]
                                  Invite packs belong ON the registry home — a
                                  pack elsewhere is plaintext codes no verb
                                  looks after. \`inventory\` lists what is here
                                  (filenames, code counts, sha256 prefixes —
                                  no plaintext). \`relocate\` copies strays to
                                  the home, PROVES the home's copy is byte-
                                  identical, and only then deletes the local
                                  one; it refuses to overwrite a home pack of
                                  the same name with different content. Dry-run
                                  by default. Endpoint: registry_home_ssh: in
                                  servers/live/demo/registry-home.yml.
    codes <site> revoke <id>...   Revoke code(s) (kept in registry as audit
                                  rows). Several ids = one batch: any bad id
                                  refuses the WHOLE batch before touching any.
    codes <site> purge <id>...    Remove revoked/expired rows from the registry,
                                  archiving them to demo-codes-purged.json.
                                  REFUSES a live id (revoke first). Registry
                                  write → same explicit-tier + delivery guards.
    codes <site> rotate           Revoke every live code, reissue one per
                                  bundle that had one (new plaintexts, once)
    codes <site> sync             Re-push the hashed registry into the site
    codes <site> reconcile --from=<path>[,<path>…] [--apply]
                                  Fold diverged registry copies into the ONE
                                  home (ops#328 D1): union by hash, revoked-
                                  anywhere wins, un-revoked rows adopt the
                                  live-enforced expiry; per-row provenance in
                                  the report. Dry-run by default. --apply
                                  backs up every input, writes the merged
                                  registry, syncs the site, re-stages the box
                                  payload, then DISCHARGES by re-reading the
                                  enforced set. Home-guarded like every write.

    Registry writes (issue/revoke/rotate/sync/purge/reconcile/invite) run ONLY
    on the registry's declared home — registry_home: in servers/live/demo/
    registry-home.yml (the console/agent host — operator ruling 2026-08-09,
    ops#328 D1). \`reveal\` joins them: it reads the invite packs, and the packs
    live with the registry (operator ruling 2026-08-11). Other reads work
    anywhere. One-off ledgered escape hatch:
    NWP_DEMO_REGISTRY_HOME_OVERRIDE='<why>'.
    codes <site> drift [--tier=live]
                                  Compare the THREE numbers that must agree —
                                  registry-active, site-live, and the box's
                                  staged payload (what the 01:00 reset restores
                                  over the top). Read-only; records the result
                                  in private/demo-codes/<site>.json, which
                                  pl todo / pl rag grade AMBER on disagreement.
    testers <site> list [--json]  Roster of the @demo.invalid-fenced tester
                                  accounts, read from the SITE through drush
                                  nwc:tester-list (guilds by seed key + group
                                  roles, sojourner level, consent state, and
                                  the guild/role catalogue the editor renders
                                  from). Fail-closed: an unreadable site or an
                                  undeployed drush command is exit 2 with a
                                  typed JSON reason, never an empty roster.
    testers <site> set-guild <account> <seed-key> [--group-role=ID|member] [--remove]
                                  Per-tester editor write (ops#328 t3): wraps
                                  drush nwc:tester-set-guild. Guilds resolve by
                                  field_group_seed_key, NEVER label; roles are
                                  the real Group-2.x individual-scope ids
                                  (there is no guild-leader — leadership =
                                  guild-admin). Requires an explicit --tier AND
                                  the site reporting demo_mode=true; the drush
                                  side additionally fences on @demo.invalid.
                                  --allow-real is NEVER forwarded from here.
    testers <site> set-level <account> <level>
                                  Raise a tester's Sojourner level THROUGH
                                  EVIDENCE (drush nwc:tester-set-level records
                                  the qualifying course completions and
                                  recomputes) — there is no raw setter, and
                                  demotion is a typed refusal. Same guards as
                                  set-guild.
    testers <site> login <account> --tier=live [--json]
                                  Mint a ONE-TIME LOGIN LINK for a fenced
                                  tester (ops#328 t4) — the personas have no
                                  passwords, so this is the only way to see the
                                  site as one of them. Always passes --name=
                                  and --uri= (the positional slot is a PATH,
                                  not a username: a name there silently returns
                                  a uid-1 ADMIN link), then proves the returned
                                  link's uid matches the roster's before
                                  showing it. Refuses uid<=1 always, refuses
                                  anything off the @demo.invalid fence, and
                                  requires demo_mode=true. The link is a
                                  credential: printed once, never logged, never
                                  stored — the demo log records only that one
                                  was minted, and for whom.
    invite <site> [--bundles a,b] [--expiry 14d] [--all]
                                  Issue ONE fresh code per level and render a
                                  copy-ready invitation email (stdout + a 0600
                                  draft under sites/<site>/demo-invites/ — the
                                  draft holds PLAINTEXT codes; delete unwanted
                                  level blocks, paste into any mail client).
                                  Default levels: member, guild-leader,
                                  content-manager; --all adds both reviewers.
    feedback-sync <site> [--tier=dev|live] [--dry-run]
                                  Push pending tester Feedback entities to
                                  GitLab issues through the module's own
                                  nwc-feedback:sync-to-gitlab (which owns the
                                  classifier, the doctrine body-withholding and
                                  the agent-eligibility fence). Runs
                                  automatically PRE-WIPE inside every
                                  \`pl demo reset\`; this is the hand/scheduled
                                  entrypoint. REFUSES to push from a site whose
                                  deployed nwc_feedback cannot be proven to
                                  carry the ops#140 minimisation — a payload
                                  that still names the submitter never leaves.
    harvest-post <site> [--dry-run]
                                  Drain sites/<site>/demo-harvest/ into nwp/ops
                                  issues (labels ${DEMO_HARVEST_LABELS};
                                  least-privilege gitlab.ops_note_token).
                                  Retry-safe: only posted digests are moved to
                                  demo-harvest/posted/. A digest whose basename
                                  already sits under triaged-*/ is SKIPPED —
                                  triage is terminal (ops#233).
    harvest-triage <site> [--mark=<basename>]... [--mark-all] [--dry-run]
                                  Reconcile the spool, posted/ and triaged-*/
                                  (they were mutually blind — ops#189-193 were
                                  five re-posts of already-mined digests). Lists
                                  posted-but-untriaged digests WITH the nwp/ops
                                  issue each became (from demo-reset.log),
                                  detects double-posts (exit 1), and --mark /
                                  --mark-all MOVES a digest to triaged-<today>/
                                  and records the move. The human still does
                                  the classifying — this verb is lifecycle
                                  only. Fail-closed: an unreadable dir is exit
                                  2 CANNOT VERIFY, never "empty".
    schedule <site> [--tier=live] [--remove] [--via-key] [--raw-ssh]
             [--host <[user@]ip>] [--print-only] [--feedback-status]
                                  Install/remove the nightly cron on THIS
                                  machine (intended host: met).
                                  --via-key schedules the RESTRICTED
                                  forced-command key (~/.ssh/<site>_demo_reset →
                                  /usr/local/bin/nwd-demo-reset-restricted on
                                  the box): no admin key, and no root on the
                                  box. The line it writes runs
                                  'pl demo nightly <site> --tier=live --via-key
                                  --host <box>' (ops#156), so the pre-wipe
                                  feedback sync and the post-reset harvest drain
                                  happen; the checkout must therefore exist on
                                  the SCHEDULER and be new enough to know the
                                  flag. --raw-ssh writes the older bare-ssh line
                                  instead, for a scheduler with the key and no
                                  checkout — it resets and does nothing else.
                                  Fires every 30 min 01:00–03:30 ${DEMO_TZ}
                                  (the wrapper is idempotent), giving the same
                                  ${DEMO_FLOOR_TIME} floor without holding a
                                  3-hour ssh session open.
                                  --feedback-status (ops#219 Phase A): install
                                  the HOURLY return leg instead — the box's own
                                  feedback-status action word runs the module's
                                  nwc-feedback:sync-status with its walled
                                  token, so /my/feedback stops saying "Sent to
                                  the team" for ever. Its own marker block;
                                  installed/removed independently of the
                                  nightly. Provider (nwd) only; requires
                                  --via-key.
                                  --host (or NWP_DEMO_BOX_HOST) names the box
                                  directly, so --via-key can run on a scheduler
                                  that has no sites/<site>/.nwp.yml — which is
                                  the whole point of --via-key and was, until
                                  ops#171, the one thing it could not do.
                                  --print-only emits the 3-line block on stdout
                                  and touches no crontab at all: generate it
                                  where the config is, install it where the
                                  scheduler is. The block is byte-identical to
                                  what the install path writes.

${BOLD}OPTIONS:${NC}
    --with-pair        Demand the paired path (refuse if the pair or the
                       partner instance is unavailable). REQUIRED at
                       --tier=live: there the paired path is opt-in, because it
                       destroys two live hosts and has not yet had a supervised
                       run. dev/stg still pair automatically.
    --no-pair          Operator override: act on this site alone even though it
                       is half of a demo pair. Leaves the other half holding
                       SSO locks against accounts that no longer exist — only
                       correct when you are about to re-capture the pair.
    --tier=dev|stg|live  Which instance to act on (default: dev). dev|stg are
                       the local DDEV pair; live acts on the remote demo host
                       over ssh (golden = remote dump+tar pulled back and
                       sha-verified; reset = upload, re-verify ON the remote,
                       then drop/restore/reseed). --tier=prod is always
                       REFUSED, and a live reset additionally refuses unless
                       the remote site reports demo_mode=true.
                       ${BOLD}REQUIRED${NC} — no default — for the verbs that write
                       invite codes into a running site: 'invite', and
                       'codes issue|revoke|rotate|sync'. An invitation whose
                       codes were quietly synced to the local dev project is
                       an invitation nobody can redeem, and the operator is
                       shown a success either way, so those verbs refuse
                       until the tier is named. 'codes list' and the
                       read-only verbs keep the dev default.
                       Naming the tier is necessary but not sufficient: those
                       same verbs then REFUSE on a host with no delivery path
                       to it (ops#173 — the console host named --tier=live
                       correctly and still could not reach the box).
    --if-idle <dur>    Only reset when no session activity within <dur>
                       (e.g. 30m). Active → exit ${DEMO_EXIT_ACTIVE} (retryable), logged as skip.
    --force            Skip the confirmation PROMPT (same as --yes). It never
                       skips the fate manifest — that always prints and is
                       always logged (ops#47 impact contract).
    --dry-run          reset: print the fate manifest and exit without touching
                       anything. harvest-post: list digests, post nothing.
    --skip-seed        Skip drush nwc:seed-demo after restore (non-nwc sites).
    --allow-config-gaps
                       golden: capture even though config-parity FAILED, i.e.
                       config shipped by the site's own modules is missing from
                       the database. Off by default and recorded in the demo
                       log, because a golden is a reference image: capturing an
                       incomplete site freezes the defect into every nightly
                       reset. That is how nwd came to serve a dead /apply link
                       (ops#133 → ops#145). Fix with 'drush nwc:config-heal'
                       instead of reaching for this flag.
    --expires=<dur>    Code lifetime for issue/rotate (default: 14d).

${BOLD}ROLE BUNDLES${NC} (decisions §4.4 — sitemanager is never offered):
    tester-member                 Open Social 'verified' member
    tester-guild-leader           member + Tester's Guild leadership role
    tester-content-manager        Open Social 'contentmanager' (NOT sitemanager)
    tester-copyright-reviewer     + copyright_reviewer role
    tester-safeguarding-reviewer  + safeguarding_reviewer role

  ${BOLD}APPLY-ROUTE BUNDLES${NC} (ops#287 — redeemed on /apply, NOT /demo/join):
      apply-review                  applies for real; operator approves in the queue
      apply-auto                    applies for real; admitted immediately

${BOLD}FILES:${NC}
    sites/<provider>/demo-golden/pair.cut.json
                                    binds the two halves' golden images by
                                    sha256 — the "one logical cut" proof a
                                    paired reset re-checks before wiping
    sites/<site>/demo-golden/       local (dev|stg) golden + sidecars + manifest
    sites/<site>/demo-golden-live/  live golden — tier-scoped so a local image
                                    can never be restored over the live host
    sites/<site>/demo-codes.json    hashed code registry (survives the wipe).
                                    ONE writable home per tier: the host that
                                    can deliver to it. Read-only replica
                                    everywhere else (ops#173).
    private/demo-codes/<site>.json  what THIS host last measured: registry vs
                                    site vs staged payload, with a timestamp
    sites/<site>/demo-reset.log     every reset / skip / harvest, one line each
    sites/<site>/demo-harvest/      pre-wipe error digests awaiting posting
    sites/<site>/demo-harvest/posted/  digests confirmed posted to nwp/ops
    sites/<site>/demo-harvest/triaged-*/  digests a human has mined — TERMINAL
                                    (written by pl demo harvest-triage --mark)
EOF
}

################################################################################
# Small helpers (ddev plumbing — kept out of lib/demo.sh for testability)
################################################################################

# The site's DDEV project dir for the tier.
demo_project_dir() {
    local site="$1" tier="$2"
    local dir
    dir="$(resolve_project "$site" "$tier")" || return 1
    [[ -d "$dir" && -d "$dir/.ddev" ]] || {
        print_error "No DDEV project for '$site' tier '$tier' at $dir"
        return 1
    }
    echo "$dir"
}

# The docroot (web/ or html/) read from .ddev/config.yaml — fail-closed.
demo_docroot() {
    local proj="$1" droot
    droot="$(awk '/^docroot:/ {print $2; exit}' "$proj/.ddev/config.yaml" 2>/dev/null)"
    if [[ -z "$droot" ]]; then
        # ddev default docroot is the project root; nwp sites always set one.
        for d in web html; do [[ -d "$proj/$d/sites/default" ]] && { echo "$d"; return 0; }; done
        print_error "Cannot determine docroot for $proj"
        return 1
    fi
    echo "$droot"
}

demo_drush() {
    local proj="$1"; shift
    ( cd "$proj" && ddev drush "$@" )
}

# dev|stg act on the local DDEV pair; live acts on the remote demo host over
# ssh (Phase 2). prod is still REFUSED: a demo tier never touches a prod site.
demo_check_tier() {
    local tier="$1"
    case "$tier" in
        dev|stg|live) return 0 ;;
        prod)
            print_error "--tier=prod is REFUSED: the demo tier never resets a production site."
            return 1 ;;
        *)
            print_error "Unknown tier '$tier' (dev|stg|live)"
            return 1 ;;
    esac
}

demo_is_live() { [[ "$1" == "live" ]]; }

# demo_instance_exists <site> <tier> — "does this site have something to act on
# at this tier?", quietly (0/1, no output, no ssh).
#
# WHY IT IS NOT demo_project_dir (nwp/ops#170). Every pair decision — main()'s
# auto-upgrade and cmd_reset's unpaired-half refusal — asked `demo_project_dir
# <partner> <tier>`, i.e. "is there a local DDEV project". At tier=live there
# never is one for either half, so at live the pair was structurally invisible:
# `pl demo reset ssd --tier=live` reset one half of a coupled pair with no
# warning, and `--with-pair --tier=live` was refused for the wrong reason ("the
# partner has no instance") before it could reach the real refusal.
#
# A live instance is a HOST, so that is what is checked: live.enabled is not
# false and an address is resolvable from config. Deliberately config-only —
# reachability is demo_live_ctx's job at the point of use, and a gate that
# opens an ssh connection is a gate that turns a flaky link into "the pair does
# not exist".
demo_instance_exists() {
    local site="$1" tier="$2"
    if demo_is_live "$tier"; then
        local enabled ip srv
        enabled="$(get_site_config_value "$site" '.live.enabled' "")"
        [[ "$enabled" == "false" ]] && return 1
        srv="$(get_site_config_value "$site" '.live.server' "")"
        ip=""
        if [[ -n "$srv" ]] && declare -F get_server_config >/dev/null 2>&1; then
            ip="$(get_server_config "$srv" "ip" "" 2>/dev/null)"
        fi
        [[ -z "$ip" ]] && ip="$(get_site_config_value "$site" '.live.server_ip' "")"
        [[ -n "$ip" ]] || return 1
        return 0
    fi
    demo_project_dir "$site" "$tier" >/dev/null 2>&1
}

################################################################################
# STACK-AWARE PLUMBING (ops#133 Phase 2)
#
# The demo tier is now TWO stacks: a Drupal provider (nwd) and a Moodle
# consumer (ssd). Every verb that touches the site — dump, files, sessions,
# cache — differs between them, so each is resolved through one small
# branch here rather than being duplicated in the paired paths.
#
# The `kind` comes from sites/<site>/.nwp.yml `project.type`. A site with no
# resolvable type falls back to `drupal`, which is exactly the Phase-1
# behaviour, so nothing that worked before changes.
################################################################################

demo_kind_of() {
    demo_site_kind "$1" 2>/dev/null || echo drupal
}

# demo_files_tar <proj> <site> <kind> <out.tgz>
# Drupal: sites/default/files (the user-uploaded set).
# Moodle: the WHOLE moodledata dir — Moodle's files live there, not under the
#         docroot, and its contents (filedir + caches) must move as one with
#         the DB or the restore produces a site with dangling file references.
demo_files_tar() {
    local proj="$1" site="$2" kind="$3" out="$4"
    if [[ "$kind" == "moodle" ]]; then
        local dr; dr="$(demo_moodledata_dir "$site")" || return 1
        tar -czf "$out" -C "$dr" . || return 1
    else
        local droot; droot="$(demo_docroot "$proj")" || return 1
        local parent="$proj/$droot/sites/default"
        [[ -d "$parent/files" ]] || { print_error "No files directory at $parent/files"; return 1; }
        tar -czf "$out" -C "$parent" files || return 1
    fi
}

# demo_files_restore <proj> <site> <kind> <in.tgz>
# Delete-then-extract so files removed since the capture don't linger.
#
# ⚠ For Moodle we clear the moodledata dir's CONTENTS and never the directory
#   itself: it is a docker bind-mount target, and `rm -rf` on the host path
#   would sever the mount inside the running container.
demo_files_restore() {
    local proj="$1" site="$2" kind="$3" in="$4"
    if [[ "$kind" == "moodle" ]]; then
        local dr; dr="$(demo_moodledata_dir "$site")" || return 1
        find "$dr" -mindepth 1 -maxdepth 1 -exec rm -rf {} + || return 1
        tar -xzf "$in" -C "$dr" || return 1
    else
        local droot; droot="$(demo_docroot "$proj")" || return 1
        local parent="$proj/$droot/sites/default"
        rm -rf "$parent/files"
        tar -xzf "$in" -C "$parent" || return 1
    fi
}

# demo_files_dir <proj> <site> <kind> — the directory a reset destroys, per
# kind. Drupal: <docroot>/sites/default/files. Moodle: the whole dataroot.
# Fail-closed on purpose: demo_files_restore refuses the same way, so a reset
# that cannot say WHICH directory it is about to delete must not get as far as
# asking permission to delete it.
demo_files_dir() {
    local proj="$1" site="$2" kind="$3"
    if [[ "$kind" == "moodle" ]]; then
        demo_moodledata_dir "$site"
        return $?
    fi
    local droot; droot="$(demo_docroot "$proj")" || return 1
    printf '%s\n' "$proj/$droot/sites/default/files"
}

# demo_moodledata_dir <site> — host path of the Moodle dataroot.
# From sites/<site>/.nwp.yml `moodle.dataroot_host`, else sites/<site>_moodledata.
# Fail-closed: a missing dir refuses rather than tarring nothing.
demo_moodledata_dir() {
    local site="$1" rel="sites/${site}_moodledata" v
    local yml="${PROJECT_ROOT}/sites/${site}/.nwp.yml"
    if command -v yq >/dev/null 2>&1 && [[ -f "$yml" ]]; then
        v="$(yq e '.moodle.dataroot_host // ""' "$yml" 2>/dev/null)"
        [[ -n "$v" && "$v" != "null" ]] && rel="$v"
    fi
    local dir="${PROJECT_ROOT}/${rel}"
    [[ -d "$dir" ]] || { print_error "Moodle dataroot not found at $dir (sites/$site/.nwp.yml moodle.dataroot_host)"; return 1; }
    echo "$dir"
}

# demo_newest_session <proj> <kind> — epoch of the newest session activity, or
# empty on any failure. demo_idle_ok treats empty as ACTIVE (fail-closed).
demo_newest_session() {
    local proj="$1" kind="$2"
    if [[ "$kind" == "moodle" ]]; then
        ( cd "$proj" && ddev mysql -N -e \
            'SELECT COALESCE(MAX(timemodified),0) FROM mdl_sessions' ) 2>/dev/null | tr -d '[:space:]'
    else
        demo_drush "$proj" sqlq \
            'SELECT COALESCE(MAX(timestamp),0) FROM sessions' 2>/dev/null | tr -d '[:space:]'
    fi
}

demo_cache_rebuild() {
    local proj="$1" kind="$2"
    if [[ "$kind" == "moodle" ]]; then
        ( cd "$proj" && ddev exec "${CLI_PHP:-php8.3} admin/cli/purge_caches.php" ) >/dev/null 2>&1
    else
        demo_drush "$proj" cr >/dev/null 2>&1
    fi
}

# Moodle-side pre-wipe error signals. Moodle has no watchdog table, so the
# equivalents are: failed scheduled tasks, the login/error events in the
# standard logstore, and the PHP error log. Same fail-open contract as the
# Drupal collector — any failure here is swallowed by demo_harvest_as.
demo_harvest_collect_moodle() {
    local proj="$1" since
    since=$(( $(date +%s) - 86400 ))
    ( cd "$proj" && ddev mysql -e "
        SELECT 'FAILED TASK' AS kind, classname, timestart, output
          FROM mdl_task_log WHERE result = 1 AND timestart > ${since}
          ORDER BY timestart DESC LIMIT 50" ) 2>/dev/null || true
    ( cd "$proj" && ddev mysql -e "
        SELECT 'EVENT' AS kind, eventname, COUNT(*) AS n, MAX(timecreated) AS newest
          FROM mdl_logstore_standard_log
         WHERE timecreated > ${since}
           AND (eventname LIKE '%failed%' OR eventname LIKE '%error%' OR eventname LIKE '%denied%')
         GROUP BY eventname ORDER BY n DESC LIMIT 50" ) 2>/dev/null || true
    ( cd "$proj" && ddev exec 'test -f /var/log/php-fpm-error.log && tail -n 50 /var/log/php-fpm-error.log' ) 2>/dev/null || true
}

################################################################################
# PAIRED GOLDEN / RESET (ops#133 Phase 2)
#
# See lib/demo-pair.sh for the WHY. In short: nwd and ssd are one product
# joined by mdl_user.idnumber == <nwd account uuid>, so their golden images
# must be captured together and restored together or a wipe leaves live locks
# pointing at accounts the other half no longer has.
#
# Opt-in: the pair contract must carry `demo.enabled: true` (+ paired_golden /
# paired_reset). Everything else refuses.
################################################################################

# Resolve the pair for <site>. Sets DEMO_PAIR_{CONTRACT,PROVIDER,CONSUMER,LABEL}.
# Returns 1 (quietly) when <site> is not in a demo-enabled pair.
demo_pair_resolve() {
    local site="$1"
    DEMO_PAIR_CONTRACT="$(demo_pair_contract_for "$site")" || return 1
    DEMO_PAIR_PROVIDER="$(demo_pair_provider "$DEMO_PAIR_CONTRACT")"
    DEMO_PAIR_CONSUMER="$(demo_pair_consumer "$DEMO_PAIR_CONTRACT")"
    DEMO_PAIR_LABEL="$(demo_pair_label "$DEMO_PAIR_CONTRACT")"
    [[ -n "$DEMO_PAIR_PROVIDER" && -n "$DEMO_PAIR_CONSUMER" ]] || return 1
    return 0
}

# Consumer-side post-restore verification. These are the same --check modes the
# build scripts expose, so "the reset worked" is asserted by the very code that
# set the site up — not by a second, drifting description of it.
demo_consumer_checks() {
    local site="$1" tier="$2" ok=true s
    for s in ssd-oidc-wire ssd-demo-posture ssd-seed-courses; do
        local script="$REPO_ROOT/scripts/demo/${s}.sh"
        [[ -x "$script" ]] || continue
        if PROJECT_ROOT="$PROJECT_ROOT" bash "$script" --site="$site" --tier="$tier" --check >/dev/null 2>&1; then
            print_status "OK" "  ${s#ssd-} verified"
        else
            print_status "FAIL" "  ${s#ssd-} FAILED post-restore"
            ok=false
        fi
    done
    [[ "$ok" == "true" ]]
}

cmd_golden_paired() {
    local site="$1" tier="$2"
    # 3rd arg: main's --allow-config-gaps. Without threading it, the paired
    # capture path would silently ignore the flag (merge 2026-07-26).
    local allow_gaps="${3:-false}"
    demo_pair_resolve "$site" || {
        print_error "REFUSED: '$site' is not in a demo-enabled pair contract (pairs/*.pair-contract.yml → demo.enabled: true)."
        return 1
    }
    demo_pair_golden_enabled "$DEMO_PAIR_CONTRACT" || {
        print_error "REFUSED: $(basename "$DEMO_PAIR_CONTRACT") does not set demo.paired_golden: true"
        return 1
    }
    # prod is refused HERE as well as in demo_check_tier: a library/direct caller
    # never reaches main()'s parse, and this function's whole job is to aim two
    # destructive verbs at two coupled sites.
    if [[ "$tier" == "prod" ]]; then
        print_error "REFUSED: --tier=prod — the demo tier never captures or resets a production site."
        return 1
    fi

    local prov="$DEMO_PAIR_PROVIDER" cons="$DEMO_PAIR_CONSUMER"

    # LIVE (nwp/ops#170). This used to refuse. The refusal was NOT a safety
    # judgement about atomicity — it was written on 2026-07-26 when the consumer
    # half had no live host to capture ("capture the halves separately once it
    # does"), and the paired path was DDEV-shaped throughout. Both facts have
    # changed: the consumer half now HAS a live host, and cmd_golden already
    # dispatches to cmd_golden_live per half. What was genuinely unsafe about
    # running it twice in one process was the process-global live context — see
    # demo_live_ctx. That is now site-keyed, and reset explicitly between the
    # halves here, so each capture reads its OWN host, path and database.
    if demo_is_live "$tier"; then
        demo_instance_exists "$prov" live || {
            print_error "REFUSED: provider '$prov' has no live host configured (sites/$prov/.nwp.yml live.*)."
            return 1
        }
        demo_instance_exists "$cons" live || {
            print_error "REFUSED: consumer '$cons' has no live host configured (sites/$cons/.nwp.yml live.*)."
            return 1
        }
    fi

    print_header "Paired golden capture: ${DEMO_PAIR_LABEL} (${tier})"
    print_info "Provider: $prov     Consumer: $cons"
    print_info "Both halves are captured back-to-back and bound into ONE cut —"
    print_info "restoring one alone would leave SSO identities pointing at nothing."

    local cut_id; cut_id="$(demo_pair_cut_id)"

    demo_is_live "$tier" && demo_live_ctx_reset
    cmd_golden "$prov" "$tier" "$allow_gaps" || { print_error "Provider capture failed — pair cut NOT written."; return 1; }
    demo_is_live "$tier" && demo_live_ctx_reset
    cmd_golden "$cons" "$tier" "$allow_gaps" || { print_error "Consumer capture failed — pair cut NOT written."; return 1; }

    local pdir cdir cut
    pdir="$(demo_golden_dir "$prov" "$tier")"
    cdir="$(demo_golden_dir "$cons" "$tier")"
    cut="$(demo_pair_cut_file "$pdir")"

    demo_pair_cut_write "$cut" "$DEMO_PAIR_LABEL" "$DEMO_PAIR_CONTRACT" "$tier" "$cut_id" \
        "$prov" "$pdir" "$cons" "$cdir" || return 1
    demo_pair_cut_verify "$cut" "$prov" "$pdir" "$cons" "$cdir" "$tier" || {
        print_error "Post-capture pair verification failed — cut NOT usable."
        return 1
    }

    demo_log "$prov" pair-golden-captured "tier=$tier cut=$cut_id consumer=$cons"
    demo_log "$cons" pair-golden-captured "tier=$tier cut=$cut_id provider=$prov"
    print_status "OK" "Paired golden captured + bound (cut ${cut_id})"
    print_hint "Reset with: pl demo reset $prov --with-pair"
}

cmd_reset_paired() {
    local site="$1" tier="$2" if_idle="$3" auto_yes="$4" skip_seed="$5"
    # arg 6 = dry_run, mirroring cmd_reset. It was missing from both this
    # signature and the dispatch, so `pl demo reset <site> --with-pair
    # --dry-run` silently performed a REAL double wipe when the operator had
    # asked for a rehearsal. Same position as cmd_reset, so the two verbs
    # cannot drift apart again unnoticed.
    local dry_run="${6:-false}"
    local start_ts; start_ts=$(date +%s)

    demo_pair_resolve "$site" || {
        print_error "REFUSED: '$site' is not in a demo-enabled pair contract."
        return 1
    }
    demo_pair_reset_enabled "$DEMO_PAIR_CONTRACT" || {
        print_error "REFUSED: $(basename "$DEMO_PAIR_CONTRACT") does not set demo.paired_reset: true"
        return 1
    }
    if [[ "$tier" == "prod" ]]; then
        print_error "REFUSED: --tier=prod — the demo tier never resets a production site."
        return 1
    fi
    # LIVE is a different machine shape entirely (two remote databases and two
    # remote file trees over ssh, no ddev anywhere), so it is its own function
    # rather than a thicket of branches through this one. It keeps every
    # guarantee this path has and adds the ones only a live pair needs: one
    # writer, the box's own pair lock, both halves staged before either is
    # destroyed, and a recorded, repairable half-applied state (ops#170).
    if demo_is_live "$tier"; then
        cmd_reset_paired_live "$site" "$if_idle" "$auto_yes" "$skip_seed" "$dry_run"
        return $?
    fi

    local prov="$DEMO_PAIR_PROVIDER" cons="$DEMO_PAIR_CONSUMER"
    local pproj cproj pkind ckind pdir cdir cut
    pproj="$(demo_project_dir "$prov" "$tier")" || return 1
    cproj="$(demo_project_dir "$cons" "$tier")" || return 1
    pkind="$(demo_kind_of "$prov")"; ckind="$(demo_kind_of "$cons")"
    pdir="$(demo_golden_dir "$prov" "$tier")"
    cdir="$(demo_golden_dir "$cons" "$tier")"
    cut="$(demo_pair_cut_file "$pdir")"

    print_header "Paired demo reset: ${DEMO_PAIR_LABEL} (${tier})"

    # --- 1. EVERYTHING THAT CAN REFUSE, REFUSES FIRST ------------------------
    # Both goldens must verify AND still be the same logical cut. This is the
    # whole point of the pair: a half that was re-captured alone is caught here,
    # before a single byte is destroyed.
    demo_golden_verify "$pdir" "$prov" || {
        demo_log "$prov" reset-failed "tier=$tier reason=golden-verify pair=1"; return 1; }
    demo_golden_verify "$cdir" "$cons" || {
        demo_log "$cons" reset-failed "tier=$tier reason=golden-verify pair=1"; return 1; }
    demo_pair_cut_verify "$cut" "$prov" "$pdir" "$cons" "$cdir" "$tier" || {
        demo_log "$prov" reset-failed "tier=$tier reason=pair-cut-broken"; return 1; }
    print_status "OK" "Both goldens verify and share cut $(demo_pair_cut_id_of "$cut")"

    # --- 2. Idle guard across BOTH halves ------------------------------------
    # A tester mid-course on the Moodle side must block the wipe just as firmly
    # as one clicking around the Drupal side. Either half active ⇒ exit 3.
    if [[ -n "$if_idle" ]]; then
        local window; window="$(demo_parse_duration "$if_idle")" || {
            print_error "Bad --if-idle duration: '$if_idle' (use e.g. 30m)"; return 1; }
        local half hsite hproj hkind newest
        for half in provider consumer; do
            if [[ "$half" == provider ]]; then hsite="$prov"; hproj="$pproj"; hkind="$pkind"
            else hsite="$cons"; hproj="$cproj"; hkind="$ckind"; fi
            newest="$(demo_newest_session "$hproj" "$hkind")" || newest=""
            if ! demo_idle_ok "$newest" "$window"; then
                demo_log "$prov" skip-active "tier=$tier pair=1 half=$hsite window=${if_idle} newest=${newest:-query-failed}"
                print_status "WARN" "Activity on ${hsite} within ${if_idle} (newest=${newest:-query-failed}) — NOT resetting the pair (exit ${DEMO_EXIT_ACTIVE})"
                return "$DEMO_EXIT_ACTIVE"
            fi
        done
        print_status "OK" "Both halves idle for ≥ ${if_idle}"
    fi

    # --- 3. ONE FATE MANIFEST COVERING BOTH HALVES, THEN ONE CONFIRMATION ----
    # This verb destroys TWO sites, one of which is the SSO provider, so it goes
    # through the SAME audited route as the single-site reset — never a weaker
    # one. The first cut of this function hand-rolled a `read -r reply` prompt
    # with no manifest at all, which made the more destructive verb the less
    # guarded one and broke the lib/impact.sh contract ("ALWAYS call
    # impact_render before impact_confirm"). The file-level contract gate could
    # not see it: demo.sh already adopts the lib via cmd_reset.
    #
    # ONE report, not two: impact_reset once, build each half into it, render
    # once. The operator sees everything that is about to be destroyed before
    # answering a single question, and cannot approve half a pair by accident.
    # Measurement is per-half and immediately precedes that half's build,
    # because DEMO_M_* are globals.
    local pfiles cfiles
    pfiles="$(demo_files_dir "$pproj" "$prov" "$pkind")" || return 1
    cfiles="$(demo_files_dir "$cproj" "$cons" "$ckind")" || return 1

    impact_reset
    demo_measure_local_kind "$pproj" "$pkind" "$pfiles" \
        "$(demo_epoch_of "$(demo_golden_field "$pdir" captured_utc)")"
    demo_reset_manifest_build "$prov" "$tier" "$pdir" "$pproj" "$dry_run" "$pfiles"
    demo_measure_local_kind "$cproj" "$ckind" "$cfiles" \
        "$(demo_epoch_of "$(demo_golden_field "$cdir" captured_utc)")"
    demo_reset_manifest_build "$cons" "$tier" "$cdir" "$cproj" "$dry_run" "$cfiles"

    # The fate that only exists BECAUSE this is a pair, and that neither
    # per-site block can state on its own.
    impact_warn "PAIRED WIPE: ${prov} AND ${cons} are both destroyed by this one command — approving it approves both."
    impact_warn "${prov} is the SSO IDENTITY PROVIDER for ${cons}. Every account it holds is dropped and re-created from the golden; ${cons}'s OIDC links are only valid again because its own DB is rolled back to the SAME cut (${DEMO_PAIR_LABEL} cut $(demo_pair_cut_id_of "$cut"))."
    impact_keep "The paired cut manifest (${cut}) and both golden images — verified together before this report was built"
    impact_warn "If this run dies between the halves the pair is left INCONSISTENT until it is re-run; the provider is restored first (ADR-0031 D5) so re-running repairs it."
    impact_render

    if [[ "$dry_run" == "true" ]]; then
        print_status "OK" "[dry-run] nothing was touched — the report above is what a real paired reset would do."
        return 0
    fi

    impact_confirm standard "ERASE BOTH ${prov} and ${cons} (${tier}) and restore the paired golden cut" "$auto_yes" \
        || { print_info "Aborted."; return 1; }

    # --- 4. Pre-wipe harvest, BOTH halves, ONE spool (fail-open) -------------
    print_info "Harvesting error signals from both halves before the wipe…"
    demo_harvest_as "$prov" "$prov" "$tier" demo_harvest_collect "$pproj" || true
    if [[ "$ckind" == "moodle" ]]; then
        demo_harvest_as "$prov" "$cons" "$tier" demo_harvest_collect_moodle "$cproj" || true
    else
        demo_harvest_as "$prov" "$cons" "$tier" demo_harvest_collect "$cproj" || true
    fi

    # --- 4b. Pre-wipe tester-feedback sync (fail-open, nwp/ops#161) ----------
    # PROVIDER half only, and that is not an omission: the Feedback entity lives
    # on the Drupal provider, and the Moodle consumer's local_feedback forwards
    # each report to GitLab synchronously at submit time — it holds no pending
    # set for this wipe to destroy. Cross-site reports raised on the Moodle half
    # arrive here through /api/feedback/log, so they are covered by this call.
    if [[ "$pkind" == "drupal" ]]; then
        print_info "Syncing pending tester feedback from ${prov} before the wipe…"
        demo_feedback_sync "$prov" "$tier" demo_drush "$pproj" || true
    fi

    # --- 5. Restore, PROVIDER FIRST (ADR-0031 D5) ----------------------------
    # The provider is the identity origin. If the run dies between the halves,
    # the consumer still holds the OLD locks against accounts the provider has
    # just restored — recoverable by re-running. The reverse order would leave
    # the consumer holding locks against accounts that do not exist yet.
    local half hsite hproj hkind hdir
    for half in provider consumer; do
        if [[ "$half" == provider ]]; then hsite="$prov"; hproj="$pproj"; hkind="$pkind"; hdir="$pdir"
        else hsite="$cons"; hproj="$cproj"; hkind="$ckind"; hdir="$cdir"; fi

        print_info "Restoring ${hsite} database…"
        ( cd "$hproj" && ddev import-db --file="$hdir/$GOLDEN_DB" ) >/dev/null || {
            demo_log "$hsite" reset-failed "tier=$tier pair=1 reason=import-db"
            print_error "ddev import-db failed for $hsite"
            return 1
        }
        print_info "Restoring ${hsite} files…"
        demo_files_restore "$hproj" "$hsite" "$hkind" "$hdir/$GOLDEN_FILES" || {
            demo_log "$hsite" reset-failed "tier=$tier pair=1 reason=files-restore"
            print_error "files restore failed for $hsite"
            return 1
        }
    done
    print_status "OK" "Both halves restored to cut $(demo_pair_cut_id_of "$cut")"

    # --- 6. Provider reseed + code re-sync -----------------------------------
    if [[ "$skip_seed" != "true" && "$pkind" == "drupal" ]]; then
        print_info "Reseeding demo accounts on ${prov} (drush nwc:seed-demo)…"
        if ! demo_drush "$pproj" nwc:seed-demo >/dev/null 2>&1; then
            demo_log "$prov" reset-failed "tier=$tier pair=1 reason=seed-demo"
            print_error "drush nwc:seed-demo failed (use --skip-seed for non-nwc providers)"
            return 1
        fi
    fi
    demo_sync_codes_to_site "$prov" "$tier" || true

    # --- 7. Caches --------------------------------------------------------------
    demo_cache_rebuild "$pproj" "$pkind" || print_warning "provider cache rebuild failed (non-fatal)"
    demo_cache_rebuild "$cproj" "$ckind" || print_warning "consumer cache rebuild failed (non-fatal)"

    # --- 8. Post-restore verification ---------------------------------------
    # A reset that "succeeded" but left the consumer unwired, un-postured or
    # course-less is a reset that broke the demo. Assert it, and RETURN NON-ZERO
    # if it failed (the Phase-1 live cutover learned this the hard way).
    print_info "Verifying the restored pair…"
    local verify_ok=true
    demo_consumer_checks "$cons" "$tier" || verify_ok=false

    local took=$(( $(date +%s) - start_ts ))
    if [[ "$verify_ok" != "true" ]]; then
        demo_log "$prov" reset-degraded "tier=$tier pair=1 took=${took}s reason=post-restore-checks"
        print_status "FAIL" "Pair restored but post-restore checks FAILED — the demo is not usable as-is."
        return 1
    fi

    demo_log "$prov" reset-ok "tier=$tier pair=1 cut=$(demo_pair_cut_id_of "$cut") took=${took}s"
    demo_log "$cons" reset-ok "tier=$tier pair=1 cut=$(demo_pair_cut_id_of "$cut") took=${took}s"
    print_status "OK" "Paired demo reset complete in ${took}s — ${prov} + ${cons} are back at the golden cut"
}

################################################################################
# LIVE tier plumbing (Phase 2) — remote demo host over ssh
#
# Mirrors the `pl backup --remote` / stg2live idiom: resolve the live target
# from sites/<site>/.nwp.yml, run privileged remote work under sudo as the
# ssh user, and bind every artifact to a sha256 computed on the FAR side.
#
# Live reset is destructive on a real host, so it is guarded by FOUR
# independent fail-closed checks before anything is dropped:
#   1. live.enabled is not false                    (operator intent)
#   2. the remote site reports demo_mode = TRUE     (it is really a demo site)
#   3. the local golden verifies (manifest + sha256) (we have something to restore)
#   4. the golden, once PUSHED, re-verifies ON THE REMOTE before the wipe
#      (we can still restore after we destroy)
################################################################################

DEMO_LIVE_IP=""; DEMO_LIVE_USER=""; DEMO_LIVE_PATH=""; DEMO_LIVE_DOMAIN=""
DEMO_LIVE_WEBROOT=""; DEMO_LIVE_SUDO=""; DEMO_LIVE_DRUSHSUDO=""
# WHICH site the memo above is for (nwp/ops#170). Load-bearing, see below.
DEMO_LIVE_SITE=""

# Forget the memoised live target. Called between the halves of a paired live
# operation, and by demo_live_ctx itself when the site changes.
demo_live_ctx_reset() {
    DEMO_LIVE_IP=""; DEMO_LIVE_USER=""; DEMO_LIVE_PATH=""; DEMO_LIVE_DOMAIN=""
    DEMO_LIVE_WEBROOT=""; DEMO_LIVE_SUDO=""; DEMO_LIVE_DRUSHSUDO=""
    DEMO_LIVE_SITE=""
}

# Resolve (and memoise) the live target for <site>. Fail-closed on a missing
# server_ip: there is no host to act on.
#
# ⚠ THE MEMO IS KEYED BY SITE (nwp/ops#170), and that is not a tidiness point.
# Before this, the memo was `[[ -n "$DEMO_LIVE_IP" ]] && return 0` — a
# one-shot-per-process design that was correct while exactly one live verb ran
# per process. A PAIRED live operation resolves TWO sites in one process, and
# nwd and ssd sit on the SAME box: the second call would have returned the
# FIRST site's DEMO_LIVE_PATH/DOMAIN with an IP that connects perfectly. The
# consumer's "golden" would then have been a dump of the provider's database,
# sha-verified end to end, manifest-stamped with the consumer's name, and
# restored onto the consumer every night. Nothing downstream could have caught
# it, because every check would have been checking the wrong site consistently.
demo_live_ctx() {
    local site="$1"
    [[ "$DEMO_LIVE_SITE" == "$site" && -n "$DEMO_LIVE_IP" ]] && return 0
    demo_live_ctx_reset

    local enabled; enabled="$(get_site_config_value "$site" '.live.enabled' "")"
    if [[ "$enabled" == "false" ]]; then
        print_error "Live deployment disabled for '$site' (live.enabled: false in sites/$site/.nwp.yml)"
        return 1
    fi

    local server_name; server_name="$(get_site_config_value "$site" '.live.server' "")"
    if [[ -n "$server_name" ]] && declare -F get_server_config >/dev/null 2>&1; then
        DEMO_LIVE_IP="$(get_server_config "$server_name" "ip" "" 2>/dev/null)"
    fi
    [[ -z "$DEMO_LIVE_IP" ]] && DEMO_LIVE_IP="$(get_site_config_value "$site" '.live.server_ip' "")"
    if [[ -z "$DEMO_LIVE_IP" ]]; then
        print_error "No live server configured for '$site' (live.server / live.server_ip empty) — refusing."
        return 1
    fi

    DEMO_LIVE_PATH="$(get_site_config_value "$site" '.live.remote_path' "")"
    [[ -z "$DEMO_LIVE_PATH" ]] && DEMO_LIVE_PATH="/var/www/${site}"
    DEMO_LIVE_DOMAIN="$(get_site_config_value "$site" '.live.domain' "")"
    DEMO_LIVE_USER="$(get_ssh_user "$site")"

    # The gitlab ssh user runs privileged remote work via sudo; root does not.
    if [[ "$DEMO_LIVE_USER" == "gitlab" ]]; then
        DEMO_LIVE_SUDO="sudo"
        DEMO_LIVE_DRUSHSUDO="sudo -u www-data"
    fi

    # Claim the memo BEFORE the reachability probe: demo_rssh now asserts that
    # the context it is about to use belongs to the site it was handed, and it
    # resolves one if not — so without this the probe below would recurse.
    DEMO_LIVE_SITE="$site"

    if ! demo_rssh "$site" "echo ok" >/dev/null 2>&1; then
        print_error "Cannot reach live host ${DEMO_LIVE_USER}@${DEMO_LIVE_IP}"
        demo_live_ctx_reset
        return 1
    fi

    # Docroot auto-detect (html | web | "" root-served), same as backup --remote.
    if demo_rssh "$site" "test -d ${DEMO_LIVE_PATH}/web" 2>/dev/null; then
        DEMO_LIVE_WEBROOT="web"
    elif demo_rssh "$site" "test -d ${DEMO_LIVE_PATH}/html" 2>/dev/null; then
        DEMO_LIVE_WEBROOT="html"
    else
        DEMO_LIVE_WEBROOT=""
    fi
    return 0
}

# An ssh-prefix STRING for the live host, so lib helpers that take a prefix
# (lib/demo-live-moodle.sh) can be reused unchanged against it. demo_rssh runs
# a command; this hands out the invocation itself.
demo_live_ssh_prefix() {
    local site="$1"
    # Site-keyed, not "have I resolved anything at all" — see demo_live_ctx.
    [[ "$DEMO_LIVE_SITE" == "$site" && -n "$DEMO_LIVE_IP" ]] || demo_live_ctx "$site" || return 1
    # shellcheck disable=SC2046
    printf 'ssh %s -o BatchMode=yes -o ConnectTimeout=15 %s@%s' \
        "$(nwp_ssh_opts "$site")" "$DEMO_LIVE_USER" "$DEMO_LIVE_IP"
}

demo_rssh() {
    local site="$1"; shift
    # A remote command is NEVER aimed at whatever host the last call happened to
    # resolve. Both halves of the demo pair live on one box, so a stale context
    # connects perfectly and acts on the wrong site (ops#170).
    [[ "$DEMO_LIVE_SITE" == "$site" ]] || demo_live_ctx "$site" || return 1
    # shellcheck disable=SC2046  # nwp_ssh_opts intentionally word-splits
    ssh $(nwp_ssh_opts "$site") -o BatchMode=yes -o ConnectTimeout=15 \
        "${DEMO_LIVE_USER}@${DEMO_LIVE_IP}" "$@"
}

# Remote drush, run from the site root as www-data. Args are shell-quoted so
# SQL fragments and JSON payloads survive the round trip intact.
demo_rdrush() {
    local site="$1"; shift
    # Resolve the live context BEFORE the command string interpolates it. The
    # old order relied on demo_rssh's own resolution — but by then the string
    # had already frozen with an EMPTY ${DEMO_LIVE_PATH}/${DEMO_LIVE_DRUSHSUDO},
    # so the FIRST demo_rdrush in a fresh process ran `cd  &&  ./vendor/bin/
    # drush` in the ssh user's $HOME (rc=127). Every pre-ops#328 caller
    # happened to call demo_live_ctx explicitly first, which is why the trap
    # sat unnoticed; `pl demo testers` was the first caller that did not.
    [[ "$DEMO_LIVE_SITE" == "$site" && -n "$DEMO_LIVE_PATH" ]] || demo_live_ctx "$site" || return 1
    local q="" a
    for a in "$@"; do q+=" $(printf '%q' "$a")"; done
    demo_rssh "$site" "cd ${DEMO_LIVE_PATH} && ${DEMO_LIVE_DRUSHSUDO} ./vendor/bin/drush${q}"
}

# GUARD 2 — the remote site must actually be in demo mode. This is what stops
# `pl demo reset <anything> --tier=live` from wiping a real site: a site that
# has not opted into nwc_demo_access with demo_mode:true is never resettable.
demo_live_require_demo_mode() {
    local site="$1" val

    # Moodle has no drush, and its demo marker lives in the mdl_config TABLE,
    # not config.php — see lib/demo-live-moodle.sh for why reading the file
    # gives the wrong answer. Same opt-in shape, different storage.
    if [[ "$(demo_kind_of "$site")" == "moodle" ]]; then
        local prefix db
        prefix="$(demo_live_ssh_prefix "$site")" || return 1
        db="$(demo_moodle_cfg_scalar "$prefix" "$DEMO_LIVE_PATH" dbname)" || {
            print_error "REFUSING: cannot read \$CFG->dbname from ${site} live config.php."
            return 1
        }
        if demo_moodle_is_demo "$prefix" "$db"; then
            return 0
        fi
        print_error "REFUSING: ${site} live does not report nwp_demo_mode=1 in mdl_config."
        print_info  "Apply the demo posture first: scripts/demo/ssd-demo-posture.sh --site=${site} --tier=live"
        return 1
    fi

    val="$(demo_rdrush "$site" cget nwc_demo_access.settings demo_mode --format=string 2>/dev/null \
           | tr -d '[:space:]')" || val=""
    case "$val" in
        1|true|TRUE) return 0 ;;
    esac
    print_error "REFUSING: ${site} live does not report demo_mode=true (got '${val:-<none>}')."
    print_info  "A live demo reset is only ever allowed against a site running nwc_demo_access with demo_mode: true."
    return 1
}

################################################################################
# CONFIG PARITY (nwp/ops#145) — a golden may not be captured from a site whose
# shipped config was never installed.
#
# Drupal reads a module's config/install ONCE, at install time, and
# ConfigInstaller silently skips anything whose dependencies are unmet at that
# instant — which, under site:install / drush recipe (config syncing is on for
# the whole run), can be most of it. The site boots and looks healthy.
#
# On 2026-07-25 the ops#133 nwd parity rebuild hit exactly that: the rebuilt
# site was 99 config entities short, including the /apply webform the homepage
# links to, the entire nwc_help topic set, the growth tiers and four content
# types. Nothing failed. `pl demo golden` then captured that site 66 minutes
# later and froze the defect into the image the nightly reset restores — so the
# demo tier served a dead /apply link to testers, and would have kept restoring
# it every night.
#
# So the gate belongs HERE, at capture: a golden is a reference image, and an
# incomplete site must never become one.
################################################################################

DEMO_PARITY_PROBE="${PROJECT_ROOT}/lib/probes/config-parity.php"

# Parse the probe's output. Fail-CLOSED: no TOTAL_CUSTOM line means the probe
# did not complete, which is never a pass.
#
# $1 site  $2 tier  $3 probe stdout
demo_parity_verdict() {
    local site="$1" tier="$2" out="$3"
    local custom vendor
    custom="$(printf '%s\n' "$out" | awk '/^TOTAL_CUSTOM /{print $2; exit}')"
    vendor="$(printf '%s\n' "$out" | awk '/^TOTAL_VENDOR /{print $2; exit}')"

    if [[ ! "$custom" =~ ^[0-9]+$ ]]; then
        print_error "Config-parity probe did not complete on ${site} (${tier}) — no TOTAL_CUSTOM line."
        print_info  "Treated as a FAILURE: an unverifiable site is never captured as a golden."
        demo_log "$site" parity-failed "tier=${tier} reason=probe-incomplete"
        return 1
    fi

    if [[ "$custom" -eq 0 ]]; then
        print_status "OK" "Config parity: every config item shipped by the site's own modules is installed${vendor:+ (${vendor} core/contrib default(s) absent — normal, not gating)}"
        return 0
    fi

    print_error "Config parity FAILED: ${custom} config item(s) shipped by ${site}'s OWN modules are missing from the database."
    printf '%s\n' "$out" | awk '/^MISSING custom /{printf "        %-58s (%s)\n", $3, $4}' | head -40
    local shown; shown="$(printf '%s\n' "$out" | awk '/^MISSING custom /' | wc -l)"
    [[ "$shown" -gt 40 ]] && print_info "… and $((shown - 40)) more."
    print_info "This site is INCOMPLETE — capturing it as a golden would freeze the defect"
    print_info "into every future nightly reset (this is exactly nwp/ops#145 / ops#133)."
    print_hint "Remedy on an nwc-profile site, then re-run the capture:"
    print_hint "  drush nwc:config-heal      # idempotent; only creates config that is absent"
    print_hint "Override (recorded in the demo log) with: --allow-config-gaps"
    demo_log "$site" parity-failed "tier=${tier} custom=${custom} vendor=${vendor:-unknown}"
    return 1
}

# Run the probe against the LOCAL (dev|stg) DDEV project.
demo_parity_check_local() {
    local site="$1" tier="$2" proj="$3"
    [[ -f "$DEMO_PARITY_PROBE" ]] || {
        print_error "Config-parity probe missing: $DEMO_PARITY_PROBE"
        return 1
    }
    # The probe must be inside the project so the web container can see it;
    # DDEV mounts the project root at /var/www/html.
    local tmp=".nwp-config-parity.$$.php"
    cp "$DEMO_PARITY_PROBE" "$proj/$tmp" || return 1
    local out rc=0
    out="$( cd "$proj" && ddev drush php:script "/var/www/html/$tmp" 2>/dev/null )" || rc=$?
    rm -f "$proj/$tmp"
    [[ $rc -eq 0 || -n "$out" ]] || { out=""; }
    demo_parity_verdict "$site" "$tier" "$out"
}

# Run the probe against the LIVE demo host. Read-only; the probe is removed
# again whether it succeeded or not.
demo_parity_check_live() {
    local site="$1"
    # ops#145 parity asks "was every module's SHIPPED CONFIG actually installed"
    # — a Drupal config-management question with no Moodle equivalent (Moodle
    # has no exported config tree to diverge from; its settings ARE the
    # database). Say so out loud rather than run a Drupal probe through drush
    # that does not exist on this host and report a confusing failure.
    if [[ "$(demo_kind_of "$site")" == "moodle" ]]; then
        print_info "Config parity: not applicable to Moodle (no shipped-config tree) — skipped."
        return 0
    fi
    [[ -f "$DEMO_PARITY_PROBE" ]] || {
        print_error "Config-parity probe missing: $DEMO_PARITY_PROBE"
        return 1
    }
    # The probe is a PHP file that drush then EXECUTES as the site user. It
    # used to be staged the cheap way: scp'd to a fixed /tmp/nwp-config-parity-
    # <pid>.php and then opened up to all readers. Both halves of that are
    # wrong on a shared host — /tmp is world-writable and the pid space is
    # ~32k, so any local user can pre-create (or symlink) the path we are
    # about to write, and thereby choose the PHP that runs as www-data.
    #
    # Two changes fix it, and neither needs the file to be world-anything:
    #   1. the REMOTE mktemp picks the name. It creates the directory O_EXCL
    #      with an unguessable suffix, mode 0700 — there is no path to squat.
    #   2. the staging runs under the SAME identity that will run drush
    #      (DEMO_LIVE_DRUSHSUDO), so the probe is readable by its executor
    #      without ever being readable by anyone else.
    local as="${DEMO_LIVE_DRUSHSUDO:+${DEMO_LIVE_DRUSHSUDO} }"
    local rdir
    rdir="$(demo_rssh "$site" "${as}mktemp -d -p /tmp nwp-config-parity-XXXXXXXXXX" 2>/dev/null | tr -d '\r' | tail -n 1)"
    if [[ ! "$rdir" =~ ^/tmp/nwp-config-parity-[A-Za-z0-9]{10}$ ]]; then
        print_error "Could not create a private staging dir for the config-parity probe on the live host"
        print_hint  "The staging runs as the drush user (${DEMO_LIVE_DRUSHSUDO:-the ssh user}); check that it may run mktemp."
        return 1
    fi
    local rprobe="${rdir}/probe.php"

    # Streamed over the existing ssh channel instead of scp'd: scp would land
    # the file as the ssh user, which cannot write into a 0700 dir owned by
    # www-data — and it keeps the whole staging path inside demo_rssh, where
    # it is stubbable and therefore testable.
    if ! demo_rssh "$site" "umask 077; ${as}tee ${rprobe} >/dev/null" < "$DEMO_PARITY_PROBE"; then
        print_error "Could not stage the config-parity probe on the live host"
        demo_rssh "$site" "${as}rm -rf -- ${rdir}" >/dev/null 2>&1 || true
        return 1
    fi

    local out
    out="$(demo_rssh "$site" "cd ${DEMO_LIVE_PATH} && ${DEMO_LIVE_DRUSHSUDO} ./vendor/bin/drush php:script ${rprobe} 2>/dev/null")" || out="${out:-}"
    demo_rssh "$site" "${as}rm -rf -- ${rdir}" >/dev/null 2>&1 || true
    demo_parity_verdict "$site" live "$out"
}

################################################################################
# PENDING DATABASE UPDATES (nwp/ops#226) — a golden may not be captured from a
# site that still owes a hook_update_N.
#
# This defect is SELF-RESTORING, which is what makes it worse than a config
# gap. Capture a golden while an update is pending and every nightly reset puts
# the pending update back: the restore returns the site to the pre-update
# schema, the reset never runs updatedb, and the update stays pending forever.
# An operator who notices and runs updatedb on the live site fixes it only
# until 02:00, when the same golden is restored over the top.
#
# It nearly happened on 2026-08-02: nwc!63 adds nwc_moodle_data_update_10001,
# and an nwd capture taken between "merged" and "updatedb run" would have
# frozen it in. The same night showed the cost of pending updates on this tier
# for real — updatedb orders by module, not dependency, so a demo hook ran
# before the guild hook that created its field, aborted, and left live nwd in
# maintenance mode.
#
# There is deliberately NO override flag. --allow-config-gaps exists because a
# config gap can be a considered trade-off you accept and remedy later; a
# pending update inside a golden never is, because "remedy it later" is exactly
# what the nightly reset undoes.
################################################################################

# The probe's completion marker. Clean sites print NOTHING to stdout (drush
# puts "No database updates required" on stderr), so emptiness cannot
# distinguish "no updates" from "the probe never ran". The marker carries that
# signal instead — the same job TOTAL_CUSTOM does for config parity, and for
# the same fail-closed reason.
DEMO_PENDING_PROBE_MARKER='PENDING_UPDATES_PROBE_OK'

# Set by the verdict for the golden manifest: 0 | not-applicable | unknown.
DEMO_PENDING_UPDATES="unknown"

# Parse the probe's output. Fail-CLOSED: no marker means the probe did not
# complete, and a site whose update state cannot be read is never a pass.
#
# $1 site  $2 tier  $3 probe stdout
demo_pending_updates_verdict() {
    local site="$1" tier="$2" out="$3"
    DEMO_PENDING_UPDATES="unknown"

    if ! printf '%s\n' "$out" | grep -qx "$DEMO_PENDING_PROBE_MARKER"; then
        print_error "Pending-updates probe did not complete on ${site} (${tier}) — no ${DEMO_PENDING_PROBE_MARKER} line."
        print_info  "Treated as a FAILURE: an unreadable update state is never captured as a golden."
        demo_log "$site" pending-updates-failed "tier=${tier} reason=probe-incomplete"
        return 1
    fi

    # `|| true`: grep -v exits 1 when it selects nothing, which under this
    # script's `set -e` would abort the verdict on the CLEAN case — the one
    # answer that must be cheapest to give.
    local json
    json="$(printf '%s\n' "$out" | grep -vx "$DEMO_PENDING_PROBE_MARKER" | sed '/^[[:space:]]*$/d' || true)"
    if [[ -z "$json" ]]; then
        DEMO_PENDING_UPDATES=0
        print_status "OK" "Pending database updates: none"
        return 0
    fi

    demo_require_jq || {
        print_error "Cannot parse the pending-updates payload on ${site} (${tier}) — jq is missing."
        print_info  "Treated as a FAILURE: an unreadable update state is never captured as a golden."
        demo_log "$site" pending-updates-failed "tier=${tier} reason=no-jq"
        return 1
    }

    local n
    n="$(printf '%s' "$json" | jq -r 'length' 2>/dev/null || true)"
    if [[ ! "$n" =~ ^[0-9]+$ ]]; then
        print_error "Pending-updates payload from ${site} (${tier}) is not the JSON drush promised."
        print_info  "Treated as a FAILURE: an unreadable update state is never captured as a golden."
        demo_log "$site" pending-updates-failed "tier=${tier} reason=payload-unparseable"
        return 1
    fi

    if [[ "$n" -eq 0 ]]; then
        DEMO_PENDING_UPDATES=0
        print_status "OK" "Pending database updates: none"
        return 0
    fi

    print_error "Pending database updates: ${n} on ${site} (${tier}) — golden REFUSED."
    printf '%s' "$json" \
        | jq -r 'if type=="object" then keys_unsorted[] else (.[]|tostring) end' 2>/dev/null \
        | head -20 | sed 's/^/        /'
    [[ "$n" -gt 20 ]] && print_info "… and $((n - 20)) more."
    print_info "A golden captured now would re-pend these on EVERY nightly reset —"
    print_info "the reset restores this schema and never runs updatedb, so it never clears."
    print_hint "Run the updates first, then re-capture:"
    print_hint "  pl drush ${site} --tier=${tier} --execute -- updatedb -y"
    print_hint "There is no override: a pending update in a golden cannot be remedied later."
    demo_log "$site" pending-updates-failed "tier=${tier} pending=${n}"
    return 1
}

# Probe the LOCAL (dev|stg) DDEV project.
demo_pending_updates_check_local() {
    local site="$1" tier="$2" proj="$3"
    if [[ "$(demo_kind_of "$site")" == "moodle" ]]; then
        # Moodle has no drush and no hook_update_N registry; its equivalent is
        # $CFG->version vs version.php, read out of the mdl_config TABLE. That
        # is a DIFFERENT rule and this one does not cover it — say so rather
        # than let a Moodle golden inherit a Drupal site's clean bill.
        print_info "Pending updates: Moodle needs its own rule (\$CFG->version vs version.php) — not checked here."
        DEMO_PENDING_UPDATES="not-applicable"
        return 0
    fi
    local out
    out="$( cd "$proj" && ddev drush updatedb:status --format=json 2>/dev/null && echo "$DEMO_PENDING_PROBE_MARKER" )"
    demo_pending_updates_verdict "$site" "$tier" "$out"
}

# Probe the LIVE demo host. Read-only — updatedb:status changes nothing.
demo_pending_updates_check_live() {
    local site="$1"
    if [[ "$(demo_kind_of "$site")" == "moodle" ]]; then
        print_info "Pending updates: Moodle needs its own rule (\$CFG->version vs version.php) — not checked here."
        DEMO_PENDING_UPDATES="not-applicable"
        return 0
    fi
    local out
    out="$(demo_rssh "$site" "cd ${DEMO_LIVE_PATH} && ${DEMO_LIVE_DRUSHSUDO} ./vendor/bin/drush updatedb:status --format=json 2>/dev/null && echo ${DEMO_PENDING_PROBE_MARKER}")"
    demo_pending_updates_verdict "$site" live "$out"
}

# Push a local artifact to the remote home dir and verify its sha256 ON THE
# REMOTE against the local sidecar. Fail-closed: a corrupt upload must be
# caught BEFORE anything is destroyed.
demo_push_verified() {
    local site="$1" local_path="$2" remote_name="$3"
    # scp reads the globals directly, so it needs the same site-keyed assertion
    # demo_rssh makes (ops#170).
    [[ "$DEMO_LIVE_SITE" == "$site" ]] || demo_live_ctx "$site" || return 1
    local want; want="$(awk '{print $1}' "${local_path}.sha256" 2>/dev/null)"
    if [[ ! "$want" =~ ^[0-9a-f]{64}$ ]]; then
        print_error "No usable sha256 sidecar for $(basename "$local_path")"
        return 1
    fi
    # shellcheck disable=SC2046
    if ! scp $(nwp_ssh_opts "$site") -o BatchMode=yes \
        "$local_path" "${DEMO_LIVE_USER}@${DEMO_LIVE_IP}:${remote_name}" >/dev/null 2>&1; then
        print_error "Failed to push $(basename "$local_path") to the live host"
        return 1
    fi
    local got
    got="$(demo_rssh "$site" "sha256sum ~/${remote_name} 2>/dev/null | awk '{print \$1}'" 2>/dev/null)"
    if [[ "$got" != "$want" ]]; then
        print_error "sha256 MISMATCH after push for ${remote_name} (local=$want remote=${got:-none}) — aborting BEFORE any destructive step."
        demo_rssh "$site" "rm -f ~/${remote_name}" >/dev/null 2>&1 || true
        return 1
    fi
    return 0
}

# Compute the sha on the remote, pull, re-verify locally, write the sidecar.
# Fail-closed on mismatch (identical contract to backup_pull_verified).
demo_pull_verified() {
    local site="$1" remote_name="$2" local_path="$3"
    [[ "$DEMO_LIVE_SITE" == "$site" ]] || demo_live_ctx "$site" || return 1
    local remote_sha
    remote_sha="$(demo_rssh "$site" "sha256sum ~/${remote_name} 2>/dev/null | awk '{print \$1}'" 2>/dev/null)"
    if [[ ! "$remote_sha" =~ ^[0-9a-f]{64}$ ]]; then
        print_error "Could not compute remote sha256 for ~/${remote_name}"
        return 1
    fi
    # shellcheck disable=SC2046
    if ! scp $(nwp_ssh_opts "$site") -o BatchMode=yes \
        "${DEMO_LIVE_USER}@${DEMO_LIVE_IP}:${remote_name}" "$local_path" >/dev/null 2>&1; then
        print_error "Failed to pull ~/${remote_name} from the live host"
        return 1
    fi
    local local_sha; local_sha="$(sha256sum "$local_path" 2>/dev/null | awk '{print $1}')"
    if [[ "$local_sha" != "$remote_sha" ]]; then
        print_error "sha256 MISMATCH for $(basename "$local_path") (remote=$remote_sha local=$local_sha) — discarding."
        rm -f "$local_path"
        return 1
    fi
    printf '%s  %s\n' "$local_sha" "$(basename "$local_path")" > "${local_path}.sha256"
    return 0
}

# demo_live_newest_session <site> — epoch of the newest session activity on the
# LIVE host, or "" on any failure (demo_idle_ok treats "" as ACTIVE — [G4]).
#
# Extracted from cmd_reset_live (ops#170) so the single-site live reset and the
# PAIRED live reset cannot end up with two different definitions of "idle".
# ops#163 already had to fix exactly that class of drift between the box wrapper
# and this file: Moodle writes an mdl_sessions row for every ANONYMOUS request
# (3931 anon : 1 authenticated, measured on live ssd), so an idle test over the
# whole table asks "has a crawler touched the site?" and vetoes the wipe for
# ever. demo_moodle_last_session counts `userid <> 0`.
demo_live_newest_session() {
    local site="$1" newest=""
    if [[ "$(demo_kind_of "$site")" == "moodle" ]]; then
        local iprefix idb
        iprefix="$(demo_live_ssh_prefix "$site")" || { printf ''; return 0; }
        idb="$(demo_moodle_cfg_scalar "$iprefix" "$DEMO_LIVE_PATH" dbname)" || idb=""
        if [[ -n "$idb" ]]; then
            newest="$(demo_moodle_last_session "$iprefix" "$idb" 2>/dev/null)" || newest=""
        fi
    else
        newest="$(demo_rdrush "$site" sqlq 'SELECT COALESCE(MAX(timestamp),0) FROM sessions' 2>/dev/null \
                  | tr -d '[:space:]')" || newest=""
    fi
    printf '%s' "$newest"
}

# demo_live_manifest_files_path <site> — the data directory a LIVE reset of this
# site actually destroys, for the fate manifest. Empty ⇒ let the manifest
# builder use Drupal's <target>/sites/default/files default.
#
# A fate manifest that names the wrong directory is worse than none: it is what
# an operator reads before consenting. On Moodle the Drupal default does not
# even exist and the real target is $CFG->dataroot, read from the site's own
# config.php. One definition, used by the single-site and the paired live paths
# (ops#170) — two would drift and only one of them would be the truth.
demo_live_manifest_files_path() {
    local site="$1" p="" prefix
    [[ "$(demo_kind_of "$site")" == "moodle" ]] || { printf ''; return 0; }
    if prefix="$(demo_live_ssh_prefix "$site")"; then
        p="$(demo_moodle_cfg_scalar "$prefix" "$DEMO_LIVE_PATH" dataroot 2>/dev/null)" || p=""
    fi
    [[ -n "$p" ]] || p="${DEMO_LIVE_PATH}_moodledata"
    printf '%s' "$p"
}

demo_live_files_parent() {
    local p="$DEMO_LIVE_PATH"
    [[ -n "$DEMO_LIVE_WEBROOT" ]] && p="${p}/${DEMO_LIVE_WEBROOT}"
    echo "${p}/sites/default"
}

# Live counterpart of demo_harvest_collect: watchdog is destroyed by the
# restore, so the digest is taken over ssh before the wipe.
demo_harvest_collect_live() {
    local site="$1"
    demo_rdrush "$site" watchdog:show --severity=Error --count=100 --format=table 2>/dev/null || true
    demo_rdrush "$site" watchdog:show --severity=Critical --count=100 --format=table 2>/dev/null || true
}

# Push the live (non-revoked, non-expired) hashed codes into the site's state
# entry. Runs after every code change and after every reset.
demo_sync_codes_to_site() {
    local site="$1" tier="$2"
    local proj payload
    payload="$(demo_codes_payload "$(demo_codes_file "$site")")" || return 1

    if demo_is_live "$tier"; then
        demo_live_ctx "$site" || return 1
        # --input-format=string is load-bearing: CodeRegistry::liveCodes() fails
        # closed (rejects EVERY code) unless the stored state value is_string. A
        # drush default of --input-format=auto would parse this JSON into an
        # array and silently break all invite codes. Pin it explicitly.
        if demo_rdrush "$site" state:set --input-format=string nwc_demo_access.codes "$payload" >/dev/null 2>&1; then
            demo_log "$site" codes-synced "tier=$tier"
            # Re-read all three numbers while the ssh context is warm. This is
            # the moment they can have changed, and it is the only moment at
            # which recording them costs nothing (ops#173 item 3).
            demo_drift_record_save "$site" "$tier"
            return 0
        fi
        print_warning "Could not sync codes into ${site} live (is nwc_demo_access enabled there?)"
        print_hint "Re-run later: pl demo codes $site sync --tier=live"
        return 1
    fi

    proj="$(demo_project_dir "$site" "$tier")" || return 1
    if demo_drush "$proj" state:set --input-format=string nwc_demo_access.codes "$payload" >/dev/null 2>&1; then
        demo_log "$site" codes-synced "tier=$tier"
        return 0
    fi
    print_warning "Could not sync codes into the site (is $site-$tier running with nwc_demo_access enabled?)"
    print_hint "Re-run later: pl demo codes $site sync --tier=$tier"
    return 1
}

################################################################################
# CAN THIS HOST DELIVER? (nwp/ops#173 item 2 — the highest-value half)
#
# "Issued a code you have no way to deliver" was a SUCCESS. The console host —
# the operator's actual interface for issuing codes — could not ssh to the box
# at all, so `pl demo invite` minted five codes, rendered a warm invitation
# naming them, printed OK, and delivered nothing to any site. The operator
# mailed those codes to real testers. The site rejected every one.
#
# Nothing in that chain was broken code: each step did what it was told. What
# was missing is the question nobody asked BEFORE minting — can this machine
# reach the place a code has to land?
#
# So: probe the real write path, minus the write, before a code exists. The
# probe is deliberately the same transport the sync uses (ssh + remote drush for
# live; ddev + drush for dev|stg) rather than a cheaper proxy such as a ping — a
# proxy that succeeds where the real path fails would reproduce the bug with
# extra steps.
#
# Ordering matters as much as the check. It runs BEFORE demo_generate_code, for
# the same reason demo_require_explicit_tier does: a refusal that had already
# burned a code id — or printed a plaintext code the operator might act on — is
# a worse outcome than the bug.
################################################################################

DEMO_DELIVERY_REASON=""
# Memoised "<site>/<tier>" of a probe that already succeeded. `codes rotate`
# re-enters cmd_codes once per bundle, and re-running a remote drush call five
# times to re-learn the same answer is pure latency. Only SUCCESS is cached: a
# failure must be re-probed, because the operator's obvious next move is to fix
# the path and try again in the same shell.
DEMO_DELIVERY_OK=""

# NOTE: deliberately NO env override. An "assume I can deliver" escape hatch is
# precisely the silence this guard exists to end, and an undocumented one would
# be found and used. The unit suite stands up a real (stubbed) delivery path
# instead, so it exercises this code rather than stepping around it.

# demo_codes_delivery_probe <site> <tier> — 0 = this host can deliver.
# Sets DEMO_DELIVERY_REASON to a plain-language cause on failure.
demo_codes_delivery_probe() {
    local site="$1" tier="$2"
    DEMO_DELIVERY_REASON=""
    [[ "$DEMO_DELIVERY_OK" == "${site}/${tier}" ]] && return 0

    if demo_is_live "$tier"; then
        if ! demo_live_ctx "$site" >/dev/null 2>&1; then
            DEMO_DELIVERY_REASON="this host cannot reach ${site}'s live box over ssh — no route, no key, or an unverified host key (that last one is what bit the console host: 'Host key verification failed', and nothing anywhere said so)"
            return 1
        fi
        if ! demo_rdrush "$site" state:get nwc_demo_access.codes >/dev/null 2>&1; then
            DEMO_DELIVERY_REASON="ssh to ${site}'s live box works, but drush there will not answer for nwc_demo_access (module disabled, or the drush user cannot bootstrap the site)"
            return 1
        fi
        DEMO_DELIVERY_OK="${site}/${tier}"
        return 0
    fi

    local proj
    if ! proj="$(demo_project_dir "$site" "$tier" 2>/dev/null)"; then
        DEMO_DELIVERY_REASON="there is no ${tier} DDEV project for '${site}' on this host"
        return 1
    fi
    if ! demo_drush "$proj" state:get nwc_demo_access.codes >/dev/null 2>&1; then
        DEMO_DELIVERY_REASON="the ${tier} DDEV project for '${site}' is not answering drush (is it running? \`ddev start\` in ${proj})"
        return 1
    fi
    DEMO_DELIVERY_OK="${site}/${tier}"
    return 0
}

################################################################################
# IS THIS HOST THE REGISTRY'S HOME? (ops#328 D1, operator ruling 2026-08-09)
#
# ops#173 made delivery capability the write gate — and the day the console
# host gained a delivery path there were TWO hosts that passed it, and their registries
# quietly diverged again (63 rows/26 active vs 72/35 while live enforced 31).
# So the home is now a DECLARED fact: `registry_home:` in the tracked
# servers/live/demo/registry-home.yml. This guard runs BEFORE the
# delivery probe on every registry-writing verb: identity first, transport
# second. Reads (`list`, `drift`, `seal-status`, `status`) stay unguarded.
#
# Fail-closed: an undeclared or unparseable home refuses writes with exit 2
# CANNOT VERIFY. The permissive reading ("no declaration, carry on") is
# exactly how two writable homes happened.
################################################################################

# demo_require_registry_home <site> <label> → 0 ok to write here;
# 1 REFUSED (not the home); 2 CANNOT VERIFY (no usable declaration).
# $3 (optional) — what this verb DOES to the home, for the refusal sentence.
# `reveal` is home-guarded but does not write: telling the operator it "writes
# the registry" would be a false statement in the one message they read.
demo_require_registry_home() {
    local site="$1" label="$2" what="${3:-writes the invite-code registry}"
    local state; state="$(demo_registry_home_state)"
    local verdict="${state%%|*}" detail="${state#*|}"
    case "$verdict" in
        home) return 0 ;;
        undeclared)
            print_error "CANNOT VERIFY: no registry home is declared — refusing '${label}'."
            print_info  "  looked for: registry_home: in ${detail}"
            print_info  "A write with no declared home is how the registry came to have two"
            print_info  "diverging copies (ops#328 D1). Declare the home (it is an OPERATOR"
            print_info  "ruling) rather than writing blind."
            return 2
            ;;
    esac
    # not-home
    if [[ -n "${NWP_DEMO_REGISTRY_HOME_OVERRIDE:-}" ]]; then
        # Ledgered override — the estate pattern: never silent, never free.
        demo_log "$site" home-override \
            "label=${label} host=$(demo_registry_local_host) home=${detail} why=${NWP_DEMO_REGISTRY_HOME_OVERRIDE}"
        print_warning "registry-home override in effect on $(demo_registry_local_host) (home is '${detail}') — LEDGERED to $(demo_log_file "$site")"
        return 0
    fi
    print_error "REFUSED: '${label}' ${what}, and its ONE home is '${detail}' (this host: '$(demo_registry_local_host)')."
    print_info  "Operator ruling 2026-08-09 (ops#328 D1): the registry lives on '${detail}' so"
    print_info  "everything works without any one laptop. A second writable copy is how the"
    print_info  "live site came to enforce a set NO host's registry matched."
    echo ""
    print_hint  "Do it on '${detail}':  pl demo codes ${site} ${label#codes } …"
    print_hint  "Fold a stray copy back into the home:  pl demo codes ${site} reconcile --from=<copy> --tier=<t>  (on '${detail}')"
    print_hint  "One-off emergency write HERE (ledgered): NWP_DEMO_REGISTRY_HOME_OVERRIDE='<why>' pl demo codes ${site} …"
    return 1
}

# demo_require_delivery <site> <tier> <label>
# The refusal. It has to do more than say no: the operator standing in front of
# it is the one who cannot see the problem, so it names the model, the cause,
# and the machine to go to.
demo_require_delivery() {
    local site="$1" tier="$2" label="$3"
    demo_codes_delivery_probe "$site" "$tier" && return 0

    print_error "REFUSED: '${label}' would issue a code this host cannot deliver to ${site} (${tier})."
    print_info  "  why: ${DEMO_DELIVERY_REASON}"
    echo ""
    print_info  "The invite-code registry has ONE writable home per tier: the host that can"
    print_info  "deliver to it. This host can read sites/${site}/demo-codes.json but must not"
    print_info  "write to it — two writable copies with nothing reconciling them is how the"
    print_info  "live site came to serve ZERO codes while five valid ones were in the post"
    print_info  "(nwp/ops#173)."
    echo ""
    print_hint  "Nothing was issued, revoked or synced. sites/${site}/demo-codes.json is untouched."
    print_hint  "Do it on the host that can reach the box (the workstation):"
    print_hint  "  pl demo invite ${site} --tier=${tier}"
    print_hint  "  bash servers/live/demo/install-box.sh ${site} --stage-codes   # survive tonight's reset"
    if demo_is_live "$tier"; then
        print_hint  "Or give THIS host the path first, then re-run:"
        print_hint  "  pl demo codes ${site} drift --tier=live    # says exactly which leg is missing"
    fi
    return 1
}

################################################################################
# DRIFT PROBE (nwp/ops#173 item 3)
#
# Reads all three numbers off the real sources and records what it saw in
# private/demo-codes/<site>.json, which `pl todo`'s check_demo_code_drift ages
# and grades — so the comparison reaches `pl rag` through the machinery that
# already exists rather than a second monitoring path nobody looks at either.
#
# Records what it CAN read. A leg that cannot be read is recorded as unknown,
# never as zero: "the box says 0 codes" and "I could not ask the box" lead to
# opposite actions, and the whole of ops#173 is what happens when a system
# cannot tell them apart.
################################################################################

DEMO_DRIFT_REGISTRY=""; DEMO_DRIFT_SITE=""; DEMO_DRIFT_STAGED=""

# demo_codes_drift_probe <site> <tier> — always returns 0; the numbers are the
# result, and "could not read" is one of the possible numbers.
demo_codes_drift_probe() {
    local site="$1" tier="$2" raw=""
    DEMO_DRIFT_REGISTRY="$(demo_codes_active_count "$(demo_codes_file "$site")")"
    # ops#328 D1: on a NON-home host the local file is a replica or a dated
    # backup, not one of the numbers that must agree — the authoritative
    # registry count lives on the declared home, and the write guard means it
    # CANNOT diverge here. Recording it as a number would grade the fleet
    # AMBER forever on every non-home host after the migration renamed its
    # copy. "-" (not applicable) is the honest reading; an UNDECLARED home
    # keeps the pre-D1 behaviour (measure it — that is the old model).
    if [[ "$(demo_registry_home_state)" == not-home\|* ]]; then
        DEMO_DRIFT_REGISTRY="-"
    fi
    DEMO_DRIFT_SITE=""
    DEMO_DRIFT_STAGED="-"

    if demo_is_live "$tier"; then
        if demo_live_ctx "$site" >/dev/null 2>&1; then
            raw="$(demo_rdrush "$site" state:get nwc_demo_access.codes --format=string 2>/dev/null)" || raw=""
            DEMO_DRIFT_SITE="$(demo_payload_count "$raw")"
            # The staged payload is a 0644 root-owned file in a 0755 dir, so the
            # ssh user reads it without sudo. It is the ONLY one of the three
            # that decides what works tomorrow morning.
            raw="$(demo_rssh "$site" "cat $(demo_box_codes_payload "$site") 2>/dev/null" 2>/dev/null)" || raw=""
            DEMO_DRIFT_STAGED="$(demo_payload_count "$raw")"
        fi
        return 0
    fi

    local proj
    if proj="$(demo_project_dir "$site" "$tier" 2>/dev/null)"; then
        raw="$(demo_drush "$proj" state:get nwc_demo_access.codes --format=string 2>/dev/null)" || raw=""
        DEMO_DRIFT_SITE="$(demo_payload_count "$raw")"
    fi
    return 0
}

# demo_drift_record_save <site> <tier> — probe + persist. Called after every
# successful live sync as well as by `pl demo codes <site> drift`, so the record
# is refreshed exactly when the numbers can change.
demo_drift_record_save() {
    local site="$1" tier="$2" f
    demo_codes_drift_probe "$site" "$tier"
    f="$(demo_drift_file "$site")"
    mkdir -p "$(dirname "$f")" 2>/dev/null || return 0
    demo_drift_record "$site" "$tier" \
        "$DEMO_DRIFT_REGISTRY" "$DEMO_DRIFT_SITE" "$DEMO_DRIFT_STAGED" > "$f" 2>/dev/null || return 0
    return 0
}

# Collector for the pre-wipe error harvest: watchdog Error + Critical rows
# (the wipe destroys watchdog) plus a best-effort PHP error-log tail. Output
# on stdout; demo_harvest spools it if non-empty. Any failure here is caught
# by demo_harvest's fail-open contract.
demo_harvest_collect() {
    local proj="$1"
    demo_drush "$proj" watchdog:show --severity=Error --count=100 --format=table 2>/dev/null || true
    demo_drush "$proj" watchdog:show --severity=Critical --count=100 --format=table 2>/dev/null || true
    # PHP error log, when the container exposes one (best-effort, never fatal).
    ( cd "$proj" && ddev exec 'test -f /var/log/php-fpm-error.log && tail -n 50 /var/log/php-fpm-error.log' 2>/dev/null ) || true
}

################################################################################
# FATE MANIFEST (nwp/ops#47 impact contract — lib/impact.sh)
#
# `pl demo reset` wipes a running site and puts a golden image back over it,
# on the LIVE tier, unattended, every night. That is the exact class of action
# the impact contract exists for, and being scheduled makes it worse rather
# than safer: nobody is watching when it goes wrong.
#
# So the manifest is COMPUTED (never assumed): the current DB size, the current
# files size and the number of accounts created since the golden was captured
# are probed live off the very instance about to be destroyed; the replacement
# is named by sha256, capture time and age out of the golden manifest. A probe
# that fails yields "" and the report SAYS so — it never fills the gap with a
# guess.
#
# `-y` / cron skip the PROMPT, never the REPORT: the manifest still renders to
# stdout (which the nightly cron captures into logs/demo-nightly-<site>.log)
# and a one-line digest is appended to demo-reset.log, so every unattended wipe
# leaves an audit record of what it believed it was destroying.
################################################################################

# Bytes-of-data query, shared by both tiers so local and live measure the same
# thing. Returns megabytes as a bare number (the manifest adds the unit).
DEMO_SQL_DBSIZE="SELECT ROUND(SUM(data_length+index_length)/1048576,1) FROM information_schema.tables WHERE table_schema=DATABASE()"

# Live measurements of the state about to be destroyed. Globals, because a
# probe that fails must be distinguishable from one that returned zero.
DEMO_M_DB=""; DEMO_M_FILES=""; DEMO_M_ACCTS=""

_demo_clean_num() {  # keep only a plausible number; anything else = failed probe
    local v; v="$(tr -d '[:space:]' <<< "${1:-}")"
    [[ "$v" =~ ^[0-9]+(\.[0-9]+)?$ ]] && printf '%s' "$v"
}

demo_measure_local() {  # $1 proj  $2 files_parent  $3 since_epoch ("" to skip)
    local proj="$1" files_parent="$2" since="$3" raw
    DEMO_M_DB=""; DEMO_M_FILES=""; DEMO_M_ACCTS=""
    raw="$(demo_drush "$proj" sqlq "$DEMO_SQL_DBSIZE" 2>/dev/null)" || raw=""
    DEMO_M_DB="$(_demo_clean_num "$raw")"
    DEMO_M_FILES="$(du -sh "$files_parent/files" 2>/dev/null | cut -f1)" || DEMO_M_FILES=""
    if [[ -n "$since" ]]; then
        raw="$(demo_drush "$proj" sqlq "SELECT COUNT(*) FROM users_field_data WHERE created > $since" 2>/dev/null)" || raw=""
        DEMO_M_ACCTS="$(_demo_clean_num "$raw")"
    fi
}

demo_measure_live() {  # $1 site  $2 files_parent  $3 since_epoch ("" to skip)
    local site="$1" files_parent="$2" since="$3" raw
    DEMO_M_DB=""; DEMO_M_FILES=""; DEMO_M_ACCTS=""

    if [[ "$(demo_kind_of "$site")" == "moodle" ]]; then
        # Moodle: no drush, and the data is in $CFG->dataroot, not under the
        # docroot. Measure the same three facts by Moodle-native means so the
        # fate manifest carries real figures — a manifest full of "?" is the
        # shape of report an operator learns to scroll past.
        local mprefix mdb mdataroot
        if mprefix="$(demo_live_ssh_prefix "$site")"; then
            mdb="$(demo_moodle_cfg_scalar "$mprefix" "$DEMO_LIVE_PATH" dbname 2>/dev/null)" || mdb=""
            mdataroot="$(demo_moodle_cfg_scalar "$mprefix" "$DEMO_LIVE_PATH" dataroot 2>/dev/null)" || mdataroot=""
            if [[ -n "$mdb" ]]; then
                raw="$($mprefix "sudo mysql -N -e \"SELECT ROUND(SUM(data_length+index_length)/1048576,1) FROM information_schema.tables WHERE table_schema='${mdb}';\" 2>/dev/null" </dev/null 2>/dev/null)" || raw=""
                DEMO_M_DB="$(_demo_clean_num "$raw")" || true
                raw="$($mprefix "sudo mysql ${mdb} -N -e 'SELECT COUNT(*) FROM mdl_user WHERE deleted=0;' 2>/dev/null" </dev/null 2>/dev/null)" || raw=""
                DEMO_M_ACCTS="$(_demo_clean_num "$raw")" || true
            fi
            if [[ -n "$mdataroot" ]]; then
                DEMO_M_FILES="$($mprefix "sudo du -sh ${mdataroot} 2>/dev/null | cut -f1" </dev/null 2>/dev/null | tr -d '[:space:]')" || DEMO_M_FILES=""
            fi
        fi
        return 0
    fi

    raw="$(demo_rdrush "$site" sqlq "$DEMO_SQL_DBSIZE" 2>/dev/null)" || raw=""
    DEMO_M_DB="$(_demo_clean_num "$raw")" || true
    DEMO_M_FILES="$(demo_rssh "$site" "${DEMO_LIVE_SUDO} du -sh ${files_parent}/files 2>/dev/null | cut -f1" 2>/dev/null | tr -d '[:space:]')" || DEMO_M_FILES=""
    if [[ -n "$since" ]]; then
        raw="$(demo_rdrush "$site" sqlq "SELECT COUNT(*) FROM users_field_data WHERE created > $since" 2>/dev/null)" || raw=""
        DEMO_M_ACCTS="$(_demo_clean_num "$raw")" || true
    fi
    # A measurement helper must never decide the fate of the command that calls
    # it: _demo_clean_num ends in a regex test, so a non-numeric (i.e. failed)
    # probe made this function return 1 and, under `set -e`, aborted the whole
    # reset after printing only its header. Unmeasurable is "?", not fatal.
    return 0
}

# One field out of golden.manifest.json (jq when available, awk otherwise).
demo_golden_field() {  # $1 gdir  $2 field
    local m="$1/golden.manifest.json" f="$2"
    [[ -f "$m" ]] || return 0
    if command -v jq >/dev/null 2>&1; then
        jq -r --arg k "$f" '.[$k] // ""' "$m" 2>/dev/null || true
    else
        awk -F'"' -v k="$f" '$2 == k { print $4; exit }' "$m" 2>/dev/null || true
    fi
}

demo_epoch_of() {  # $1 iso8601 → epoch seconds, "" when unparseable
    [[ -n "${1:-}" ]] || return 0
    date -u -d "$1" +%s 2>/dev/null || true
}

demo_human_age() {  # $1 epoch → "3h old" / "12d old"
    local then="${1:-}" d
    [[ "$then" =~ ^[0-9]+$ ]] || { printf 'age unknown'; return 0; }
    d=$(( $(date -u +%s) - then ))
    (( d < 0 )) && { printf 'captured in the future?!'; return 0; }
    if   (( d < 3600 ));  then printf '%dm old' $(( d / 60 ))
    elif (( d < 86400 )); then printf '%dh old' $(( d / 3600 ))
    else                       printf '%dd old' $(( d / 86400 )); fi
}

# demo_measure_local_kind <proj> <kind> <files_dir> <since_epoch>
# Kind-aware front door for demo_measure_local. The Drupal path is unchanged.
# The Moodle path cannot use it at all — there is no drush and no
# users_field_data table — so without this the Moodle half of a paired manifest
# would be nothing but "could not measure" warnings, i.e. a manifest that tells
# the operator nothing about the site it is asking permission to destroy.
demo_measure_local_kind() {
    local proj="$1" kind="$2" files_dir="$3" since="$4" raw
    if [[ "$kind" != "moodle" ]]; then
        demo_measure_local "$proj" "$(dirname "$files_dir")" "$since"
        return 0
    fi
    DEMO_M_DB=""; DEMO_M_FILES=""; DEMO_M_ACCTS=""
    raw="$( cd "$proj" && ddev mysql -N -e "$DEMO_SQL_DBSIZE" 2>/dev/null )" || raw=""
    DEMO_M_DB="$(_demo_clean_num "$raw")"
    DEMO_M_FILES="$(du -sh "$files_dir" 2>/dev/null | cut -f1)" || DEMO_M_FILES=""
    if [[ -n "$since" ]]; then
        raw="$( cd "$proj" && ddev mysql -N -e \
            "SELECT COUNT(*) FROM mdl_user WHERE timecreated > $since" 2>/dev/null )" || raw=""
        DEMO_M_ACCTS="$(_demo_clean_num "$raw")"
    fi
}

# demo_reset_manifest_build <site> <tier> <gdir> <target> [dry_run] [files_path]
# APPENDS one site's fates to the report currently in flight, and writes that
# site's audit line. Does NOT impact_reset and does NOT impact_render — that is
# the caller's job, and it is what lets a PAIRED reset put BOTH halves into ONE
# manifest under ONE confirmation instead of rendering two reports and asking
# twice (or, as the first cut of cmd_reset_paired did, asking with no report at
# all). Call demo_measure_{local,local_kind,live} for THIS site immediately
# before: the DEMO_M_* measurements are globals and the second call would
# otherwise be reported with the first site's numbers.
# Returns 0 always: the report never decides, it only informs.
demo_reset_manifest_build() {
    local site="$1" tier="$2" gdir="$3" target="$4" dry_run="${5:-false}"
    # An EMPTY 6th arg means "caller had nothing better" — fall back to Drupal's
    # layout, as before. A caller that knows (Moodle) passes the real path.
    local files_path="${6:-}"
    [[ -n "$files_path" ]] || files_path="${target}/sites/default/files"
    local captured cap_epoch age db_sha gdb gfiles cfile live_codes

    captured="$(demo_golden_field "$gdir" captured_utc)"
    db_sha="$(demo_golden_field "$gdir" db_sha256)"
    cap_epoch="$(demo_epoch_of "$captured")"
    age="$(demo_human_age "$cap_epoch")"
    gdb="$(du -h "$gdir/$GOLDEN_DB" 2>/dev/null | cut -f1)"
    gfiles="$(du -h "$gdir/$GOLDEN_FILES" 2>/dev/null | cut -f1)"

    impact_overwrite "Database" \
        "${site} ${tier} DB${DEMO_M_DB:+ (${DEMO_M_DB}M)} — every table DROPPED, replaced by ${GOLDEN_DB} (${gdb:-?}, sha256 ${db_sha:0:12}…, captured ${captured:-unknown}, ${age})"
    impact_delete "Files" \
        "${files_path}${DEMO_M_FILES:+ (${DEMO_M_FILES})} — removed, then restored from ${GOLDEN_FILES} (${gfiles:-?})"
    impact_delete "Tester work" \
        "${site}: every account, post, comment, upload and log row created since the golden was captured (${age})${DEMO_M_ACCTS:+ — ${DEMO_M_ACCTS} account(s) created since then}"

    # Honest about blind spots: a failed probe is reported, never guessed past.
    [[ -z "$DEMO_M_DB" ]]    && impact_warn "${site}: could not measure the current database size — the wipe proceeds without knowing what is there"
    [[ -z "$DEMO_M_FILES" ]] && impact_warn "${site}: could not measure the current uploads directory — same"
    [[ -z "$captured" ]]     && impact_warn "${site}: golden manifest carries no capture time — provenance of the replacement is unknown"
    if [[ "$cap_epoch" =~ ^[0-9]+$ ]] && (( $(date -u +%s) - cap_epoch > 2592000 )); then
        impact_warn "the golden image is ${age} — the site will be rolled back a long way; recapture with 'pl demo golden $site --tier=$tier'"
    fi
    if demo_is_live "$tier"; then
        impact_warn "LIVE TIER: ${target} is the site real testers are using right now; their work is not backed up anywhere else"
    fi

    cfile="$(demo_codes_file "$site")"
    live_codes=""
    if [[ -f "$cfile" ]] && command -v jq >/dev/null 2>&1; then
        live_codes="$(jq -r --argjson now "$(date +%s)" \
            '[.codes[] | select(.revoked == false and .expires > $now)] | length' "$cfile" 2>/dev/null)" || live_codes=""
    fi
    impact_keep "Invite-code registry ${cfile}${live_codes:+ (${live_codes} live code(s))} — hashed codes survive the wipe and are re-synced afterwards"
    impact_keep "The golden image itself (${gdir}) — verified (sha256 + site match) before this report was built"
    impact_keep "Pre-wipe error digests — watchdog is harvested to demo-harvest/ BEFORE anything is destroyed"
    if demo_is_live "$tier"; then
        impact_keep "Code, vendor/, settings.php, TLS certificates and DNS on the host — only the DB and ${files_path} are touched"
    fi

    # The audit half of the contract: this line lands even when -y/cron skipped
    # the prompt, so an unattended wipe is still accounted for. One line PER
    # SITE, so a paired reset is accounted for in both sites' logs.
    demo_log "$site" reset-manifest \
        "tier=$tier dry_run=$dry_run target=$target golden_sha=${db_sha:0:12} captured=${captured:-unknown} age=${age// /_} db_now=${DEMO_M_DB:-unknown} files_now=${DEMO_M_FILES:-unknown} new_accounts=${DEMO_M_ACCTS:-unknown}"
}

# demo_reset_manifest <site> <tier> <gdir> <target> [dry_run]
# The single-site front door, unchanged for its callers: reset the report,
# build this site's fates, render. Kept as a thin wrapper so cmd_reset and
# cmd_reset_live are byte-identical in behaviour to before the split.
demo_reset_manifest() {
    impact_reset
    demo_reset_manifest_build "$@"
    impact_render
}

################################################################################
# golden — capture the current state as the golden image
################################################################################

cmd_golden() {
    local site="$1" tier="$2" allow_gaps="${3:-false}"
    if demo_is_live "$tier"; then
        cmd_golden_live "$site" "$allow_gaps"
        return $?
    fi
    local proj gdir kind
    proj="$(demo_project_dir "$site" "$tier")" || return 1
    kind="$(demo_kind_of "$site")"
    gdir="$(demo_golden_dir "$site" "$tier")"
    mkdir -p "$gdir"

    print_header "Capturing golden image: $site ($tier, $kind)"

    # 0. CONFIG PARITY (ops#145) — refuse to freeze an incomplete site into the
    #    image the nightly reset restores. Runs BEFORE the dump so a failure
    #    costs nothing and leaves the previous golden untouched.
    if ! demo_parity_check_local "$site" "$tier" "$proj"; then
        if [[ "$allow_gaps" != "true" ]]; then
            print_error "Golden NOT captured — the existing image is unchanged."
            return 1
        fi
        print_status "WARN" "--allow-config-gaps: capturing anyway (recorded in the demo log)"
        demo_log "$site" parity-overridden "tier=$tier"
    fi

    # 0b. PENDING DB UPDATES (ops#226). Also BEFORE the dump, and deliberately
    #     NOT covered by --allow-config-gaps: a pending update frozen into the
    #     image is re-pended by every nightly reset and can never be cleared.
    if ! demo_pending_updates_check_local "$site" "$tier" "$proj"; then
        print_error "Golden NOT captured — the existing image is unchanged."
        return 1
    fi

    # 1. DB dump (ddev export-db handles credentials + gzip).
    print_info "Exporting database…"
    ( cd "$proj" && ddev export-db --file="$gdir/$GOLDEN_DB" --gzip ) >/dev/null || {
        print_error "ddev export-db failed"
        return 1
    }

    # 2. Files tar — Drupal: sites/default/files; Moodle: the whole moodledata.
    print_info "Archiving files…"
    demo_files_tar "$proj" "$site" "$kind" "$gdir/$GOLDEN_FILES" || {
        print_error "files tar failed"
        return 1
    }

    # 3. sha256 sidecars (format matches sha256sum -c).
    local f
    for f in "$GOLDEN_DB" "$GOLDEN_FILES"; do
        ( cd "$gdir" && sha256sum "$f" > "$f.sha256" ) || {
            print_error "sha256 sidecar failed for $f"
            return 1
        }
    done

    # 4. Manifest, then verify the whole set exactly as reset will.
    demo_manifest_write "$gdir" "$site" "$GOLDEN_DB" "$GOLDEN_FILES" "${DEMO_PENDING_UPDATES:-unknown}" || return 1
    demo_golden_verify "$gdir" "$site" || {
        print_error "Post-capture verification failed — golden NOT usable"
        return 1
    }

    demo_log "$site" golden-captured "tier=$tier db=$(du -h "$gdir/$GOLDEN_DB" | cut -f1) files=$(du -h "$gdir/$GOLDEN_FILES" | cut -f1)"
    print_status "OK" "Golden image captured + verified: $gdir"
    print_hint "Nightly restore will return $site to exactly this state."
}

# Drupal tables whose SCHEMA belongs in the golden but whose ROWS never do
# (nwp/ops#168). Comma-separated because that is drush's own syntax.
#
# WHY, with the numbers. The 2026-08-01 nwd golden carried 36 `watchdog` rows,
# SIXTEEN of them from the ddev dev environment — `location` of
# `https://nwd-dev.ddev.site/…`, backtraces rooted at `/var/www/html/html/…`
# (live is `/var/www/nwd/html/…`) — plus the operator's personal email address
# twice, a real public client IP nine times, and 11 `sessions` rows including
# one AUTHENTICATED session captured on dev.
#
# The golden is restored onto the live demo site every night, so none of that
# ages out: the table that would age it out is replaced from the image at
# 01:00. The concrete cost is the monitoring channel. The pre-wipe harvest
# collects `watchdog:show --severity=Error`, the golden holds exactly two Error
# rows, and so every nightly digest re-reports the same two errors with the same
# timestamps for ever — one of them printing a path from an environment that is
# not the one being monitored. ops#168 caught this in the wild: three digests
# from three different nights (2026-07-27/28/29) are byte-identical below their
# header. A channel that cries wolf nightly is a channel that stops being read,
# and then the next REAL tester error vanishes into it.
#
# Nothing is lost by dumping these empty. The box wrapper harvests before the
# wipe (servers/live/demo/nwd-demo-reset-restricted) and those digests are the
# record; the golden's copy of `watchdog` is not the record of anything.
#
# STRUCTURE, not omission: drush's --structure-tables-list keeps the CREATE
# TABLE and drops only the rows, which is what a reference image wants — the
# same idiom lib/sanitize.sh, lib/sanitizers/standard.sh and lib/import.sh
# already use. `sessions` and `flood` are here for the same reason as
# `watchdog`: they are runtime state, not reference state, and re-inserting
# last week's session rows nightly is meaningless at best.
DEMO_DRUPAL_NODATA_TABLES="${DEMO_DRUPAL_NODATA_TABLES:-watchdog,sessions,flood}"

# ---------------------------------------------------------------------------
# demo_drupal_dump_cmd <site-root> <drush-sudo-prefix> <out-path>
# The remote Drupal dump command. PURE — no ssh, no globals — so the table
# exclusions above are assertable in a unit test instead of only observable by
# unpacking a golden after the fact, which is how ops#168 had to be found.
#
# 2>/dev/null: drush writes its progress chatter to stderr and the caller
# redirects stdout into the artifact, so anything drush says would otherwise
# interleave into the operator's terminal on every capture.
# ---------------------------------------------------------------------------
demo_drupal_dump_cmd() {
    local root="$1" drushsudo="$2" out="$3"
    printf 'cd %s && %s ./vendor/bin/drush sql:dump --gzip --structure-tables-list=%s 2>/dev/null > %s' \
        "$root" "$drushsudo" "$DEMO_DRUPAL_NODATA_TABLES" "$out"
}

# --- live capture (read-only against the demo host) --------------------------
# Dumps the DB and tars sites/default/files ON the live host, computes each
# sha256 there, pulls both back and re-verifies locally. Nothing on live is
# modified; the only writes are two temp files in ~ that are removed again.
cmd_golden_live() {
    local site="$1" allow_gaps="${2:-false}"
    local gdir; gdir="$(demo_golden_dir "$site" live)"

    demo_live_ctx "$site" || return 1
    print_header "Capturing golden image: $site (live)"
    print_info "Live host:   ${DEMO_LIVE_USER}@${DEMO_LIVE_IP}"
    print_info "Remote path: ${DEMO_LIVE_PATH}"
    [[ -n "$DEMO_LIVE_DOMAIN" ]] && print_info "Domain:      https://${DEMO_LIVE_DOMAIN}"

    # Capturing a NON-demo site as a "golden" would be a loaded gun pointed at
    # the reset path — refuse it here too, not just at restore time.
    demo_live_require_demo_mode "$site" || return 1
    print_status "OK" "Remote site reports demo_mode=true"

    # CONFIG PARITY (ops#145). Read-only, and before the dump: a failure costs
    # nothing and leaves the previous golden in place.
    if ! demo_parity_check_live "$site"; then
        if [[ "$allow_gaps" != "true" ]]; then
            print_error "Golden NOT captured — the existing image is unchanged."
            return 1
        fi
        print_status "WARN" "--allow-config-gaps: capturing anyway (recorded in the demo log)"
        demo_log "$site" parity-overridden "tier=live"
    fi

    # PENDING DB UPDATES (ops#226). Read-only, before the dump, no override —
    # see the demo_pending_updates_verdict header for why this one cannot be
    # traded away the way a config gap can.
    if ! demo_pending_updates_check_live "$site"; then
        print_error "Golden NOT captured — the existing image is unchanged."
        return 1
    fi

    mkdir -p "$gdir"
    local stamp="demo-golden-$$-$(date -u '+%Y%m%d%H%M%S')"
    local rdb="${stamp}.db.sql.gz" rfiles="${stamp}.files.tar.gz"
    local files_parent; files_parent="$(demo_live_files_parent)"

    local gkind; gkind="$(demo_kind_of "$site")"

    if [[ "$gkind" == "moodle" ]]; then
        # MOODLE. No drush, and the user data lives in $CFG->dataroot OUTSIDE
        # the docroot — archiving the webroot would capture code and miss every
        # course file. Both locations come from the site's OWN config.php.
        local mprefix mdb mdataroot
        mprefix="$(demo_live_ssh_prefix "$site")" || return 1
        mdb="$(demo_moodle_cfg_scalar "$mprefix" "$DEMO_LIVE_PATH" dbname)" || {
            print_error "Cannot read \$CFG->dbname from ${site} live config.php"; return 1; }
        mdataroot="$(demo_moodle_cfg_scalar "$mprefix" "$DEMO_LIVE_PATH" dataroot)" || {
            print_error "Cannot read \$CFG->dataroot from ${site} live config.php"; return 1; }
        print_info "Database:  ${mdb}"
        print_info "Moodledata: ${mdataroot}"

        print_info "Dumping database on the live host…"
        if ! demo_rssh "$site" "$(demo_moodle_dump_cmd "$mdb" "~/${rdb}")"; then
            print_error "Remote mysqldump failed"
            demo_rssh "$site" "rm -f ~/${rdb}" >/dev/null 2>&1 || true
            return 1
        fi

        print_info "Archiving moodledata on the live host (excluding regenerable caches)…"
        if ! demo_rssh "$site" "$(demo_moodle_files_tar_cmd "$mdataroot" "~/${rfiles}" "$DEMO_LIVE_USER")"; then
            print_error "Remote moodledata tar failed (${mdataroot})"
            demo_rssh "$site" "rm -f ~/${rdb} ~/${rfiles}" >/dev/null 2>&1 || true
            return 1
        fi
    else
        # 1. Remote DB dump.
        print_info "Dumping database on the live host…"
        if ! demo_rssh "$site" "$(demo_drupal_dump_cmd "${DEMO_LIVE_PATH}" "${DEMO_LIVE_DRUSHSUDO}" "~/${rdb}")"; then
            print_error "Remote drush sql:dump failed"
            demo_rssh "$site" "rm -f ~/${rdb}" >/dev/null 2>&1 || true
            return 1
        fi

        # 2. Remote files tar (as root: files/ is www-data-owned), then chown back
        #    so scp can pull it without sudo.
        print_info "Archiving files on the live host…"
        if ! demo_rssh "$site" "${DEMO_LIVE_SUDO} tar czf ~/${rfiles} -C ${files_parent} files && ${DEMO_LIVE_SUDO} chown ${DEMO_LIVE_USER}:${DEMO_LIVE_USER} ~/${rfiles}"; then
            print_error "Remote files tar failed (${files_parent}/files)"
            demo_rssh "$site" "rm -f ~/${rdb} ~/${rfiles}" >/dev/null 2>&1 || true
            return 1
        fi
    fi

    # 3. Pull both back, sha-verified fail-closed.
    print_info "Pulling artifacts back (sha256 verified)…"
    local ok=true
    demo_pull_verified "$site" "$rdb"    "$gdir/$GOLDEN_DB"    || ok=false
    if [[ "$ok" == "true" ]]; then
        demo_pull_verified "$site" "$rfiles" "$gdir/$GOLDEN_FILES" || ok=false
    fi
    demo_rssh "$site" "rm -f ~/${rdb} ~/${rfiles}" >/dev/null 2>&1 || true
    [[ "$ok" == "true" ]] || { print_error "Golden capture aborted — artifact verification failed."; return 1; }

    # 4. Manifest + the same verification the restore will run.
    demo_manifest_write "$gdir" "$site" "$GOLDEN_DB" "$GOLDEN_FILES" "${DEMO_PENDING_UPDATES:-unknown}" || return 1
    demo_golden_verify "$gdir" "$site" || {
        print_error "Post-capture verification failed — golden NOT usable"
        return 1
    }

    demo_log "$site" golden-captured "tier=live host=${DEMO_LIVE_IP} db=$(du -h "$gdir/$GOLDEN_DB" | cut -f1) files=$(du -h "$gdir/$GOLDEN_FILES" | cut -f1)"
    print_status "OK" "Live golden image captured + verified: $gdir"

    # The survival claim below is EARNED, not assumed. On 2026-08-03 this verb
    # printed "Nightly restore will return <site> to exactly this state" after
    # every capture — but capture writes only to this repo, and the nightly
    # restores from /var/lib/nwp-demo/<site>/golden/ ON THE BOX. Both of that
    # day's live fixes were reverted overnight while the operator had been told
    # they were durable. The hint now prints only after the box verifiably
    # holds this capture (install-box.sh sha256-checks it there), and inverts
    # into a loud warning otherwise. A message that states the consequence of
    # the state, rather than the intention of the command, cannot make that
    # mistake.
    if [[ "${DEMO_GOLDEN_NO_STAGE:-false}" == "true" ]]; then
        print_warning "NOT STAGED (--no-stage): the box still holds the PREVIOUS golden."
        print_warning "Tonight's reset will restore THAT image, not this capture."
        print_hint    "stage when ready: bash servers/live/demo/install-box.sh ${site} --stage-golden --no-key"
    elif demo_golden_stage_and_verify "$site"; then
        print_hint "Nightly restore will return ${DEMO_LIVE_DOMAIN:-$site} to exactly this state (staged + sha256-verified on the box)."
    else
        return 1
    fi
}

################################################################################
# reset — verified restore of the golden image
################################################################################

# demo_reset_pair_guard <site> <tier> <pair_ok>
# A half of a demo PAIR must never be reset alone AT A TIER WHERE THE PAIR
# EXISTS: the other half's SSO identities are locked against this one's
# accounts. Refuse and point at the paired path. (--force is NOT an escape
# hatch; re-capturing the pair is. ADR-0031 D9 both-or-nothing.)
#
# Scoped by "does the partner actually have an instance at this tier", so a tier
# where only one half exists still resets single-site. At live that question is
# "is a live host configured", not "is there a .ddev directory" — see
# demo_instance_exists.
#
# 0 = carry on (not a pair here, or --no-pair given and logged); 1 = REFUSED.
demo_reset_pair_guard() {
    local site="$1" tier="$2" pair_ok="${3:-}"
    demo_pair_resolve "$site" || return 0
    demo_pair_reset_enabled "$DEMO_PAIR_CONTRACT" || return 0
    demo_instance_exists "$(demo_pair_partner "$site" "$DEMO_PAIR_CONTRACT")" "$tier" || return 0

    if [[ "$pair_ok" == "skip" ]]; then
        # --no-pair: the operator asked for this explicitly. Do it, but say
        # plainly what it costs, and leave a log line the next reader can find.
        print_warning "--no-pair: resetting ONLY '$site', which is half of ${DEMO_PAIR_LABEL}."
        print_warning "The other half keeps SSO locks against accounts this wipe destroys."
        print_hint    "Re-capture the pair afterwards: pl demo golden ${DEMO_PAIR_PROVIDER} --with-pair --tier=${tier}"
        demo_log "$site" reset-unpaired-override "tier=$tier pair=${DEMO_PAIR_LABEL}"
        return 0
    fi
    # At dev/stg this is reached only by a direct/library call that bypassed
    # main()'s auto-upgrade. AT LIVE IT IS THE NORMAL PATH: the paired live
    # reset is opt-IN (ops#170), so `pl demo reset ssd --tier=live` lands here
    # and is told what to pass. That is deliberate — the alternative was for a
    # live verb to silently start doing a new, never-exercised thing.
    print_error "REFUSED: '$site' is half of the demo pair ${DEMO_PAIR_LABEL} at tier '$tier'."
    print_error "Resetting it alone leaves ${DEMO_PAIR_LABEL}'s other half holding SSO locks against accounts this wipe destroys."
    print_hint  "Both halves, one cut:  pl demo reset ${DEMO_PAIR_PROVIDER} --with-pair --tier=${tier}"
    print_hint  "This site only:        pl demo reset ${site} --no-pair --tier=${tier}   (then re-capture the pair)"
    if demo_is_live "$tier"; then
        print_info "The paired LIVE path is OPT-IN and has not yet had a supervised run — capture first: pl demo golden ${DEMO_PAIR_PROVIDER} --with-pair --tier=live"
    fi
    demo_log "$site" reset-refused "tier=$tier reason=unpaired-half-of-demo-pair"
    return 1
}

cmd_reset() {
    local site="$1" tier="$2" if_idle="$3" auto_yes="$4" skip_seed="$5" dry_run="${6:-false}"
    # 7th arg: "skip" suppresses the paired-half refusal. Only the paired path
    # itself and an explicit operator --no-pair may pass it.
    # NOTE (merge, 2026-07-26): main took position 6 for dry_run, which is
    # load-bearing (it gates the fate manifest and the early return), so the
    # pair flag moved to 7. Every call site below passes both positionally.
    local pair_ok="${7:-}"

    # THE PAIRED-HALF GUARD RUNS BEFORE THE TIER SPLIT (nwp/ops#170).
    # It used to sit below the live dispatch, so at --tier=live it was dead code:
    # `pl demo reset ssd --tier=live` wiped one half of a coupled pair with no
    # warning, no --no-pair, and no log line saying an unpaired reset had
    # happened. The guard is about the PAIR, not about ddev, so it belongs above
    # the split — and it now asks demo_instance_exists, which knows that a live
    # instance is a host rather than a .ddev directory.
    demo_reset_pair_guard "$site" "$tier" "$pair_ok" || return 1

    if demo_is_live "$tier"; then
        cmd_reset_live "$site" "$if_idle" "$auto_yes" "$skip_seed" "$dry_run"
        return $?
    fi
    local proj gdir start_ts kind
    start_ts=$(date +%s)
    proj="$(demo_project_dir "$site" "$tier")" || return 1
    # NOTE (merge, 2026-07-27): the rebase dropped `droot="$(demo_docroot …)"`
    # from here while keeping its only consumer below. Under `set -u` that made
    # EVERY dev/stg single-site reset die with "droot: unbound variable" at the
    # manifest step — fail-closed, but the verb was dead. The docroot lookup now
    # lives in demo_files_dir, which both reset paths share, so the resolution
    # and its only consumer can no longer be separated by a merge.
    kind="$(demo_kind_of "$site")"
    gdir="$(demo_golden_dir "$site" "$tier")"

    print_header "Demo reset: $site ($tier)"

    # 1. Fail-closed golden verification (site match + sha256 both artifacts).
    demo_golden_verify "$gdir" "$site" || {
        demo_log "$site" reset-failed "tier=$tier reason=golden-verify"
        return 1
    }
    print_status "OK" "Golden image verified (sha256 + manifest site match)"

    # 2. Activity guard (--if-idle). A failed sessions query counts as ACTIVE:
    #    never wipe on bad data.
    if [[ -n "$if_idle" ]]; then
        local window newest
        window="$(demo_parse_duration "$if_idle")" || {
            print_error "Bad --if-idle duration: '$if_idle' (use e.g. 30m)"
            return 1
        }
        newest="$(demo_newest_session "$proj" "$kind")" || newest=""
        if ! demo_idle_ok "$newest" "$window"; then
            demo_log "$site" skip-active "tier=$tier window=${if_idle} newest=${newest:-query-failed}"
            print_status "WARN" "Session activity within ${if_idle} (newest=${newest:-query-failed}) — NOT resetting (exit ${DEMO_EXIT_ACTIVE})"
            return "$DEMO_EXIT_ACTIVE"
        fi
        print_status "OK" "Idle for ≥ ${if_idle} — safe to reset"
    fi

    # 3. FATE MANIFEST (ops#47). Measured off the live instance, rendered
    #    unconditionally, logged. --force/--yes skips only the prompt below it.
    local files_dir; files_dir="$(demo_files_dir "$proj" "$site" "$kind")" || return 1
    demo_measure_local_kind "$proj" "$kind" "$files_dir" \
        "$(demo_epoch_of "$(demo_golden_field "$gdir" captured_utc)")"
    demo_reset_manifest "$site" "$tier" "$gdir" "$proj" "$dry_run" "$files_dir"

    if [[ "$dry_run" == "true" ]]; then
        print_status "OK" "[dry-run] nothing was touched — the report above is what a real reset would do."
        return 0
    fi

    impact_confirm standard "ERASE ${site} (${tier}) and restore the golden image" "$auto_yes" \
        || { print_info "Aborted."; return 1; }

    # 3.5 PRE-WIPE ERROR HARVEST (fail-OPEN — must never block the reset).
    #     Runs strictly BEFORE import-db: the restore destroys watchdog, and
    #     testers only report what they notice. demo_harvest always returns 0;
    #     the `|| true` is belt-and-braces against set -e.
    print_info "Harvesting error signals before the wipe…"
    demo_harvest "$site" "$tier" demo_harvest_collect "$proj" || true

    # 3.6 PRE-WIPE TESTER-FEEDBACK SYNC (fail-OPEN — nwp/ops#161).
    #     The harvest above catches errors nobody reported. This catches the
    #     reports testers DID file: Feedback entities live in the DB the next
    #     line destroys. Interlocked with ops#140 — demo_feedback_sync refuses
    #     to push from a site whose deployed payload is not provably minimised.
    if [[ "$kind" == "drupal" ]]; then
        print_info "Syncing pending tester feedback to GitLab before the wipe…"
        demo_feedback_sync "$site" "$tier" demo_drush "$proj" || true
    fi

    # 4. Restore DB.
    print_info "Restoring database from golden…"
    ( cd "$proj" && ddev import-db --file="$gdir/$GOLDEN_DB" ) >/dev/null || {
        demo_log "$site" reset-failed "tier=$tier reason=import-db"
        print_error "ddev import-db failed"
        return 1
    }

    # 5. Restore files (delete-then-extract so removed files don't linger).
    print_info "Restoring files from golden…"
    demo_files_restore "$proj" "$site" "$kind" "$gdir/$GOLDEN_FILES" || {
        demo_log "$site" reset-failed "tier=$tier reason=files-restore"
        print_error "files restore failed"
        return 1
    }

    # 6. Reseed the demo account matrix (nwc profile sites). Deliberately NOT
    #    --force: if real members somehow appear post-restore, seed-demo's own
    #    guard refuses and the reset fails loudly.
    if [[ "$skip_seed" != "true" && "$kind" == "drupal" ]]; then
        print_info "Reseeding demo accounts (drush nwc:seed-demo)…"
        if ! demo_drush "$proj" nwc:seed-demo >/dev/null 2>&1; then
            demo_log "$site" reset-failed "tier=$tier reason=seed-demo"
            print_error "drush nwc:seed-demo failed (use --skip-seed for non-nwc sites)"
            return 1
        fi
    fi

    # 7. Re-push the invite-code registry (the wipe just erased the state
    #    entry; the local registry is the source of truth). Non-fatal: codes
    #    can be re-synced, the reset itself succeeded.
    demo_sync_codes_to_site "$site" "$tier" || true

    # 8. Cache rebuild.
    demo_cache_rebuild "$proj" "$kind" || print_warning "cache rebuild failed (non-fatal)"

    local took=$(( $(date +%s) - start_ts ))
    demo_log "$site" reset-ok "tier=$tier took=${took}s"
    print_status "OK" "Demo reset complete in ${took}s — $site ($tier) is back at the golden image"
}

################################################################################
# reset (live) — verified restore of the golden image onto the remote demo host
#
# Step order is the safety property. Everything that can refuse, refuses BEFORE
# the first destructive command; the golden is uploaded and re-verified on the
# far side while the site is still intact, so a failed upload can never leave
# the host wiped with nothing to restore.
################################################################################

cmd_reset_live() {
    local site="$1" if_idle="$2" auto_yes="$3" skip_seed="$4" dry_run="${5:-false}"
    # --- PAIRED-HALF MODE (ops#170), args 6-8 ---------------------------------
    # arg 6 = the cut id this half belongs to; NON-EMPTY means "you are one half
    #         of a paired live reset that has ALREADY rendered ONE fate manifest
    #         covering both halves, passed the deploy gate once and taken one
    #         typed confirmation". So this invocation must not render a second
    #         report, ask a second time, or re-run the idle guard the pair
    #         already ran across BOTH halves. Everything else — the demo_mode
    #         assertion, the golden verification, the staged-artifact
    #         re-verification, the harvest, the restore, the smoke — is
    #         per-half and stays exactly as it is for a single site.
    # args 7-8 = artifacts ALREADY pushed and sha-verified on the far side by
    #         the paired caller, which stages BOTH halves before destroying
    #         either. Empty ⇒ this call pushes its own (single-site behaviour).
    local pair_cut="${6:-}" staged_db="${7:-}" staged_files="${8:-}"
    local paired="false"; [[ -n "$pair_cut" ]] && paired="true"
    local gdir start_ts
    start_ts=$(date +%s)
    gdir="$(demo_golden_dir "$site" live)"

    demo_live_ctx "$site" || return 1
    print_header "Demo reset: $site (live — ${DEMO_LIVE_DOMAIN:-$DEMO_LIVE_IP})"

    # 1. GUARD 3 — fail-closed golden verification (site match + sha256 both).
    demo_golden_verify "$gdir" "$site" || {
        demo_log "$site" reset-failed "tier=live reason=golden-verify"
        return 1
    }
    print_status "OK" "Golden image verified locally (sha256 + manifest site match)"

    # 2. GUARD 2 — the remote really is a demo site.
    demo_live_require_demo_mode "$site" || {
        demo_log "$site" reset-failed "tier=live reason=not-demo-mode"
        return 1
    }
    print_status "OK" "Remote site reports demo_mode=true"

    # 3. Activity guard. A failed/garbled sessions query counts as ACTIVE.
    if [[ -n "$if_idle" ]]; then
        local window newest
        window="$(demo_parse_duration "$if_idle")" || {
            print_error "Bad --if-idle duration: '$if_idle' (use e.g. 30m)"
            return 1
        }
        newest="$(demo_live_newest_session "$site")" || newest=""
        if ! demo_idle_ok "$newest" "$window"; then
            demo_log "$site" skip-active "tier=live window=${if_idle} newest=${newest:-query-failed}"
            print_status "WARN" "Session activity within ${if_idle} (newest=${newest:-query-failed}) — NOT resetting (exit ${DEMO_EXIT_ACTIVE})"
            return "$DEMO_EXIT_ACTIVE"
        fi
        print_status "OK" "Idle for ≥ ${if_idle} — safe to reset"
    fi

    # 4. FATE MANIFEST (ops#47) — measured on the REMOTE instance that is about
    #    to be wiped, rendered unconditionally, logged. It sits above the deploy
    #    gate on purpose: the operator sees what the Solo touch is authorising
    #    BEFORE being asked to touch it, and --dry-run leaves without one.
    local files_parent; files_parent="$(demo_live_files_parent)"
    if [[ "$paired" != "true" ]]; then
        demo_measure_live "$site" "$files_parent" "$(demo_epoch_of "$(demo_golden_field "$gdir" captured_utc)")"
        demo_reset_manifest "$site" live "$gdir" "https://${DEMO_LIVE_DOMAIN:-$DEMO_LIVE_IP}" "$dry_run" \
            "$(demo_live_manifest_files_path "$site")"

        if [[ "$dry_run" == "true" ]]; then
            print_status "OK" "[dry-run] nothing was touched — the report above is what a real reset would do."
            return 0
        fi

        # 4b. Deploy gate. Unconfigured (met/dev) → a printed notice and proceed,
        #    so the nightly cron still runs; configured (ver) → a real Solo touch.
        if declare -F deploy_gate_require >/dev/null 2>&1; then
            deploy_gate_require "$site" "live" \
                "restore the demo golden image over ${DEMO_LIVE_DOMAIN:-$site} (DB + uploads are ERASED and replaced)" || {
                demo_log "$site" reset-failed "tier=live reason=deploy-gate"
                return 1
            }
        fi
    else
        # The pair rendered ONE manifest for BOTH halves, took ONE deploy-gate
        # touch and ONE typed confirmation before calling us. A dry run never
        # gets this far: cmd_reset_paired_live returns after its own report.
        print_info "Paired half of cut ${pair_cut} — the pair's manifest, gate and confirmation already covered this site."
    fi

    # 5. Confirm. A LIVE wipe destroys the LAST copy of everything the testers
    #    made (nothing else holds it), so this is the TYPED tier — a y/N reflex
    #    is not proportionate to erasing a site people are using. --force/--yes
    #    skips the prompt for the scheduler; the report above already ran.
    if [[ "$paired" != "true" ]]; then
        impact_confirm typed "${DEMO_LIVE_DOMAIN:-$site}" "$auto_yes" \
            || { print_info "Aborted."; return 1; }
    fi

    # 6. PRE-WIPE ERROR HARVEST (fail-OPEN — must never block the reset).
    print_info "Harvesting error signals before the wipe…"
    demo_harvest "$site" live demo_harvest_collect_live "$site" || true

    # 6b. PRE-WIPE TESTER-FEEDBACK SYNC (fail-OPEN — nwp/ops#161).
    #     Strictly before the sql:drop below: the Feedback entities are IN the
    #     database this reset replaces, and on live there is no other copy of
    #     them anywhere. Moodle halves are skipped — local_feedback forwards at
    #     submit time, so it has no pending set for a wipe to destroy.
    if [[ "$(demo_kind_of "$site")" == "drupal" ]]; then
        print_info "Syncing pending tester feedback to GitLab before the wipe…"
        demo_feedback_sync "$site" live demo_rdrush "$site" || true
    fi

    # 7. GUARD 4 — push both artifacts and re-verify their sha256 ON THE REMOTE
    #    while the site is still intact. Nothing below this line is reversible.
    local stamp="demo-restore-$$-$(date -u '+%Y%m%d%H%M%S')"
    local rdb="${stamp}.db.sql.gz" rfiles="${stamp}.files.tar.gz"
    if [[ -n "$staged_db" && -n "$staged_files" ]]; then
        # PAIRED: the caller pushed BOTH halves' artifacts and verified both
        # sha256s on the far side BEFORE approving any destruction, so that a
        # transfer failure — by far the likeliest way this fails — cannot happen
        # with one half already wiped. Re-verify here anyway: this function is
        # what destroys, so it checks its own restore source rather than
        # trusting a claim in an argument.
        rdb="$staged_db"; rfiles="$staged_files"
        local wdb wfiles gdb_r gfiles_r
        wdb="$(awk '{print $1}' "${gdir}/${GOLDEN_DB}.sha256" 2>/dev/null)"
        wfiles="$(awk '{print $1}' "${gdir}/${GOLDEN_FILES}.sha256" 2>/dev/null)"
        gdb_r="$(demo_rssh "$site" "sha256sum ~/${rdb} 2>/dev/null | awk '{print \$1}'" 2>/dev/null | tr -d '[:space:]')"
        gfiles_r="$(demo_rssh "$site" "sha256sum ~/${rfiles} 2>/dev/null | awk '{print \$1}'" 2>/dev/null | tr -d '[:space:]')"
        if [[ "$gdb_r" != "$wdb" || "$gfiles_r" != "$wfiles" || ! "$wdb" =~ ^[0-9a-f]{64}$ ]]; then
            demo_log "$site" reset-failed "tier=live reason=prestaged-sha-mismatch"
            print_error "Pre-staged golden on the live host does not match ${site}'s local golden — refusing to restore."
            return 1
        fi
        print_status "OK" "Pre-staged golden re-verified on the live host (sha256)"
    else
        print_info "Uploading golden image to the live host (sha256 verified on arrival)…"
        if ! demo_push_verified "$site" "$gdir/$GOLDEN_DB" "$rdb"; then
            demo_log "$site" reset-failed "tier=live reason=push-db"
            return 1
        fi
        if ! demo_push_verified "$site" "$gdir/$GOLDEN_FILES" "$rfiles"; then
            demo_rssh "$site" "rm -f ~/${rdb}" >/dev/null 2>&1 || true
            demo_log "$site" reset-failed "tier=live reason=push-files"
            return 1
        fi
        print_status "OK" "Golden image staged on the live host and re-verified there"
    fi

    local cleanup="rm -f ~/${rdb} ~/${rfiles}"

    local rkind; rkind="$(demo_kind_of "$site")"
    local rprefix rdb_name rdataroot
    if [[ "$rkind" == "moodle" ]]; then
        rprefix="$(demo_live_ssh_prefix "$site")" || return 1
        rdb_name="$(demo_moodle_cfg_scalar "$rprefix" "$DEMO_LIVE_PATH" dbname)" || {
            demo_rssh "$site" "$cleanup" >/dev/null 2>&1 || true
            print_error "Cannot read \$CFG->dbname — refusing to restore."; return 1; }
        rdataroot="$(demo_moodle_cfg_scalar "$rprefix" "$DEMO_LIVE_PATH" dataroot)" || {
            demo_rssh "$site" "$cleanup" >/dev/null 2>&1 || true
            print_error "Cannot read \$CFG->dataroot — refusing to restore."; return 1; }
        # The one string that a recursive delete is aimed at, checked before use.
        if ! demo_moodle_dataroot_is_safe "$rdataroot"; then
            demo_rssh "$site" "$cleanup" >/dev/null 2>&1 || true
            print_error "REFUSING: \$CFG->dataroot '${rdataroot}' does not look like a moodledata directory."
            return 1
        fi
    fi

    # 8. Restore DB (drop then import — a plain import would leave orphan
    #    tables that the golden no longer has).
    print_info "Restoring database…"
    if [[ "$rkind" == "moodle" ]]; then
        if ! demo_rssh "$site" "$(demo_moodle_droptables_cmd "$rdb_name") && $(demo_moodle_import_cmd "$rdb_name" "~/${rdb}")"; then
            demo_rssh "$site" "$cleanup" >/dev/null 2>&1 || true
            demo_log "$site" reset-failed "tier=live reason=import-db"
            print_error "Remote database restore FAILED — the golden is still at $gdir; restore by hand before reopening the site."
            return 1
        fi
    elif ! demo_rssh "$site" "cd ${DEMO_LIVE_PATH} && ${DEMO_LIVE_DRUSHSUDO} ./vendor/bin/drush sql:drop -y >/dev/null 2>&1 && gunzip -c ~/${rdb} | ${DEMO_LIVE_DRUSHSUDO} ./vendor/bin/drush sql:cli"; then
        demo_rssh "$site" "$cleanup" >/dev/null 2>&1 || true
        demo_log "$site" reset-failed "tier=live reason=import-db"
        print_error "Remote database restore FAILED — the golden is still at $gdir; restore by hand before reopening the site."
        return 1
    fi

    # 9. Restore files (delete-then-untar so removed files don't linger), and
    #    hand ownership back to the web user. For Moodle that is the whole of
    #    $CFG->dataroot, which lives OUTSIDE the docroot.
    print_info "Restoring files…"
    if [[ "$rkind" == "moodle" ]]; then
        # The destructive half is written HERE, beside the fate manifest that
        # disclosed it (ops#47), not hidden in a helper a second caller could
        # invoke with no disclosure. $rdataroot has already passed
        # demo_moodle_dataroot_is_safe above — this string is the reason that
        # guard exists.
        local mclean="sudo find ${rdataroot} -mindepth 1 -maxdepth 1 -exec rm -rf {} +"
        if ! demo_rssh "$site" "${mclean} && $(demo_moodle_unpack_files_cmd "$rdataroot" "~/${rfiles}")"; then
            demo_rssh "$site" "$cleanup" >/dev/null 2>&1 || true
            demo_log "$site" reset-failed "tier=live reason=files-untar"
            print_error "Remote moodledata restore FAILED"
            return 1
        fi
    elif ! demo_rssh "$site" "${DEMO_LIVE_SUDO} rm -rf ${files_parent}/files && ${DEMO_LIVE_SUDO} tar xzf ~/${rfiles} -C ${files_parent} && ${DEMO_LIVE_SUDO} chown -R www-data:www-data ${files_parent}/files"; then
        demo_rssh "$site" "$cleanup" >/dev/null 2>&1 || true
        demo_log "$site" reset-failed "tier=live reason=files-untar"
        print_error "Remote files restore FAILED"
        return 1
    fi

    demo_rssh "$site" "$cleanup" >/dev/null 2>&1 || true

    # 10. Reseed the demo account matrix. Deliberately NOT --force.
    #     Moodle has no nwc:seed-demo: accounts on ssd arrive by SSO from nwd,
    #     which is the provider and is seeded on its own half of the pair. There
    #     is nothing to seed here, and calling drush would fail on a host that
    #     has none — so this is skipped explicitly rather than by accident.
    if [[ "$rkind" == "moodle" ]]; then
        print_info "Reseed: not applicable to the Moodle half (accounts arrive by SSO from the provider) — skipped."
    elif [[ "$skip_seed" != "true" ]]; then
        print_info "Reseeding demo accounts (drush nwc:seed-demo)…"
        if ! demo_rdrush "$site" nwc:seed-demo >/dev/null 2>&1; then
            demo_log "$site" reset-failed "tier=live reason=seed-demo"
            print_error "Remote drush nwc:seed-demo failed (use --skip-seed for non-nwc sites)"
            return 1
        fi
    fi

    # 11. Re-push the invite-code registry (the wipe erased the state entry;
    #     the local registry is the source of truth). Non-fatal.
    #     Invite codes are a provider-side (nwc_demo_access) concept.
    if [[ "$rkind" != "moodle" ]]; then
        demo_sync_codes_to_site "$site" live || true
    fi

    # 12. Cache rebuild. The restore replaced moodledata wholesale, so Moodle's
    #     caches are not merely stale — their directories are GONE. Purging
    #     recreates them now rather than leaving the first visitor to do it.
    if [[ "$rkind" == "moodle" ]]; then
        local mcliphp; mcliphp="$(get_site_config_value "$site" '.moodle.cli_php_version' '8.3')"
        demo_rssh "$site" "$(demo_moodle_purge_caches_cmd "$DEMO_LIVE_PATH" "$mcliphp")" >/dev/null 2>&1 \
            || print_warning "remote Moodle purge_caches failed (non-fatal)"
    else
        demo_rdrush "$site" cr >/dev/null 2>&1 || print_warning "remote drush cr failed (non-fatal)"
    fi

    # 13. Post-restore smoke. RETRIED on purpose: the first request after a
    #     cache rebuild is a cold full render, and on a small shared host that
    #     can exceed the php-fpm worker pool and return 5xx once before the
    #     caches warm. A single sample would report a healthy site as broken.
    #     Persistent failure is real, so it degrades the exit status.
    local degraded=false
    if [[ -n "$DEMO_LIVE_DOMAIN" ]]; then
        local code="" attempt
        for attempt in 1 2 3 4 5; do
            code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 45 "https://${DEMO_LIVE_DOMAIN}/" 2>/dev/null || echo 000)"
            [[ "$code" == "200" ]] && break
            sleep 5
        done
        if [[ "$code" == "200" ]]; then
            local jcode
            # The route that proves the tester's NEXT step still works. On the
            # provider that is the join form; on the Moodle half it is the login
            # page carrying the "Log in using your account on" SSO button, which
            # is where a tester actually lands. /demo/join does not exist there,
            # so checking it would report every healthy Moodle reset as failed.
            local jpath="/demo/join"
            [[ "$rkind" == "moodle" ]] && jpath="/login/index.php"
            jcode="$(curl -s -o /dev/null -w '%{http_code}' --max-time 45 "https://${DEMO_LIVE_DOMAIN}${jpath}" 2>/dev/null || echo 000)"
            if [[ "$jcode" == "200" ]]; then
                print_status "OK" "https://${DEMO_LIVE_DOMAIN}/ and ${jpath} both serve 200"
            else
                degraded=true
                demo_log "$site" reset-degraded "tier=live join_http=${jcode}"
                print_status "FAIL" "${jpath} returned ${jcode} after the restore — testers cannot proceed."
            fi
        else
            degraded=true
            demo_log "$site" reset-degraded "tier=live http=${code} attempts=5"
            print_status "FAIL" "https://${DEMO_LIVE_DOMAIN}/ still ${code} after 5 attempts — investigate."
        fi
    fi

    local took=$(( $(date +%s) - start_ts ))
    if [[ "$degraded" == "true" ]]; then
        demo_log "$site" reset-ok-degraded "tier=live took=${took}s host=${DEMO_LIVE_IP}"
        print_warning "Data restored, but the site did not pass its smoke check — treat as FAILED."
        # PAIRED: the data IS at the cut, so the other half must still be brought
        # to the same cut — stopping here is what leaves the pair mismatched.
        # DEMO_EXIT_DEGRADED says "restored but red" so the caller can finish the
        # pair and still report the run as failed. Single-site keeps returning 1.
        [[ "$paired" == "true" ]] && return "$DEMO_EXIT_DEGRADED"
        return 1
    fi
    demo_log "$site" reset-ok "tier=live took=${took}s host=${DEMO_LIVE_IP}"
    print_status "OK" "Live demo reset complete in ${took}s — ${DEMO_LIVE_DOMAIN:-$site} is back at the golden image"
}

################################################################################
# reset (live, PAIRED) — one cut, two live hosts, no shared transaction
#                                                          (nwp/ops#170)
#
# WHAT THE OLD REFUSAL WAS, AND WHY REPLACING IT IS NOT DELETING A GUARD
# ---------------------------------------------------------------------
# `cmd_reset_paired` used to answer `--tier=live` with
#   "REFUSED: paired reset on --tier=live is not implemented (ops#133 Phase 2 is
#    dev/stg)."
# The commit that wrote it (2228088, 2026-07-26) is explicit about the reason in
# the sibling refusal: *"The consumer half has no live host yet; capture the
# halves separately once it does."* It was a NOT-BUILT marker, not a safety
# judgement — the paired path was `ddev import-db`/`ddev mysql` from end to end
# and there was no second live host for it to act on. Both facts have since
# changed (the consumer half now has a live host; the Moodle live plumbing
# landed in lib/demo-live-moodle.sh), and what the refusal was standing in front
# of has been built here rather than removed.
#
# The one thing that WAS genuinely unsafe about running the live path twice in
# one process is fixed at the root: demo_live_ctx memoised its target for the
# life of the process, and both halves sit on the SAME box, so the second half
# would have inherited the first half's path/domain/database with an IP that
# connects perfectly. It is now site-keyed and every remote helper asserts it.
#
# WHAT IS AND IS NOT GUARANTEED
# -----------------------------
# NOT ATOMIC, and this function does not pretend otherwise: two databases, two
# file trees, no shared transaction. What is guaranteed:
#
#   * ONE CUT. Both goldens verify AND still carry the sha256s the cut recorded,
#     AND the cut declares tier=live, before anything is destroyed. A cut that
#     binds only one half cannot exist (demo_pair_cut_write refuses to write one)
#     and a half re-captured alone is caught here.
#   * EVERY REFUSAL FIRST, FOR BOTH HALVES. live.enabled, reachability,
#     demo_mode, golden, cut, idle — all of it, on BOTH sites, before the first
#     destructive command. A pair with one unreachable half destroys nothing.
#   * ONE MANIFEST, ONE GATE, ONE TYPED CONFIRM covering both halves. An
#     operator cannot approve half a pair by accident.
#   * BOTH ARTIFACT SETS STAGED AND RE-VERIFIED ON THE BOX BEFORE EITHER SITE IS
#     TOUCHED. Transfer is the likeliest failure; this moves it entirely in front
#     of the first wipe.
#   * PROVIDER FIRST (ADR-0031 D5). The identity origin is restored first, so
#     re-running repairs a partial run.
#   * ONE WRITER + THE BOX'S OWN PAIR LOCK for the whole run, so this cannot
#     interleave with the box-resident nightlies (which know nothing about it).
#   * THE HALF-APPLIED STATE IS RECORDED AND REPAIRABLE — see below.
#
# THE HALF-APPLIED FAILURE MODE, STATED EXPLICITLY
# ------------------------------------------------
# Provider fails      → consumer NEVER TOUCHED. The pair is still on its old
#                       matched state on the consumer side and a partially
#                       restored provider; re-run to repair. No breadcrumb: the
#                       pair was not split by us.
# Consumer fails after
# the provider was
# restored            → THE PAIR IS SPLIT: nwd is at cut X, ssd is still at
#                       whatever testers left. mdl_user.idnumber on ssd now
#                       points at nwd accounts that no longer exist, which is
#                       precisely what the pair exists to prevent. So:
#                         - a breadcrumb file is written
#                           (sites/<provider>/demo-pair-INCONSISTENT.json),
#                         - both halves' logs get `pair-inconsistent`,
#                         - the exact repair command is printed,
#                         - `pl demo status` reports it until it is repaired,
#                         - the run exits NON-ZERO,
#                         - and the breadcrumb is cleared ONLY by a paired reset
#                           in which both halves reached the same cut.
#                       Re-running the same command is the repair, and it is safe
#                       to re-run: restoring an already-restored half is a no-op
#                       in effect.
# Either half restores
# but smokes red      → the OTHER half is still brought to the same cut (leaving
#                       them on different cuts to report a 502 would be trading a
#                       cosmetic failure for a data-consistency one), then the run
#                       reports FAILED. DEMO_EXIT_DEGRADED carries that
#                       distinction out of cmd_reset_live.
################################################################################

# The lock pair, acquired for the whole paired run. Returns 1 (having said why)
# unless BOTH the local one-writer lock and the box's two wrapper locks are ours.
# Sets DEMO_PAIR_BOX_HOLDER (the remote pid) when the box locks were taken.
DEMO_PAIR_BOX_HOLDER=""
DEMO_PAIR_LOCAL_LOCK_FD=""

demo_pair_live_lock() {
    local prov="$1" cons="$2" probe_only="${3:-false}"
    local lock_file; lock_file="$(demo_pair_local_lock_file "$prov")"
    mkdir -p "$(dirname "$lock_file")" 2>/dev/null || true
    # touch-then-exec, not exec alone: a redirection error on `exec` kills a
    # non-interactive bash outright (the `|| {…}` never runs), so the operator
    # would get a bare exit with no reason. Fail closed, but say why.
    if ! touch "$lock_file" 2>/dev/null; then
        print_error "Cannot open the pair lock ${lock_file} — refusing."
        return 1
    fi
    # 201: a fixed high fd, held for the life of the process. Fail-CLOSED — two
    # paired restores of one pair must never interleave.
    exec 201>>"$lock_file" || {
        print_error "Cannot open the pair lock ${lock_file} — refusing."
        return 1
    }
    if ! flock -n 201; then
        print_error "REFUSED: another paired demo reset for ${prov}↔${cons} is already running (lock ${lock_file})."
        return 1
    fi
    DEMO_PAIR_LOCAL_LOCK_FD=201

    local la lb
    la="$(demo_pair_box_lock_file "$prov")"
    lb="$(demo_pair_box_lock_file "$cons")"

    # --dry-run takes nothing on the box: it only reports. It still LOOKS, so the
    # report can say that a nightly is mid-flight.
    if [[ "$probe_only" == "true" ]]; then
        local probe
        probe="$(demo_rssh "$prov" "$(demo_pair_box_lock_probe_cmd "$la" "$lb")" 2>/dev/null)" || probe="UNKNOWN"
        case "$probe" in
            FREE)  print_status "OK" "Box pair locks are free (${la}, ${lb})" ;;
            BUSY*) print_status "WARN" "Box pair lock BUSY — a box-resident nightly is running now: ${probe}" ;;
            *)     print_status "WARN" "Could not probe the box pair locks — a real run would REFUSE here." ;;
        esac
        return 0
    fi

    local out
    out="$(demo_rssh "$prov" "$(demo_pair_box_lock_cmd "$la" "$lb" "$DEMO_PAIR_BOX_LOCK_TTL")" 2>/dev/null)" || out="${out:-}"
    case "$out" in
        HOLDER*)
            DEMO_PAIR_BOX_HOLDER="${out#HOLDER }"
            DEMO_PAIR_BOX_HOLDER="${DEMO_PAIR_BOX_HOLDER//[^0-9]/}"
            [[ -n "$DEMO_PAIR_BOX_HOLDER" ]] || {
                print_error "Box pair lock returned a holder with no pid — refusing."
                return 1
            }
            print_status "OK" "Box pair locks held for this run (pid ${DEMO_PAIR_BOX_HOLDER}, self-releasing after ${DEMO_PAIR_BOX_LOCK_TTL}s)"
            ;;
        BUSY*)
            print_error "REFUSED: a box-resident demo reset holds the pair lock right now (${out#BUSY })."
            print_hint  "The nightly wrappers run 01:00–03:30 Australia/Melbourne; retry outside that window."
            return 1
            ;;
        NOTHELD*)
            # The holder did not actually take the locks. Believing it would mean
            # believing a lock we do not hold.
            print_error "REFUSED: could not take the box pair lock (${out})."
            return 1
            ;;
        *)
            print_error "REFUSED: could not establish the box pair lock (got '${out:-<nothing>}')."
            print_hint  "This gate is fail-closed on purpose: without it a workstation-driven paired reset can run at the same moment as the box nightly."
            return 1
            ;;
    esac
    return 0
}

demo_pair_live_unlock() {
    if [[ -n "$DEMO_PAIR_BOX_HOLDER" ]]; then
        demo_rssh "$1" "$(demo_pair_box_unlock_cmd "$DEMO_PAIR_BOX_HOLDER")" >/dev/null 2>&1 || true
        DEMO_PAIR_BOX_HOLDER=""
    fi
    if [[ -n "$DEMO_PAIR_LOCAL_LOCK_FD" ]]; then
        flock -u 201 2>/dev/null || true
        DEMO_PAIR_LOCAL_LOCK_FD=""
    fi
}

# The front door: lock, run, unlock — whatever the body does. The body has many
# early returns (that is the point of a fail-closed verb), so the release cannot
# live inside it.
cmd_reset_paired_live() {
    local rc=0
    # Normally reached through cmd_reset_paired, which has already resolved the
    # contract and checked the opt-in. A direct caller (a test, a future verb)
    # gets the same gates rather than an unset-variable crash: the opt-in is the
    # only thing keeping the REAL ssc↔nwc pair out of a wipe, so it is asserted
    # wherever the function can be entered.
    if [[ -z "${DEMO_PAIR_CONTRACT:-}" || -z "${DEMO_PAIR_PROVIDER:-}" ]]; then
        demo_pair_resolve "$1" || {
            print_error "REFUSED: '$1' is not in a demo-enabled pair contract."
            return 1
        }
        demo_pair_reset_enabled "$DEMO_PAIR_CONTRACT" || {
            print_error "REFUSED: $(basename "$DEMO_PAIR_CONTRACT") does not set demo.paired_reset: true"
            return 1
        }
    fi
    local prov="$DEMO_PAIR_PROVIDER" cons="$DEMO_PAIR_CONSUMER"
    demo_pair_live_lock "$prov" "$cons" "${5:-false}" || return 1
    _cmd_reset_paired_live_body "$@" || rc=$?
    demo_pair_live_unlock "$prov"
    DEMO_LOG_EXTRA=""
    return "$rc"
}

_cmd_reset_paired_live_body() {
    local site="$1" if_idle="$2" auto_yes="$3" skip_seed="$4" dry_run="${5:-false}"
    local start_ts; start_ts=$(date +%s)
    local prov="$DEMO_PAIR_PROVIDER" cons="$DEMO_PAIR_CONSUMER" label="$DEMO_PAIR_LABEL"
    local pdir cdir cut cut_id
    pdir="$(demo_golden_dir "$prov" live)"
    cdir="$(demo_golden_dir "$cons" live)"
    cut="$(demo_pair_cut_file "$pdir")"

    print_header "Paired demo reset: ${label} (live)"
    print_info "Provider: ${prov}   Consumer: ${cons}   (restored in that order — ADR-0031 D5)"

    # --- 1. ONE CUT, OR NOTHING ---------------------------------------------
    demo_golden_verify "$pdir" "$prov" || {
        demo_log "$prov" reset-failed "tier=live pair=1 reason=golden-verify"; return 1; }
    demo_golden_verify "$cdir" "$cons" || {
        demo_log "$cons" reset-failed "tier=live pair=1 reason=golden-verify"; return 1; }
    demo_pair_cut_verify "$cut" "$prov" "$pdir" "$cons" "$cdir" live || {
        demo_log "$prov" reset-failed "tier=live pair=1 reason=pair-cut-broken"; return 1; }
    cut_id="$(demo_pair_cut_id_of "$cut")"
    print_status "OK" "Both live goldens verify and share cut ${cut_id}"
    # Tag every log line this run writes — including the ones written deep inside
    # the per-half code, which knows nothing about the pair.
    DEMO_LOG_EXTRA="pair=1 cut=${cut_id}"

    # --- 2. EVERY REFUSAL, FOR BOTH HALVES, BEFORE ANY DESTRUCTION ----------
    # This is the answer to "what happens if a half is unreachable mid-run": it
    # is checked BEFORE the run, on both halves, so the common cases (host down,
    # live.enabled false, demo posture missing) cannot split the pair at all.
    local half hsite
    for half in provider consumer; do
        [[ "$half" == provider ]] && hsite="$prov" || hsite="$cons"
        demo_live_ctx_reset
        demo_live_ctx "$hsite" || {
            print_error "Pre-flight FAILED for ${hsite} — nothing has been touched."
            demo_log "$hsite" reset-failed "tier=live pair=1 reason=preflight-unreachable"
            return 1
        }
        demo_live_require_demo_mode "$hsite" || {
            demo_log "$hsite" reset-failed "tier=live pair=1 reason=not-demo-mode"
            print_error "Pre-flight FAILED for ${hsite} — nothing has been touched."
            return 1
        }
        print_status "OK" "${hsite}: live host reachable and reports demo_mode"
    done

    # --- 3. IDLE GUARD ACROSS BOTH HALVES (exit 3 on either) ----------------
    if [[ -n "$if_idle" ]]; then
        local window newest
        window="$(demo_parse_duration "$if_idle")" || {
            print_error "Bad --if-idle duration: '$if_idle' (use e.g. 30m)"; return 1; }
        for half in provider consumer; do
            [[ "$half" == provider ]] && hsite="$prov" || hsite="$cons"
            demo_live_ctx_reset
            demo_live_ctx "$hsite" || return 1
            newest="$(demo_live_newest_session "$hsite")" || newest=""
            if ! demo_idle_ok "$newest" "$window"; then
                demo_log "$prov" skip-active "tier=live half=${hsite} window=${if_idle} newest=${newest:-query-failed}"
                print_status "WARN" "Activity on ${hsite} within ${if_idle} (newest=${newest:-query-failed}) — NOT resetting the pair (exit ${DEMO_EXIT_ACTIVE})"
                return "$DEMO_EXIT_ACTIVE"
            fi
        done
        print_status "OK" "Both halves idle for ≥ ${if_idle}"
    fi

    # --- 4. ONE FATE MANIFEST FOR BOTH HALVES (ops#47) ----------------------
    # Measurement is per-half and immediately precedes that half's block:
    # DEMO_M_* are globals, and so is the live context they are measured through.
    local pfiles cfiles ptarget ctarget
    impact_reset
    demo_live_ctx_reset; demo_live_ctx "$prov" || return 1
    ptarget="https://${DEMO_LIVE_DOMAIN:-$DEMO_LIVE_IP}"
    pfiles="$(demo_live_manifest_files_path "$prov")"
    demo_measure_live "$prov" "$(demo_live_files_parent)" \
        "$(demo_epoch_of "$(demo_golden_field "$pdir" captured_utc)")"
    demo_reset_manifest_build "$prov" live "$pdir" "$ptarget" "$dry_run" "$pfiles"

    demo_live_ctx_reset; demo_live_ctx "$cons" || return 1
    ctarget="https://${DEMO_LIVE_DOMAIN:-$DEMO_LIVE_IP}"
    cfiles="$(demo_live_manifest_files_path "$cons")"
    demo_measure_live "$cons" "$(demo_live_files_parent)" \
        "$(demo_epoch_of "$(demo_golden_field "$cdir" captured_utc)")"
    demo_reset_manifest_build "$cons" live "$cdir" "$ctarget" "$dry_run" "$cfiles"

    # The fates that exist ONLY because this is a live pair.
    impact_warn "PAIRED LIVE WIPE: ${prov} (${ptarget}) AND ${cons} (${ctarget}) are both destroyed by this one command — approving it approves both."
    impact_warn "${prov} is the SSO IDENTITY PROVIDER for ${cons}. ${cons}'s OIDC identities (mdl_user.idnumber == the nwd account uuid) are only valid after this because ${cons} is rolled back to the SAME cut (${label} cut ${cut_id})."
    impact_warn "NOT ATOMIC: two databases and two file trees on one box. ${prov} is restored FIRST; if ${cons} then fails the pair is left SPLIT, recorded in $(demo_pair_inconsistent_file "$prov"), and repaired by re-running this exact command."
    impact_warn "Both halves' goldens are staged and re-verified ON THE BOX before either site is touched, so a failed transfer cannot leave one half wiped."
    impact_keep "The paired cut manifest (${cut}) and both live golden images — verified together, and against tier=live, before this report was built"
    impact_keep "The box's own nightly wrappers cannot run during this: their pair lock is held for the duration (self-releasing after ${DEMO_PAIR_BOX_LOCK_TTL}s)"
    impact_render

    if [[ "$dry_run" == "true" ]]; then
        print_status "OK" "[dry-run] nothing was touched — the report above is what a real paired live reset would do."
        return 0
    fi

    # --- 5. ONE DEPLOY GATE, ONE TYPED CONFIRMATION -------------------------
    if declare -F deploy_gate_require >/dev/null 2>&1; then
        deploy_gate_require "$prov" "live" \
            "restore the ${label} demo golden cut ${cut_id} over BOTH ${ptarget} and ${ctarget} (both DBs and both file trees are ERASED and replaced)" || {
            demo_log "$prov" reset-failed "tier=live pair=1 reason=deploy-gate"
            return 1
        }
    fi
    print_warning "About to ERASE BOTH ${ptarget} and ${ctarget} and restore them to cut ${cut_id}."
    impact_confirm typed "$label" "$auto_yes" || { print_info "Aborted."; return 1; }

    # --- 6. STAGE BOTH HALVES BEFORE DESTROYING EITHER ----------------------
    local stamp="demo-pair-${cut_id}-$$"
    local prdb="${stamp}-${prov}.db.sql.gz"   prfiles="${stamp}-${prov}.files.tar.gz"
    local crdb="${stamp}-${cons}.db.sql.gz"   crfiles="${stamp}-${cons}.files.tar.gz"
    local staged_ok=true
    print_info "Staging BOTH golden images on the box (sha256 verified there) before anything is destroyed…"
    demo_live_ctx_reset; demo_live_ctx "$prov" || return 1
    demo_push_verified "$prov" "$pdir/$GOLDEN_DB"    "$prdb"    || staged_ok=false
    [[ "$staged_ok" == "true" ]] && { demo_push_verified "$prov" "$pdir/$GOLDEN_FILES" "$prfiles" || staged_ok=false; }
    if [[ "$staged_ok" == "true" ]]; then
        demo_live_ctx_reset; demo_live_ctx "$cons" || staged_ok=false
    fi
    [[ "$staged_ok" == "true" ]] && { demo_push_verified "$cons" "$cdir/$GOLDEN_DB"    "$crdb"    || staged_ok=false; }
    [[ "$staged_ok" == "true" ]] && { demo_push_verified "$cons" "$cdir/$GOLDEN_FILES" "$crfiles" || staged_ok=false; }
    if [[ "$staged_ok" != "true" ]]; then
        demo_live_ctx_reset; demo_live_ctx "$prov" >/dev/null 2>&1 \
            && demo_rssh "$prov" "rm -f ~/${prdb} ~/${prfiles} ~/${crdb} ~/${crfiles}" >/dev/null 2>&1 || true
        demo_log "$prov" reset-failed "tier=live pair=1 reason=prestage"
        print_error "Could not stage both goldens on the box — NOTHING was destroyed. Fix the transfer and re-run."
        return 1
    fi
    print_status "OK" "Both goldens staged and verified on the box"

    # --- 7. RESTORE, PROVIDER FIRST ------------------------------------------
    local degraded=false prc=0 crc=0
    demo_live_ctx_reset
    cmd_reset_live "$prov" "" true "$skip_seed" false "$cut_id" "$prdb" "$prfiles" || prc=$?
    if [[ "$prc" == "$DEMO_EXIT_DEGRADED" ]]; then
        degraded=true
        print_warning "${prov} restored but smoked RED — continuing to ${cons} so both halves reach cut ${cut_id}."
    elif [[ "$prc" -ne 0 ]]; then
        # The consumer was never touched: the pair is NOT split by us.
        demo_live_ctx_reset; demo_live_ctx "$cons" >/dev/null 2>&1 \
            && demo_rssh "$cons" "rm -f ~/${crdb} ~/${crfiles}" >/dev/null 2>&1 || true
        demo_log "$prov" reset-failed "tier=live pair=1 reason=provider-restore half=provider rc=${prc}"
        print_error "PROVIDER (${prov}) restore FAILED (rc=${prc}). ${cons} was NOT touched."
        print_hint  "Re-run to repair: pl demo reset ${prov} --with-pair --tier=live"
        return 1
    fi

    demo_live_ctx_reset
    cmd_reset_live "$cons" "" true "$skip_seed" false "$cut_id" "$crdb" "$crfiles" || crc=$?
    if [[ "$crc" == "$DEMO_EXIT_DEGRADED" ]]; then
        degraded=true
        print_warning "${cons} restored but smoked RED — both halves ARE on cut ${cut_id}."
    elif [[ "$crc" -ne 0 ]]; then
        # THE SPLIT STATE. Loud, recorded, repairable.
        demo_pair_mark_inconsistent "$prov" "$cons" "$cut_id" consumer "cmd_reset_live rc=${crc}"
        demo_log "$prov" pair-inconsistent "tier=live pair=1 failed_half=consumer cut=${cut_id}"
        demo_log "$cons" pair-inconsistent "tier=live pair=1 failed_half=consumer cut=${cut_id}"
        print_error "CONSUMER (${cons}) restore FAILED (rc=${crc}) AFTER ${prov} was restored."
        print_error "THE PAIR IS SPLIT: ${prov} is at cut ${cut_id}, ${cons} is not. ${cons}'s SSO identities now point at ${prov} accounts that no longer exist."
        print_hint  "REPAIR (safe to re-run, provider-first makes it idempotent): pl demo reset ${prov} --with-pair --tier=live"
        print_hint  "Recorded in $(demo_pair_inconsistent_file "$prov") and reported by 'pl demo status ${prov} --tier=live' until repaired."
        return 1
    fi

    # --- 8. CONSUMER-SIDE POST-RESTORE ASSERTIONS ---------------------------
    # The same --check modes the build scripts expose: "the reset worked" is
    # asserted by the code that set the site up, not by a second description.
    local verify_ok=true
    print_info "Verifying the restored consumer wiring…"
    demo_consumer_checks "$cons" live || verify_ok=false

    local took=$(( $(date +%s) - start_ts ))
    if [[ "$verify_ok" != "true" || "$degraded" == "true" ]]; then
        demo_log "$prov" reset-degraded "tier=live pair=1 took=${took}s cut=${cut_id} consumer_checks=${verify_ok} smoke_degraded=${degraded}"
        demo_log "$cons" reset-degraded "tier=live pair=1 took=${took}s cut=${cut_id}"
        print_status "FAIL" "Both halves are on cut ${cut_id}, but the pair did not pass its post-restore checks — treat as FAILED."
        return 1
    fi

    # Both halves are on one cut: any earlier split is over.
    demo_pair_clear_inconsistent "$prov"
    demo_log "$prov" reset-ok "tier=live pair=1 cut=${cut_id} took=${took}s consumer=${cons}"
    demo_log "$cons" reset-ok "tier=live pair=1 cut=${cut_id} took=${took}s provider=${prov}"
    print_status "OK" "Paired LIVE demo reset complete in ${took}s — ${prov} + ${cons} are both at cut ${cut_id}"
}

################################################################################
# nightly — scheduled entrypoint with the §4.3 retry loop
################################################################################

# demo_nightly_via_key <site> <host-override> <dry-run> <print-transport>
#
# THE SCHEDULER'S NIGHTLY, AS A pl VERB (nwp/ops#156 + #161, operator ruling D15).
#
# What this is NOT: it is not `pl demo reset --tier=live` on a timer. met cannot
# run that and must not be made able to. cmd_reset_live needs
# sites/<site>/.nwp.yml (met has no sites/nwd or sites/ssd), a LOCAL golden to
# upload on every run (the box already holds a sha256-verified copy), and an
# admin `gitlab@` shell on the LIVE box — a host whose `gitlab` user has
# NOPASSWD sudo over ~15 live sites. Handing that key to an AI-accessible
# machine to save a `--via-key` flag trades a logged gap for root on the live
# box. The standing rule in docs/guides/demo-nightly-on-met.md §1 says never,
# and it is right.
#
# So the transport is unchanged: the restricted forced-command key, one action
# word, the box-resident golden, the box's own pair lock serialising the two
# halves (§11.6). Byte-identical to the cron line `pl demo schedule --via-key
# --raw-ssh` writes, because both come out of demo_box_ssh_args.
#
# What routing it through pl BUYS is the steps only a checkout can take, in the
# one place they belong — around the wipe, on the scheduler:
#
#   PRE   tester-feedback sync (ops#161). The Feedback entities are IN the
#         database the box is about to replace and live holds no other copy.
#         Attempted only where a real drush transport exists; where it does not
#         (met today) the verb says so and LOGS it, instead of the loss being
#         inferred from a box-side WARN nobody reads.
#   POST  harvest drain (ops#161's other half). The box has always written a
#         pre-wipe error digest and the box keeps only 30; nothing on met ever
#         collected them, so every live tester error aged out silently. The
#         drain is the read-only `harvest` action word on the SAME restricted
#         key — no token, no shell, no box change.
#
# Both are fail-OPEN and neither can change the reset's exit code: a scheduler
# step that can turn a good reset into a reported failure is a scheduler step
# that will eventually stop the nightly.
demo_nightly_via_key() {
    local site="$1" host_override="${2:-}" dry_run="${3:-false}" print_transport="${4:-false}"
    local -a sshargs=()
    mapfile -t sshargs < <(demo_box_ssh_args "$site" "$host_override")
    (( ${#sshargs[@]} > 0 )) || {
        print_error "Cannot resolve the demo box for '$site' — pass --host <[user@]ip> or set NWP_DEMO_BOX_HOST."
        return 1
    }

    # The CRON form carries a literal `$HOME` (sh expands it). Executing it here
    # means expanding it ourselves — the one and only difference between the
    # scheduled string and the executed argv, and the pinning test asserts it.
    local i
    for i in "${!sshargs[@]}"; do sshargs[$i]="${sshargs[$i]//\$HOME/$HOME}"; done

    if [[ "$print_transport" == "true" ]]; then
        printf '%s\n' "${sshargs[*]}"
        return 0
    fi

    local action="nightly"
    [[ "$dry_run" == "true" ]] && action="dry-run"

    print_header "Nightly demo reset via the restricted key: $site (live)"
    print_info "Transport: restricted forced command — no admin key, no shell, no root on the box."

    # --- PRE: tester feedback, before the box destroys the database ----------
    demo_nightly_feedback_preflight "$site" "$dry_run" "${sshargs[@]}"

    # --- The reset itself, on the box ----------------------------------------
    local rc=0
    set +e
    # -n: never read stdin. Under cron there is none, but an interactive re-run
    # must not have the wrapper inherit a terminal either.
    "${sshargs[@]}" -n "$action"
    rc=$?
    set -e

    case "$rc" in
        0) print_status "OK" "Box reported success (action=${action})" ;;
        "$DEMO_EXIT_ACTIVE")
            # Cron retries every 30 min to the floor; the wrapper is idempotent.
            print_status "WARN" "Box reports ACTIVE sessions (exit ${DEMO_EXIT_ACTIVE}) — cron retries within the window" ;;
        2) print_status "FAIL" "Box REFUSED the action word — the key or the wrapper is not what this verb expects" ;;
        *) print_status "FAIL" "Box reset failed (exit ${rc})" ;;
    esac
    demo_log "$site" nightly-via-key "tier=live action=${action} rc=${rc}"

    # --- POST: drain the box's pre-wipe error digests ------------------------
    if [[ "$rc" -eq 0 && "$dry_run" != "true" ]]; then
        demo_nightly_harvest_drain "$site" "$host_override" "${sshargs[@]}"
    fi
    return "$rc"
}

# demo_nightly_box_leg <site> <leg> <ssh…> — run one ops#315 action word on the
# box over the restricted key and CLASSIFY the answer, because "it did not run"
# has three different truths with three different remedies:
#
#   ok           the box did the leg itself — the permanent Option-A path.
#   no-token     new wrapper, no /etc/nwp-demo/feedback.token yet. The box
#                said CANNOT VERIFY (exit 2); the remedy is the OPERATOR
#                provisioning step (registry entry demo_box_feedback_token).
#   unsupported  the wrapper predates the word ([G1] refusal, exit 2). The
#                remedy is redeploying it: bash servers/live/demo/install-box.sh
#   failed       the wrapper knows the word and could not complete it.
#
# Fail-OPEN by construction: this function reports and logs, the CALLER decides
# what a non-ok means — and for the nightly it never means failing the reset.
# Results land in GLOBALS (not stdout — a $() capture would strand them in a
# subshell): DEMO_BOX_LEG_VERDICT, and the box's own output in
# DEMO_BOX_LEG_OUT for callers that need it (harvest-post's POSTED lines).
DEMO_BOX_LEG_VERDICT=""
DEMO_BOX_LEG_OUT=""
demo_nightly_box_leg() {
    local site="$1" leg="$2"; shift 2
    local out rc=0
    set +e
    out="$("$@" -n "$leg" 2>&1)"
    rc=$?
    set -e
    DEMO_BOX_LEG_OUT="$out"
    if [[ "$rc" -eq 0 ]]; then
        demo_log "$site" "${leg}-box-ok" "tier=live"
        DEMO_BOX_LEG_VERDICT="ok"
    elif [[ "$rc" -eq 2 && "$out" == *"CANNOT VERIFY"* ]]; then
        demo_log "$site" "${leg}-box-no-token" "tier=live"
        DEMO_BOX_LEG_VERDICT="no-token"
    elif [[ "$rc" -eq 2 ]]; then
        demo_log "$site" "${leg}-box-unsupported" "tier=live rc=2"
        DEMO_BOX_LEG_VERDICT="unsupported"
    else
        demo_log "$site" "${leg}-box-failed" "tier=live rc=${rc}"
        DEMO_BOX_LEG_VERDICT="failed"
    fi
    return 0
}

# Attempt the ops#161 pre-wipe sync, and be honest when it cannot be attempted.
# Fail-OPEN in every branch: this function always returns 0.
#
# ops#315: the FIRST attempt is now the box's own `feedback-sync` action word —
# the pending set, the ops#140 minimisation gate and (once provisioned) the
# walled token all live on the box, so the scheduler needs no site config and
# no secret. The local-transport path below survives as the fallback for a box
# whose wrapper predates the word or whose token is not yet staged.
demo_nightly_feedback_preflight() {
    local site="$1" dry_run="${2:-false}"; shift 2
    if [[ "$dry_run" == "true" ]]; then
        print_info "[dry-run] pre-wipe feedback sync not attempted (a rehearsal must not push tester reports)."
        return 0
    fi
    # Moodle halves hold no pending set — local_feedback forwards at submit time.
    if [[ "$(demo_kind_of "$site")" != "drupal" ]]; then
        return 0
    fi

    # --- 1st choice: the box syncs its own feedback (ops#315) ----------------
    if (( $# > 0 )); then
        print_info "Asking the box to sync pending tester feedback before the wipe…"
        demo_nightly_box_leg "$site" feedback-sync "$@"
        case "$DEMO_BOX_LEG_VERDICT" in
            ok)
                [[ -n "$DEMO_BOX_LEG_OUT" ]] && printf '%s\n' "$DEMO_BOX_LEG_OUT"
                print_status "OK" "Box-side feedback-sync completed."
                return 0 ;;
            no-token)
                print_status "WARN" "The box CANNOT VERIFY its feedback-sync leg — no token at /etc/nwp-demo/feedback.token yet."
                print_hint "Operator step: mint + stage the walled token (registry entry demo_box_feedback_token, pl secrets steps demo_box_feedback_token)." ;;
            unsupported)
                print_status "WARN" "The box wrapper predates the feedback-sync action word — redeploy it: bash servers/live/demo/install-box.sh ${site}" ;;
            failed)
                print_status "WARN" "Box-side feedback-sync FAILED — see the box wrapper log (${site}-demo-reset.log on the box)." ;;
        esac
    fi

    # --- fallback: a real drush transport on THIS host -----------------------
    # Without live site config here there is nothing to run the module's own
    # sync command through, and the restricted key cannot provide one by
    # design ([G1]: fixed action words).
    if ! demo_live_ctx "$site" >/dev/null 2>&1; then
        demo_log "$site" feedback-sync-no-transport "tier=live reason=no-live-config-on-scheduler"
        print_status "WARN" "Pending tester feedback CANNOT be synced from this host either — no live site config here."
        print_hint "From a host with admin access + a token: pl demo feedback-sync ${site} --tier=live"
        return 0
    fi
    print_info "Syncing pending tester feedback to GitLab before the box wipes it…"
    demo_feedback_sync "$site" live demo_rdrush "$site" || true
    return 0
}

# Drain + post the box's pre-wipe digests. Fail-OPEN: always returns 0.
#
# ops#315 ORDER: drain FIRST (this host keeps its own evidence copy of every
# digest no matter what happens next), THEN ask the box to post its spool with
# its own `harvest-post` word. When the box confirms a post, the local copy is
# moved to posted/ so no host ever files the same digest twice. Only when the
# box cannot post (old wrapper, no token) does the local-token path still try.
demo_nightly_harvest_drain() {
    local site="$1" host_override="${2:-}"; shift 2
    set +e
    cmd_harvest_pull "$site" live false "$host_override"
    set -e

    # --- 1st choice: the box posts its own spool (ops#315) -------------------
    if (( $# > 0 )); then
        demo_nightly_box_leg "$site" harvest-post "$@"
        case "$DEMO_BOX_LEG_VERDICT" in
            ok)
                # Mark every box-posted digest in OUR spool too. The box names
                # them: NWP-HARVEST-POSTED <basename>.txt iid=<iid>
                local hdir base iid line n=0
                hdir="$(demo_harvest_dir "$site")"
                mkdir -p "$hdir/posted" 2>/dev/null || true
                while IFS= read -r line; do
                    base="${line#NWP-HARVEST-POSTED }"; base="${base%% *}"; base="${base%.txt}"
                    [[ -n "$base" ]] || continue
                    # Record the post + its iid LOCALLY (ops#233): without this
                    # line the iid existed only in the box's stdout, and
                    # `pl demo harvest-triage` could never name the issue a
                    # posted digest became.
                    iid="${line##*iid=}"; iid="${iid%%[^0-9]*}"
                    demo_log "$site" harvest-posted "file=${base}.md issue=#${iid:-?} via=box"
                    if [[ -f "$hdir/${base}.md" ]]; then
                        mv "$hdir/${base}.md" "$hdir/posted/${base}.md"
                        n=$(( n + 1 ))
                    fi
                done < <(printf '%s\n' "$DEMO_BOX_LEG_OUT" | grep '^NWP-HARVEST-POSTED ' || true)
                [[ -n "$DEMO_BOX_LEG_OUT" ]] && printf '%s\n' "$DEMO_BOX_LEG_OUT"
                print_status "OK" "Box posted its own harvest spool (local copies marked posted: ${n})."
                return 0 ;;
            no-token)
                print_status "WARN" "The box CANNOT VERIFY its harvest-post leg — no token at /etc/nwp-demo/feedback.token yet."
                print_hint "Operator step: mint + stage the walled token (registry entry demo_box_feedback_token)." ;;
            unsupported)
                print_status "WARN" "The box wrapper predates the harvest-post action word — redeploy it: bash servers/live/demo/install-box.sh ${site}" ;;
            failed)
                print_status "WARN" "Box-side harvest-post FAILED — digests stay spooled on the box for retry." ;;
        esac
    fi

    # --- fallback: post the pulled copies with a token on THIS host ----------
    # cmd_harvest_post sources lib/gitlab-issues.sh, whose _token EXITS the
    # process when there is none. Checking first is the difference between "no
    # token, digests kept for later" and a nightly that dies after the reset.
    if demo_ops_token_present; then
        set +e
        cmd_harvest_post "$site" false
        set -e
    else
        demo_log "$site" harvest-post-skipped "tier=live reason=no-token"
        print_info "No GitLab token on this host — digests kept in the spool. Post them with: pl demo harvest-post ${site}"
    fi
    return 0
}

# Is there a token cmd_harvest_post could use? Delegated to lib/gitlab-issues.sh
# so demo.sh still names no token key of its own (the rule the harvest-post test
# pins), and run in a SUBSHELL so a `die` inside the lib cannot take the nightly
# down after the reset has already succeeded.
demo_ops_token_present() {
    ( source "$REPO_ROOT/lib/gitlab-issues.sh" >/dev/null 2>&1 && _token_present )
}

cmd_nightly() {
    local site="$1" tier="$2" use_pair="${3:-false}"
    local via_key="${4:-false}" host_override="${5:-}" dry_run="${6:-false}"
    local print_transport="${7:-false}"
    local rc now

    # --via-key is a different NIGHTLY, not a different reset: it hands the wipe
    # to the box's own idempotent wrapper, so the retry loop below (which exists
    # to re-attempt a locally-driven reset) is cron's job instead — every 30 min
    # to the 04:00 floor, exactly as the installed schedule already does.
    if [[ "$via_key" == "true" ]]; then
        if ! demo_is_live "$tier"; then
            print_error "REFUSED: --via-key is a LIVE-tier transport (the restricted key reaches the live box)."
            return 2
        fi
        demo_nightly_via_key "$site" "$host_override" "$dry_run" "$print_transport"
        return $?
    fi

    if [[ "$use_pair" == "true" ]]; then
        print_info "Pair mode: this reset restores BOTH halves to one golden cut."
    fi
    while true; do
        set +e
        # -y for the scheduler: skips the PROMPT, never the fate manifest —
        # the report lands in logs/demo-nightly-<site>.log + demo-reset.log.
        # dry_run is explicitly "false": a scheduled reset is never a rehearsal.
        if [[ "$use_pair" == "true" ]]; then
            cmd_reset_paired "$site" "$tier" "30m" "true" "false" "false"
        else
            cmd_reset "$site" "$tier" "30m" "true" "false" "false"
        fi
        rc=$?
        set -e
        if [[ "$rc" -ne "$DEMO_EXIT_ACTIVE" ]]; then
            return "$rc"   # success (0) or hard failure (≠0,≠3) — both final
        fi
        now="$(TZ="$DEMO_TZ" date '+%H:%M')"
        if demo_past_floor "$now"; then
            demo_log "$site" skip-floor "tier=$tier now=$now floor=$DEMO_FLOOR_TIME"
            print_status "WARN" "Still active at the ${DEMO_FLOOR_TIME} ${DEMO_TZ} floor — skipping tonight's reset (logged)"
            return 0
        fi
        print_info "Active session — retrying in $(( DEMO_RETRY_SECONDS / 60 )) min (floor ${DEMO_FLOOR_TIME} ${DEMO_TZ}, now ${now})"
        sleep "$DEMO_RETRY_SECONDS"
    done
}

################################################################################
# status
################################################################################

cmd_status() {
    local site="$1" tier="${2:-dev}"
    local gdir cfile lfile
    gdir="$(demo_golden_dir "$site" "$tier")"
    cfile="$(demo_codes_file "$site")"
    lfile="$(demo_log_file "$site")"

    print_header "Demo status: $site ($tier)"

    if [[ -f "$gdir/golden.manifest.json" ]]; then
        echo "  Golden image:"
        echo "    captured: $(jq -r '.captured_utc' "$gdir/golden.manifest.json" 2>/dev/null)"
        echo "    db:       $GOLDEN_DB ($(du -h "$gdir/$GOLDEN_DB" 2>/dev/null | cut -f1))"
        echo "    files:    $GOLDEN_FILES ($(du -h "$gdir/$GOLDEN_FILES" 2>/dev/null | cut -f1))"
        if demo_golden_verify "$gdir" "$site" >/dev/null 2>&1; then
            print_status "OK" "Golden verifies (sha256)"
        else
            print_status "FAIL" "Golden does NOT verify — recapture before the next reset"
        fi
    else
        print_status "WARN" "No golden image captured yet (pl demo golden $site --tier=$tier)"
    fi

    # --- pair state (ops#133 Phase 2) ---------------------------------------
    if demo_pair_resolve "$site"; then
        local _prov="$DEMO_PAIR_PROVIDER" _cons="$DEMO_PAIR_CONSUMER"
        local _pdir _cdir _cut
        _pdir="$(demo_golden_dir "$_prov" "$tier")"
        _cdir="$(demo_golden_dir "$_cons" "$tier")"
        _cut="$(demo_pair_cut_file "$_pdir")"
        echo ""
        echo "  Demo pair: ${DEMO_PAIR_LABEL}  (provider=$_prov, consumer=$_cons)"
        echo "    contract: $(basename "$DEMO_PAIR_CONTRACT")"
        if [[ -f "$_cut" ]]; then
            echo "    cut:      $(demo_pair_cut_id_of "$_cut")  captured $(jq -r '.captured_utc // "?"' "$_cut" 2>/dev/null)"
            if demo_pair_cut_verify "$_cut" "$_prov" "$_pdir" "$_cons" "$_cdir" "$tier" >/dev/null 2>&1; then
                print_status "OK" "Both halves share one logical cut (tier ${tier})"
            else
                print_status "FAIL" "PAIR CUT BROKEN — one half was re-captured alone, or the cut is for another tier. Re-run: pl demo golden $_prov --with-pair --tier=${tier}"
            fi
        else
            print_status "WARN" "No pair cut yet (pl demo golden $_prov --with-pair --tier=${tier})"
        fi
        # A paired LIVE reset that died between the halves leaves the pair on two
        # different cuts. The session that caused it is long gone; the breadcrumb
        # is how the next reader finds out (nwp/ops#170).
        local _split
        if _split="$(demo_pair_inconsistent_summary "$_prov" 2>/dev/null)" && [[ -n "$_split" ]]; then
            print_status "FAIL" "$_split"
        fi
    fi

    # Unposted harvest digests — until the GitLab poster runs they are the only
    # place pre-wipe errors survive, so surface the backlog loudly.
    local hdir; hdir="$(demo_harvest_dir "$site")"
    if [[ -d "$hdir" ]]; then
        local pending; pending=$(find "$hdir" -maxdepth 1 -name 'harvest-*.md' 2>/dev/null | wc -l)
        if (( pending > 0 )); then
            echo ""
            print_status "WARN" "${pending} harvest digest(s) in the spool — post with: pl demo harvest-post $site"
        fi
    fi

    echo ""
    echo "  Invite codes:"
    if [[ -f "$cfile" ]] && command -v jq >/dev/null 2>&1; then
        local now; now="$(date +%s)"
        jq -r --argjson now "$now" '
            .codes[] |
            [ .id, .bundle,
              (if .revoked then "revoked" elif .expires <= $now then "expired" else "live" end),
              (.expires | todate) ] | @tsv' "$cfile" 2>/dev/null \
        | awk -F'\t' 'BEGIN { printf "    %-5s %-30s %-8s %s\n", "id", "bundle", "state", "expires" }
                      { printf "    %-5s %-30s %-8s %s\n", $1, $2, $3, $4 }'
    else
        echo "    (no code registry — pl demo codes $site issue <bundle> --tier=live)"
    fi

    # Registry-active vs site-live vs staged-payload, as last MEASURED by this
    # host (ops#173). Read from the record rather than probed here: `pl demo
    # status` must stay fast and read-only, and a number is worth more with its
    # age attached than a fresh one that costs two ssh round trips every time.
    if [[ -f "$cfile" ]]; then
        local _rep _rstate _rdetail
        _rep="$(demo_drift_report "$(demo_drift_file "$site")")"
        _rstate="${_rep%%|*}"; _rdetail="${_rep#*|}"
        echo ""
        case "$_rstate" in
            ok)      print_status "OK"   "Code delivery verified: $_rdetail" ;;
            drift)   print_status "FAIL" "CODE DRIFT: $_rdetail — testers are being rejected, or will be after 01:00"
                     print_hint "  pl demo codes $site drift --tier=live" ;;
            stale)   print_status "WARN" "Code delivery unverified: $_rdetail"
                     print_hint "  pl demo codes $site drift --tier=live" ;;
            missing) print_status "WARN" "This host has NEVER checked that ${site}'s codes reach the site."
                     print_hint "  pl demo codes $site drift --tier=live" ;;
            *)       print_status "WARN" "Code delivery: $_rdetail" ;;
        esac
    fi

    # nwp/ops#198 — SAY WHOSE LOG THIS IS.
    #
    # This block used to be headed "Recent resets/skips (last 10)" with no
    # qualifier, and it reads sites/<site>/demo-reset.log: a file written only
    # by THIS checkout. On a night when both unattended box resets ran perfectly
    # at 15:00 and 15:15 it reported "last reset 06:32" — the last time someone
    # ran a reset from this laptop. True about the wrong machine.
    echo ""
    echo "  Recent resets/skips — THIS CHECKOUT only (last 10):"
    if [[ -f "$lfile" ]]; then
        tail -n 10 "$lfile" | sed 's/^/    /'
        if tail -n 3 "$lfile" | grep -q "skip-"; then
            print_status "WARN" "Recent skip present — check activity guard / floor"
        fi
    else
        echo "    (this checkout has run no resets)"
    fi

    # The unattended resets do not run here. At the live tier, ask the box.
    if [[ "$tier" == "live" && "${DEMO_STATUS_NO_BOX:-0}" != "1" ]]; then
        cmd_status_box "$site"
    elif [[ "$tier" == "live" ]]; then
        echo ""
        echo "  Box-side (unattended) resets: SKIPPED (DEMO_STATUS_NO_BOX=1)"
    fi
}

# cmd_status_box <site> — the box's own account of the unattended resets.
#
# Split into its own function so the reporting stays honest about its THREE
# states. The old code had two ("a time" / "nothing logged"), and collapsed
# "I could not look" into the second — which is how a silently-dead nightly
# would have gone on reading as "no resets yet" forever.
cmd_status_box() {
    local site="$1" raw="" rc=0
    echo ""
    echo "  Box-side (unattended) resets:"
    raw="$(demo_box_reset_status "$site")" || rc=$?

    # rc 4 (ops#329 D6): the box answered a DIFFERENT question. Measured
    # 2026-08-10 on ssd — the admin route sends the action word positionally,
    # a pre-D6 wrapper read only $SSH_ORIGINAL_COMMAND, and what came back was
    # the transcript of a nightly RESET the monitoring probe had just asked for.
    # "The wrapper format changed?" is far too mild a thing to say about that.
    if [[ "$rc" -eq 4 ]]; then
        print_status "FAIL" "CANNOT VERIFY — the box answered, but not a status block (no 'last reset:' line)"
        echo "    It said:"
        printf '%s\n' "$raw" | head -3 | sed 's/^/      /'
        if printf '%s\n' "$raw" | grep -q 'action=nightly'; then
            echo "    That is a RESET transcript. The deployed wrapper predates ops#329 D6:"
            echo "    it reads its action word only from \$SSH_ORIGINAL_COMMAND, which sudo"
            echo "    strips, so this read-only probe resolved to the nightly reset."
        fi
        print_hint "  redeploy the wrapper: bash servers/live/demo/install-box.sh $site --no-key"
        return 0
    fi

    if [[ "$rc" -ne 0 ]]; then
        print_status "WARN" "UNKNOWN — could not read the box (no ${site}_demo_reset key, ssh refused, or timed out)"
        echo "    This is NOT 'no resets'. The box may be resetting perfectly."
        print_hint "  ssh route: pl demo schedule $site --via-key   ·   skip this probe: DEMO_STATUS_NO_BOX=1"
        return 0
    fi

    local last; last="$(demo_box_last_reset "$raw")"
    if [[ -z "$last" ]]; then
        print_status "WARN" "UNKNOWN — the box answered but named no 'last reset' (wrapper format changed?)"
    elif [[ "$last" == "none" ]]; then
        print_status "WARN" "the box has NEVER reset $site — the unattended path has not run"
        print_hint "  pl demo schedule $site --via-key"
    else
        local age
        if age="$(demo_box_reset_age_days "$last")"; then
            if [[ "$age" -ge 2 ]]; then
                print_status "WARN" "last box reset: $last (${age} days ago)"
            else
                print_status "OK" "last box reset: $last"
            fi
        else
            print_status "OK" "last box reset: $last"
        fi
    fi

    local tailed; tailed="$(demo_box_log_tail "$raw" 10)"
    if [[ -n "$tailed" ]]; then
        echo "    box log (/var/log/nwp-demo/${site}-demo-reset.log, pipe-separated):"
        printf '%s\n' "$tailed" | sed 's/^/      /'
    fi

    # The pair CONSUMER's wrapper reports neither the return leg nor the backup
    # census, by design (ops#329 D4/D5 — see demo_box_extras_by_design_json).
    # seal-status has always made that distinction; without the same branch here
    # the text surface told the operator to redeploy for a block that half will
    # never emit.
    if demo_pair_resolve "$site" 2>/dev/null && [[ "$site" != "$DEMO_PAIR_PROVIDER" ]]; then
        NWP_DEMO_EXTRAS_PREBUILT="$(demo_box_extras_by_design_json "$DEMO_PAIR_PROVIDER")" \
            demo_box_render_extras "$site" "$raw"
    else
        demo_box_render_extras "$site" "$raw"
    fi
}

# demo_box_render_extras <site> <raw-status-output> — the ops#329 D4/D5 blocks
# of the box's status word, rendered with the same three-state honesty as the
# reset stamp: a value, NOT REPORTED (old wrapper — a redeploy fixes it), or
# CANNOT VERIFY. The return leg is hourly, so a newest event older than two
# cycles is CANNOT VERIFY (stale return leg) — a stopped leg must never keep
# reading as its last good run.
demo_box_render_extras() {
    local site="$1" raw="$2" extras
    if [[ -n "${NWP_DEMO_EXTRAS_PREBUILT:-}" ]]; then
        extras="$NWP_DEMO_EXTRAS_PREBUILT"
    else
        extras="$(demo_box_extras_json "$raw")"
    fi

    echo ""
    echo "  Return leg (hourly feedback-status, box's own log):"
    local fb_reported fb_result fb_ts fb_summary fb_age fb_stale
    fb_reported="$(jq -r '.feedback_status.reported' <<<"$extras")"
    if [[ "$fb_reported" != "true" && "$(jq -r '.feedback_status.by_design // false' <<<"$extras")" == "true" ]]; then
        # DECLARED-ABSENT, not unknown. There is nothing to fix and nothing to
        # wait for, so this must not carry the redeploy hint.
        print_status "INFO" "not applicable — $(jq -r '.feedback_status.reason' <<<"$extras")"
    elif [[ "$fb_reported" != "true" ]]; then
        print_status "WARN" "NOT REPORTED — $(jq -r '.feedback_status.reason' <<<"$extras")"
    else
        fb_result="$(jq -r '.feedback_status.result' <<<"$extras")"
        fb_ts="$(jq -r '.feedback_status.ts // ""' <<<"$extras")"
        fb_summary="$(jq -r '.feedback_status.summary // ""' <<<"$extras")"
        fb_age="$(jq -r '.feedback_status.age_seconds // ""' <<<"$extras")"
        fb_stale="$(jq -r '.feedback_status.stale // false' <<<"$extras")"
        if [[ "$fb_result" == "none" ]]; then
            print_status "WARN" "the return leg has NEVER run on the box"
            print_hint "  pl demo schedule $site --feedback-status --via-key"
        elif [[ "$fb_result" == "unreadable" ]]; then
            print_status "WARN" "CANNOT VERIFY — the box log is unreadable"
        elif [[ "$fb_stale" == "true" ]]; then
            print_status "WARN" "CANNOT VERIFY (stale return leg): newest feedback-status ${fb_ts} ($(demo_box_human_age "$fb_age") ago) — expected hourly"
        elif [[ "$fb_result" == "ok" ]]; then
            print_status "OK" "last run ${fb_ts} ($(demo_box_human_age "$fb_age") ago): ${fb_summary}"
        else
            print_status "FAIL" "last run ${fb_ts} ${fb_result}: ${fb_summary}"
        fi
    fi

    echo ""
    echo "  Live-box nightly backups (newest per subdir):"
    local bk_reported bk_state bk_dir
    bk_reported="$(jq -r '.backups.reported' <<<"$extras")"
    if [[ "$bk_reported" != "true" && "$(jq -r '.backups.by_design // false' <<<"$extras")" == "true" ]]; then
        print_status "INFO" "not applicable — $(jq -r '.backups.reason' <<<"$extras")"
        return 0
    fi
    if [[ "$bk_reported" != "true" ]]; then
        print_status "WARN" "NOT REPORTED — $(jq -r '.backups.reason' <<<"$extras")"
        return 0
    fi
    bk_state="$(jq -r '.backups.state' <<<"$extras")"
    bk_dir="$(jq -r '.backups.dir' <<<"$extras")"
    case "$bk_state" in
        missing)    print_status "WARN" "CANNOT VERIFY — ${bk_dir} is MISSING on the box (the 01:30 producer cron has no landing dir)" ;;
        unreadable) print_status "WARN" "CANNOT VERIFY — ${bk_dir} exists but the wrapper cannot read it" ;;
        ok)
            local n; n="$(jq -r '.backups.entries | length' <<<"$extras")"
            if [[ "$n" == "0" ]]; then
                print_status "WARN" "${bk_dir} exists but holds no backup subdirs"
            else
                echo "    ${bk_dir}:"
                local entry sub newest bytes age
                while IFS= read -r entry; do
                    sub="$(jq -r '.subdir' <<<"$entry")"
                    if [[ "$(jq -r '.empty // false' <<<"$entry")" == "true" ]]; then
                        echo "      ${sub}: EMPTY"
                        continue
                    fi
                    newest="$(jq -r '.newest' <<<"$entry")"
                    bytes="$(jq -r '.bytes // "?"' <<<"$entry")"
                    age="$(jq -r '.age_seconds // ""' <<<"$entry")"
                    echo "      ${sub}: ${newest} (${bytes} bytes, $(demo_box_human_age "$age") old)"
                done < <(jq -c '.backups.entries[]' <<<"$extras")
            fi
            ;;
        *) print_status "WARN" "CANNOT VERIFY — unrecognised backups state '${bk_state}'" ;;
    esac
}

################################################################################
# seal-status — what will tonight's reset restore? (ops#328)
#
# The golden-interaction truth the console demo tab must carry: ANY change made
# on the live demo pair (a revoke, a purge side-effect, a guild edit) survives
# only until the next nightly reset UNLESS a new golden is sealed. The number
# that decides what comes back is the BOX-STAGED golden's capture time — not
# the repo copy (ops#269: two live fixes were "captured" locally and the
# nightly restored a two-day-old box image over both).
#
# Read-only. Fail-closed: an unreachable box or unreadable manifest is exit 2
# CANNOT VERIFY — "I could not read the staged golden" and "no golden" lead to
# different actions and must never render alike.
################################################################################

# demo_seal_emit_fail <site> <tier> <reason> — the ok:false document / line.
demo_seal_emit_fail() {
    local site="$1" tier="$2" reason="$3"
    if [[ "${DEMO_JSON:-false}" == "true" ]]; then
        jq -cn --arg site "$site" --arg tier "$tier" --arg reason "$reason" \
           '{ok:false, site:$site, tier:$tier, reason:$reason}'
    else
        print_status "WARN" "CANNOT VERIFY: $reason"
    fi
}

cmd_seal_status() {
    local site="$1" tier="${2:-dev}"
    demo_require_jq || return 2
    # extras = the ops#329 D4/D5 blocks; `{}` at dev/stg (no box, no leg —
    # absent keys, not fabricated not-reported ones).
    local src captured="" last_reset="" extras='{}'

    if demo_is_live "$tier"; then
        src="box:$(demo_box_state_dir "$site")/golden"
        if ! demo_live_ctx "$site" >/dev/null 2>&1; then
            demo_seal_emit_fail "$site" "$tier" \
                "cannot reach ${site}'s live box over ssh — the staged golden is UNKNOWN (this is NOT 'no golden')"
            return 2
        fi
        local mani=""
        mani="$(demo_rssh "$site" "cat $(demo_box_state_dir "$site")/golden/golden.manifest.json 2>/dev/null" 2>/dev/null)" || mani=""
        if [[ -z "$mani" ]]; then
            demo_seal_emit_fail "$site" "$tier" \
                "box reachable but no golden is staged at $(demo_box_state_dir "$site")/golden — the nightly reset has nothing of yours to restore (pl demo golden $site --tier=live)"
            return 2
        fi
        captured="$(printf '%s' "$mani" | jq -r '.captured_utc // empty' 2>/dev/null)" || captured=""
        if [[ -z "$captured" ]]; then
            demo_seal_emit_fail "$site" "$tier" "staged golden manifest is unreadable — CANNOT VERIFY"
            return 2
        fi
        last_reset="$(demo_rssh "$site" "cat $(demo_box_state_dir "$site")/last-reset 2>/dev/null" 2>/dev/null | tr -d '\r\n')" || last_reset=""

        # ops#329 D4/D5 — the return leg + the box's nightly pull backups ride
        # the same read, through the SAME parser the status verb uses
        # (demo_box_extras_json: one renderer, no drift). The consumer half of
        # a pair skips the probe BY DESIGN: the leg and the pull dir are
        # box-level facts and the pair provider's wrapper is their one
        # reporter — a by_design absence must never render as an error.
        if demo_pair_resolve "$site" 2>/dev/null && [[ "$site" != "$DEMO_PAIR_PROVIDER" ]]; then
            extras="$(demo_box_extras_by_design_json "$DEMO_PAIR_PROVIDER")"
        else
            local box_raw=""
            box_raw="$(demo_box_reset_status "$site" 2>/dev/null)" || box_raw=""
            extras="$(demo_box_extras_json "$box_raw")"
        fi
    else
        local gdir; gdir="$(demo_golden_dir "$site" "$tier")"
        src="$gdir"
        if [[ ! -f "$gdir/golden.manifest.json" ]]; then
            demo_seal_emit_fail "$site" "$tier" \
                "no golden captured at tier ${tier} (pl demo golden $site --tier=$tier)"
            return 2
        fi
        captured="$(jq -r '.captured_utc // empty' "$gdir/golden.manifest.json" 2>/dev/null)" || captured=""
        if [[ -z "$captured" ]]; then
            demo_seal_emit_fail "$site" "$tier" "golden manifest is unreadable — CANNOT VERIFY"
            return 2
        fi
    fi

    local cap_epoch age_secs=""
    cap_epoch="$(demo_epoch_of "$captured")"
    [[ -n "$cap_epoch" ]] && age_secs=$(( $(date +%s) - cap_epoch ))

    local window="01:00-03:30 Australia/Melbourne nightly (04:00 floor)"
    local warning="changes made after sealed_at revert at the next reset unless a new golden is sealed (pl demo golden $site --tier=$tier --with-pair, ~4-6 min paired)"
    if [[ "${DEMO_JSON:-false}" == "true" ]]; then
        jq -cn --arg site "$site" --arg tier "$tier" --arg captured "$captured" \
               --arg last_reset "$last_reset" --arg src "$src" --arg age "$age_secs" \
               --arg window "$window" --arg warning "$warning" \
               --argjson extras "$extras" \
           '{ok:true, site:$site, tier:$tier, sealed_at:$captured,
             age_seconds:(($age|tonumber?) // null),
             last_reset:(if $last_reset == "" then null else $last_reset end),
             source:$src, reset_window:$window, warning:$warning} + $extras'
    else
        print_header "Demo seal status: $site ($tier)"
        echo "    sealed_at:  $captured$( [[ -n "$age_secs" ]] && echo " ($(demo_human_age "$cap_epoch"))" )"
        echo "    source:     $src"
        [[ -n "$last_reset" ]] && echo "    last reset: $last_reset"
        echo "    window:     $window"
        print_status "WARN" "$warning"
        # ops#329 D4/D5 — same extras, same renderer as `pl demo status`.
        if [[ "$extras" != "{}" ]]; then
            demo_box_render_extras_from_json "$site" "$extras"
        fi
    fi
    return 0
}

# demo_box_render_extras_from_json <site> <extras-json> — text renderer for an
# already-assembled extras document (seal-status text mode; the status verb
# goes through demo_box_render_extras which builds the doc from the raw read).
demo_box_render_extras_from_json() {
    local site="$1" extras="$2"
    NWP_DEMO_EXTRAS_PREBUILT="$extras" demo_box_render_extras "$site" ""
}

################################################################################
# testers — the per-tester editor's pl surface (ops#328 tranche 3)
#
# The console NEVER talks drush; it runs these. Reads pass the site's own
# nwc:tester-list JSON through; writes wrap nwc:tester-set-guild /
# nwc:tester-set-level. The tier decides the transport: live → demo_rdrush
# (ssh + remote drush, the ops#170 site-keyed context), dev/stg → the local
# DDEV project. These are SITE writes, not registry writes, so the D1
# registry-home guard does not apply — the guards that DO are: an explicit
# tier (ops#225), the target reporting demo_mode=true (the pl-layer half of
# the fence; the drush command's @demo.invalid account fence is the other),
# and fail-closed exit 2 CANNOT VERIFY whenever the site cannot be reached
# or the command is not deployed there yet.
################################################################################

# Tier-appropriate drush for the testers verbs. stdout = drush output
# (stdout+stderr merged, so "Command not defined" is catchable), rc = drush rc.
demo_testers_drush() {
    local site="$1" tier="$2"; shift 2
    if demo_is_live "$tier"; then
        demo_rdrush "$site" "$@" 2>&1
    else
        local proj
        proj="$(demo_project_dir "$site" "$tier")" || return 1
        demo_drush "$proj" "$@" 2>&1
    fi
}

################################################################################
# THE PROD-PHASE GUARD (CLAUDE.md standing order · ops#33 · ops#214)
#
# Every demo action that MINTS A CREDENTIAL for a live identity, WRITES a
# member's guild/level, or PROBES a running host is refused when the target
# site's CANONICAL PHASE is `prod`.
#
# It keys off the phase, never off a site's name. "Refuse nwd" would be wrong
# today (nwd is the demo tier and this whole surface exists for it) and wrong
# later (it would miss whatever new site becomes prod). "Refuse a site whose
# canonical phase is prod" is INERT today — `pl canonical` reports no prod site
# anywhere on the estate — and correct forever; it arms itself the moment
# `pl canonical set <site> prod` runs.
#
# An inert guard nobody has seen fire is the check-that-cannot-fail class, so
# tests/unit/test-demo-walkthrough.bats drives it against a fixture nwp.yml that
# declares `canonical: prod` and asserts the refusal TEXT — and a sibling case
# asserts it stays silent at dev and live, so "refuses everything" cannot pass
# for "refuses prod".
#
# FAIL CLOSED: an unreadable or invalid phase is exit 2 CANNOT VERIFY, not a
# pass. "I could not read the policy" must never look like a decision.
#
#   rc 0 — allowed        rc 1 — REFUSED (prod)        rc 2 — CANNOT VERIFY
################################################################################
demo_refuse_prod_phase() {
    local site="$1" label="${2:-this action}" phase
    phase="$(canonical_get_phase "$site" 2>/dev/null || echo "")"
    case "$phase" in
        prod)
            print_error "REFUSED: '${site}' is canonical: prod — ${label} is a demo-tier action." >&2
            print_info  "The demo tier mints one-time logins, rewrites guild membership and probes URLs." >&2
            print_info  "None of that belongs on a site holding real members' data. Check: pl canonical show ${site}" >&2
            jq -n --arg s "$site" --arg l "$label" \
                '{ok: false, refused: true, phase: "prod",
                  reason: ("REFUSED: " + $s + " is canonical: prod — " + $l + " is a demo-tier action and never runs against prod")}'
            return 1 ;;
        dev|live)
            return 0 ;;
        "")
            print_error "CANNOT VERIFY the canonical phase of '${site}' — refusing ${label}." >&2
            jq -n --arg s "$site" --arg l "$label" \
                '{ok: false, reason: ("CANNOT VERIFY: the canonical phase of " + $s + " could not be read, so " + $l + " is refused. This is not a clean result.")}'
            return 2 ;;
        *)
            # cannot-verify:<why> and invalid:<raw> both land here.
            print_error "CANNOT VERIFY the canonical phase of '${site}' (${phase}) — refusing ${label}." >&2
            jq -n --arg s "$site" --arg l "$label" --arg p "$phase" \
                '{ok: false, reason: ("CANNOT VERIFY: " + $s + " reports canonical phase " + $p + ", so " + $l + " is refused. This is not a clean result.")}'
            return 2 ;;
    esac
}

# One JSON refusal shape for wrapper-level refusals, so the console parses
# every outcome the same way. Human summary goes to stderr.
demo_testers_refuse() {
    local reason="$1"
    print_error "REFUSED: ${reason}" >&2
    jq -n --arg r "$reason" '{ok: false, refused: true, reason: $r}'
    return 1
}

# Classify a drush result and emit/exit honestly:
#   rc 0                  → pass the JSON through, exit 0
#   "Command … not defined" → exit 2, {"ok":false,"not_deployed":true,…} naming the fix
#   typed drush refusal   → pass it through, exit 1
#   anything else         → exit 2 CANNOT VERIFY carrying the output tail
demo_testers_emit() {
    local site="$1" tier="$2" cmdname="$3" rc="$4" out="$5"
    if [[ "$rc" -eq 0 ]]; then
        printf '%s\n' "$out"
        return 0
    fi
    if grep -q 'is not defined' <<<"$out"; then
        jq -n --arg r "drush command ${cmdname} is not on ${site} ${tier} yet — merge + deploy the nwc profile MR (ops#328 tranche 3), then retry" \
            '{ok: false, not_deployed: true, reason: $r}'
        return 2
    fi
    if jq -e '.refused == true' <<<"$out" >/dev/null 2>&1; then
        printf '%s\n' "$out"
        return 1
    fi
    if jq -e '.ok == false' <<<"$out" >/dev/null 2>&1; then
        # drush's own CANNOT VERIFY document — pass it through at its exit class.
        printf '%s\n' "$out"
        return 2
    fi
    jq -n --arg r "CANNOT VERIFY: ${cmdname} failed on ${site} ${tier} (rc=${rc})" \
          --arg raw "$(tail -c 1500 <<<"$out")" \
          '{ok: false, reason: $r, raw: $raw}'
    return 2
}

# The pl-layer fence half for WRITES: the target site must itself say it is a
# demo tier (demo_mode=true). Anything else — false, empty, unreadable —
# refuses: this wrapper only ever edits demo testers, and when it cannot
# prove the target is the demo tier it fails toward the fence. (The drush
# command's own @demo.invalid fence still applies underneath; dev-tier
# operators who genuinely need more run drush directly.)
demo_testers_require_demo_mode() {
    local site="$1" tier="$2" val
    val="$(demo_testers_drush "$site" "$tier" cget nwc_demo_access.settings demo_mode --format=string 2>/dev/null \
           | tr -d '[:space:]')" || val=""
    case "$val" in
        1|true|TRUE) return 0 ;;
    esac
    demo_testers_refuse "${site} (${tier}) does not report nwc_demo_access demo_mode=true (got '${val:-<unreadable>}') — the testers editor only writes on a demo tier, and an unreadable flag fails toward the fence."
}

################################################################################
# login — see the site through a tester's eyes (ops#328 t4)
#
# The personas have NO PASSWORDS: nwc:seed-demo mints them and nobody ever set
# one, so a one-time login link is the only way in. Two traps, both hit for
# real on nwd live before this verb existed:
#
#   1. --uri IS REQUIRED. Without it drush has no base URL and mints
#      http://default/user/reset/… — a link that goes nowhere, handed to an
#      operator who has no way to tell from looking at it.
#   2. THE POSITIONAL ARGUMENT IS A PATH, NOT A USERNAME. `drush user:login
#      demo_writer` puts "demo_writer" in the `path` slot; with no --name the
#      command falls through to `User::load(1)` and returns an ADMIN link.
#      It looks exactly like a persona link and it is a root session.
#
# Trap 2 is made UNREACHABLE rather than merely avoided: the verb passes
# --name=, and then reads the uid back out of the returned
# /user/reset/<uid>/… and refuses unless it is the uid the roster gave for
# this account. A link for any other uid — most of all uid 1 — is discarded
# and never printed, on any path.
#
# THE LINK IS A CREDENTIAL. It is rendered once on stdout and that is the only
# place it ever exists: not in argv (the account name is the argument), not in
# sites/<site>/demo-reset.log (which records account+uid+outcome), and not in
# any refusal document or raw-output tail — demo_testers_scrub_links strips
# any reset URL from anything this path emits on the way out.
################################################################################

# Strip one-time login links out of any text before it is emitted. Belt to the
# braces of "never put it there in the first place": the raw-output tail of a
# CANNOT VERIFY document is assembled from drush's own output, which is
# exactly where a link that failed its uid check would be.
demo_testers_scrub_links() {
    sed -E 's#https?://[^[:space:]]*/user/reset/[^[:space:]]*#<one-time link REDACTED>#g'
}

# demo_login_uri <site> <tier> → the base URL to hand drush as --uri, or "".
# live  → https://<live.domain>, the same fact the invitation email resolves.
# dev|stg → the DDEV project's URL (name from .ddev/config.yaml, else the
#           documented <site>-<tier> convention).
demo_login_uri() {
    local site="$1" tier="$2" base="" proj name=""
    if demo_is_live "$tier"; then
        base="$(demo_invite_community_base "$site")"
    else
        proj="$(demo_project_dir "$site" "$tier" 2>/dev/null)" || proj=""
        if [[ -n "$proj" && -f "$proj/.ddev/config.yaml" ]]; then
            # yq, never awk (ADR-0015 / lint-yq-first). demo_yq resolves the
            # user-local installs the console host needs.
            local yqb; yqb="$(demo_yq 2>/dev/null || true)"
            if [[ -n "$yqb" ]]; then
                name="$("$yqb" eval '.name // ""' "$proj/.ddev/config.yaml" 2>/dev/null || true)"
                [[ "$name" == "null" ]] && name=""
            fi
        fi
        [[ -n "$name" ]] || name="${site}-${tier}"
        base="https://${name}.ddev.site"
    fi
    [[ "$base" == https://* ]] || base=""
    echo "$base"
}

cmd_testers_login() {
    local site="$1" tier="$2" acct="$3"; shift 3 || true
    [[ $# -eq 0 ]] || { demo_testers_refuse "unrecognised argument(s) for login: $*"; return 1; }
    [[ -n "$acct" ]] || {
        demo_testers_refuse "Usage: pl demo testers ${site} login <account> --tier=live"
        return 1
    }
    [[ "$acct" =~ ^[A-Za-z0-9][A-Za-z0-9_.@-]{0,79}$ ]] || {
        demo_testers_refuse "account '${acct}' fails the shape check (letters/digits/._@- only)"
        return 1
    }

    # 1. The URI, FIRST. drush is never called without one — a link minted
    #    against http://default is worse than a refusal, because it looks like
    #    a success.
    local uri; uri="$(demo_login_uri "$site" "$tier")"
    [[ -n "$uri" ]] || {
        demo_testers_refuse "cannot resolve a base URL for ${site} (${tier}) — without --uri drush mints a http://default/ link that goes nowhere. Set live.domain in sites/${site}/.nwp.yml."
        return 1
    }

    # 2. The roster decides WHO this is: uid and fence come from the site, not
    #    from the argument. An unreadable roster is CANNOT VERIFY — it never
    #    proceeds on an assumption about an identity it could not read.
    local out rc=0
    out="$(demo_testers_drush "$site" "$tier" nwc:tester-list --format=json)" || rc=$?
    if (( rc != 0 )); then
        demo_testers_emit "$site" "$tier" nwc:tester-list "$rc" "$out"
        return $?
    fi
    local row
    row="$(jq -c --arg n "$acct" '[.accounts[]? | select(.name == $n)] | .[0] // empty' <<<"$out" 2>/dev/null)" || row=""
    if [[ -z "$row" ]]; then
        demo_testers_refuse "'${acct}' is not in ${site}'s fenced tester roster — nothing was minted. The roster lists the @demo.invalid accounts only; a real account is not loggable through this verb by design."
        return 1
    fi
    local uid mail active
    uid="$(jq -r '.uid // empty' <<<"$row")"
    mail="$(jq -r '.mail // ""' <<<"$row")"
    active="$(jq -r 'if .active then "true" else "false" end' <<<"$row")"
    if [[ ! "$uid" =~ ^[0-9]+$ ]]; then
        jq -n --arg r "CANNOT VERIFY: ${site}'s roster gave no usable uid for '${acct}' — refusing to mint a session for an identity it could not read" \
            '{ok:false, reason:$r}'
        return 2
    fi
    # uid<=1 is refused ALWAYS. This is the admin-link trap's destination, and
    # it is closed here as well as at the link check — a guard at one end only
    # is a guard you can walk around.
    if (( uid <= 1 )); then
        demo_testers_refuse "'${acct}' is uid ${uid} — uid<=1 is the site administrator and is REFUSED always. A console button that hands out a root session while saying 'sign in as this tester' is the whole reason this check exists."
        return 1
    fi
    if [[ "$mail" != *"@demo.invalid" ]]; then
        demo_testers_refuse "'${acct}' (${mail:-<no mail>}) is not on the @demo.invalid fence — this verb only ever signs in as a synthetic tester. The pl wrapper never forwards --allow-real."
        return 1
    fi
    if [[ "$active" != "true" ]]; then
        demo_testers_refuse "'${acct}' is blocked on ${site} — drush would refuse the login anyway. Unblock the account first if this is deliberate."
        return 1
    fi

    # 3. The pl-layer fence half, same as every other tester write.
    demo_testers_require_demo_mode "$site" "$tier" || return 1

    # 4. Mint. --name= (never the positional path slot) and --uri=, both.
    rc=0
    out="$(demo_testers_drush "$site" "$tier" user:login --name="$acct" --uri="$uri" --no-browser)" || rc=$?
    if (( rc != 0 )); then
        # Scrubbed: a failed call may still have printed a link.
        demo_testers_emit "$site" "$tier" user:login "$rc" "$(printf '%s' "$out" | demo_testers_scrub_links)"
        local _erc=$?
        demo_log "$site" tester-login-failed "acct=${acct} uid=${uid} tier=${tier} rc=${rc}"
        return $_erc
    fi
    local link link_uid
    link="$(grep -Eo 'https?://[^[:space:]]+/user/reset/[0-9]+/[0-9]+/[^[:space:]]+' <<<"$out" | head -n1)" || link=""
    if [[ -z "$link" ]]; then
        jq -n --arg r "CANNOT VERIFY: drush user:login returned no one-time link for '${acct}' on ${site} (${tier}) — nothing is being shown, because there is nothing that verified" \
            '{ok:false, reason:$r}'
        demo_log "$site" tester-login-failed "acct=${acct} uid=${uid} tier=${tier} no-link"
        return 2
    fi
    link_uid="$(sed -E 's#.*/user/reset/([0-9]+)/.*#\1#' <<<"$link")"
    if [[ "$link_uid" != "$uid" ]]; then
        # THE TRAP, caught. The link is dropped on the floor here — it is not
        # echoed, not put in a reason, not tailed into a raw field.
        demo_testers_refuse "the link drush returned is for uid ${link_uid}, not '${acct}' (uid ${uid}) — it was DISCARDED and is NOT shown. user:login's positional argument is a PATH, not a username, so a name in that slot silently returns a uid 1 administrator session that looks exactly like a tester link."
        demo_log "$site" tester-login-refused "acct=${acct} uid=${uid} got_uid=${link_uid} tier=${tier} link-discarded"
        return 1
    fi
    if [[ "$link" != "${uri}/"* ]]; then
        demo_testers_refuse "the link is not on ${uri} — DISCARDED unprinted. That is the missing-base-URL symptom (drush falls back to http://default/), and such a link cannot log anybody in."
        demo_log "$site" tester-login-refused "acct=${acct} uid=${uid} tier=${tier} wrong-origin link-discarded"
        return 1
    fi

    # The ACCESS is recorded; the CREDENTIAL is not.
    demo_log "$site" tester-login-minted \
        "acct=${acct} uid=${uid} tier=${tier} by=${SUDO_USER:-${USER:-unknown}} (one-time link NOT recorded)"

    if [[ "${DEMO_JSON:-false}" == "true" ]]; then
        jq -n --arg a "$acct" --argjson uid "$uid" --arg url "$link" --arg uri "$uri" --arg site "$site" \
            '{ok:true, account:$a, uid:$uid, site:$site, uri:$uri, url:$url, shown_once:true,
              note:"one-time login link: single use, expires with the site login-link window, and grants this tester session. It exists in this output only - it is not stored and not logged."}'
        return 0
    fi
    print_header "One-time login link — ${acct} (uid ${uid}) on ${site} (${tier})"
    echo ""
    echo "    ${BOLD}${link}${NC}"
    echo ""
    print_status "WARN" "Shown ONCE — single use. It is not stored and not logged; the demo log records only that you minted one."
    print_info "Open it in a private window so it does not replace your own session."
    return 0
}

cmd_testers() {
    local site="$1" tier="$2" remove="$3"; shift 3 || true
    local action="${1:-list}"; shift || true
    demo_require_jq || return 1

    # --allow-real is a drush-side hatch for NON-demo installs; the pl wrapper
    # never forwards it. Refuse it by name wherever it appears, before any
    # validation could reorder the message.
    local a
    for a in "$@"; do
        case "$a" in
            --allow-real*)
                demo_testers_refuse "the pl wrapper never forwards --allow-real — the @demo.invalid fence is the point of this verb. On a dev tier, run the drush command directly if you really mean it."
                return 1 ;;
        esac
    done

    case "$action" in
        list) ;;
        set-guild|set-level|login)
            # Writes name their tier — the ops#225/#173 rule, same wording as
            # every code verb. `login` is not a write to the roster, but it
            # MINTS A CREDENTIAL against a running site, and minting one for
            # the wrong site is the same class of accident.
            demo_require_explicit_tier "testers ${action}" \
                "pl demo testers ${site} ${action} <account> … --tier=live" || return 1
            # …and the phase, not the name. A prod site never has its members
            # edited or a login link minted for it from here. Inert today.
            demo_refuse_prod_phase "$site" "pl demo testers ${action}" || return $?
            ;;
        *)
            print_error "Unknown testers action '${action}' (list|set-guild|set-level|login)"
            return 1 ;;
    esac

    local out rc
    case "$action" in
        list)
            if [[ "${DEMO_JSON:-false}" == "true" ]]; then
                rc=0; out="$(demo_testers_drush "$site" "$tier" nwc:tester-list --format=json)" || rc=$?
                demo_testers_emit "$site" "$tier" nwc:tester-list "$rc" "$out"
                return $?
            fi
            rc=0; out="$(demo_testers_drush "$site" "$tier" nwc:tester-list)" || rc=$?
            if [[ "$rc" -ne 0 ]]; then
                demo_testers_emit "$site" "$tier" nwc:tester-list "$rc" "$out"
                return $?
            fi
            printf '%s\n' "$out"
            ;;
        set-guild)
            local acct="${1:-}" key="${2:-}"; shift 2 2>/dev/null || true
            [[ -n "$acct" && -n "$key" ]] || {
                demo_testers_refuse "Usage: pl demo testers ${site} set-guild <account> <seed-key> [--group-role=ID|member] [--remove] --tier=…"
                return 1
            }
            [[ "$acct" =~ ^[A-Za-z0-9][A-Za-z0-9_.@-]{0,79}$ ]] || {
                demo_testers_refuse "account '${acct}' fails the shape check (letters/digits/._@- only)"
                return 1
            }
            [[ "$key" =~ ^[a-z0-9][a-z0-9-]{0,39}$ ]] || {
                demo_testers_refuse "'${key}' is not a seed key (lowercase machine id, e.g. 'writers'). Guilds are addressed by field_group_seed_key, never by label."
                return 1
            }
            local role=""
            for a in "$@"; do
                case "$a" in
                    --group-role=*) role="${a#--group-role=}" ;;
                    *)
                        demo_testers_refuse "unrecognised argument '${a}' for set-guild"
                        return 1 ;;
                esac
            done
            if [[ -n "$role" ]]; then
                [[ "$role" =~ ^[a-z][a-z0-9-]{0,39}$ ]] || {
                    demo_testers_refuse "group role '${role}' fails the shape check (drush validates the real role set)"
                    return 1
                }
            fi
            if [[ "$remove" == "true" && -n "$role" ]]; then
                demo_testers_refuse "--remove and --group-role are contradictory — pass exactly one"
                return 1
            fi
            demo_testers_require_demo_mode "$site" "$tier" || return 1
            local dargs=(nwc:tester-set-guild "$acct" "$key")
            [[ -n "$role" ]] && dargs+=("--group-role=${role}")
            [[ "$remove" == "true" ]] && dargs+=(--remove)
            rc=0; out="$(demo_testers_drush "$site" "$tier" "${dargs[@]}")" || rc=$?
            demo_log "$site" testers-set-guild "acct=${acct} key=${key} role=${role:-—} remove=${remove} tier=${tier} rc=${rc}"
            demo_testers_emit "$site" "$tier" nwc:tester-set-guild "$rc" "$out"
            return $?
            ;;
        set-level)
            local acct="${1:-}" level="${2:-}"; shift 2 2>/dev/null || true
            [[ -n "$acct" && -n "$level" ]] || {
                demo_testers_refuse "Usage: pl demo testers ${site} set-level <account> <level> --tier=…"
                return 1
            }
            [[ "$acct" =~ ^[A-Za-z0-9][A-Za-z0-9_.@-]{0,79}$ ]] || {
                demo_testers_refuse "account '${acct}' fails the shape check"
                return 1
            }
            [[ "$level" =~ ^[0-9]{1,2}$ ]] || {
                demo_testers_refuse "level '${level}' is not an integer (the drush side enforces the real 1..max bounds)"
                return 1
            }
            [[ $# -eq 0 ]] || {
                demo_testers_refuse "unrecognised argument(s) for set-level: $*"
                return 1
            }
            demo_testers_require_demo_mode "$site" "$tier" || return 1
            rc=0; out="$(demo_testers_drush "$site" "$tier" nwc:tester-set-level "$acct" "$level")" || rc=$?
            demo_log "$site" testers-set-level "acct=${acct} level=${level} tier=${tier} rc=${rc}"
            demo_testers_emit "$site" "$tier" nwc:tester-set-level "$rc" "$out"
            return $?
            ;;
        login)
            cmd_testers_login "$site" "$tier" "${1:-}" "${@:2}"
            return $?
            ;;
    esac
}

################################################################################
# codes
################################################################################

cmd_codes() {
    local site="$1" tier="$2" action="$3"; shift 3 || true
    local cfile; cfile="$(demo_codes_file "$site")"
    demo_require_jq || return 1

    # `list` is read-only and keeps the default tier. Everything else either
    # mints a code or pushes the registry into a running site, and must say
    # WHICH site. (revoke is the sharpest of these: revoking against dev while
    # the code is live in the site's state leaves it redeemable.) `purge` never
    # touches a running site, but it rewrites the registry, and the registry
    # has ONE writable home per tier (ops#173) — so it carries the same two
    # guards as every other registry write.
    case "$action" in
        issue|revoke|rotate|sync|purge|reconcile)
            demo_require_explicit_tier "codes ${action}" \
                "pl demo codes ${site} ${action} --tier=live" || return 1
            ;;
    esac

    # …then whether this host IS the registry's declared home (ops#328 D1) —
    # identity before transport, and before anything is minted…
    #
    # `reveal` is a READ, and reads are otherwise unguarded — but it reads the
    # INVITE PACKS, and the operator ruled (2026-08-11) that the packs live
    # with the registry home. A reveal on any other host would answer off
    # whichever packs happened to be lying around there, which is precisely
    # the half-working, two-copies state D1 exists to end. `packs` is exempt
    # because relocating a stray copy is by definition run on the stray host.
    local _rc=0
    case "$action" in
        issue|revoke|rotate|sync|purge|reconcile)
            demo_require_registry_home "$site" "codes ${action}" || { _rc=$?; return $_rc; }
            ;;
        reveal)
            demo_require_registry_home "$site" "codes reveal" \
                "reads the invite packs, and they live with the invite-code registry" \
                || { _rc=$?; return $_rc; }
            ;;
    esac

    # …and then, on the same write verbs, whether this host can reach the
    # tier it just named (ops#173). `sync` is exempt from the pre-check only in
    # the sense that it has no code to burn — it still goes through the same
    # probe so the refusal explains the registry-home model instead of leaving
    # the operator with a bare "Cannot reach live host".
    case "$action" in
        issue|revoke|rotate|sync|purge|reconcile)
            demo_require_delivery "$site" "$tier" "codes ${action}" || return 1
            ;;
    esac

    case "$action" in
        list)
            # --json (parsed by main into DEMO_JSON) is the console's contract:
            # structured rows + counts, absent≠unreadable (ops#328).
            if [[ "${DEMO_JSON:-false}" == "true" ]]; then
                demo_codes_list_json "$site" "$cfile" "$(demo_invite_pack_dir "$site")"
                return $?
            fi
            cmd_status "$site" "$tier" | sed -n '/Invite codes:/,/Recent resets/p' | head -n -1
            print_info "Only sha256 hashes are stored — plaintext codes are shown once at issue time."
            ;;
        issue)
            local bundle="${1:-}" expires_in="14d" a
            for a in "$@"; do [[ "$a" == --expires=* ]] && expires_in="${a#--expires=}"; done
            [[ -n "$bundle" ]] || { print_error "Usage: pl demo codes <site> issue <bundle> [--expires=14d]"; return 1; }
            demo_bundle_valid "$bundle" || {
                print_error "Unknown bundle '$bundle'. Valid: ${DEMO_BUNDLES[*]}"
                return 1
            }
            local secs code hash id expires
            secs="$(demo_parse_duration "$expires_in")" || { print_error "Bad --expires duration '$expires_in'"; return 1; }
            code="$(demo_generate_code)" || { print_error "Code generation failed"; return 1; }
            hash="$(demo_hash_code "$code")"
            id="$(demo_next_code_id "$cfile")"
            expires=$(( $(date +%s) + secs ))
            demo_code_add "$cfile" "$id" "$bundle" "$hash" "$expires" || return 1
            demo_log "$site" codes-issued "id=$id bundle=$bundle expires_in=$expires_in"
            print_header "Invite code issued (${bundle})"
            echo ""
            echo "    ${BOLD}${code}${NC}"
            echo ""
            print_status "WARN" "Shown ONCE — only its sha256 hash is stored ($id, expires $(date -d "@$expires" '+%Y-%m-%d'))."
            print_info "Distribute to INVITED helpers only (decisions §4.2 — never post publicly)."
            demo_sync_codes_to_site "$site" "$tier" || true
            ;;
        revoke)
            # One or MANY ids (console bulk-select, ops#328). Validate the whole
            # batch BEFORE revoking anything: a bulk verb that half-applies and
            # then errors reports a state it did not leave. (Before this, a
            # stray second argument was silently ignored and the first id was
            # revoked anyway — proven red by the ops#328 bats test.)
            local ids=("$@") id
            [[ ${#ids[@]} -gt 0 && -n "${ids[0]:-}" ]] \
                || { print_error "Usage: pl demo codes <site> revoke <id>..."; return 1; }
            for id in "${ids[@]}"; do
                jq -e --arg id "$id" '.codes[] | select(.id == $id)' "$cfile" >/dev/null 2>&1 \
                    || { print_error "no code with id '$id' — NOTHING was revoked (whole batch refused)"; return 1; }
            done
            for id in "${ids[@]}"; do
                demo_code_revoke "$cfile" "$id" || return 1
                demo_log "$site" codes-revoked "id=$id"
            done
            print_status "OK" "Revoked ${#ids[@]} code(s): ${ids[*]}"
            demo_sync_codes_to_site "$site" "$tier" || true
            ;;
        purge)
            # Remove revoked/expired rows from the registry, archiving them to
            # sites/<site>/demo-codes-purged.json (ops#328). NEVER a live code:
            # purge is housekeeping, revoke is the verb that kills a code.
            local ids=("$@") id state now
            [[ ${#ids[@]} -gt 0 && -n "${ids[0]:-}" ]] \
                || { print_error "Usage: pl demo codes <site> purge <id>... --tier=<t>"; return 1; }
            [[ -f "$cfile" ]] || { print_error "no code registry at $cfile"; return 1; }
            now="$(date +%s)"
            for id in "${ids[@]}"; do
                state="$(jq -r --arg id "$id" --argjson now "$now" '
                    [.codes[] | select(.id == $id)]
                    | if length == 0 then "missing"
                      else .[0] | (if .revoked then "revoked"
                                   elif .expires <= $now then "expired"
                                   else "live" end) end' "$cfile" 2>/dev/null)" || state=""
                if [[ -z "$state" || "$state" == "missing" ]]; then
                    print_error "no code with id '$id' — NOTHING was purged (whole batch refused)"
                    return 1
                fi
                if [[ "$state" == "live" ]]; then
                    print_error "REFUSED: '$id' is a LIVE code — purge only removes revoked/expired rows."
                    print_hint "Revoke it first: pl demo codes $site revoke $id --tier=$tier"
                    return 1
                fi
            done
            demo_codes_purge "$cfile" "$(demo_purged_file "$site")" "${ids[@]}" || return 1
            demo_log "$site" codes-purged "ids=${ids[*]} count=${#ids[@]}"
            print_status "OK" "Purged ${#ids[@]} code(s) → $(demo_purged_file "$site") (archived, not destroyed)"
            ;;
        rotate)
            local bundles b now
            bundles="$(demo_active_bundles "$cfile")"
            [[ -n "$bundles" ]] || { print_info "No live codes to rotate."; return 0; }
            now="$(date +%s)"
            # Revoke every live code…
            while IFS= read -r cid; do
                demo_code_revoke "$cfile" "$cid"
            done < <(jq -r --argjson now "$now" \
                '.codes[] | select(.revoked == false and .expires > $now) | .id' "$cfile")
            demo_log "$site" codes-rotated ""
            print_status "OK" "All live codes revoked."
            # …then reissue one per bundle that had one (each prints once).
            while IFS= read -r b; do
                cmd_codes "$site" "$tier" issue "$b"
            done <<< "$bundles"
            ;;
        sync)
            demo_sync_codes_to_site "$site" "$tier"
            ;;
        reveal)
            cmd_codes_reveal "$site" "$cfile" "$@"
            return $?
            ;;
        packs)
            cmd_codes_packs "$site" "$@"
            return $?
            ;;
        reconcile)
            cmd_codes_reconcile "$site" "$tier" "$@"
            ;;
        drift)
            cmd_codes_drift "$site" "$tier"
            ;;
        *)
            print_error "Unknown codes action '$action' (list|issue|revoke|rotate|sync|drift|purge|reconcile|reveal|packs)"
            return 1
            ;;
    esac
}

################################################################################
# reveal — show ONE code's plaintext again, without weakening the registry
#
# `pl demo codes <site> reveal <id> [--json]`
#
# The registry is still hash-only. This does not undo that: it recomputes the
# join the estate always had but never used — demo_hash_code is UNSALTED, the
# invite packs hold the plaintext, and the hash the registry already stored is
# the key. Nothing is written; the plaintext is printed exactly once, to this
# process's stdout, and reaches no file, no log and no argv.
#
# What IS written is an ACCESS RECORD: who revealed which id, when. A code
# whose plaintext has been looked at again is a code whose exposure surface
# grew, and that has to be legible afterwards — the value never is, the access
# always is.
################################################################################
cmd_codes_reveal() {
    local site="$1" cfile="$2"; shift 2 || true
    local id="${1:-}"; shift || true
    if [[ -z "$id" ]]; then
        print_error "Usage: pl demo codes <site> reveal <id> [--json]"
        print_hint  "Which ids are recoverable at all: pl demo codes ${site} list --json | jq '.codes[]|select(.recoverable)'"
        return 1
    fi
    [[ $# -eq 0 ]] || { print_error "REFUSED: unrecognised argument(s) for reveal: $*"; return 1; }
    [[ "$id" =~ ^[A-Za-z0-9_-]{1,40}$ ]] || { print_error "'$id' is not a code id"; return 1; }

    local packdir out rc=0
    packdir="$(demo_invite_pack_dir "$site")"
    out="$(demo_code_reveal "$cfile" "$packdir" "$id")" || rc=$?

    # The access record — id, who, where. NEVER the value, on any path.
    if (( rc == 0 )); then
        demo_log "$site" code-revealed \
            "id=${id} by=${SUDO_USER:-${USER:-unknown}}@$(demo_registry_local_host) pack=$(printf '%s' "$out" | jq -r '.pack // "?"')"
    else
        demo_log "$site" code-reveal-miss "id=${id} by=${SUDO_USER:-${USER:-unknown}}@$(demo_registry_local_host) rc=${rc}"
    fi

    if [[ "${DEMO_JSON:-false}" == "true" ]]; then
        printf '%s\n' "$out"
        return $rc
    fi
    if (( rc == 0 )); then
        print_header "Invite code ${id} ($(printf '%s' "$out" | jq -r '.bundle'), $(printf '%s' "$out" | jq -r '.state'))"
        echo ""
        echo "    ${BOLD}$(printf '%s' "$out" | jq -r '.code')${NC}"
        echo ""
        print_status "WARN" "Shown here and nowhere else — recovered from $(printf '%s' "$out" | jq -r '.pack'); the registry still stores only its sha256."
        print_info "The reveal is recorded in $(demo_log_file "$site") (id + who, never the value)."
        return 0
    fi
    print_error "$(printf '%s' "$out" | jq -r '.reason // "reveal failed"')"
    return $rc
}

################################################################################
# packs — the invite packs belong ON THE REGISTRY HOME (operator ruling
# 2026-08-11; the home is named in servers/live/demo/registry-home.yml and
# nowhere else, per the P61 leakage rule that the pre-commit gitleaks hook
# enforces — it caught exactly this comment on the first commit attempt)
#
# `pl demo codes <site> packs inventory`         what is here, no plaintext
# `pl demo codes <site> packs relocate [--apply]` move strays to the home
#
# A pack is the ONLY surviving copy of a code's plaintext. One sitting on a
# non-home host is plaintext invite codes in a place no verb looks after: not
# in the home's backup pull, not visible to `reveal`, and duplicated on two
# machines. relocate copies each pack to the home, PROVES the home's copy is
# byte-identical, and only then removes the local one. It refuses to overwrite
# a home pack of the same name whose content differs — that pack's plaintext
# may exist nowhere else either.
#
# The plaintext never touches argv, stdout or the ledger: rsync moves the file
# as a file, and what is recorded is the filename and a sha256 prefix.
################################################################################
cmd_codes_packs() {
    local site="$1"; shift || true
    local action="${1:-inventory}"; shift || true
    local apply="false" a
    for a in "$@"; do
        case "$a" in
            --apply) apply="true" ;;
            *) print_error "REFUSED: unrecognised argument '$a' for packs ${action}"; return 1 ;;
        esac
    done
    local packdir; packdir="$(demo_invite_pack_dir "$site")"

    case "$action" in
        inventory)
            local files rc=0
            files="$(demo_pack_files "$packdir" 2>&1)" || rc=$?
            if (( rc != 0 )); then
                print_error "$(printf '%s' "$files" | tail -n1)"
                return 2
            fi
            print_header "Invite packs on $(demo_registry_local_host) — ${site}"
            echo "    dir: ${packdir}"
            local f n total=0
            while IFS= read -r f; do
                [[ -n "$f" ]] || continue
                n="$(grep -Eco "$DEMO_CODE_PLAINTEXT_RE" "$f" 2>/dev/null || echo 0)"
                printf '    %-34s %s code(s)  sha256:%s…\n' "$(basename "$f")" "$n" \
                    "$(sha256sum < "$f" | cut -c1-12)"
                total=$(( total + 1 ))
            done <<< "$files"
            [[ "$total" -eq 0 ]] && echo "    (none)"
            echo ""
            local hs; hs="$(demo_registry_home_state)"
            if [[ "${hs%%|*}" == "home" ]]; then
                print_info "This host IS the registry home — packs belong here."
            else
                print_warning "This host is NOT the registry home ('${hs#*|}'). Packs here are strays."
                print_hint "  pl demo codes ${site} packs relocate --apply"
            fi
            return 0
            ;;
        relocate) ;;
        *)
            print_error "Unknown packs action '${action}' (inventory|relocate)"
            return 1 ;;
    esac

    # ---- relocate ----------------------------------------------------------
    local hs verdict home
    hs="$(demo_registry_home_state)"; verdict="${hs%%|*}"; home="${hs#*|}"
    case "$verdict" in
        home)
            print_error "REFUSED: this host is already the registry home ('${home}') — there is nothing to relocate."
            print_info  "Packs belong here. Run this on a host that still holds strays."
            return 1 ;;
        undeclared)
            print_error "CANNOT VERIFY: no registry home is declared (${home}) — refusing to move plaintext codes to a host nobody named."
            return 2 ;;
    esac

    local dest_ssh="${NWP_DEMO_PACK_HOME_SSH:-$(demo_registry_home_ssh)}"
    local dest_dir="${NWP_DEMO_PACK_HOME_DIR:-nwp/sites/${site}/demo-invites}"
    if [[ -z "$dest_ssh" ]]; then
        print_error "CANNOT VERIFY: no ssh endpoint is declared for the registry home '${home}'."
        print_info  "Add   registry_home_ssh: <user>@<addr>   to servers/live/demo/registry-home.yml"
        print_info  "(the home's address is a declared fact and lives in exactly that one file)."
        return 2
    fi

    local files rc=0
    files="$(demo_pack_files "$packdir" 2>&1)" || rc=$?
    if (( rc != 0 )); then
        print_info "No invite packs on this host — nothing to relocate."
        return 0
    fi
    [[ -n "${files//[[:space:]]/}" ]] || { print_info "No invite packs on this host — nothing to relocate."; return 0; }

    local ssh_opts=(-o BatchMode=yes -o ConnectTimeout=20)
    print_header "Relocate invite packs → registry home '${home}' (${dest_ssh}:${dest_dir})"
    [[ "$apply" == "true" ]] || print_warning "DRY RUN — nothing is copied or deleted. Re-run with --apply."

    local f base lsum rsum moved=0 skipped=0
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        base="$(basename "$f")"
        lsum="$(sha256sum < "$f" | awk '{print $1}')"
        rsum="$(ssh "${ssh_opts[@]}" "$dest_ssh" "sha256sum < '${dest_dir}/${base}' 2>/dev/null | awk '{print \$1}'" 2>/dev/null | tr -d '[:space:]')" || rsum=""
        if [[ -n "$rsum" && "$rsum" != "$lsum" ]]; then
            print_error "REFUSED: the home already has a DIFFERENT ${base} (local ${lsum:0:12}… vs home ${rsum:0:12}…)."
            print_info  "Neither copy is disposable — a pack is the only surviving plaintext of its codes."
            print_hint  "Rename one side, then re-run:  mv '${f}' '${f%.md}-from-$(demo_registry_local_host).md'"
            return 1
        fi
        if [[ "$rsum" == "$lsum" ]]; then
            printf '    %-34s already on the home (identical)\n' "$base"
            if [[ "$apply" == "true" ]]; then
                rm -f "$f"
                demo_log "$site" packs-relocated "file=${base} sha256=${lsum:0:12} verdict=already-present local-copy-removed"
                moved=$(( moved + 1 ))
            else
                skipped=$(( skipped + 1 ))
            fi
            continue
        fi
        printf '    %-34s → home  (sha256:%s…)\n' "$base" "${lsum:0:12}"
        if [[ "$apply" != "true" ]]; then skipped=$(( skipped + 1 )); continue; fi
        ssh "${ssh_opts[@]}" "$dest_ssh" "mkdir -p '${dest_dir}' && chmod 700 '${dest_dir}'" >/dev/null 2>&1 || {
            print_error "CANNOT VERIFY: could not prepare ${dest_dir} on the home — nothing was moved."
            return 2
        }
        rsync -a --chmod=F600 -e "ssh ${ssh_opts[*]}" "$f" "${dest_ssh}:${dest_dir}/" || {
            print_error "CANNOT VERIFY: rsync of ${base} to the home FAILED — the local copy is untouched."
            return 2
        }
        rsum="$(ssh "${ssh_opts[@]}" "$dest_ssh" "sha256sum < '${dest_dir}/${base}' 2>/dev/null | awk '{print \$1}'" 2>/dev/null | tr -d '[:space:]')" || rsum=""
        if [[ "$rsum" != "$lsum" ]]; then
            print_error "REFUSED to delete ${base}: the home's copy does not verify (${rsum:-<unreadable>} != ${lsum})."
            return 2
        fi
        rm -f "$f"
        demo_log "$site" packs-relocated "file=${base} sha256=${lsum:0:12} home=${home} verified local-copy-removed"
        moved=$(( moved + 1 ))
    done <<< "$files"

    echo ""
    if [[ "$apply" == "true" ]]; then
        print_status "OK" "Relocated ${moved} pack(s) to '${home}'; every one verified byte-identical before the local copy was removed."
        print_info "Their codes have now lived on two hosts — consider rotating any that are still live:"
        print_hint "  pl demo codes ${site} list --json   (on '${home}')"
    else
        print_status "OK" "DRY RUN: ${skipped} pack(s) would move. Re-run with --apply."
    fi
    return 0
}

################################################################################
# reconcile — fold diverged registry copies back into the ONE home (ops#328 D1)
#
# `pl demo codes <site> reconcile --from=<path>[,<path>…] [--apply] --tier=<t>`
#
# Runs ON THE HOME (the home guard in cmd_codes enforces it). Sources are
# LOCAL paths — fetch another host's copy first (scp to a scratch path); the
# verb then owns everything after the fetch: merge (union by hash,
# revoked-anywhere wins, live-enforced expiry adopted — demo_codes_merge),
# per-row provenance report, timestamped backups of EVERY input beside its
# source, atomic write of the merged home registry, the existing delivery
# sync, a re-stage of the box payload (live tier — without it tonight's reset
# restores the OLD set over the merge), and a DISCHARGE: re-read the enforced
# set and diff it against what was just written (ops#327 lesson — no
# note-and-hope). Dry-run by default, impact-manifest style.
################################################################################

# Push the home registry's active payload to the box's staged file — the copy
# the nightly reset treats as authoritative. Same payload renderer as the sync
# (demo_codes_payload); transport is the site's own ssh route.
demo_stage_codes_payload() {
    local site="$1" payload target n
    payload="$(demo_codes_payload "$(demo_codes_file "$site")")" || return 1
    target="$(demo_box_codes_payload "$site")"
    demo_live_ctx "$site" || return 1
    printf '%s' "$payload" | demo_rssh "$site" \
        "t=\$(mktemp) && cat > \"\$t\" && ${DEMO_LIVE_SUDO} install -o root -g root -m 0644 \"\$t\" '${target}' && rm -f \"\$t\"" \
        || return 1
    n="$(demo_payload_count "$payload")"
    demo_log "$site" codes-staged "count=${n:-?} target=${target}"
    return 0
}

cmd_codes_reconcile() {
    local site="$1" tier="$2"; shift 2
    local apply="false" a
    local -a srcs=()
    for a in "$@"; do
        case "$a" in
            --apply)  apply="true" ;;
            --from=*) local -a _f=()
                      IFS=',' read -r -a _f <<< "${a#--from=}"
                      srcs+=("${_f[@]}") ;;
            *) print_error "Unknown reconcile option '$a'"
               print_hint  "Usage: pl demo codes ${site} reconcile --from=<path>[,<path>…] [--apply] --tier=<t>"
               return 1 ;;
        esac
    done
    [[ ${#srcs[@]} -gt 0 ]] || {
        print_error "reconcile needs at least one --from=<path> — another host's copy of the registry, fetched to a local path."
        return 1
    }

    local cfile proj=""
    cfile="$(demo_codes_file "$site")"

    print_header "Invite-code reconcile: ${site} (${tier})$( [[ "$apply" == "true" ]] || echo ' — DRY RUN' )"

    # The live-enforced set: both a merge INPUT (un-revoked rows adopt its
    # expiry) and the discharge baseline. Unreadable → CANNOT VERIFY, because
    # "state from the live-enforced set" cannot be taken from a guess.
    local enforced=""
    if demo_is_live "$tier"; then
        enforced="$(demo_rdrush "$site" state:get nwc_demo_access.codes --format=string 2>/dev/null)" || enforced=""
    else
        if proj="$(demo_project_dir "$site" "$tier" 2>/dev/null)"; then
            enforced="$(demo_drush "$proj" state:get nwc_demo_access.codes --format=string 2>/dev/null)" || enforced=""
        fi
    fi
    if ! printf '%s' "$enforced" | jq -e '.codes | type == "array"' >/dev/null 2>&1; then
        print_error "CANNOT VERIFY: could not read the ${tier} enforced code set (state nwc_demo_access.codes)."
        print_info  "The merge takes each un-revoked row's state from the live-enforced set — refusing to substitute a guess."
        return 2
    fi

    # Labels: home + src1..srcN (legend below maps them back to paths).
    local -a pairs=()
    local i=1 s
    for s in "${srcs[@]}"; do pairs+=("src${i}=${s}"); i=$(( i + 1 )); done

    local doc rc=0
    doc="$(demo_codes_merge home "$cfile" "$enforced" "${pairs[@]}")" || rc=$?
    (( rc == 0 )) || return $rc

    # ---- report ----
    echo ""
    print_info "Inputs (every row from every copy is accounted for):"
    _rec_counts() {  # label path
        local c; c="$(jq -r --argjson now "$(date +%s)" \
            '[(.codes // [])[]] | "\(length) rows, \([.[]|select(.revoked==false and .expires > $now)]|length) active"' \
            "$2" 2>/dev/null || echo "unreadable")"
        printf '    %-6s %-52s %s\n' "$1" "$2" "$c"
    }
    _rec_counts "home" "$cfile"
    i=1
    for s in "${srcs[@]}"; do _rec_counts "src${i}" "$s"; i=$(( i + 1 )); done
    echo ""

    local total live_n rev_n exp_n
    total="$(jq -r '.report.counts.total'   <<< "$doc")"
    live_n="$(jq -r '.report.counts.live'   <<< "$doc")"
    rev_n="$(jq -r '.report.counts.revoked' <<< "$doc")"
    exp_n="$(jq -r '.report.counts.expired' <<< "$doc")"
    local added revprop
    added="$(jq -r '[.report.rows[] | select([.provenance[] | startswith("home:")] | any | not)] | length' <<< "$doc")"
    revprop="$(jq --slurpfile h <(jq -c '{codes:(.codes // [])}' "$cfile" 2>/dev/null || echo '{"codes":[]}') -r '
        [($h[0].codes // [])[] | select(.revoked == false) | .hash] as $homelive
        | [.merged.codes[] | select(.revoked and (.hash as $x | $homelive | index($x) != null))] | length' <<< "$doc")"

    print_info "Merged result: ${total} rows — ${live_n} live / ${rev_n} revoked / ${exp_n} expired  (${total} rows, showing ${total})"
    print_info "  new to the home registry: ${added}   revocations propagated INTO home rows: ${revprop}"
    echo ""
    printf '    %-5s %-28s %-8s %-12s %s\n' "id" "bundle" "state" "expires" "provenance"
    jq -r '.report.rows[] | [.id, .bundle, .state, (.expires | todate | .[0:10]), (.provenance | join(","))] | @tsv' <<< "$doc" \
        | while IFS=$'\t' read -r rid rb rs re rp; do
            printf '    %-5s %-28s %-8s %-12s %s\n' "$rid" "$rb" "$rs" "$re" "$rp"
        done
    echo ""

    # Enforced-set delta the apply will cause.
    local now_enforced merged_active to_add to_drop
    now_enforced="$(printf '%s' "$enforced" | jq -r '[.codes[].hash] | sort | .[]' 2>/dev/null)"
    merged_active="$(jq -r --argjson now "$(date +%s)" \
        '[.merged.codes[] | select(.revoked == false and .expires > $now) | .hash] | sort | .[]' <<< "$doc")"
    to_add="$(comm -13 <(printf '%s\n' "$now_enforced") <(printf '%s\n' "$merged_active") | grep -c . || true)"
    to_drop="$(comm -23 <(printf '%s\n' "$now_enforced") <(printf '%s\n' "$merged_active") | grep -c . || true)"
    print_info "Enforced set (${tier}) after apply: +${to_add} code(s), -${to_drop} code(s) vs what the site checks today."

    if [[ "$apply" != "true" ]]; then
        echo ""
        print_status "WARN" "DRY RUN — nothing was written, synced or staged."
        print_hint "Apply: pl demo codes ${site} reconcile $(printf -- '--from=%s ' "${srcs[@]}")--tier=${tier} --apply"
        return 0
    fi

    # ---- apply ----
    # Backups FIRST, every input, timestamped, beside its source (0600).
    local ts b
    ts="$(date -u '+%Y%m%dT%H%M%SZ')"
    for b in "$cfile" "${srcs[@]}"; do
        [[ -f "$b" ]] || continue
        ( umask 077; cp -p "$b" "${b}.pre-reconcile-${ts}" ) || {
            print_error "Could not back up ${b} — refusing to continue (nothing written)."
            return 1
        }
    done
    print_status "OK" "Backed up every input copy (*.pre-reconcile-${ts})"

    local tmp="${cfile}.tmp.$$"
    ( umask 077; jq '.merged' <<< "$doc" > "$tmp" ) && mv "$tmp" "$cfile" || { rm -f "$tmp"; return 1; }
    demo_log "$site" codes-reconciled \
        "tier=${tier} sources=${#srcs[@]} rows=${total} added=${added} revoked_propagated=${revprop} host=$(demo_registry_local_host)"
    print_status "OK" "Merged registry written: ${cfile} (${total} rows)"

    demo_sync_codes_to_site "$site" "$tier" || {
        print_error "Merged registry written but NOT synced to ${site} (${tier}) — the site still enforces the OLD set."
        return 1
    }
    if demo_is_live "$tier"; then
        demo_stage_codes_payload "$site" || {
            print_error "Synced, but the BOX payload was NOT re-staged — tonight's reset would restore the OLD set over this merge."
            print_hint  "Re-stage: bash servers/live/demo/install-box.sh ${site} --stage-codes --no-key"
            return 1
        }
        print_status "OK" "Box payload re-staged ($(demo_box_codes_payload "$site"))"
    fi

    # ---- discharge (ops#327): re-read the enforced set, diff against what we
    # just wrote. Execute → re-read → render the re-read state.
    local after=""
    if demo_is_live "$tier"; then
        after="$(demo_rdrush "$site" state:get nwc_demo_access.codes --format=string 2>/dev/null)" || after=""
    else
        after="$(demo_drush "$proj" state:get nwc_demo_access.codes --format=string 2>/dev/null)" || after=""
    fi
    local after_hashes
    after_hashes="$(printf '%s' "$after" | jq -r '[.codes[].hash] | sort | .[]' 2>/dev/null)"
    if [[ "$after_hashes" == "$merged_active" ]]; then
        print_status "OK" "DISCHARGED: re-read the ${tier} enforced set — it now matches the merged registry ($(printf '%s\n' "$merged_active" | grep -c . || true) active code(s))."
    else
        print_status "FAIL" "DISCHARGE FAILED: the re-read enforced set does NOT match the merged registry."
        print_info "enforced now: $(printf '%s' "$after" | jq -r '.codes | length' 2>/dev/null || echo '?') code(s); merged active: $(printf '%s\n' "$merged_active" | grep -c . || true)"
        return 1
    fi
    # Refresh the recorded three-number drift verdict while everything is warm.
    demo_drift_record_save "$site" "$tier"
    return 0
}

# `pl demo codes <site> drift [--tier=live]` — read the three numbers off the
# real sources, print them side by side, and leave the record `pl todo`/`pl rag`
# grade. Read-only: it writes nothing to any site or box.
cmd_codes_drift() {
    local site="$1" tier="$2"
    print_header "Invite-code drift: $site ($tier)"
    demo_drift_record_save "$site" "$tier"

    local f; f="$(demo_drift_file "$site")"
    local reg="$DEMO_DRIFT_REGISTRY" live="$DEMO_DRIFT_SITE" staged="$DEMO_DRIFT_STAGED"
    _fmt() { case "${1:-}" in -) echo "n/a" ;; ''|*[!0-9]*) echo "?" ;; *) echo "$1" ;; esac; }
    echo ""
    local _hs; _hs="$(demo_registry_home_state)"
    if [[ "$_hs" == not-home\|* ]]; then
        printf '    %-18s %-6s %s\n' "registry-active" "n/a" \
            "this host is not the registry home — the writable registry lives on '${_hs#*|}' (ops#328 D1)"
    else
        printf '    %-18s %-6s %s\n' "registry-active" "$(_fmt "$reg")"    "$(demo_codes_file "$site")"
    fi
    printf '    %-18s %-6s %s\n' "site-live"       "$(_fmt "$live")"   "state nwc_demo_access.codes — what a code is checked against TODAY"
    printf '    %-18s %-6s %s\n' "staged-payload"  "$(_fmt "$staged")" "$(demo_box_codes_payload "$site") — what the 01:00 reset restores TOMORROW"
    echo ""

    local verdict detail
    verdict="$(demo_drift_state "$reg" "$live" "$staged")"
    detail="${verdict#*|}"; verdict="${verdict%%|*}"
    case "$verdict" in
        ok)      print_status "OK"   "All three agree ($detail)" ;;
        drift)   print_status "FAIL" "DRIFT — these must agree: $detail"
                 print_hint "  pl demo codes $site sync --tier=$tier                        # registry → site"
                 print_hint "  bash servers/live/demo/install-box.sh $site --stage-codes    # registry → box" ;;
        *)       print_status "WARN" "Could not read every number: $detail"
                 print_hint "A number this host cannot read is NOT zero — see 'why' above." ;;
    esac
    print_info "Recorded: $f (graded by pl todo / pl rag)"
    unset -f _fmt
    [[ "$verdict" == "drift" ]] && return 1
    return 0
}

################################################################################
# invite — copy-ready invitation email with one fresh code per level
################################################################################

# Default invite levels (decisions §4.4). The two reviewer bundles are
# opt-in (--all / --bundles=…): reviewer queues are a narrower ask and the
# operator usually recruits for them separately.
DEMO_INVITE_DEFAULT_BUNDLES=(tester-member tester-guild-leader tester-content-manager)

################################################################################
# TIER MUST BE NAMED for anything that writes or syncs codes.
#
# main() defaults --tier to `dev`, which is right for the read-only verbs and
# wrong — silently — for the code verbs. `pl demo invite nwd`, the command
# printed verbatim in howto-invite-codes.md, howto-demo-tier.md and the Art.9
# runbook, issued three fresh codes and then pushed the hashes into the LOCAL
# nwd-dev DDEV project. nwd LIVE never received them, and the operator was
# shown a success either way. The registry bears it out: 19 codes issued, all
# 19 revoked, not one that a live tester could ever have redeemed.
#
# Flipping the default to `live` would be the same defect aimed at a real host,
# so the tier is simply REQUIRED here. The guard runs before any code is
# generated: a refusal that had already burned a code id (or, worse, printed a
# plaintext code) would be a worse outcome than the bug.
################################################################################

# Set by main() when the operator actually wrote --tier=… on the command line.
DEMO_TIER_EXPLICIT="false"

# Set by main() on --json. Read by the verbs that offer a machine-readable
# contract (codes list, seal-status — ops#328). Parsed centrally so it can
# never fall into the ops#225 stray-positional refusal.
DEMO_JSON="false"

# $1 label for the message   $2 a copy-pasteable corrected example
demo_require_explicit_tier() {
    local label="$1" example="$2"
    [[ "$DEMO_TIER_EXPLICIT" == "true" ]] && return 0
    print_error "REFUSED: '$label' writes invite codes into a running site, so it must name the tier."
    print_info  "  --tier=live   the public demo site — what an invitation is normally for"
    print_info  "  --tier=dev    the local DDEV project"
    print_hint  "Nothing was issued, revoked or synced. Re-run naming the tier, e.g.:"
    print_hint  "  ${example}"
    return 1
}

cmd_invite() {
    local site="$1" tier="$2"; shift 2 || true
    # FIRST, before the option parse and long before a code is generated: an
    # invitation whose codes landed on the wrong tier is an invitation to a
    # site that will reject every one of its recipients.
    demo_require_explicit_tier invite "pl demo invite ${site} --tier=live" || return 1
    demo_require_jq || return 1
    # SECOND: invite MINTS codes, so it is a registry write — it must be on
    # the registry's declared home (ops#328 D1). Identity before transport.
    local _rc=0
    demo_require_registry_home "$site" invite || { _rc=$?; return $_rc; }
    # THIRD, still before the option parse: naming the right tier is not the
    # same as being able to REACH it. The console host named --tier=live
    # correctly every time and still could not deliver a single code (ops#173).
    demo_require_delivery "$site" "$tier" invite || return 1

    # ---- invite-specific options (arrive via passthru) ----
    local bundles_csv="" expiry="14d" all="false" a
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --bundles=*) bundles_csv="${1#--bundles=}"; shift ;;
            --bundles)   [[ $# -ge 2 ]] || { print_error "--bundles needs a value"; return 1; }
                         bundles_csv="$2"; shift 2 ;;
            --expiry=*|--expires=*) expiry="${1#*=}"; shift ;;
            --expiry|--expires)     [[ $# -ge 2 ]] || { print_error "--expiry needs a value"; return 1; }
                         expiry="$2"; shift 2 ;;
            --all)       all="true"; shift ;;
            *) print_error "Unknown invite option '$1'"; return 1 ;;
        esac
    done

    # ---- resolve the bundle list (fail-closed on unknown names) ----
    local bundles=()
    if [[ -n "$bundles_csv" ]]; then
        IFS=',' read -r -a bundles <<< "$bundles_csv"
        local b
        for b in "${bundles[@]}"; do
            demo_bundle_valid "$b" || {
                print_error "Unknown bundle '$b'. Valid: ${DEMO_BUNDLES[*]}"
                return 1
            }
        done
    elif [[ "$all" == "true" ]]; then
        bundles=("${DEMO_BUNDLES[@]}")
    else
        bundles=("${DEMO_INVITE_DEFAULT_BUNDLES[@]}")
    fi

    local secs expiry_days
    secs="$(demo_parse_duration "$expiry")" || {
        print_error "Bad --expiry duration '$expiry' (use e.g. 14d)"
        return 1
    }
    expiry_days=$(( (secs + 86399) / 86400 ))

    # ---- issue ONE fresh code per bundle (hashed at rest; plaintext lives
    #      only in this process and the 0600 draft) ----
    local cfile pairs=() code hash id expires
    cfile="$(demo_codes_file "$site")"
    expires=$(( $(date +%s) + secs ))
    local b
    for b in "${bundles[@]}"; do
        code="$(demo_generate_code)" || { print_error "Code generation failed"; return 1; }
        hash="$(demo_hash_code "$code")"
        id="$(demo_next_code_id "$cfile")"
        demo_code_add "$cfile" "$id" "$b" "$hash" "$expires" || return 1
        demo_log "$site" codes-issued "id=$id bundle=$b expires_in=$expiry invite"
        pairs+=("${b}=${code}")
    done

    # ---- render the draft: stdout + 0600 file (it holds plaintext codes) ----
    # The email resolves its pair-contract facts (courses URL, SSO button
    # label) for THIS site — not for the library default.
    DEMO_INVITE_PROVIDER_SITE="${DEMO_INVITE_PROVIDER_SITE:-$site}"
    local join_url invite_dir invite_file draft
    join_url="$(demo_invite_join_url "$site")"
    invite_dir="$(demo_site_dir "$site")/demo-invites"
    invite_file="${invite_dir}/invite-$(date -u '+%Y%m%d-%H%M%S').md"
    # Never clobber an earlier draft (its plaintext codes exist nowhere else).
    local n=2
    while [[ -e "$invite_file" ]]; do
        invite_file="${invite_dir}/invite-$(date -u '+%Y%m%d-%H%M%S')-${n}.md"
        n=$(( n + 1 ))
    done
    draft="$(demo_invite_email "$join_url" "$expiry_days" "${pairs[@]}")"

    ( umask 077; mkdir -p "$invite_dir" && printf '%s\n' "$draft" > "$invite_file" ) || {
        print_error "Could not write draft to $invite_file"
        return 1
    }

    print_header "Invitation draft — $site (${#bundles[@]} level(s), codes expire in ${expiry_days}d)"
    echo ""
    printf '%s\n' "$draft"
    echo ""
    print_status "OK" "Draft saved: $invite_file (mode 0600 — it contains PLAINTEXT codes)"
    print_info "Delete any level blocks the recipient shouldn't get, then paste into your mail client."
    print_info "Distribute to INVITED helpers only (decisions §4.2 — never post publicly)."
    if [[ "$join_url" == "<YOUR-SITE-URL>"* ]]; then
        print_warning "No live.domain in sites/$site/.nwp.yml — replace the <YOUR-SITE-URL> placeholder before sending."
    fi
    print_hint "Consider deleting the draft file after sending (the registry keeps only hashes)."

    # Push the new hashes into the running site. Non-fatal to the DRAFT (which is
    # already saved), but the operator MUST know if the code never reached the
    # site — otherwise they hand out a code that rejects every recipient.
    if demo_sync_codes_to_site "$site" "$tier"; then
        if demo_is_live "$tier"; then
            # DUAL SOURCE OF TRUTH (demo-pilot audit A4-B3): the live sync writes
            # Drupal state NOW, but the nightly box reset overwrites that state
            # from its own staged payload. A freshly-issued code works today and
            # then STOPS at the next 01:00 reset unless the box payload is
            # re-staged. Make that explicit rather than let it fail silently.
            print_warning "Code is live NOW, but the nightly reset restores the box's staged payload."
            print_hint "To survive tonight's reset, re-stage on the box: servers/live/demo/install-box.sh --stage-codes"
        fi
    else
        print_error "Codes were NOT synced to $site ($tier) — recipients would be REJECTED. The draft is saved, but do not send until the sync succeeds:"
        print_hint "  pl demo codes $site sync --tier=$tier"
    fi
}

################################################################################
# harvest-post — drain the pre-wipe harvest spool into nwp/ops issues
#
# The nightly reset destroys watchdog, so demo_harvest writes a digest to
# sites/<site>/demo-harvest/ BEFORE the wipe. This drains that spool into
# GitLab issues using the least-privilege gitlab.ops_note_token (lib/gitlab-
# issues.sh) — never the root PAT, and the token value is never printed or
# placed in argv.
#
# Retry-safe: a digest is only moved to demo-harvest/posted/ after GitLab
# confirms an iid. A failed post leaves the file in the spool for next time,
# and `pl demo status` reports the backlog.
################################################################################

DEMO_HARVEST_LABELS="demo-tester,auto-harvest"

################################################################################
# feedback-sync — push pending tester Feedback entities to GitLab (ops#161)
#
# The same function the reset calls pre-wipe, exposed as a verb so it can be
# scheduled, or run by hand after a `feedback-sync-refused` / `-skipped` line
# shows up in sites/<site>/demo-reset.log. Unlike the hook, a verb owes the
# caller an exit status, so this one reads $DEMO_FEEDBACK_STATUS and fails on
# refused/skipped/failed. The hook itself still always returns 0.
################################################################################

cmd_feedback_sync() {
    local site="$1" tier="${2:-dev}" dry_run="${3:-false}"

    print_header "Tester feedback → GitLab: ${site} (${tier})"

    if [[ "$(demo_kind_of "$site")" != "drupal" ]]; then
        print_info "'${site}' is not a Drupal site — it has no Feedback entities."
        print_hint  "The Moodle half forwards each report at submit time (local_feedback), so it has no pending set."
        return 0
    fi

    local -a run=()
    if demo_is_live "$tier"; then
        demo_live_ctx "$site" || return 1
        run=( demo_rdrush "$site" )
    else
        local proj; proj="$(demo_project_dir "$site" "$tier")" || return 1
        run=( demo_drush "$proj" )
    fi

    DEMO_FEEDBACK_DRY_RUN="$dry_run" demo_feedback_sync "$site" "$tier" "${run[@]}"

    case "$DEMO_FEEDBACK_STATUS" in
        ok)
            if [[ "$dry_run" == "true" ]]; then
                print_status "OK" "[dry-run] feedback IS pending and the deployed payload is minimised — a real run would push it."
            else
                print_status "OK" "Pending feedback synced (see sites/${site}/demo-reset.log)"
            fi
            return 0 ;;
        empty)
            print_status "OK" "Nothing pending — no token was read and nothing was sent."
            return 0 ;;
        refused)
            print_status "FAIL" "REFUSED: the deployed nwc_feedback on '${site}' does not provably carry the ops#140 minimisation."
            print_info   "A payload that still names the submitter would copy member identity into GitLab, which has a wider reader set and appears in no RoPA."
            print_hint   "Deploy nwc main (MR nwp/nwc!50 or later) to ${site}, then re-run. Nothing was sent."
            return 1 ;;
        skipped)
            print_status "FAIL" "No usable feedback-sync token in .secrets.yml (see demo_feedback_token in lib/demo.sh). Nothing was sent."
            return 1 ;;
        *)
            print_status "FAIL" "Sync did not complete — see sites/${site}/demo-reset.log."
            return 1 ;;
    esac
}

cmd_harvest_post() {
    local site="$1" dry_run="${2:-false}"
    local hdir; hdir="$(demo_harvest_dir "$site")"

    print_header "Demo harvest → nwp/ops: $site"

    if [[ ! -d "$hdir" ]]; then
        print_info "No harvest spool at $hdir — nothing to post."
        return 0
    fi
    local -a spooled=()
    while IFS= read -r f; do [[ -n "$f" ]] && spooled+=("$f"); done \
        < <(find "$hdir" -maxdepth 1 -name 'harvest-*.md' -type f 2>/dev/null | sort)
    if (( ${#spooled[@]} == 0 )); then
        print_info "Harvest spool is empty — nothing to post."
        return 0
    fi

    # ops#233: TRIAGED is a terminal state, and the poster must honour it.
    # posted/ and triaged-*/ used to be mutually blind — the 2026-08-01
    # hand-triage was followed hours later by a harvest-post that re-filed the
    # SAME already-mined digests as five fresh issues (ops#189–193). A digest
    # whose basename sits under any triaged-*/ dir is skipped, never re-posted.
    local -a postable=() skipped_triaged=()
    local f b
    for f in "${spooled[@]}"; do
        b="$(basename "$f")"
        if compgen -G "$hdir/triaged-*/$b" >/dev/null 2>&1; then
            skipped_triaged+=("$b")
        else
            postable+=("$f")
        fi
    done
    print_info "${#postable[@]} digest(s) queued (${#skipped_triaged[@]} already-triaged skipped)."

    if [[ "$dry_run" == "true" ]]; then
        for b in "${skipped_triaged[@]}"; do
            echo "  would skip: ${b} (already under triaged-*/)"
        done
        for f in "${postable[@]}"; do
            echo "  would post: $(basename "$f") → nwp/ops issue (labels: ${DEMO_HARVEST_LABELS})"
        done
        print_status "OK" "[dry-run] nothing posted, spool untouched."
        return 0
    fi

    for b in "${skipped_triaged[@]}"; do
        print_status "WARN" "skip ${b} — already under triaged-*/ (re-posting would double-file it; see pl demo harvest-triage ${site})"
        demo_log "$site" harvest-post-skip-triaged "file=${b}"
    done
    if (( ${#postable[@]} == 0 )); then
        print_info "Nothing to post — every spooled digest is already triaged."
        return 0
    fi

    # Lazy-source: only harvest-post needs yq + a token, so `pl demo golden`
    # keeps working on a host with neither.
    # shellcheck source=../../lib/gitlab-issues.sh
    source "$REPO_ROOT/lib/gitlab-issues.sh" || {
        print_error "Could not load lib/gitlab-issues.sh"
        return 1
    }

    mkdir -p "$hdir/posted"
    local posted=0 failed=0
    for f in "${postable[@]}"; do
        local when title body payload resp iid
        when="$(awk -F': ' '/^harvested_utc:/ {print $2; exit}' "$f" 2>/dev/null)"
        [[ -n "$when" ]] || when="$(basename "$f" .md)"
        title="Demo harvest — ${site}: errors before the ${when} reset"
        body="$(cat "$f")"
        payload="$(jq -nc --arg t "$title" --arg d "$body" --arg l "$DEMO_HARVEST_LABELS" \
            '{title:$t, description:$d, labels:$l}')" || {
            print_status "FAIL" "$(basename "$f") — could not build payload"
            failed=$(( failed + 1 )); continue
        }
        resp="$(_api_send POST "/projects/${PROJECT_ID}/issues" "$payload" 2>/dev/null)" || resp=""
        iid="$(printf '%s' "$resp" | _jget 'iid')"
        if [[ -n "$iid" ]]; then
            mv "$f" "$hdir/posted/$(basename "$f")"
            demo_log "$site" harvest-posted "file=$(basename "$f") issue=#${iid}"
            print_status "OK" "$(basename "$f") → nwp/ops#${iid}"
            posted=$(( posted + 1 ))
        else
            demo_log "$site" harvest-post-failed "file=$(basename "$f")"
            print_status "FAIL" "$(basename "$f") — not posted (left in the spool for retry)"
            failed=$(( failed + 1 ))
        fi
    done

    echo ""
    print_info "Posted: ${posted}   Failed: ${failed}   (posted digests moved to ${hdir}/posted/)"
    (( failed == 0 ))
}

################################################################################
# schedule — nightly cron on THIS machine (intended host: met)
################################################################################

# The restricted forced-command path (ops#133 / Option A): the scheduler host
# holds only ~/.ssh/<site>_demo_reset, whose authorized_keys entry pins
# command="/usr/local/bin/nwd-demo-reset-restricted". It can invoke the reset
# and nothing else — no shell, no sudo, no scp, no forwarding.
#
# IdentitiesOnly=yes AND IdentityAgent=none are LOAD-BEARING: without them ssh
# offers an agent-held admin key first and lands on the UNRESTRICTED gitlab
# entry instead of the forced command (found the hard way — see the guide).
DEMO_KEY_PATH="${DEMO_KEY_PATH:-\$HOME/.ssh/<site>_demo_reset}"

# demo_schedule_key_cmd <site> [<[user@]host-override>] → the ssh invocation
# the cron line will run.
#
# Host and user normally come from sites/<site>/.nwp.yml (live.server_ip →
# live.domain, get_ssh_user), never from a hardcoded hostname.
#
# THE OVERRIDE EXISTS BECAUSE THE VERB COULD NOT RUN WHERE IT IS MEANT TO RUN
# (nwp/ops#171). `--via-key`'s whole point is that the SCHEDULER needs no site
# config: the cron line is self-contained and the box-side forced command does
# the rest. But resolving the box's address through get_site_config_value made
# the verb depend on exactly the `sites/<site>/.nwp.yml` the scheduler is
# designed not to have — so on met it failed with "No live.server_ip", and the
# one verb that installs the repo-free cron was the one thing that could not run
# on the repo-free host. Both nightly blocks (nwd and ssd) had to be generated
# on the workstation against a stub crontab and installed by hand, which nearly
# became a live regression: met's checkout predated MR !262, so a re-run there
# would have installed the cron line WITHOUT `-F /dev/null` — the exact
# admin-key hijack that MR had just fixed.
#
# The override takes `host` or `user@host`. It is honoured ahead of every config
# lookup, because someone who names the box explicitly is not asking to be
# second-guessed by whatever a stale local checkout happens to think.
#
# SPLIT INTO THREE (nwp/ops#156/#161). The endpoint resolution, the argv and the
# joined string used to be one function whose only consumer was the cron line.
# `pl demo nightly --via-key` now EXECUTES the same transport, and a scheduler
# that runs a different command from the one the verb installed is a scheduler
# nobody can reason about. So there is exactly one place that decides what ssh
# invocation reaches the box, and both the installer and the runner read it.
demo_box_endpoint() {
    local site="$1" override="${2:-${NWP_DEMO_BOX_HOST:-}}"
    local host="" user="" server_name=""
    if [[ -n "$override" ]]; then
        # `user@host` splits; a bare host keeps the config-derived user.
        if [[ "$override" == *"@"* ]]; then
            user="${override%@*}"
            host="${override##*@}"
        else
            host="$override"
        fi
        # print_error already goes to stderr; nothing may reach stdout here
        # because stdout is the returned ssh command (see the refusal below).
        [[ -n "$host" ]] || { print_error "--host '${override}' has no hostname part"; return 1; }
    else
        # Same resolution order as demo_live_ctx: named server → server_ip → domain.
        server_name="$(get_site_config_value "$site" '.live.server' "")"
        if [[ -n "$server_name" ]] && declare -F get_server_config >/dev/null 2>&1; then
            host="$(get_server_config "$server_name" "ip" "" 2>/dev/null)"
        fi
        [[ -z "$host" ]] && host="$(get_site_config_value "$site" '.live.server_ip' "")"
        [[ -z "$host" ]] && host="$(get_site_config_value "$site" '.live.domain' "")"
        [[ -n "$host" ]] || {
            # >&2 is LOAD-BEARING: this function's stdout IS the ssh command the
            # caller captures with $( ). print_hint writes to stdout, so an
            # un-redirected hint would be swallowed into the command string and
            # the operator would be told nothing — which is how a "cannot
            # schedule" message ended up naming no way out.
            print_error "No live.server_ip / live.domain for '$site' — cannot schedule --via-key"
            print_hint "On a host with no sites/ config (met): pass --host <ip> or --host <user>@<ip>, or set NWP_DEMO_BOX_HOST." >&2
            return 1
        }
    fi
    [[ -n "$user" ]] || user="$(get_ssh_user "$site")"
    printf '%s@%s' "$user" "$host"
}

# demo_box_ssh_args <site> [<[user@]host-override>] → the ssh invocation, ONE
# ARGUMENT PER LINE, so the runner can exec it as an argv array instead of
# re-splitting a string it did not build.
#
# -F /dev/null: IdentitiesOnly + IdentityAgent=none block the AGENT, but an
# `IdentityFile` in ~/.ssh/config for this host is still offered — and on a
# workstation that file usually names the ADMIN key. When that wins, the forced
# command never applies and the wrapper is bypassed entirely: the action word
# lands in a login shell instead ("status: command not found"), so the nightly
# silently stops resetting while cron reports success. Reading no config at all
# is the only way to guarantee this key, and only this key, is what
# authenticates. known_hosts still applies (it is not a config-file setting), so
# host verification is unaffected.
#
# The key path deliberately keeps the LITERAL `$HOME` that DEMO_KEY_PATH carries:
# a crontab line is run by sh and expands it, and the runner expands it itself
# (demo_nightly_via_key). One string, two correct readings — not two strings.
demo_box_ssh_args() {
    local site="$1" override="${2:-}"
    local endpoint key
    endpoint="$(demo_box_endpoint "$site" "$override")" || return 1
    key="${DEMO_KEY_PATH//<site>/$site}"
    printf '%s\n' ssh -F /dev/null -i "$key" \
        -o IdentitiesOnly=yes -o IdentityAgent=none \
        -o BatchMode=yes -o ConnectTimeout=30 "$endpoint"
}

# demo_schedule_key_cmd <site> [<[user@]host-override>] → the same invocation as
# a single space-joined string, for the `--via-key --raw-ssh` cron line.
demo_schedule_key_cmd() {
    local -a a=()
    mapfile -t a < <(demo_box_ssh_args "$1" "${2:-${NWP_DEMO_BOX_HOST:-}}")
    # mapfile's status is its own, not the producer's — an empty array IS the
    # failure signal, and treating it as anything else would emit a truncated
    # ssh command into a crontab.
    (( ${#a[@]} > 0 )) || return 1
    printf '%s' "${a[*]}"
}

cmd_schedule() {
    local site="$1" remove="$2" tier="${3:-dev}" via_key="${4:-false}"
    local host_override="${5:-}" print_only="${6:-false}" raw_ssh="${7:-false}"
    local fb_status="${8:-false}"
    # `pl demo schedule --help` parsed the FLAG as a site name and cheerfully
    # installed a nightly cron for a site called "--help". A scheduler that
    # accepts a name no site could ever have is writing a job that can only
    # fail, nightly, into a crontab nobody re-reads.
    if [[ -z "$site" || "$site" == -* ]]; then
        print_error "Usage: pl demo schedule <site> [--tier=live] [--via-key] [--host <[user@]ip>] [--print-only] [--remove]"
        [[ "$site" == -* ]] && print_hint "'$site' looks like an option, not a site name."
        return 2
    fi
    # --print-only EMITS a block; --remove DELETES one. Together they are a
    # request with no meaning, and the dangerous reading ("print what I would
    # remove") is not the one the code would take — it would remove for real.
    if [[ "$print_only" == "true" && "$remove" == "true" ]]; then
        print_error "REFUSED: --print-only and --remove are contradictory."
        print_hint "To see what --remove would drop: crontab -l | grep -A2 'NWP Demo Reset - ${site}'"
        return 2
    fi

    # ops#219 Phase A — the HOURLY return leg. Its own marker, its own block:
    # the nightly and the return leg are installed and removed independently.
    if [[ "$fb_status" == "true" ]]; then
        # The leg runs ON the box (that is where the walled token lives), so
        # the only transport is the restricted key. Without --via-key there is
        # nothing this flag could install that would actually run.
        if [[ "$via_key" != "true" && "$remove" != "true" ]]; then
            print_error "REFUSED: --feedback-status is a restricted-key line — the return leg runs ON the box, where the walled token lives. Pass --via-key."
            print_hint "pl demo schedule ${site} --feedback-status --via-key [--host <[user@]ip>]"
            return 2
        fi
        # The consumer half has no return leg: Moodle's local_feedback forwards
        # at submit time, and /my/feedback is an nwc_feedback (Drupal) surface.
        # The box wrapper refuses the word too; refusing here keeps a cron line
        # that can only ever fail out of anyone's crontab.
        if declare -F demo_pair_resolve >/dev/null 2>&1 && demo_pair_resolve "$site" 2>/dev/null \
           && [[ "$site" == "${DEMO_PAIR_CONSUMER:-}" ]]; then
            print_error "REFUSED: ${site} is the consumer half of ${DEMO_PAIR_LABEL:-its pair} — Moodle forwards feedback at submit time; there is no pending set and no return leg to schedule."
            return 2
        fi
    fi

    local marker="# NWP Demo Reset - $site"
    [[ "$fb_status" == "true" ]] && marker="# NWP Demo Feedback Status - $site"
    local current="" cleaned=""
    # --print-only does not touch a crontab AT ALL — not even to read one. That
    # is the point of it (nwp/ops#171): the block gets generated on whatever
    # machine has the site config and is installed on the machine that is
    # actually the scheduler, so reading THIS machine's crontab here would be
    # reading the wrong one and inviting the block to be trimmed against it.
    if [[ "$print_only" != "true" ]]; then
        current="$(crontab -l 2>/dev/null || true)"
        # Drop any existing entry (idempotent install / clean removal). The install
        # writes a 3-line block (marker, CRON_TZ, command) — remove the whole block
        # by marker, plus any stray command line as belt-and-braces (either flavour).
        #
        # BOTH belts are feedback-status-aware (ops#219): the return-leg line
        # carries the same restricted key path as the nightly, so a blind
        # `grep -v <site>_demo_reset` here would silently delete the hourly leg
        # every time the reset block was (re)installed or removed.
        if [[ "$fb_status" == "true" ]]; then
            cleaned="$(printf '%s\n' "$current" \
                | awk -v m="$marker" 'index($0, m) == 1 { skip = 3 } skip > 0 { skip--; next } { print }' \
                | awk -v k="${site}_demo_reset" '!(index($0, k) && / feedback-status/)' || true)"
        else
            cleaned="$(printf '%s\n' "$current" \
                | awk -v m="$marker" 'index($0, m) == 1 { skip = 3 } skip > 0 { skip--; next } { print }' \
                | grep -v "pl demo nightly $site\b" \
                | awk -v k="${site}_demo_reset" '!(index($0, k) && !/ feedback-status/)' || true)"
        fi
    fi

    if [[ "$remove" == "true" ]]; then
        printf '%s\n' "$cleaned" | crontab -
        if [[ "$fb_status" == "true" ]]; then
            print_status "OK" "Removed the hourly feedback-status cron for $site (if present)"
        else
            print_status "OK" "Removed demo-reset cron for $site (if present)"
        fi
        return 0
    fi

    # No logs/ dir is created under --print-only: this machine is not the one
    # that will run the job, so creating it here would be creating it in the
    # wrong place while implying the right one exists.
    [[ "$print_only" == "true" ]] || mkdir -p "$PROJECT_ROOT/logs"
    local log="${PROJECT_ROOT}/logs/demo-nightly-${site}.log"
    local entry

    # WHICH MINUTES. Both halves of a demo pair now live on the SAME box, and a
    # restore is the heaviest thing that box does. Firing them on the same
    # minute means two simultaneous drop-and-reload cycles on a 3.8 GB host, and
    # it maximises the window in which one half is back at its golden while the
    # other is not — the window in which an SSO identity points at an account
    # the other side no longer has. So the CONSUMER half is offset by 15
    # minutes: same 01:00–03:30 window, same 30-minute retry cadence, just never
    # the same minute. Derived, not flagged, because a collision-avoidance
    # measure an operator has to remember to pass is one they will forget.
    local minutes="0,30" pair_note=""
    if declare -F demo_pair_resolve >/dev/null 2>&1 && demo_pair_resolve "$site" 2>/dev/null; then
        if [[ "$site" == "$DEMO_PAIR_CONSUMER" ]]; then
            minutes="15,45"
            pair_note=" (consumer half of ${DEMO_PAIR_LABEL} — offset 15 min from ${DEMO_PAIR_PROVIDER})"
        fi
    fi

    if [[ "$fb_status" == "true" ]]; then
        # ops#219 Phase A — the HOURLY return leg, as a raw restricted-key line:
        # the box does the whole job (token, drush, redaction, logging), so the
        # scheduler stays a dumb clock and needs no checkout for this line.
        # Minute 7, deliberately off the nightly's 0/15/30/45 grid — the return
        # leg is cheap and read-mostly, but the box is small.
        local sshcmd
        sshcmd="$(demo_schedule_key_cmd "$site" "$host_override")" || return 1
        log="${PROJECT_ROOT}/logs/demo-feedback-status-${site}.log"
        entry="CRON_TZ=${DEMO_TZ}
7 * * * * ${sshcmd} feedback-status >> ${log} 2>&1"
    elif [[ "$via_key" == "true" && "$raw_ssh" == "true" ]]; then
        # RAW flavour — the pre-ops#156 line, kept for a scheduler that has the
        # restricted key and NO checkout. It resets and nothing else: no
        # pre-wipe feedback sync, no harvest drain. Explicit, because a
        # scheduler silently doing less than the operator thinks is how
        # ops#161's loss went unnoticed in the first place.
        local sshcmd
        sshcmd="$(demo_schedule_key_cmd "$site" "$host_override")" || return 1
        entry="CRON_TZ=${DEMO_TZ}
${minutes} 1-3 * * * ${sshcmd} nightly >> ${log} 2>&1"
    elif [[ "$via_key" == "true" ]]; then
        # Restricted-key flavour, DRIVEN BY pl (ops#156 / operator ruling D15).
        # The transport is identical — same key, same options, same action word,
        # same idempotent box wrapper — but the invocation goes through
        # `pl demo nightly --via-key`, so the pre-wipe feedback sync and the
        # post-reset harvest drain have somewhere to live. The retry loop still
        # lives in CRON, not in a 3-hour ssh session: the wrapper is idempotent
        # (one reset per Melbourne day) and returns 3 while sessions are active,
        # so firing every 30 min from 01:00 to 03:30 gives the same "retry to
        # the 04:00 floor" semantics without holding a connection open on a
        # small host.
        #
        # The endpoint is BAKED INTO THE LINE rather than resolved at run time,
        # so the job does not start depending on site config the scheduler was
        # deliberately never given.
        local endpoint
        endpoint="$(demo_box_endpoint "$site" "$host_override")" || return 1
        entry="CRON_TZ=${DEMO_TZ}
${minutes} 1-3 * * * ${PROJECT_ROOT}/pl demo nightly ${site} --tier=live --via-key --host ${endpoint} >> ${log} 2>&1"
    else
        # CRON_TZ pins the fire time to Melbourne regardless of host TZ (handles
        # DST; supported by ISC/vixie cron on Ubuntu 22.04+). The retry semantics
        # (every 30 min to a 04:00 floor) live in `pl demo nightly`, keeping cron
        # itself a single dumb line.
        entry="CRON_TZ=${DEMO_TZ}
0 1 * * * ${PROJECT_ROOT}/pl demo nightly ${site} --tier=${tier} >> ${log} 2>&1"
    fi

    # The marker line stays a PREFIX (the removal awk matches index==1), so the
    # suffix is free for provenance — which matters because the laptop copy is
    # interim and someone has to know to delete it when met takes over.
    local marker_line="$marker"
    [[ "$via_key" == "true" ]] && marker_line="${marker} (restricted key; see docs/guides/demo-nightly-on-met.md)"
    [[ "$fb_status" == "true" ]] && marker_line="${marker} (restricted key; hourly return leg — nwp/ops#219)"

    # BYTE-IDENTITY BY CONSTRUCTION. Both paths render the same two variables in
    # the same order, so what --print-only emits is exactly the block the
    # install path appends — never a second rendering that can drift from it.
    # An operator pasting this into met's crontab is running the tested path,
    # not reproducing it by hand, which is the whole ask of ops#171.
    if [[ "$print_only" == "true" ]]; then
        printf '%s\n%s\n' "$marker_line" "$entry"
        # Everything else goes to STDERR so `… --print-only > block.txt` and
        # `… --print-only | ssh met 'cat >> …'` stay clean.
        {
            print_info "--print-only: nothing was written to any crontab."
            print_hint "Install on the scheduler (met): crontab -l > /tmp/c; cat block >> /tmp/c; crontab /tmp/c"
            if [[ "$fb_status" == "true" ]] || [[ "$via_key" == "true" && "$raw_ssh" == "true" ]]; then
                # The repo-free flavour still names a log path, and it is this
                # machine's. On met the checkout lives elsewhere and cron would
                # silently write nowhere useful.
                print_info "Log path in the block is ${log} — confirm it exists on the target, or edit the block's '>>' path."
            else
                # Every other flavour hard-codes THIS machine's checkout path.
                print_status "WARN" "This block runs ${PROJECT_ROOT}/pl — that path must exist on the TARGET machine, not just this one."
                [[ "$via_key" == "true" ]] && print_status "WARN" "The target's checkout must be new enough to know 'pl demo nightly --via-key' (nwp/ops#156). An older pl ignores the flag and attempts a FULL LIVE RESET it cannot do."
            fi
        } >&2
        return 0
    fi

    printf '%s\n%s\n%s\n' "$cleaned" "$marker_line" "$entry" | crontab -
    if [[ "$fb_status" == "true" ]]; then
        print_status "OK" "Installed the HOURLY feedback return leg for $site via the RESTRICTED key (minute 7, ${DEMO_TZ})"
        print_info "The box runs the module's own nwc-feedback:sync-status with its walled token — reporters' /my/feedback advances within the hour."
        print_info "Until /etc/nwp-demo/feedback.token is staged on the box, each run answers exit 2 CANNOT VERIFY (visible in ${log})."
        print_hint "Verify: crontab -l | grep -A2 'NWP Demo Feedback Status'"
        return 0
    fi
    if [[ "$via_key" == "true" ]]; then
        print_status "OK" "Installed nightly demo reset for $site via the RESTRICTED key (01:00–03:30 ${DEMO_TZ}, minutes ${minutes}, ${DEMO_FLOOR_TIME} floor)${pair_note}"
        if [[ "$raw_ssh" == "true" ]]; then
            print_info "This host needs only ~/.ssh/${site}_demo_reset — no repo, no admin key, no root on the box."
            print_status "WARN" "--raw-ssh: the reset runs, but NOTHING syncs tester feedback or drains the box's error digests (nwp/ops#161)."
        else
            print_info "This host needs ~/.ssh/${site}_demo_reset and THIS checkout — still no admin key and no root on the box."
        fi
    else
        print_status "OK" "Installed nightly demo reset for $site --tier=${tier} (01:00 ${DEMO_TZ}, retries to ${DEMO_FLOOR_TIME})"
        print_info "Runs on THIS machine's crontab — the production schedule belongs on met (pl schedule host)."
    fi
    print_hint "Verify: crontab -l | grep -A2 'NWP Demo Reset'"
}

################################################################################
# Subcommand: walkthrough <site> [--verify] [--json] [--tier=…]
#
# "Jump straight into any part of the demo pair, already signed in."
#
# This verb answers the DATA half of that: which places exist, on which half,
# under which guild, and whether each one still resolves. The credential half
# stays where it already lives — `pl demo testers <site> login` (ops#328 t4),
# which mints a one-time link, reads the uid back out of it and refuses unless
# it matches the roster. Nothing here mints anything.
#
# Read (no --verify) is CHEAP and SAFE: catalogue + one roster read, plus
# whatever this host last measured. Verify is EXPLICIT because it costs one
# router read and ~30 HTTP probes against the live pair, and because probing a
# running host is exactly the class of action the prod-phase guard covers.
################################################################################
cmd_walkthrough() {
    local site="$1" tier="${2:-dev}" do_verify="${3:-false}"
    demo_require_jq || return 1

    local catalog rc=0
    catalog="$(demo_walkthrough_catalog_json)" || rc=$?
    if [[ $rc -ne 0 ]]; then
        jq -n --arg s "$site" \
            '{ok: false, site: $s, reason: "CANNOT VERIFY: the walkthrough target catalogue could not be read — this is not an empty walkthrough. Expected scripts/demo/walkthrough-targets.yml (or $NWP_WALKTHROUGH_CATALOG)."}'
        return 2
    fi

    # The pair: the provider is the site named, the consumer comes from the
    # pair contract that already binds these two. Never guessed.
    local contract="" consumer="" yqb
    yqb="$(demo_yq 2>/dev/null || true)"
    contract="$(demo_invite_pair_contract "$site" 2>/dev/null || true)"
    if [[ -n "$contract" && -n "$yqb" ]]; then
        consumer="$("$yqb" eval '.consumer // ""' "$contract" 2>/dev/null || true)"
        [[ "$consumer" == "null" ]] && consumer=""
    fi
    local pbase cbase
    pbase="$(demo_invite_community_base "$site")"
    cbase=""
    [[ -n "$consumer" ]] && cbase="$(demo_invite_community_base "$consumer")"

    # The roster is the site's own answer about itself: which groups exist and
    # whether the walkthrough account is there. Unreadable → exit 2, never an
    # empty walkthrough (that would render as "nothing to jump into", which is
    # the exact lie ops#281 is about).
    local roster out
    rc=0; out="$(demo_testers_drush "$site" "$tier" nwc:tester-list --format=json)" || rc=$?
    if [[ $rc -ne 0 ]]; then
        demo_testers_emit "$site" "$tier" nwc:tester-list "$rc" "$out"
        return 2
    fi
    if ! jq -e '.accounts' <<<"$out" >/dev/null 2>&1; then
        jq -n --arg s "$site" --arg raw "$(tail -c 800 <<<"$out")" \
            '{ok: false, site: $s, raw: $raw,
              reason: "CANNOT VERIFY: the roster read returned something that is not a tester roster — refusing to render a walkthrough over an unreadable site."}'
        return 2
    fi
    roster="$out"

    local groups account targets
    groups="$(demo_walkthrough_groups_json "$roster")"
    account="$(demo_walkthrough_account_json "$roster")"
    targets="$(demo_walkthrough_targets_json "$catalog" "$groups" "$account")"
    local dropped; dropped="$(demo_walkthrough_dropped_json "$catalog" "$groups" "$account")"

    local phase; phase="$(canonical_get_phase "$site" 2>/dev/null || echo "")"
    local jump_ok="true"; [[ "$phase" == "prod" ]] && jump_ok="false"

    local verification
    if [[ "$do_verify" == "true" ]]; then
        # Probing a running host is an action, so it is phase-guarded.
        demo_refuse_prod_phase "$site" "pl demo walkthrough --verify" || return $?

        # The provider is verified through the ROUTER, not over HTTP — see
        # lib/demo-walkthrough.sh's header for the measurement that forced it.
        local routes="" rrc=0 rout
        rout="$(demo_testers_drush "$site" "$tier" route --format=json)" || rrc=$?
        if [[ $rrc -eq 0 ]] && jq -e 'type == "object"' <<<"$rout" >/dev/null 2>&1; then
            routes="$rout"
        fi

        local verified
        rc=0; verified="$(demo_walkthrough_verify_json "$targets" "$routes" "$pbase" "$cbase")" || rc=$?
        if [[ $rc -ne 0 ]]; then
            jq -n --arg s "$site" \
                '{ok: false, site: $s, reason: "CANNOT VERIFY: nothing could be measured (curl unusable, or every probe failed) — no verdict was recorded."}'
            return 2
        fi
        targets="$verified"
        local now; now="$(date -u +%FT%TZ)"
        mkdir -p "$(demo_walkthrough_record_dir)"
        jq -n --arg at "$now" --arg site "$site" --argjson t "$targets" \
            '{site: $site, at: $at, source: ((if ($t | map(select(.verify.state != "unknown")) | length) > 0 then "measured" else "empty" end)),
              targets: ($t | map({key: .id, value: .verify}) | from_entries)}' \
            > "$(demo_walkthrough_record_file "$site")"
        verification="$(jq -n --arg at "$now" '{state: "measured", at: $at, age_seconds: 0, source: "this host"}')"
        demo_log "$site" walkthrough-verified "tier=${tier} targets=$(jq 'length' <<<"$targets")"
    else
        local rec; rec="$(demo_walkthrough_record_file "$site")"
        if [[ -f "$rec" ]] && jq -e '.targets' "$rec" >/dev/null 2>&1; then
            targets="$(jq -c --slurpfile r "$rec" \
                'map(. as $t | .verify = ($r[0].targets[$t.id] // $t.verify))' <<<"$targets")"
            local at age
            at="$(jq -r '.at // ""' "$rec")"
            age="$(( $(date -u +%s) - $(date -u -d "$at" +%s 2>/dev/null || echo "$(date -u +%s)") ))"
            verification="$(jq -n --arg at "$at" --argjson age "$age" \
                '{state: "measured", at: $at, age_seconds: $age, source: "this host"}')"
        else
            verification="$(jq -n '{state: "never", at: null, age_seconds: null,
                                    source: null,
                                    note: "no target on this host has ever been measured — every link below is UNKNOWN, not verified. Measure: pl demo walkthrough <site> --verify --tier=live"}')"
        fi
    fi

    local counts; counts="$(demo_walkthrough_counts "$targets")"

    if [[ "${DEMO_JSON:-false}" == "true" ]]; then
        jq -n --arg site "$site" --arg tier "$tier" --arg phase "${phase:-unknown}" \
              --argjson jump "$jump_ok" \
              --arg consumer "$consumer" --arg pbase "$pbase" --arg cbase "$cbase" \
              --argjson groups "$groups" --argjson account "$account" \
              --argjson targets "$targets" --argjson counts "$counts" \
              --argjson verification "$verification" --argjson session "$(jq -c '.session // {}' <<<"$catalog")" \
              --argjson dropped "$dropped" \
            '{ok: true, site: $site, tier: $tier, phase: $phase, jump_in_allowed: $jump,
              provider: {site: $site, base: $pbase},
              consumer: {site: (if $consumer == "" then null else $consumer end), base: $cbase},
              account: $account, groups: $groups, session: $session, dropped: $dropped,
              counts: ($counts + {total: ($targets | length), dropped: ($dropped | length)}),
              verification: $verification, targets: $targets}'
        return 0
    fi

    print_header "Demo walkthrough: $site ($tier)"
    jq -r --argjson c "$counts" --argjson a "$account" --argjson g "$groups" --argjson v "$verification" '
      "  account   : " + (if $a.present then ($a.name + " (uid " + ($a.uid|tostring) + ", " +
          (if $a.admin then "administrator" else "no admin role" end) + ", " + ($a.guilds|tostring) + " group(s))")
          else ("MISSING — " + $a.reason) end),
      "  groups    : " + ($g.count|tostring) + " (source: " + $g.source + ")",
      "  targets   : " + (length|tostring) + "  verified=" + ($c.verified|tostring) +
          " unknown=" + ($c.unknown|tostring) + " missing=" + ($c.missing|tostring) +
          " drifted=" + ($c.drifted|tostring) + " ambiguous=" + ($c.ambiguous|tostring),
      "  measured  : " + ($v.state) + (if $v.at then " at " + $v.at else "" end)' <<<"$targets"
    echo
    jq -r 'group_by(.side)[] | (.[0].side | ascii_upcase) + ":",
           (.[] | "    [" + (.verify.state|.[0:9]) + "] " + .path +
                  (if .group then "   (" + .group + ")" else "" end) + "  — " + .label)' <<<"$targets"
    [[ "$jump_ok" == "false" ]] && print_warning "canonical: prod — jump-in is REFUSED for this site."
    return 0
}

################################################################################
# main
################################################################################

main() {
    local sub="${1:-}"; shift || true
    case "$sub" in
        -h|--help|"") show_help; return 0 ;;
    esac

    local site="${1:-}"; shift || true
    [[ -n "$site" ]] || { print_error "Site name required."; show_help; return 1; }

    # Did the operator NAME the tier? Recorded here, before the parse below
    # substitutes the `dev` default, so the code verbs can refuse rather than
    # silently pick a tier for the operator (see demo_require_explicit_tier).
    local _arg
    for _arg in "$@"; do
        case "$_arg" in --tier=*) DEMO_TIER_EXPLICIT="true" ;; esac
    done

    # Common option parse (subcommand-specific positionals pass through).
    local tier="dev" if_idle="" auto_yes="false" skip_seed="false" remove="false" dry_run="false" via_key="false"
    local allow_gaps="false"
    # ops#171. NWP_DEMO_BOX_HOST is the env form of --host, so a scheduler host
    # can carry the box address in its environment instead of in site config it
    # is deliberately not given.
    local box_host="${NWP_DEMO_BOX_HOST:-}" print_only="false"
    # ops#156: --via-key now installs (and runs) a pl-mediated nightly.
    # --raw-ssh asks for the older bare-ssh cron line, for a scheduler with the
    # restricted key and no checkout. --print-transport is the introspection
    # hook the pinning test uses: it prints the ssh command `nightly --via-key`
    # would execute and runs nothing.
    local raw_ssh="false" print_transport="false"
    local do_verify="false"
    local with_pair="auto"
    # ops#219: schedule's hourly return-leg flavour.
    local fb_status="false"
    # ops#233: harvest-triage's marking flags (globals — the verb reads them).
    DEMO_TRIAGE_MARKS=()
    DEMO_TRIAGE_ALL="false"
    local passthru=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --tier=*)   tier="${1#--tier=}"; shift ;;
            --json)     DEMO_JSON="true"; shift ;;
            --allow-config-gaps) allow_gaps="true"; shift ;;
            # Capture WITHOUT staging to the box — for taking a point-in-time
            # copy you do not want the nightly to restore yet. The default is
            # to stage, because a capture the reset cannot see is a trap (see
            # cmd_golden_live).
            --no-stage) DEMO_GOLDEN_NO_STAGE="true"; shift ;;
            --dry-run)  dry_run="true"; shift ;;
            --if-idle)  if_idle="${2:-}"; shift 2 ;;
            --if-idle=*) if_idle="${1#--if-idle=}"; shift ;;
            --force|--yes|-y) auto_yes="true"; shift ;;
            --skip-seed) skip_seed="true"; shift ;;
            --with-pair) with_pair="yes"; shift ;;
            --no-pair)   with_pair="no";  shift ;;
            --remove)   remove="true"; shift ;;
            --via-key)  via_key="true"; shift ;;
            --raw-ssh)  raw_ssh="true"; shift ;;
            --feedback-status) fb_status="true"; shift ;;
            # A bare trailing `--mark` would `shift 2` off the end — same trap
            # as --host below, same refusal.
            --mark)     [[ -n "${2:-}" ]] || { print_error "--mark requires a value: --mark <basename>"; return 2; }
                        DEMO_TRIAGE_MARKS+=("$2"); shift 2 ;;
            --mark=*)   DEMO_TRIAGE_MARKS+=("${1#--mark=}"); shift ;;
            --mark-all) DEMO_TRIAGE_ALL="true"; shift ;;
            --print-transport) print_transport="true"; shift ;;
            # A bare trailing `--host` would `shift 2` off the end and, under
            # `set -e`, kill the script with no message at all. Say what is wrong.
            --host)     [[ -n "${2:-}" ]] || { print_error "--host requires a value: --host <[user@]ip>"; return 2; }
                        box_host="$2"; shift 2 ;;
            --host=*)   box_host="${1#--host=}"; shift ;;
            --print-only) print_only="true"; shift ;;
            # walkthrough: MEASURE the targets (one router read + HTTP probes
            # against the live pair) instead of reporting what was last measured.
            --verify)   do_verify="true"; shift ;;
            *)          passthru+=("$1"); shift ;;
        esac
    done

    ###########################################################################
    # ops#225 — AN UNRECOGNISED POSITIONAL IS A REFUSAL, NOT A SHRUG.
    #
    # `passthru` collects every argument the parse above did not recognise, and
    # only `codes` and `invite` ever read it. For all other subcommands it was
    # silently DISCARDED. So `pl demo golden nwd live` did not act on live: the
    # bare `live` fell into passthru, `tier` kept its `dev` default, and the
    # verb graded and STAGED A GOLDEN for a different site than the words on the
    # command line named — with no warning of any kind.
    #
    # Measured on this tree before the fix, using the read-only sibling so the
    # reproduction costs nothing:
    #
    #     pl demo status nwd live        -> "Demo status: nwd (dev)"
    #                                       golden captured 2026-07-25T14:42:09Z
    #     pl demo status nwd --tier=live -> "Demo status: nwd (live)"
    #                                       golden captured 2026-08-02T05:35:47Z
    #
    # Two different sites, eight days apart, same command line but for the
    # spelling of one argument. The reported consequence on `golden` was 75
    # phantom identity-hygiene gaps that vanished when re-run with `--tier=live`
    # — not merely "wrong target" but "wrong target, plausible output, opposite
    # conclusion". And `golden` STAGES IMAGES the nightly reset later restores.
    #
    # WHY REFUSE RATHER THAN ACCEPT A POSITIONAL TIER. Accepting both spellings
    # for the estate's most dangerous argument is how this recurs: the next verb
    # to grow a positional gets to re-decide, and the two spellings drift. The
    # estate already made this call twice this week — `pl install`'s name
    # validation and `pl issue create`'s flag refusal. Same answer here.
    #
    # `codes` and `invite` take real positionals, so they keep them — but NOT a
    # tier-shaped one, because no `codes`/`invite` action is named dev/stg/live/
    # prod and that is precisely the argument this issue is about.
    ###########################################################################
    if [[ ${#passthru[@]} -gt 0 ]]; then
        local _stray _tierish=""
        for _stray in "${passthru[@]}"; do
            case "$_stray" in dev|stg|live|prod) _tierish="$_stray"; break ;; esac
        done
        if [[ -n "$_tierish" ]]; then
            print_error "REFUSED: '$_tierish' is not a positional argument — the tier is a FLAG."
            echo "  You almost certainly meant:  pl demo $sub $site --tier=$_tierish"
            echo "  A bare tier used to be SILENTLY IGNORED, and the verb acted on tier '$tier'"
            echo "  instead — a different site, with plausible-looking output (nwp/ops#225)."
            return 2
        fi
        case "$sub" in
            codes|invite|testers) : ;;   # these genuinely take positional actions
            *)
                print_error "REFUSED: unrecognised argument(s) for 'pl demo $sub': ${passthru[*]}"
                echo "  Nothing consumes them, so continuing would run a DIFFERENT command"
                echo "  than the one written (nwp/ops#225). Check the spelling, or see:"
                echo "    pl demo --help"
                return 2 ;;
        esac
    fi

    demo_check_tier "$tier" || return 1

    # Pair resolution (ops#133 Phase 2). `auto` = pair when the contract opts in
    # AND the partner actually has an instance at this tier; `yes` = demand it
    # (refuse if unavailable); `no` = operator override, single-site path.
    #
    # AT --tier=live, `auto` IS NOT ENOUGH — the paired path must be asked for
    # (nwp/ops#170, operator decision 2026-08-02).
    #
    # WHY THE LIVE DEFAULT IS INVERTED, when dev/stg auto-upgrade. The paired
    # live path is destructive, touches two live hosts, and — as of this
    # commit — HAS NEVER RUN AGAINST THE ESTATE. Making a never-exercised
    # destructive path the new default behaviour of an existing live verb is
    # exactly the move that the bug found while writing it argues against: the
    # process-global live context would have written the provider's database
    # into the consumer's golden, sha-verified and correctly manifest-stamped,
    # and no downstream check could have seen it because every check would have
    # been consistently checking the wrong site. In that neighbourhood, a new
    # behaviour must be REQUESTED, not inherited.
    #
    # What does NOT relax is the pair itself: without --with-pair, a live reset
    # of a coupled half still hits demo_reset_pair_guard and REFUSES, naming the
    # flag. Refusing is a fine default; silently doing a new thing is not.
    # Flip this to auto once the path has a supervised live run behind it.
    local use_pair="false"
    if [[ "$with_pair" != "no" ]] && demo_pair_resolve "$site"; then
        local _partner; _partner="$(demo_pair_partner "$site" "$DEMO_PAIR_CONTRACT")"
        # demo_instance_exists, not demo_project_dir: at --tier=live neither half
        # has a local DDEV project, so the old test made the pair structurally
        # invisible exactly where it matters most (nwp/ops#170).
        if demo_instance_exists "$_partner" "$tier" >/dev/null 2>&1; then
            if demo_is_live "$tier" && [[ "$with_pair" != "yes" ]]; then
                use_pair="false"   # opt-IN only at live; the guard below refuses
            else
                use_pair="true"
            fi
        elif [[ "$with_pair" == "yes" ]]; then
            print_error "REFUSED: --with-pair, but the partner '$_partner' has no instance at tier '$tier'."
            return 1
        fi
    elif [[ "$with_pair" == "yes" ]]; then
        print_error "REFUSED: --with-pair, but '$site' is not in a demo-enabled pair contract."
        return 1
    fi

    case "$sub" in
        golden)   if [[ "$use_pair" == "true" ]]; then cmd_golden_paired "$site" "$tier" "$allow_gaps"
                  else cmd_golden "$site" "$tier" "$allow_gaps"; fi ;;
        reset)    if [[ "$use_pair" == "true" ]]; then
                      # Naming either half runs the PAIRED reset — the two are
                      # one product and one is never safe to wipe alone.
                      [[ "$site" != "$DEMO_PAIR_PROVIDER" ]] && \
                          print_info "'$site' is half of ${DEMO_PAIR_LABEL} — running the PAIRED reset (both halves)."
                      # At live this only happens because --with-pair was passed.
                      # Say what was asked for, since it destroys two hosts.
                      demo_is_live "$tier" && \
                          print_warning "--with-pair at LIVE: BOTH ${DEMO_PAIR_PROVIDER} and ${DEMO_PAIR_CONSUMER} will be ERASED and restored to ONE cut."
                      # dry_run is arg 6 on BOTH reset verbs. Dropping it here
                      # turned `--with-pair --dry-run` into a real double wipe.
                      cmd_reset_paired "$site" "$tier" "$if_idle" "$auto_yes" "$skip_seed" "$dry_run"
                  else
                      # --no-pair is the ONLY way to suppress the paired-half
                      # refusal; otherwise cmd_reset's own guard decides (and
                      # lets a tier with no partner instance through).
                      # dry_run stays positional arg 6; the pair flag is arg 7.
                      local _pg=""; [[ "$with_pair" == "no" ]] && _pg="skip"
                      cmd_reset "$site" "$tier" "$if_idle" "$auto_yes" "$skip_seed" "$dry_run" "$_pg"
                  fi ;;
        nightly)  cmd_nightly "$site" "$tier" "$use_pair" "$via_key" "$box_host" "$dry_run" "$print_transport" ;;
        status)   cmd_status "$site" "$tier" ;;
        seal-status) cmd_seal_status "$site" "$tier" ;;
        walkthrough) cmd_walkthrough "$site" "$tier" "$do_verify" ;;
        smoke)    cmd_smoke "$site" "$tier" "${DEMO_SMOKE_IP:-}" ;;
        codes)    cmd_codes "$site" "$tier" "${passthru[@]:-list}" ;;
        testers)  cmd_testers "$site" "$tier" "$remove" "${passthru[@]:-list}" ;;
        invite)   cmd_invite "$site" "$tier" "${passthru[@]}" ;;
        schedule) cmd_schedule "$site" "$remove" "$tier" "$via_key" "$box_host" "$print_only" "$raw_ssh" "$fb_status" ;;
        feedback-sync) cmd_feedback_sync "$site" "$tier" "$dry_run" ;;
        harvest-post) cmd_harvest_post "$site" "$dry_run" ;;
        harvest-pull) cmd_harvest_pull "$site" "$tier" "$dry_run" "$box_host" ;;
        harvest-triage) cmd_harvest_triage "$site" "$dry_run" ;;
        *)        print_error "Unknown subcommand: $sub"; show_help; return 1 ;;
    esac
}

################################################################################
# Subcommand: harvest-pull <site> --tier=live
#
# DRAIN the box's spooled error digests into the local spool, so
# `pl demo harvest-post` can turn them into nwp/ops issues.
#
# This is the missing half of the feedback loop. The box has always WRITTEN a
# pre-wipe error digest before each nightly reset — and nothing ever collected
# it. Digests aged out of the box's 30-file window and every error a live
# tester hit was lost, silently, which is the pilot's entire purpose going
# missing. `cmd_harvest_post` read a LOCAL directory that live never wrote to.
#
# Idempotent: the box drain is read-only and emits everything it holds, and
# this deduplicates against both the local spool and what has already been
# posted. Re-running is free; a half-finished pull loses nothing.
################################################################################
cmd_harvest_pull() {
    local site="$1" tier="${2:-live}" dry_run="${3:-false}" host_override="${4:-}"

    if [[ "$tier" != "live" ]]; then
        print_error "harvest-pull is a LIVE-tier action (the box is the only place these digests exist)."
        return 1
    fi

    local hdir; hdir="$(demo_harvest_dir "$site")"
    mkdir -p "$hdir/posted"

    print_header "Demo harvest ← live box: $site"

    # The restricted forced-command key is the right transport: it can run the
    # action words and nothing else. Fall back to the ordinary admin path when
    # the restricted key is not on this machine.
    local keyfile="$HOME/.ssh/${site}_demo_reset" out
    if [[ -r "$keyfile" ]]; then
        # The endpoint comes from demo_box_endpoint, not demo_live_ctx: the
        # scheduler that most needs this drain (met) has no sites/ config, which
        # is exactly the ops#171 trap the schedule verb already climbed out of.
        # --host / NWP_DEMO_BOX_HOST wins; site config is the fallback.
        local endpoint
        endpoint="$(demo_box_endpoint "$site" "$host_override")" || return 1
        out=$(ssh -i "$keyfile" -o IdentitiesOnly=yes -o IdentityAgent=none \
                  -o BatchMode=yes -o StrictHostKeyChecking=accept-new -n \
                  "$endpoint" harvest 2>/dev/null) || {
            print_error "Restricted-key drain failed. Is the box wrapper current? (scripts/deploy-demo-reset-wrapper.sh)"
            return 1
        }
    else
        print_info "No ${keyfile} on this host — draining over the ordinary admin path."
        if ! demo_live_ctx "$site"; then return 1; fi
        out=$(demo_rssh "$site" "sudo /usr/local/bin/${site}-demo-reset-restricted harvest" 2>/dev/null) || {
            print_error "Could not drain the harvest spool from live."
            return 1
        }
    fi

    if [[ -z "$out" || "$out" == *"NWP-HARVEST-EMPTY"* && "$out" != *"NWP-HARVEST-BEGIN"* ]]; then
        print_info "Box harvest spool is empty — nothing to pull."
        return 0
    fi

    # Split the stream on the fixed envelope. Written to a .md so the existing
    # poster picks it up, with the raw digest fenced so a watchdog table
    # survives GitLab's markdown intact.
    local pulled=0 skipped=0 name="" buf="" line
    while IFS= read -r line; do
        case "$line" in
            "NWP-HARVEST-BEGIN "*) name="${line#NWP-HARVEST-BEGIN }"; buf=""; continue ;;
            "NWP-HARVEST-END "*)
                local base="${name%.txt}" target
                target="$hdir/${base}.md"
                # triaged-*/ counts as "already have it": pulling a digest the
                # operator has already mined would resurrect it into the spool
                # and re-post it (ops#233 — triage is a TERMINAL state).
                if [[ -f "$target" || -f "$hdir/posted/${base}.md" ]] \
                   || compgen -G "$hdir/triaged-*/${base}.md" >/dev/null 2>&1; then
                    skipped=$(( skipped + 1 )); name=""; continue
                fi
                if [[ "$dry_run" == "true" ]]; then
                    echo "  would pull: ${base}.md"
                else
                    {
                        echo "harvested_utc: $(printf '%s' "$base" | sed -E 's/^harvest-//')"
                        echo ""
                        echo "Pre-wipe error digest drained from the ${site} live box."
                        echo ""
                        echo '```'
                        printf '%s\n' "$buf"
                        echo '```'
                    } > "$target"
                    print_status "OK" "pulled ${base}.md"
                fi
                pulled=$(( pulled + 1 )); name=""; continue ;;
        esac
        [[ -n "$name" ]] && buf+="${line}"$'\n'
    done <<< "$out"

    echo ""
    print_info "Pulled: ${pulled}   Already had: ${skipped}"
    if (( pulled > 0 )) && [[ "$dry_run" != "true" ]]; then
        print_info "Post them with: pl demo harvest-post ${site}"
    fi
    return 0
}

################################################################################
# Subcommand: harvest-triage <site> [--mark=<basename>]... [--mark-all] [--dry-run]
#
# ops#233 option B — a digest gets a TERMINAL state, and one verb can see all
# three directories at once:
#
#     sites/<site>/demo-harvest/            the spool (captured, not yet posted)
#     sites/<site>/demo-harvest/posted/     posted to nwp/ops (iid in demo-reset.log)
#     sites/<site>/demo-harvest/triaged-*/  mined by a human — TERMINAL
#
# They were mutually blind: the 2026-08-01 hand-triage was followed the same
# day by a harvest-post that re-filed the SAME mined digests as five fresh
# issues (ops#189–193). This verb reconciles the three, names each
# posted-but-untriaged digest WITH the issue it became, detects double-posts,
# and gives the operator --mark / --mark-all to move a digest into
# triaged-<today>/ and record the move in demo-reset.log.
#
# THE HUMAN STILL CLASSIFIES. The verb does lifecycle only: it moves and
# records, it never summarises, never files issues, never deletes. Fail-closed:
# a directory it cannot read is exit 2 CANNOT VERIFY, never "nothing there".
#
# Exit: 0 reconciled (backlog is workflow, not an anomaly) · 1 anomalies found
# (double-posts / triaged digests re-materialised in the spool) or a --mark
# refused · 2 CANNOT VERIFY.
################################################################################
cmd_harvest_triage() {
    local site="$1" dry_run="${2:-false}"
    local hdir; hdir="$(demo_harvest_dir "$site")"

    print_header "Demo harvest triage: $site"

    if [[ ! -d "$hdir" ]]; then
        print_info "No harvest state at $hdir — nothing to reconcile."
        return 0
    fi

    # --- fail-closed: every directory consulted must actually be readable ----
    local d
    for d in "$hdir" "$hdir/posted"; do
        [[ -d "$d" ]] || continue
        if [[ ! -r "$d" || ! -x "$d" ]]; then
            print_status "FAIL" "CANNOT VERIFY: $d exists but is not readable — the spool state is unknown, not empty."
            return 2
        fi
    done
    local -a tdirs=()
    for d in "$hdir"/triaged-*/; do
        [[ -d "$d" ]] || continue
        if [[ ! -r "$d" || ! -x "$d" ]]; then
            print_status "FAIL" "CANNOT VERIFY: $d exists but is not readable — triage state is unknown."
            return 2
        fi
        tdirs+=("${d%/}")
    done

    # --- gather the three sets ----------------------------------------------
    local -a spooled=() posted=()
    local f
    while IFS= read -r f; do [[ -n "$f" ]] && spooled+=("$f"); done \
        < <(find "$hdir" -maxdepth 1 -name 'harvest-*.md' -type f 2>/dev/null | sort)
    while IFS= read -r f; do [[ -n "$f" ]] && posted+=("$f"); done \
        < <(find "$hdir/posted" -maxdepth 1 -name 'harvest-*.md' -type f 2>/dev/null | sort)

    local -A triaged_in=()   # basename → the triaged-* dir(s) holding it
    local b
    for d in "${tdirs[@]}"; do
        for f in "$d"/harvest-*.md; do
            [[ -e "$f" ]] || continue
            b="$(basename "$f")"
            triaged_in["$b"]="${triaged_in[$b]:+${triaged_in[$b]} }$(basename "$d")"
        done
    done

    # --- what each posted digest BECAME: demo-reset.log's harvest-posted rows.
    # (Both the local poster and the box leg write them; via=box is a suffix.)
    local -A post_iids=() post_count=()
    local lfile ts ev rest tok pf pi
    lfile="$(demo_log_file "$site")"
    if [[ -f "$lfile" ]]; then
        while read -r ts ev rest; do
            [[ "$ev" == "harvest-posted" ]] || continue
            pf=""; pi=""
            for tok in $rest; do
                case "$tok" in
                    file=*)  pf="${tok#file=}" ;;
                    issue=*) pi="${tok#issue=}" ;;
                esac
            done
            [[ -n "$pf" ]] || continue
            post_iids["$pf"]="${post_iids[$pf]:+${post_iids[$pf]}, }${pi:-?}"
            post_count["$pf"]=$(( ${post_count[$pf]:-0} + 1 ))
        done < "$lfile"
    fi

    local anomalies=0

    # --- report: the spool ---------------------------------------------------
    echo "  Spool (captured, not yet posted): ${#spooled[@]}"
    for f in "${spooled[@]}"; do
        b="$(basename "$f")"
        if [[ -n "${triaged_in[$b]:-}" ]]; then
            print_status "FAIL" "  ${b} — already triaged in ${triaged_in[$b]} but BACK IN THE SPOOL (the ops#189-193 double-post shape; harvest-post will skip it, remove the spool copy by hand)"
            anomalies=$(( anomalies + 1 ))
        else
            echo "    ${b}"
        fi
    done

    # --- report: posted, awaiting triage ------------------------------------
    local -a untriaged=()
    for f in "${posted[@]}"; do
        b="$(basename "$f")"
        [[ -z "${triaged_in[$b]:-}" ]] && untriaged+=("$b")
    done
    echo "  Posted, awaiting triage: ${#untriaged[@]}"
    for b in "${untriaged[@]}"; do
        if [[ -n "${post_iids[$b]:-}" ]]; then
            echo "    ${b}   → nwp/ops${post_iids[$b]}"
        else
            echo "    ${b}   (no issue recorded in demo-reset.log)"
        fi
    done

    # --- report: terminal ----------------------------------------------------
    echo "  Triaged (terminal): ${#triaged_in[@]}${tdirs[0]:+  (dirs: $(for d in "${tdirs[@]}"; do basename "$d"; done | paste -sd' ' -))}"
    for f in "${posted[@]}"; do
        b="$(basename "$f")"
        [[ -n "${triaged_in[$b]:-}" ]] || continue
        echo "    note: ${b} sits in BOTH posted/ and ${triaged_in[$b]} — duplicate copy; --mark refuses it, reconcile by hand"
    done

    # --- anomaly: the same basename posted more than once --------------------
    for b in "${!post_count[@]}"; do
        if (( ${post_count[$b]} > 1 )); then
            print_status "FAIL" "  DOUBLE-POST: ${b} was posted ${post_count[$b]} times → ${post_iids[$b]} — close the duplicates on nwp/ops"
            anomalies=$(( anomalies + 1 ))
        fi
    done

    # --- marking (move + record; the only writes this verb performs) ---------
    local -a targets=()
    if [[ "${DEMO_TRIAGE_ALL:-false}" == "true" ]]; then
        targets=("${untriaged[@]}")
        (( ${#targets[@]} == 0 )) && print_info "--mark-all: nothing is awaiting triage."
    fi
    (( ${#DEMO_TRIAGE_MARKS[@]} > 0 )) && targets+=("${DEMO_TRIAGE_MARKS[@]}")

    local mark_failed=0
    if (( ${#targets[@]} > 0 )); then
        echo ""
        local today_dir="$hdir/triaged-$(date +%Y%m%d)"
        local base src from
        for base in "${targets[@]}"; do
            base="$(basename "$base")"; base="${base%.md}.md"
            if [[ -n "${triaged_in[$base]:-}" ]]; then
                print_status "FAIL" "--mark ${base}: already triaged in ${triaged_in[$base]} — refusing to triage it twice"
                mark_failed=$(( mark_failed + 1 )); continue
            fi
            if [[ -f "$hdir/posted/$base" ]]; then
                src="$hdir/posted/$base"; from="posted"
            elif [[ -f "$hdir/$base" ]]; then
                src="$hdir/$base"; from="spool"
            else
                print_status "FAIL" "--mark ${base}: no such digest in the spool or posted/"
                mark_failed=$(( mark_failed + 1 )); continue
            fi
            if [[ "$dry_run" == "true" ]]; then
                echo "  would move: ${src#$hdir/} → $(basename "$today_dir")/${base}"
                continue
            fi
            mkdir -p "$today_dir" || { print_status "FAIL" "cannot create $today_dir"; mark_failed=$(( mark_failed + 1 )); continue; }
            if mv "$src" "$today_dir/$base"; then
                demo_log "$site" harvest-triaged "file=${base} dir=$(basename "$today_dir") from=${from} issue=${post_iids[$base]:-none}"
                print_status "OK" "triaged ${base} → $(basename "$today_dir")/ (from ${from}, issue ${post_iids[$base]:-none})"
            else
                print_status "FAIL" "could not move ${base} to $today_dir"
                mark_failed=$(( mark_failed + 1 ))
            fi
        done
        [[ "$dry_run" == "true" ]] && print_status "OK" "[dry-run] nothing moved, nothing recorded."
    else
        echo ""
        (( ${#untriaged[@]} > 0 )) && print_hint "mark one: pl demo harvest-triage ${site} --mark=<basename>   all posted: --mark-all"
    fi

    (( mark_failed > 0 )) && return 1
    (( anomalies > 0 )) && return 1
    return 0
}

################################################################################
# Subcommand: smoke <site> --tier=live|dev|stg [--ip=A.B.C.D]
#
# Assert the invite email's PROMISES against what the site actually serves.
# Read-only: every probe is a GET, which is what makes it safe against live and
# runnable from CI. See lib/demo-smoke.sh for why claim-checking and not uptime.
################################################################################
# The consumer half's OWN promises (A10, A14 + its login surface), runnable
# from either direction: `pl demo smoke <consumer>` runs exactly this, and the
# provider run includes it as its STEP 2 section. One implementation so the
# two runs cannot drift.
smoke_consumer_half() {
    local csite="$1" contract="$2" ip="${3:-}" cdomain issuer own
    cdomain="$(get_site_config_value "$csite" '.live.domain' "")"
    if [[ -z "$cdomain" ]]; then
        printf '  [warn] %-34s %s has no .live.domain — cannot smoke this half\n' \
               "consumer half" "$csite"
        SMOKE_WARN=$((SMOKE_WARN+1)); return 0
    fi
    local login="https://${cdomain}/login/index.php"
    smoke_check_status   "consumer login"  "$login" "200" "$ip"
    smoke_check_contains "SSO heading"     "$login" "Log in using your account on" "$ip"

    # A10 — the button the email tells the tester to click, by its EXACT text.
    # The heading check above passed for weeks while the email named the button
    # wrongly: only equality against the contract's issuer_name catches that.
    issuer="$(demo_pair_get "$contract" '.oidc.issuer_name')"
    if [[ -n "$issuer" ]]; then
        smoke_check_button_label "SSO button = contract issuer_name" "$login" \
                                 "login-identityprovider-btn" "$issuer" "$ip"
    else
        printf '  [warn] %-34s no oidc.issuer_name in %s — cannot check the button text\n' \
               "SSO button" "$(basename "$contract")"
        SMOKE_WARN=$((SMOKE_WARN+1))
    fi

    # A14 — the consumer must present its PUBLIC name, and its machine
    # shortname must not leak into the title (the nwd run was 9/9 green while
    # ssd's own front page was titled "Home | ssd").
    own="$(get_site_config_value "$csite" '.project.title' "")"
    if [[ -n "$own" ]]; then
        smoke_check_title_regex "consumer names ITSELF, not '${csite}'" \
                                "https://${cdomain}/" "$own" "\\b${csite}\\b" "$ip"
    else
        printf '  [warn] %-34s no .project.title for %s — cannot check the name it claims\n' \
               "consumer name" "$csite"
        SMOKE_WARN=$((SMOKE_WARN+1))
    fi
}

cmd_smoke() {
    local site="$1" tier="${2:-live}" ip="${3:-}"

    # The consumer half (Moodle) gets its OWN assertion set, run directly.
    # It used to bounce wholesale to the provider run — which is how
    # `pl demo smoke nwd` stayed green while ssd's own surface was wrong.
    if demo_pair_resolve "$site" 2>/dev/null && [[ -n "${DEMO_PAIR_PROVIDER:-}" ]] \
       && [[ "$site" != "$DEMO_PAIR_PROVIDER" ]]; then
        print_header "demo smoke: ${site} (consumer half of ${DEMO_PAIR_LABEL:-the pair}) @ ${tier}${ip:+  (forced to ${ip})}"
        smoke_reset_counters
        # A RED check must never stop the run: under `set -e` the first honest
        # failure would abort before the remaining checks and the tally — a
        # red that silences the rest of the report is worse than no check.
        set +e
        echo "  -- this half's own promises --"
        smoke_consumer_half "$site" "$DEMO_PAIR_CONTRACT" "$ip"
        print_info "The provider half's promises: pl demo smoke ${DEMO_PAIR_PROVIDER}"
        local crc; smoke_summary; crc=$?
        set -e
        return "$crc"
    fi

    local domain partner partner_domain
    domain="$(get_site_config_value "$site" '.live.domain' "")"
    if [[ -z "$domain" ]]; then
        print_error "No .live.domain for '$site' — cannot smoke a site with no address."
        return 1
    fi
    local base="https://${domain}"

    # The partner half (ssd for nwd): STEP 2 of the invite email.
    partner=""
    if demo_pair_resolve "$site" 2>/dev/null; then
        partner="$(demo_pair_partner "$site" "$DEMO_PAIR_CONTRACT" 2>/dev/null || true)"
    fi
    [[ -n "$partner" ]] && partner_domain="$(get_site_config_value "$partner" '.live.domain' "")"

    print_header "demo smoke: ${site} @ ${tier}${ip:+  (forced to ${ip})}"
    smoke_reset_counters
    # As above: a RED check reports and counts; only smoke_summary decides the
    # exit code. `set -e` would otherwise abort at the first failure and hide
    # every check after it.
    set +e

    echo "  -- routes the invite email sends testers to --"
    smoke_check_status "front door"        "${base}/"                 "200"         "$ip"
    smoke_check_status "invite redemption" "${base}/demo/join"        "200"         "$ip"
    smoke_check_status "feedback"          "${base}/feedback/submit"  "200,302,303,307" "$ip"
    smoke_check_status "achievements"      "${base}/nwc/achievements" "200,302,303,403" "$ip"

    # A11 — pages an anonymous visitor must be able to read: the legal terms
    # the join flow points at, the help index, the application page, the
    # examen, and the suggestions board. Each 200s or the email's story has a
    # hole an uptime check would never see.
    echo "  -- anonymous member-facing pages --"
    smoke_check_status "terms"        "${base}/legal/terms"           "200" "$ip"
    smoke_check_status "help index"   "${base}/nwc/help/all"          "200" "$ip"
    smoke_check_status "apply"        "${base}/apply"                 "200" "$ip"
    smoke_check_status "examen"       "${base}/examen"                "200" "$ip"
    smoke_check_status "suggestions"  "${base}/community/suggestions" "200" "$ip"

    echo "  -- identity / SSO surface --"
    smoke_check_status "OIDC signing keys" "${base}/.well-known/jwks.json" "200"    "$ip"
    smoke_check_status "login"             "${base}/user/login"       "200"         "$ip"
    # A12 — gated signup: self-registration must LAND on /apply, not render an
    # open registration form (checked without following the redirect).
    smoke_check_redirect "register routes to /apply" "${base}/user/register" "302" "/apply" "$ip"

    if [[ -n "${partner_domain:-}" ]]; then
        echo "  -- STEP 2: the partner half (${partner}) --"
        smoke_consumer_half "$partner" "$DEMO_PAIR_CONTRACT" "$ip"
    fi

    echo "  -- claims that are true or false, never merely 'up' --"
    # A13 — the two claims every invite email leads with must be on the join
    # page itself: the nightly erase and the Sojourner start.
    smoke_check_contains "join page: erased-nightly" "${base}/demo/join" "erased"    "$ip"
    smoke_check_contains "join page: Sojourner"      "${base}/demo/join" "sojourner" "$ip"
    # A1-2: nwd shipped with system.site.name = "Saint School Demo" — the
    # PARTNER's name — on every page title while claiming to be the community.
    # Both halves of this are checked, because either alone is passable: the
    # page must carry its OWN name AND must not carry the partner's.
    local own_name partner_name=""
    own_name="$(get_site_config_value "$site" '.project.title' "")"
    if [[ -n "$partner" ]]; then
        partner_name="$(get_site_config_value "$partner" '.project.title' "")"
        [[ "$partner_name" == "$own_name" ]] && partner_name=""
    fi
    if [[ -n "$own_name" ]]; then
        smoke_check_title "site names ITSELF, not partner" "${base}/" "$own_name" "$partner_name" "$ip"
    else
        printf '  [warn] %-34s no .project.title declared — cannot check the name it claims\n' "site name"
        SMOKE_WARN=$((SMOKE_WARN+1))
    fi

    local rc; smoke_summary; rc=$?
    set -e
    return "$rc"
}

# Sourced by tests (bats) to exercise the manifest builders without
# dispatching (same idiom as ver-test.sh). Executed normally, this is `main`.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
