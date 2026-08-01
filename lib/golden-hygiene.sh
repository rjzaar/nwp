#!/bin/bash
################################################################################
# lib/golden-hygiene.sh — "is anybody's identity baked into a golden image?"
#
# WHY THIS EXISTS
# ---------------
# A demo golden is not a backup. A backup ages out; a golden is *restored over
# the live site every night*, so anything inside it is immortal — it survives
# every reset, it is copied to the demo box, and it is duplicated at rest into
# every backup of that box. On 2026-08-01 the ssd golden was found carrying a
# Moodle **site-administrator** row with the operator's real given name, family
# name and personal mailbox. It had been there since the site was installed on
# 2026-05-19, and the nightly restore had been putting it back every night.
#
# The demo tier's entire promise to a tester is "you never give us your name or
# your email, and nothing about you is kept". An admin account in the image that
# carries a real person's name and personal mailbox contradicts that promise on
# a site that is handed to strangers.
#
# WHAT IT ASSERTS — and how it avoids becoming the leak
# -----------------------------------------------------
# The obvious check ("grep the golden for <the operator's address>") cannot be
# written down: this repo's leakage gate (P61 / .gitleaks.toml, rules
# `operator-personal-email` and `live-domain-apex`) blocks both the personal
# mailbox AND the operator's own domains from every tracked file. A guard that
# has to name the thing it guards is a guard that leaks it.
#
# So, exactly as nwc's CanonicalTextHygieneTest does for published legal text,
# the rule is expressed STRUCTURALLY and the specifics are resolved at runtime:
#
#   RULE 1 (always on, no configuration)
#     Every mailbox in a golden must be on a domain that is either
#       (a) an RFC 2606 / RFC 6761 reserved sentinel — .invalid, .test,
#           .example, .localhost, localhost, example.{com,net,org} — i.e. a
#           provably undeliverable address, which is what a demo account should
#           have; or
#       (b) a domain this estate declares for itself, read at run time out of
#           the (gitignored) nwp.yml. Never spelled out here.
#     Anything else — a consumer mailbox, a colleague, a customer — fails.
#     This catches a personal address without anyone ever writing one down.
#
#   RULE 2 (opt-in, for personal NAMES)
#     Names have no structure to exploit — a real family name and a generated
#     patron-saint demo username are both just words, and only local knowledge
#     tells them apart. So the name tokens live in ONE untracked file,
#     private/golden-identity-denylist.txt (private/* is gitignored), and the
#     check reads it if it is there. If it is NOT there, the result is UNKNOWN,
#     never CLEAR — a host holding goldens that has never been told whose name
#     to look for has not been checked, and `pl rag` refuses to grade an UNKNOWN
#     site green.
#
#   RULE 3 (always on, no configuration) — ORPHANED CONSENT
#     Every user_consent row must still resolve to a data_policy revision that
#     exists. This is the structural fingerprint of the WRONG REMEDY: someone
#     found personal data in an old policy revision and DELETED the revision.
#     See "THE SANCTIONED REMEDY" below.
#
# THE SANCTIONED REMEDY — REDACT AS A REVISION, NEVER DELETE
# ----------------------------------------------------------
# Finding personal data inside a golden is only half a guard. The other half is
# saying what to DO about it, because the obvious reflex is destructive and the
# damage is silent.
#
# On 2026-08-02 an identity-hygiene scrub of live `nwd` found the operator's
# personal mailbox and full name inside an OLD `data_policy` revision — the
# PUBLISHED text was already clean; only the superseded draft was dirty. The
# scrub DELETED that revision. It worked, in the sense that the mailbox was
# gone. It also:
#
#   * destroyed the drafting work in that revision, irrecoverably from live; and
#   * ORPHANED a `user_consent` row, whose whole evidentiary purpose is to say
#     "this person accepted THAT revision of the policy". With the revision
#     deleted, the estate could no longer show what the user had agreed to.
#     A consent record pointing at nothing is worse than no consent record: it
#     looks like proof and is not.
#
# Operator ruling (nwp/ops#200), verbatim:
#
#     "it should be a new revision which is a redaction since we want to
#      preserve any work done."
#
# So the remedy for personal data in a REVISIONED, CONSENT-BEARING entity is:
#
#   1. WRITE A REVISION whose body is the original text with the identifiers
#      replaced by their institutional equivalents — the role address and the
#      impersonal operator wording the CURRENT clean revisions already use. Do
#      not invent a new convention; copy the one in force.
#   2. Change nothing else. Same body byte-for-byte everywhere the identifier
#      is not. The point of the ruling is that the WORK survives.
#   3. Record the redaction in the revision log message: what was replaced (in
#      kind, never in content), why, and the provenance of the recovered text.
#   4. Leave the published/current revision alone unless it is itself dirty.
#   5. NEVER `DELETE FROM` a revision table to make a scanner go quiet. If the
#      revision has already been deleted, restore it AT ITS ORIGINAL revision
#      id with the redacted body — that is the only thing that un-orphans the
#      consent rows that name it.
#
# Rule 3 exists so this is not merely written down. A deletion of a
# consent-bearing revision now shows up in `pl todo check` as a DATA/high
# finding on the very next scan.
#
# Read-only. No network. Decompresses each golden once and streams it.
################################################################################

# The remedy text every finding carries. One definition, so the guidance cannot
# drift between the library, `pl todo` and whatever reads them next.
GOLDEN_HYGIENE_REMEDY='REMEDY — REDACT, NEVER DELETE (operator ruling, nwp/ops#200): fix the LIVE site by REPLACING the identifier with the institutional equivalent already in use (role address / impersonal operator wording), then recapture. For a revisioned, consent-bearing entity (data_policy) write a REVISION carrying the redacted text and preserve everything else byte-for-byte — deleting the revision destroys the drafting work AND orphans the user_consent rows that cite it, leaving a consent record that points at nothing.'

# Reserved/sentinel mail domains. RFC 2606 (.test/.example/.invalid/.localhost +
# example.com|net|org) and RFC 6761 — all guaranteed never to resolve, which is
# exactly the property a demo account's address needs.
GOLDEN_SENTINEL_DOMAINS_RE='^(localhost|(.+\.)?(invalid|test|example|localhost)|example\.(com|net|org)|(.+\.)?ddev\.site)$'

# Exact mailboxes that CONTRIB MODULES SHIP as placeholder test data. These are
# allowlisted as whole addresses, never as domains: test.com and random.com are
# real registered domains, so exempting the domain would blind the check to a
# real person who happened to have an address there. Webform's
# webform.settings:test.types ships this pair in every install; without this the
# check would report the same impersonal lorem-ipsum fixture on every capture
# forever, and a guard that cries wolf every night is a guard that gets ignored.
GOLDEN_VENDOR_FIXTURE_MAILBOXES='^(test@test\.com|random@random\.com)$'

# Bumped whenever a RULE is added or its verdict changes. It is part of the
# memoisation key: without it, a golden whose bytes have not changed would keep
# serving a verdict computed by an OLDER ruleset — stale-NEGATIVE, the one
# direction lib/golden-hygiene.sh's cache contract promises never to go. A new
# rule that silently does not run on existing goldens is not a new rule.
GOLDEN_HYGIENE_RULESET_VERSION=2

################################################################################
# RULE 3 — the demo SEED FENCE must hold INSIDE the golden.
#
# RULE 1 asks "is anybody's identity baked into this golden?". RULE 3 asks a
# different question about the same bytes: "can the nightly reset still SEED
# from this golden, or have we just built one that aborts?"
#
# They are not the same question, and on 2026-08-01 the gap between them cost a
# reset. `nwc:seed-demo` fences the demo tier on ONE domain — @demo.invalid —
# and NwcPrivacyDemoCommands::guardAgainstRealMembers() treats ANY account above
# uid 1 that is off it as "a real member", refusing to seed. RULE 1's sentinel
# set is deliberately much wider (every RFC 2606/6761 reserved domain), because
# for the PRIVACY question .example is just as undeliverable as .invalid.
#
# So an account at `applicant@nwd.example` is invisible to RULE 1 — correctly,
# it leaks nothing — while being fatal to the reset. It was captured into the
# nwd golden, and servers/live/demo/*-demo-reset-restricted runs seed-demo
# fail-CLOSED (`die "reset-failed" "reason=seed-demo"`), so the next restore
# would have aborted, then retried hourly to the 04:00 floor and failed every
# time. A golden that cannot be reset FROM is a booby-trapped golden.
#
# Mirrors the seeder's predicate exactly, including its uid>1: root's address is
# irrelevant to whether a reset can proceed, so flagging it would be a false
# positive, and a guard that cries wolf is a guard that gets ignored.
################################################################################
GOLDEN_DEMO_FENCE_DOMAIN='demo.invalid'

# Mailboxes that are DELIBERATELY off the fence, whitespace/comma separated.
#
# EMPTY BY DEFAULT, and adding one is the same decision as passing seed-demo's
# `--force`: it asserts "this account is not a real member, and I accept that
# every future reset must special-case it". Exemptions are EXACT ADDRESSES, never
# domains — exempting a domain would blind the check to a real person who
# happened to have an address there, which is the mistake RULE 1 already avoids
# with GOLDEN_VENDOR_FIXTURE_MAILBOXES.
#
# Note there is currently no such persona. The one account that looked like a
# candidate (demo_applicant, the synthetic safeguarding-register subject) turned
# out to carry .example by style-inheritance from ten sibling personas, not by
# design — its ten siblings are all on the fence — so it was corrected rather
# than exempted. Prefer that resolution: an exemption is a permanent carve-out
# in a safety interlock.
GOLDEN_DEMO_FENCE_EXEMPT_MAILBOXES=''

# Accounts in a golden that would make `nwc:seed-demo` refuse.
# Prints one `uid=<n> <domain>` per offending account (deduplicated). Empty = ok.
#
# Reports the DOMAIN only, never the mailbox — same discipline as RULES 1 and 2.
# If a real member ever does reach a golden, the finding must be reportable,
# loggable and mailable without republishing that person's address.
#
# SCOPE: anchored on Drupal's `users_field_data`, so it is a deliberate no-op on
# a Moodle golden (ssd) — which is correct, not a blind spot: `nwc:seed-demo` is
# a Drupal Drush command and only the provider half's reset ever runs it. If a
# Moodle half ever grows an equivalent seed step, it needs its own rule; do not
# assume this one covered it. RULE 1 already scans both halves for leaks.
#
# Args: $1 = artifact path, $2 = exempt mailboxes (default: the constant above)
golden_demo_fence_violations() {
    local artifact="$1"
    local exempt="${2-$GOLDEN_DEMO_FENCE_EXEMPT_MAILBOXES}"

    # Users only exist in the DB dump; streaming the files tarball as well would
    # add a third full decompression per golden for a table it cannot contain,
    # and `pl todo check` budgets 45s for every check it runs.
    case "$artifact" in
        *.sql|*.sql.gz|*.db.sql.gz) ;;
        *) return 0 ;;
    esac

    golden_hygiene_stream "$artifact" | awk \
        -v fence="@${GOLDEN_DEMO_FENCE_DOMAIN}" \
        -v exempt="$exempt" '
    BEGIN { nex = split(exempt, ex, /[ ,\t\n]+/) }

    # One offending account, reported once.
    function handle(r,   uid, mail, dom, k) {
        if (match(r, /^[0-9]+/) == 0) return           # column list, not a row
        uid = substr(r, RSTART, RLENGTH) + 0
        if (uid <= 1) return                           # seeder ignores 0 and 1
        # First quoted field carrying "@" is the mail column: uid, langcode,
        # preferred_*, name, pass all precede it and none can contain one.
        if (match(r, /\x27[^\x27]*@[^\x27]*\x27/) == 0) return
        mail = tolower(substr(r, RSTART + 1, RLENGTH - 2))
        if (index(mail, fence) == length(mail) - length(fence) + 1) return
        for (k = 1; k <= nex; k++)
            if (ex[k] != "" && tolower(ex[k]) == mail) return
        if (uid in seen) return
        seen[uid] = 1
        dom = mail; sub(/^[^@]*@/, "", dom)
        print "uid=" uid " " dom
    }

    # Split a VALUES list into top-level (...) groups, honouring quotes and
    # backslash escapes. Splitting on "),(" would tear any row whose text
    # happens to contain that sequence.
    function emit_rows(s,   i, c, n, depth, instr, start) {
        n = length(s); depth = 0; instr = 0
        for (i = 1; i <= n; i++) {
            c = substr(s, i, 1)
            if (instr) {
                if (c == "\\") { i++; continue }
                if (c == "\x27") instr = 0
                continue
            }
            if (c == "\x27") { instr = 1; continue }
            if (c == "(") { depth++; if (depth == 1) start = i + 1 }
            else if (c == ")") {
                depth--
                if (depth == 0) handle(substr(s, start, i - start))
            }
        }
    }

    !cap && /^INSERT INTO `users_field_data`/ { cap = 1; buf = "" }
    cap {
        buf = buf $0 "\n"
        if (/;[[:space:]]*$/) { cap = 0; emit_rows(buf); buf = "" }
    }
    END { if (cap && buf != "") emit_rows(buf) }
    '
}

# Where the optional personal-name tokens live. Untracked by construction.
golden_hygiene_denylist_file() {
    printf '%s/private/golden-identity-denylist.txt' "${1:-$PWD}"
}

# Every domain this estate declares for itself, harvested from nwp.yml at run
# time (domain: / mail_domain: / anything domain-shaped under sites:). nwp.yml
# is gitignored, so the operator's real domains are read, never stored here.
# Args: $1 = path to nwp.yml
golden_hygiene_declared_domains() {
    local config="$1"
    [ -f "$config" ] || return 0
    grep -hoE '^[[:space:]]*[a-z_]*domain:[[:space:]]*[A-Za-z0-9.-]+' "$config" 2>/dev/null \
        | sed -E 's/.*:[[:space:]]*//' \
        | tr 'A-Z' 'a-z' \
        | grep -E '^[a-z0-9-]+(\.[a-z0-9-]+)+$' \
        | sort -u
}

# Stream a golden artifact's readable text.
# Args: $1 = path to golden.db.sql.gz or golden.files.tar.gz
golden_hygiene_stream() {
    local artifact="$1"
    case "$artifact" in
        *.tar.gz) gzip -dc -- "$artifact" 2>/dev/null | tar -xO 2>/dev/null ;;
        *.gz)     gzip -dc -- "$artifact" 2>/dev/null ;;
        *)        cat -- "$artifact" 2>/dev/null ;;
    esac
}

# RULE 1 — mailbox domains that are neither sentinel nor estate-declared.
# Prints one offending domain per line (deduplicated). Empty output = clean.
# Args: $1 = artifact path, $2 = newline-separated declared domains
golden_hygiene_foreign_mail_domains() {
    local artifact="$1" declared="$2"
    local domains d allowed
    domains=$(golden_hygiene_stream "$artifact" \
        | grep -aoiE '[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+' \
        | tr 'A-Z' 'a-z' | sort -u \
        | grep -vE "$GOLDEN_VENDOR_FIXTURE_MAILBOXES" \
        | sed -E 's/.*@//' | sort -u)
    [ -n "$domains" ] || return 0

    while IFS= read -r d; do
        [ -n "$d" ] || continue
        # Trailing dots / version-looking strings (mathjax@2.7.9) are not mail.
        printf '%s' "$d" | grep -qE '[a-z]' || continue
        # ...and neither is `intl-tel-input@v17.0.19`. The `[a-z]` test above
        # passes it, because the "domain" v17.0.19 contains a letter. A real
        # mail domain's LAST label is alphabetic — no TLD is all-digits (a
        # trailing numeric label means an IPv4 literal or, here, a package
        # version). Warm cache tables in a Drupal golden are full of CDN
        # library refs in exactly this shape, so without this the check
        # reports three "foreign mail domains" on every capture forever —
        # and a guard that cries wolf every night is a guard that gets
        # ignored, which is the failure mode this whole library exists to
        # avoid. Nothing deliverable is excluded: gmail.com still fails.
        printf '%s' "$d" | grep -qE '\.[A-Za-z][A-Za-z-]*$' || continue
        if printf '%s' "$d" | grep -qE "$GOLDEN_SENTINEL_DOMAINS_RE"; then
            continue
        fi
        allowed=false
        local decl
        while IFS= read -r decl; do
            [ -n "$decl" ] || continue
            if [ "$d" = "$decl" ] || [ "${d%".$decl"}" != "$d" ]; then
                allowed=true; break
            fi
        done <<< "$declared"
        [ "$allowed" = true ] || printf '%s\n' "$d"
    done <<< "$domains"
}

# RULE 2 — personal-name tokens from the untracked denylist.
# Prints one MASKED token per line (first char + length) so a finding can be
# reported, logged and mailed without re-publishing the identifier it found.
# Args: $1 = artifact path, $2 = denylist file
golden_hygiene_denylisted_tokens() {
    local artifact="$1" list="$2"
    [ -f "$list" ] || return 0

    local tmp; tmp=$(mktemp) || return 0
    grep -vE '^[[:space:]]*(#|$)' "$list" 2>/dev/null \
        | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | grep -v '^$' > "$tmp"
    [ -s "$tmp" ] || { rm -f "$tmp"; return 0; }

    # ONE streaming pass, one grep. The obvious loop — slurp the decompressed
    # golden into a shell variable and grep it once per token — took 60s on five
    # goldens, which blows the 45s budget `pl todo check` runs inside and would
    # have made `pl rag` report UNKNOWN instead of the finding. -o -i -F -f gets
    # every match in one pass; sort -u collapses them.
    local hits; hits=$(golden_hygiene_stream "$artifact" \
        | grep -aoiF -f "$tmp" 2>/dev/null | tr 'A-Z' 'a-z' | sort -u)
    rm -f "$tmp"
    [ -n "$hits" ] || return 0

    local tok
    while IFS= read -r tok; do
        [ -n "$tok" ] || continue
        printf '%s%s (%d chars)\n' "${tok:0:1}" \
            "$(printf '%*s' $(( ${#tok} - 1 )) '' | tr ' ' '*')" "${#tok}"
    done <<< "$hits"
}

# RULE 3 — consent rows whose data_policy revision no longer exists.
#
# This is the structural signature of the WRONG REMEDY (see the header). Nobody
# has to know which revision was dirty, or what was in it: a `user_consent` row
# exists precisely to say "this person accepted revision N", so if revision N is
# gone, the record has been hollowed out. Deleting a revision is the only
# ordinary way to produce this state — the module never reuses or renumbers vids.
#
# Both tables are read in ONE streaming pass. `pl todo check` budgets 45s for
# ~24 checks and a second decompression per artifact would blow it, which
# downgrades the check to UNKNOWN and thereby to no check at all.
#
# Prints one line per orphaned revision id:  <vid> <consent-row-count>
# Empty output = clean (and also = "this golden has no data_policy at all").
# Args: $1 = artifact path
golden_hygiene_orphaned_consents() {
    local artifact="$1"
    local raw
    # The `.` standing in for a backtick/quote keeps the awk program free of
    # shell-quoting escapes; the surrounding tuple shape is what makes it exact.
    # The patterns are STRINGS, not /regex/ literals: awk evaluates a regex
    # literal passed as a function argument to 0 or 1 (the result of matching it
    # against $0), so scan() would silently receive "0" and find nothing. That
    # bug reports every golden clean, which is the one answer this must never
    # give by accident — hence the round-trip test on a fixture with a known
    # deleted revision.
    raw=$(golden_hygiene_stream "$artifact" | awk '
        function scan(s, pat, kind,   t) {
            while (match(s, pat)) {
                t = substr(s, RSTART, RLENGTH)
                print kind " " t
                s = substr(s, RSTART + RLENGTH)
            }
        }
        /^INSERT INTO .data_policy_revision. VALUES/                  { cur = "REV" }
        /^INSERT INTO .user_consent__data_policy_revision_id. VALUES/ { cur = "CON" }
        cur == "REV" { scan($0, "\\([0-9]+,[0-9]+,.[A-Za-z-]+.,", "REV") }
        cur == "CON" { scan($0, "\\(.user_consent.,[0-9]+,[0-9]+,[0-9]+,.[A-Za-z-]+.,[0-9]+,[0-9]+\\)", "CON") }
        /;[[:space:]]*$/ { cur = "" }
    ' 2>/dev/null)
    [ -n "$raw" ] || return 0

    # data_policy_revision: (id, vid, langcode, …) → field 2 is the vid.
    local revs; revs=$(printf '%s\n' "$raw" \
        | sed -n 's/^REV ([0-9]*,\([0-9]*\),.*/\1/p' | sort -u)
    # user_consent__…: (bundle, deleted, entity, revision, langcode, delta, VALUE)
    # → the trailing field is the data_policy revision the consent cites.
    local cons; cons=$(printf '%s\n' "$raw" \
        | sed -n 's/^CON .*,\([0-9]*\))$/\1/p' | sort)

    # No revisions parsed at all means this golden has no data_policy tables —
    # silence, not "every consent is orphaned". Fail QUIET here, never loud:
    # a false RED on every Moodle golden would get the whole check switched off.
    [ -n "$revs" ] || return 0
    [ -n "$cons" ] || return 0

    local vid n
    while IFS= read -r vid; do
        [ -n "$vid" ] || continue
        if ! printf '%s\n' "$revs" | grep -qx -- "$vid"; then
            n=$(printf '%s\n' "$cons" | grep -cx -- "$vid")
            printf '%s %s\n' "$vid" "$n"
        fi
    done <<< "$(printf '%s\n' "$cons" | sort -u)"
}

# All three rules for one artifact, memoised on CONTENT.
#
# Decompressing a multi-megabyte golden twice per artifact costs ~20s across the
# five images this workstation holds. `pl todo check` budgets 45s for ~24 checks
# and `pl rag` calls a check that overruns UNKNOWN, so an honest-but-slow check
# degrades into no check at all. Goldens change at most once a day, so the result
# is cached against the sha256 of the artifact AND of the inputs that decide the
# verdict (the denylist, the declared-domain set). Any recapture, any edit to
# either input, is a different key and forces a fresh scan — the cache can go
# stale-positive but never stale-negative.
#
# Prints:  MAIL   <domain>          (one per line)
#          NAME   <masked>          (one per line)
#          FENCE  uid=<n> <domain>  (one per line)
#          ORPHAN <vid> <rows>      (one per line)
# Args: $1=artifact  $2=declared domains  $3=denylist file  $4=cache dir
golden_hygiene_scan() {
    local artifact="$1" declared="$2" list="$3" cache_dir="$4"
    [ -f "$artifact" ] || return 0

    local key="" cache=""
    if [ -n "$cache_dir" ] && command -v sha256sum >/dev/null 2>&1; then
        key=$(printf '%s|%s|%s|%s|%s' \
                "$(sha256sum -- "$artifact" 2>/dev/null | cut -d' ' -f1)" \
                "$([ -f "$list" ] && sha256sum -- "$list" 2>/dev/null | cut -d' ' -f1)" \
                "$(printf '%s' "$declared" | sha256sum 2>/dev/null | cut -d' ' -f1)" \
                "$GOLDEN_HYGIENE_RULESET_VERSION" \
                "$(printf '%s' "$GOLDEN_DEMO_FENCE_EXEMPT_MAILBOXES" | sha256sum 2>/dev/null | cut -d' ' -f1)" \
              | sha256sum | cut -d' ' -f1)
        cache="$cache_dir/golden-hygiene/$key"
        if [ -f "$cache" ]; then cat -- "$cache"; return 0; fi
    fi

    local out=""
    local d m o
    while IFS= read -r d; do
        [ -n "$d" ] && out+="MAIL $d"$'\n'
    done <<< "$(golden_hygiene_foreign_mail_domains "$artifact" "$declared")"
    while IFS= read -r m; do
        [ -n "$m" ] && out+="NAME $m"$'\n'
    done <<< "$(golden_hygiene_denylisted_tokens "$artifact" "$list")"
    # FENCE (seed-fence violations) and ORPHAN (consent rows whose policy
    # revision is gone) were added independently on either side of this rebase.
    # They are separate hazards and neither subsumes the other, so the
    # aggregator reports both.
    local v
    while IFS= read -r v; do
        [ -n "$v" ] && out+="FENCE $v"$'\n'
    done <<< "$(golden_demo_fence_violations "$artifact")"
    local o
    while IFS= read -r o; do
        [ -n "$o" ] && out+="ORPHAN $o"$'\n'
    done <<< "$(golden_hygiene_orphaned_consents "$artifact")"

    if [ -n "$cache" ]; then
        mkdir -p "$(dirname "$cache")" 2>/dev/null && printf '%s' "$out" > "$cache" 2>/dev/null
    fi
    printf '%s' "$out"
}
