#!/usr/bin/env bash
################################################################################
# lib/demo-walkthrough.sh — the demo pair's WALKTHROUGH surface (ops#328 t5)
#
# One question, answered honestly: *what can the operator jump straight into on
# this demo pair, and does each of those targets still resolve?*
#
# The catalogue is scripts/demo/walkthrough-targets.yml (declared, reviewable,
# hostname-free). This library turns it into a flat target list with the site's
# OWN group ids and the walkthrough account's OWN uid substituted in, plus a
# verification verdict per target.
#
# THREE PROPERTIES THIS FILE EXISTS TO KEEP
# -----------------------------------------
# 1. A TARGET NOBODY MEASURED IS `unknown`, NEVER `verified`. The console renders
#    a link that has never been probed differently from one that has. ops#292's
#    lesson, applied before the first render rather than after the first
#    complaint.
#
# 2. ABSENCE IS NOT MEASURABLE OVER HTTP ON EITHER STACK, so HTTP is not used to
#    claim it. Measured 2026-08-11: nwd serves a 55 KB THEMED 404 for an unknown
#    path; ssd serves a Moodle-rendered 404 for /auth/oauth2/login.php, a file
#    that exists and that its own login page links to. The provider is therefore
#    verified through `drush route` — which can say "no such route" and mean it,
#    and can also say "that route MOVED" (`drifted`). A consumer 404 carrying an
#    application body is `ambiguous`; only a BARE 404 is `missing`.
#
# 3. FAIL CLOSED. No catalogue, unparseable catalogue, unreadable roster, no
#    curl, unreadable router: exit 2 CANNOT VERIFY with a reason. There is no
#    path through this file that returns an empty target list and calls it fine.
#
# Pure-ish: everything here reads. The one-time login link is minted by
# `pl demo testers <site> login` (ops#328 t4) and never by this file.
################################################################################

# The account the walkthrough is designed around. Seeded by `drush nwc:seed-demo`
# (nwp/nwc), so the nightly reset restores it — a hand-made account would not
# survive 01:00. Overridable for tests only.
DEMO_WALKTHROUGH_ACCOUNT="${DEMO_WALKTHROUGH_ACCOUNT:-nwcdemo_walkthrough}"

# demo_walkthrough_catalog_file — the declared target catalogue.
# Repo-relative (like the registry-home declaration): the catalogue and the code
# that reads it must come from the same checkout, so a branch or worktree run
# sees the targets that branch declares.
demo_walkthrough_catalog_file() {
    if [[ -n "${NWP_WALKTHROUGH_CATALOG:-}" ]]; then
        echo "$NWP_WALKTHROUGH_CATALOG"
        return 0
    fi
    local here="${BASH_SOURCE[0]%/*}"
    echo "${here}/../scripts/demo/walkthrough-targets.yml"
}

# Where THIS host records what it last measured. private/, gitignored, one file
# per site — the same posture as private/demo-codes/<site>.json, and for the
# same reason: it is an observation made by this host, not a shared fact.
demo_walkthrough_record_dir()  { echo "${PROJECT_ROOT:?PROJECT_ROOT not set}/private/demo-walkthrough"; }
demo_walkthrough_record_file() { echo "$(demo_walkthrough_record_dir)/${1:?site required}.json"; }

# demo_walkthrough_catalog_json — the catalogue as JSON on stdout.
# rc 2 (with a reason on stderr) when it is absent or will not parse. A
# catalogue that cannot be read is not an empty catalogue.
demo_walkthrough_catalog_json() {
    local f yqb
    f="$(demo_walkthrough_catalog_file)"
    if [[ ! -f "$f" ]]; then
        echo "walkthrough catalogue not found at ${f}" >&2
        return 2
    fi
    yqb="$(demo_yq 2>/dev/null)" || {
        echo "yq is not available — cannot read the walkthrough catalogue" >&2
        return 2
    }
    local out
    out="$("$yqb" eval -o=json '.' "$f" 2>/dev/null)" || {
        echo "walkthrough catalogue at ${f} did not parse as YAML" >&2
        return 2
    }
    jq -e '.provider and .consumer' <<<"$out" >/dev/null 2>&1 || {
        echo "walkthrough catalogue at ${f} is missing a provider or consumer block" >&2
        return 2
    }
    printf '%s\n' "$out"
}

################################################################################
# Groups
#
# The console hardcodes NOTHING about guilds — the bundle-triplication lesson.
# Two sources, in preference order, and the one actually used is NAMED in the
# output so a partial answer can never pass as a complete one:
#
#   catalog — guild_catalog.groups from `drush nwc:tester-list --format=json`.
#             Complete by construction (every group carrying a seed key).
#   roster  — the union of the roster accounts' own memberships. Complete only
#             if some account is in every group; it is a FALLBACK for a site
#             whose deployed nwc:tester-list predates the catalogue extension,
#             and it says so.
################################################################################
demo_walkthrough_groups_json() {
    local roster="$1"
    local cat_groups
    cat_groups="$(jq -c '[ (.guild_catalog.groups // .guild_catalog.guilds // [])[]
                           | select((.group_id // null) != null and (.seed_key // "") != "")
                           | {group_id: .group_id, seed_key: .seed_key,
                              label: (.label // .seed_key), type: (.type // "")} ]' <<<"$roster" 2>/dev/null)" || cat_groups="[]"

    local roster_groups
    roster_groups="$(jq -c '[ (.accounts // [])[] | (.guilds // [])[]
                              | select((.group_id // null) != null)
                              | {group_id: .group_id, seed_key: (.seed_key // ""),
                                 label: (.label // .seed_key // ""), type: (.type // "")} ]
                            | unique_by(.group_id)' <<<"$roster" 2>/dev/null)" || roster_groups="[]"

    # Prefer whichever source knows about MORE groups, and say which won. A
    # deployed catalogue that lists only type=guild must not hide the seven
    # interest groups the roster can plainly see.
    local n_cat n_ros
    n_cat="$(jq 'length' <<<"$cat_groups")"
    n_ros="$(jq 'length' <<<"$roster_groups")"
    if (( n_cat >= n_ros && n_cat > 0 )); then
        jq -c --argjson g "$cat_groups" \
           '{source: "catalog", count: ($g | length), groups: ($g | sort_by(.group_id)),
             note: "from the site'"'"'s own guild_catalog (every group carrying a seed key)"}' -n
    elif (( n_ros > 0 )); then
        jq -c --argjson g "$roster_groups" --argjson c "$n_cat" \
           '{source: "roster", count: ($g | length), groups: ($g | sort_by(.group_id)),
             note: ("derived from roster memberships because the deployed guild_catalog listed only " +
                    ($c | tostring) + " group(s); it is complete only if some tester is in every group")}' -n
    else
        jq -c -n '{source: "none", count: 0, groups: [],
                   note: "the site reported no groups at all — this is a finding, not an empty walkthrough"}'
    fi
}

################################################################################
# The walkthrough account, read out of the roster the site itself returned.
################################################################################
demo_walkthrough_account_json() {
    local roster="$1" want="${2:-$DEMO_WALKTHROUGH_ACCOUNT}"
    jq -c --arg want "$want" '
      ( [ (.accounts // [])[] | select(.name == $want) ] | first ) as $a
      | if $a == null then
          {present: false, name: $want, uid: null, admin: false, guilds: 0, roles: [],
           reason: ("no account named " + $want + " on this site — it is seeded by `drush nwc:seed-demo` (nwp/nwc); until that profile change is deployed the jump-in buttons have no identity to use")}
        else
          {present: true, name: $a.name, uid: ($a.uid // null),
           mail: ($a.mail // ""), active: ($a.active // false),
           admin: ((($a.roles // []) | index("administrator")) != null),
           roles: ($a.roles // []),
           guilds: (($a.guilds // []) | length),
           guild_roles: [ ($a.guilds // [])[] | {label: (.label // .seed_key), roles: (.roles // [])} ],
           sojourner_level: ($a.sojourner_level // 0),
           fenced: ((($a.mail // "") | endswith("@demo.invalid")))}
        end' <<<"$roster"
}

################################################################################
# Target expansion
#
# Placeholders: {gid} — a real group id; {uid} — the walkthrough account's uid.
# A target still carrying an unsubstituted placeholder is DROPPED and counted
# as dropped; rendering /user/{uid}/dashboard as a link would be a guaranteed
# 404 dressed as a feature.
################################################################################
demo_walkthrough_targets_json() {
    local catalog="$1" groups="$2" account="$3"
    jq -c -n --argjson cat "$catalog" --argjson grp "$groups" --argjson acct "$account" '
      def mk(side; section; group; t):
        {id: (side + "." + section.key + "." + (if group == null then "" else (group.seed_key + ".") end) + t.key),
         side: side,
         section: section.key,
         section_label: section.label,
         group: (if group == null then null else group.label end),
         group_seed_key: (if group == null then null else group.seed_key end),
         key: t.key,
         label: t.label,
         path: (t.path
                | (if group == null then . else gsub("\\{gid\\}"; (group.group_id | tostring)) end)
                | (if ($acct.uid // null) == null then . else gsub("\\{uid\\}"; ($acct.uid | tostring)) end)),
         path_template: t.path,
         route: (t.route // null),
         kind: (t.kind // "route"),
         admin_only: (t.admin_only // false),
         note: (t.note // null),
         verify: {state: "unknown", detail: "not measured on this host yet", at: null}};

      ( [ $cat.provider.sections[] as $s | $s.targets[] as $t | mk("provider"; $s; null; $t) ]
      + [ $grp.groups[] as $g | $cat.provider.group_targets[] as $t
          | mk("provider"; {key: "guilds", label: "Guilds & interest groups"}; $g; $t) ]
      + [ $cat.consumer.sections[] as $s | $s.targets[] as $t | mk("consumer"; $s; null; $t) ] )
      | map(select(.path | test("\\{[a-z]+\\}") | not))
    '
}

# demo_walkthrough_dropped_json <catalog> <groups> <account> — the targets that
# could NOT be addressed, and why. A silent drop is how a walkthrough quietly
# stops covering a third of the product: /user/{uid}/dashboard simply vanishes
# when the account is missing, and nothing says a thing. So it is counted and
# named instead.
demo_walkthrough_dropped_json() {
    local catalog="$1" groups="$2" account="$3"
    jq -c -n --argjson cat "$catalog" --argjson grp "$groups" --argjson acct "$account" '
      [ ($cat.provider.sections[].targets[]), ($cat.consumer.sections[].targets[]) ]
      | map(select(.path | test("\\{uid\\}")))
      | if ($acct.uid // null) == null
        then map({key: .key, label: .label, path_template: .path,
                  reason: "needs the walkthrough account'"'"'s uid, and that account is not on this site yet"})
        else [] end
      + (if ($grp.count // 0) == 0
         then [{key: "group_targets", label: "every per-guild link",
                path_template: "/group/{gid}/…",
                reason: "the site reported no groups, so no guild link could be addressed"}]
         else [] end)'
}

################################################################################
# Verification
#
# provider — `drush route --format=json` (a {name: path} map). Authoritative:
#            absent name  → missing; present but a DIFFERENT path → drifted.
#            Alias targets have no route, so they fall through to HTTP.
# consumer — HTTP, with the only honest discriminator available (see header).
#
# Probed ONCE PER DISTINCT PATH TEMPLATE, not once per target: /group/{gid}/about
# is one route whatever the gid, and 16 identical probes would be 16 times the
# load for the same fact. Each target records which URL actually answered.
################################################################################

# demo_walkthrough_http <url> → "<code> <bodylen>" on stdout, rc 0.
# rc 2 when curl itself is unusable — never a fabricated code.
demo_walkthrough_http() {
    local url="$1" out code body
    if [[ -n "${NWP_WALKTHROUGH_NO_CURL:-}" ]] || ! command -v curl >/dev/null 2>&1; then
        return 2
    fi
    out="$(curl -sS -L --max-time "${NWP_WALKTHROUGH_HTTP_TIMEOUT:-12}" \
                 -w $'\n__NWPHTTP__%{http_code}\n' "$url" 2>/dev/null)" || return 2
    code="$(sed -n 's/^__NWPHTTP__\([0-9]*\)$/\1/p' <<<"$out" | tail -1)"
    [[ "$code" =~ ^[0-9]{3}$ ]] || return 2
    body="$(sed '/^__NWPHTTP__[0-9]*$/d' <<<"$out")"
    printf '%s %s\n' "$code" "${#body}"
}

# demo_walkthrough_http_state <code> <bodylen> → one of the four states.
#
# 404 is the whole reason this function exists. On BOTH halves of this pair the
# application renders its own 404 page, so "404 with a body" cannot tell a
# missing page from a page that exists and rejected the request — it is
# `ambiguous`, and the console says CANNOT VERIFY rather than drawing a dead
# link or a live one. Only a BARE 404 (nothing served) is `missing`.
demo_walkthrough_http_state() {
    local code="$1" len="${2:-0}"
    case "$code" in
        2??|30?|401|403|405) echo "verified" ;;
        404) if (( len > 200 )); then echo "ambiguous"; else echo "missing"; fi ;;
        *)   echo "cannot_verify" ;;
    esac
}

# demo_walkthrough_verify_json <targets> <route_map|""> <provider_base> <consumer_base>
# Emits the targets with their verify blocks filled in. rc 2 if it could not
# measure at all.
demo_walkthrough_verify_json() {
    local targets="$1" routes="$2" pbase="$3" cbase="$4"
    local now; now="$(date -u +%FT%TZ)"

    # 1. route-backed provider targets — settled from the router map alone.
    local out
    if [[ -n "$routes" ]]; then
        out="$(jq -c --argjson r "$routes" --arg at "$now" '
          map(if .side == "provider" and .kind != "alias" and .route != null
              then . as $t
                   | ($r[$t.route] // null) as $p
                   | .verify = (if $p == null
                                then {state: "missing", detail: ("the live router has no route named " + $t.route), at: $at}
                                elif ($p | gsub("\\{[a-z_]+\\}"; "*")) == ($t.path_template | gsub("\\{gid\\}"; "*"))
                                then {state: "verified", detail: ("router: " + $t.route + " → " + $p), at: $at}
                                else {state: "drifted", detail: ("route " + $t.route + " now serves " + $p + ", not " + $t.path_template), at: $at}
                                end)
              else . end)' <<<"$targets")" || return 2
    else
        out="$(jq -c --arg at "$now" '
          map(if .side == "provider" and .kind != "alias" and .route != null
              then .verify = {state: "cannot_verify", detail: "the live router could not be read", at: $at}
              else . end)' <<<"$targets")" || return 2
    fi

    # 2. everything else — one HTTP probe per distinct (side, path_template).
    local probes=() key side tmpl url code len state first_path
    mapfile -t probes < <(jq -r '[ .[] | select(.verify.state == "unknown") | .side + "	" + .path_template ]
                                 | unique | .[]' <<<"$out")
    local any_measured=false
    for key in "${probes[@]}"; do
        side="${key%%$'\t'*}"; tmpl="${key#*$'\t'}"
        first_path="$(jq -r --arg s "$side" --arg t "$tmpl" \
            'map(select(.side == $s and .path_template == $t)) | .[0].path' <<<"$out")"
        if [[ "$side" == "provider" ]]; then url="${pbase}${first_path}"; else url="${cbase}${first_path}"; fi
        if [[ -z "$pbase" && "$side" == "provider" ]] || [[ -z "$cbase" && "$side" == "consumer" ]]; then
            out="$(jq -c --arg s "$side" --arg t "$tmpl" --arg at "$now" \
                'map(if .side == $s and .path_template == $t
                     then .verify = {state: "cannot_verify", detail: "no base URL is configured for this half", at: $at}
                     else . end)' <<<"$out")"
            continue
        fi
        local probe rc=0
        probe="$(demo_walkthrough_http "$url")" || rc=$?
        if [[ $rc -ne 0 ]]; then
            state="cannot_verify"; code="-"; len=0
        else
            code="${probe%% *}"; len="${probe##* }"
            state="$(demo_walkthrough_http_state "$code" "$len")"
            any_measured=true
        fi
        out="$(jq -c --arg s "$side" --arg t "$tmpl" --arg at "$now" --arg st "$state" \
               --arg d "HTTP ${code} from ${first_path}" --arg via "$first_path" \
            'map(if .side == $s and .path_template == $t
                 then .verify = {state: $st, detail: $d, at: $at, via: $via}
                 else . end)' <<<"$out")"
    done

    if [[ ${#probes[@]} -gt 0 && "$any_measured" == "false" ]]; then
        return 2
    fi
    printf '%s\n' "$out"
}

# demo_walkthrough_counts <targets> → the per-state tally, from the rows
# themselves. Never a separate hand-kept number that can drift from the list.
demo_walkthrough_counts() {
    jq -c 'group_by(.verify.state) | map({key: .[0].verify.state, value: length}) | from_entries
           | {total: 0, verified: 0, missing: 0, drifted: 0, ambiguous: 0, unknown: 0, cannot_verify: 0} + .' \
       --argjson _ null <<<"$1" 2>/dev/null \
    || echo '{"total":0,"verified":0,"missing":0,"drifted":0,"ambiguous":0,"unknown":0,"cannot_verify":0}'
}
