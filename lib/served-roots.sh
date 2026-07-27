#!/usr/bin/env bash
#
# lib/served-roots.sh — the engine behind `pl server roots <server>`.
#
# WHY THIS FILE EXISTS (nwp/ops#149)
# ----------------------------------
# The `rgs` live site served the pre-ops#90 mod_depthcontent — raw `<details>`
# re-insert, i.e. stored XSS — for ELEVEN DAYS after the fix had reached every
# copy on a HAND-MAINTAINED list. rgs was declared in the global nwp.yml, but
# it had no sites/rgs/.nwp.yml, so every `pl moodle` verb refused it BY NAME:
#
#     $ pl moodle gate-status rgs
#     ERROR: No site config at sites/rgs/.nwp.yml
#
# The site was up, reachable, and serving traffic — and simultaneously
# invisible to every gate in the tool. Nobody could have noticed, because
# nothing in `pl` ever asked the box what it was actually serving. The corpus
# of every check was a list a human maintained by hand, and a hand-maintained
# corpus fails silently: it goes green by omission.
#
# This file asks the other question. It enumerates what nginx ACTUALLY SERVES
# and reconciles that against what NWP DECLARES, in both directions.
#
# DESIGN RULES (load-bearing — do not relax without a decision-log entry)
# ----------------------------------------------------------------------
#  1. FAIL CLOSED ON BLINDNESS. This is the single most important property.
#     A dead transport, an unreadable vhost, a missing nginx master or an
#     enumeration that returns zero roots is CANNOT-VERIFY (rc=3) — NEVER a
#     clean 0. An empty result must never read as "nothing undeclared", because
#     a silently incomplete corpus is exactly what caused the incident.
#  2. NO HAND-MAINTAINED ALLOWLIST. It is tempting to add an `ignore:` list for
#     known-good roots. That would reintroduce the failure mode verbatim. The
#     only way to make a root green is to DECLARE it in the inventory the rest
#     of `pl` already reads (nwp.yml / sites/<name>/.nwp.yml), which is also
#     what makes it visible to every other gate.
#  3. READ-ONLY BY CONSTRUCTION. The remote probe issues a fixed sequence of
#     `ps`, `cat` and `ls`. It writes nothing, reloads nothing, and never
#     interpolates operator input into a remote shell.
#  4. CHEAP AND SERIAL. A few greps over config files, one ssh round trip, no
#     parallel fan-out. NOTHING here may invoke gitlab-rails, gitlab-rake,
#     nginx -t/-T, composer or a database dump. The git box is 3.8 GB and runs
#     GitLab plus the live fleet; a heavy op OOM-killed it for 5-8 minutes on
#     2026-07-25. `pl server health <server>` remains the REQUIRED preflight
#     before anything heavy — this verb is deliberately not heavy.
#  5. yq-FIRST. Every YAML read goes through yq (ADR-0015 / lint:yq-first).
#     The awk in this file parses nginx output and `ls`, never YAML.
#
# WHAT COUNTS AS "SERVED"
# -----------------------
# The corpus is derived from the RUNNING nginx master, not from a guess. On the
# git box the system nginx.service is dead by design and GitLab's BUNDLED nginx
# (`/opt/gitlab/embedded/sbin/nginx -p /var/opt/gitlab/nginx`) serves every
# vhost. Its own nginx.conf is root-readable only, and it includes
# `/etc/nginx/conf.d/*.conf` — but the Debian /etc/nginx/nginx.conf ALSO
# includes `/etc/nginx/sites-enabled/*`, which the bundled nginx does NOT read.
# Hardcoding either directory would therefore produce a corpus that is wrong in
# one direction or the other. We follow the include graph from whichever config
# the live master process was started with, and if we cannot read a file in
# that graph we say so and fail closed rather than grading a partial corpus.

# ---------------------------------------------------------------------------
# The remote probe.
#
# Emits a line-oriented capture:
#   NWPROOTS v1
#   master=yes|no          was a running nginx master found?
#   config=<path>          the root config the master was started with
#   readmode=plain|sudo    how files were read
#   file=<path>            start of one config file's filtered content
#   L<line>                one filtered config line (structure-bearing only)
#   unreadable=<path>      a file in the include graph we could NOT read
#   dirlist=<parent>       a docroot parent directory
#   D<name>                one entry in that directory
#
# Only structure-bearing lines are emitted (braces, server_name, root, alias,
# include, return, proxy_pass, location), which keeps the transfer tiny even
# though GitLab's own service_conf tree is in the graph.
# ---------------------------------------------------------------------------
served_roots_probe_script() {
    cat <<'PROBE'
set -u
printf 'NWPROOTS v1\n'

argv=$(ps -eo args 2>/dev/null | grep '[n]ginx: master' | head -1)
if [ -z "$argv" ]; then
    printf 'master=no\n'
    printf 'config=\n'
    exit 0
fi
printf 'master=yes\n'

prefix=''
conf=''
# shellcheck disable=SC2086
set -- $argv
while [ $# -gt 0 ]; do
    case "$1" in
        -p) prefix="${2:-}"; shift ;;
        -c) conf="${2:-}"; shift ;;
    esac
    shift 2>/dev/null || break
done
[ -n "$prefix" ] || prefix=/etc/nginx

# Read one file, preferring an unprivileged read. Returns 1 if unreadable by
# either route, which the caller records as blindness.
rf() {
    if [ -r "$1" ]; then cat "$1" 2>/dev/null; return $?; fi
    sudo -n cat "$1" 2>/dev/null
}

# Resolve the root config STRICTLY RELATIVE TO THE RUNNING MASTER'S PREFIX, and
# probe each candidate by READING it rather than with `-f`.
#
# Both halves of that sentence are load-bearing, and the first version of this
# file got both wrong. On the git box the bundled nginx runs with
# `-p /var/opt/gitlab/nginx`, whose conf/ directory is root-only: `-f` returns
# false on PERMISSION DENIED exactly as it does on ABSENT. The old code read
# that false as "not there", fell through to the hardcoded /etc/nginx/nginx.conf
# — the DEBIAN config, belonging to an nginx that is dead by design — and
# reported the resulting corpus with full confidence. It picked up
# sites-enabled/* (which the bundled nginx never loads) and would have missed
# anything the bundled config includes from its own prefix.
#
# That is the ops#149 failure verbatim: a silently wrong corpus producing a
# confident answer. So: no cross-prefix fallback, and a candidate counts only
# if we could actually READ it. If none can be read we emit `unreadable=` and
# the caller returns CANNOT-VERIFY.
readmode=plain
if [ -n "$conf" ]; then
    cands="$conf"
else
    cands="$prefix/conf/nginx.conf
$prefix/nginx.conf"
fi
found=''
for c in $cands; do
    if rf "$c" >/dev/null 2>&1; then
        found="$c"
        [ -r "$c" ] || readmode=sudo
        break
    fi
done
if [ -z "$found" ]; then
    printf 'config=\n'
    printf 'readmode=%s\n' "$readmode"
    for c in $cands; do printf 'unreadable=%s\n' "$c"; done
    exit 0
fi
conf="$found"
printf 'config=%s\n' "$conf"
printf 'readmode=%s\n' "$readmode"

seen=''
queue="$conf"
roots=''
n=0
while [ -n "$queue" ]; do
    f=$(printf '%s\n' "$queue" | head -1)
    queue=$(printf '%s\n' "$queue" | tail -n +2)
    [ -n "$f" ] || continue
    case "$seen" in *"|$f|"*) continue ;; esac
    seen="$seen|$f|"
    n=$((n + 1))
    [ "$n" -gt 300 ] && { printf 'unreadable=TOO-MANY-FILES\n'; break; }

    if ! body=$(rf "$f"); then
        printf 'unreadable=%s\n' "$f"
        continue
    fi
    printf 'file=%s\n' "$f"
    # Strip comments, keep only structure-bearing directives.
    body=$(printf '%s\n' "$body" | sed 's/#.*$//' \
        | grep -E '[{}]|server_name|[[:space:]]root[[:space:]]|^root[[:space:]]|alias[[:space:]]|include[[:space:]]|return[[:space:]]|proxy_pass|location')
    printf '%s\n' "$body" | sed 's/^/L/'

    # Collect docroots for the directory listing below.
    more=$(printf '%s\n' "$body" | grep -oE '(^|[[:space:]{])root[[:space:]]+[^;]+' | awk '{print $NF}')
    [ -n "$more" ] && roots="$roots
$more"

    # Follow includes. Relative paths resolve against the prefix, as nginx does.
    incs=$(printf '%s\n' "$body" | grep -oE 'include[[:space:]]+[^;]+' | awk '{print $2}')
    for g in $incs; do
        case "$g" in
            /*) : ;;
            *)  g="$prefix/$g" ;;
        esac
        for m in $g; do
            [ -e "$m" ] || continue
            case "$m" in *mime.types) continue ;; esac
            queue="$queue
$m"
        done
    done
done

# List the parent of each docroot, so a tree that is on disk but served by
# nothing can still be reported. Two components deep (/var/www), deduplicated.
parents=$(printf '%s\n' "$roots" | grep -E '^/' | cut -d/ -f1-3 | sort -u)
for p in $parents; do
    [ -d "$p" ] || continue
    printf 'dirlist=%s\n' "$p"
    ls -1 "$p" 2>/dev/null | sed 's/^/D/'
done
PROBE
}

# served_roots_probe <ssh-prefix>
# Runs the probe. Any transport failure or missing banner is rc=3, never 0.
served_roots_probe() {
    local prefix="$1" out rc
    out="$(host_run "$prefix" "$(served_roots_probe_script)" 2>/dev/null)"; rc=$?
    if [ "$rc" -ne 0 ] || [ -z "$out" ] || [[ "$out" != *"NWPROOTS"* ]]; then
        printf 'CANNOT-VERIFY: the served-roots probe failed (rc=%s) — this is NOT "nothing undeclared"\n' "$rc"
        return 3
    fi
    printf '%s\n' "$out"
    return 0
}

# ---------------------------------------------------------------------------
# Capture parsing.
#
# Populates, in the caller's scope:
#   SR_SERVER_ROOTS[]  "path|server_names"   docroot of a server{} block
#   SR_LOC_ROOTS[]     "path|server_names"   root inside a location{} — an ACME
#                                            stub or similar, NOT a site docroot
#   SR_DIRS[]          "parent/entry"        trees present on disk
#   SR_UNREADABLE[]    paths we could not read
#   SR_FILES           count of config files read
#   SR_MASTER, SR_CONFIG
#
# nginx nesting is per-file: a server{} sits at depth 1 inside http{} in
# nginx.conf but at depth 0 in an included vhost. We therefore never test an
# absolute depth — we record the depth at which each server{} opened and treat
# a root exactly one level inside it as that server's docroot.
# ---------------------------------------------------------------------------
served_roots_parse() {
    local capture="$1"
    SR_SERVER_ROOTS=(); SR_LOC_ROOTS=(); SR_DIRS=(); SR_UNREADABLE=()
    SR_FILES=0; SR_MASTER="no"; SR_CONFIG=""

    local line body depth=0 in_server=0 sdepth=-1 names="" cur_dir=""
    local -a pend_server=() pend_loc=()

    _sr_flush() {
        local r
        for r in "${pend_server[@]:-}"; do
            [ -n "$r" ] && SR_SERVER_ROOTS+=("${r}|${names}")
        done
        for r in "${pend_loc[@]:-}"; do
            [ -n "$r" ] && SR_LOC_ROOTS+=("${r}|${names}")
        done
        pend_server=(); pend_loc=(); names=""
    }

    while IFS= read -r line; do
        case "$line" in
            "NWPROOTS "*) continue ;;
            "master="*)   SR_MASTER="${line#master=}"; continue ;;
            "config="*)   SR_CONFIG="${line#config=}"; continue ;;
            "readmode="*) continue ;;
            "unreadable="*) SR_UNREADABLE+=("${line#unreadable=}"); continue ;;
            "file="*)
                # A new file resets nesting state; an unterminated block in one
                # file must not leak into the next.
                [ "$in_server" -eq 1 ] && _sr_flush
                depth=0; in_server=0; sdepth=-1; names=""
                SR_FILES=$((SR_FILES + 1)); cur_dir=""
                continue ;;
            "dirlist="*)  cur_dir="${line#dirlist=}"; continue ;;
            "D"*)
                [ -n "$cur_dir" ] && SR_DIRS+=("${cur_dir}/${line#D}")
                continue ;;
            "L"*) body="${line#L}" ;;
            *) continue ;;
        esac

        local depth_before=$depth

        # Enter a server block. `server {` — never `server_name`, never the
        # `server` inside an upstream block (that has no brace).
        if [ "$in_server" -eq 0 ] && [[ "$body" =~ (^|[^_[:alnum:]])server[[:space:]]*\{ ]]; then
            in_server=1; sdepth=$depth_before; names=""
            pend_server=(); pend_loc=()
        fi

        if [ "$in_server" -eq 1 ]; then
            if [[ "$body" =~ server_name[[:space:]]+([^;]+) ]]; then
                local got="${BASH_REMATCH[1]}"
                names="${names:+$names }$(printf '%s' "$got" | tr -s ' ' ' ' | sed 's/^ *//;s/ *$//')"
            fi
            if [[ "$body" =~ (^|[[:space:]{])root[[:space:]]+([^;[:space:]]+) ]]; then
                local rp="${BASH_REMATCH[2]}"
                # A root is this server's docroot only when it sits exactly one
                # level inside the server block. Deeper — or on a single line
                # that opens a location before the root — it is a location root
                # (the `location ^~ /.well-known/acme-challenge/ { root ... }`
                # ACME stub in rgv.conf and hs.conf is exactly this).
                if [[ "$body" =~ location.*\{.*root ]] || [ "$depth_before" -gt $((sdepth + 1)) ]; then
                    pend_loc+=("$rp")
                else
                    pend_server+=("$rp")
                fi
            fi
        fi

        local opens closes
        opens=$(printf '%s' "$body" | tr -cd '{' | wc -c)
        closes=$(printf '%s' "$body" | tr -cd '}' | wc -c)
        depth=$((depth + opens - closes))

        if [ "$in_server" -eq 1 ] && [ "$depth" -le "$sdepth" ]; then
            _sr_flush
            in_server=0; sdepth=-1
        fi
    done <<< "$capture"

    [ "$in_server" -eq 1 ] && _sr_flush
    unset -f _sr_flush
    return 0
}

# ---------------------------------------------------------------------------
# Declaration loading — yq only (ADR-0015). Populates SR_DECL[] as
# "name|path|domain|gated|source".
#
# A declaration is attributed to <server> when it names the server, names its
# IP, or its declared domain is one this box answers on. Note we deliberately
# do NOT attribute by path match: that would be circular with the very
# reconciliation we are about to perform.
# ---------------------------------------------------------------------------
served_roots_declarations() {
    local server="$1" root="$2" served_names="$3"
    local yq="${YQ:-yq}"
    SR_DECL=()

    local ip=""
    if declare -F get_server_ip >/dev/null 2>&1; then
        ip="$(get_server_ip "$server" 2>/dev/null || true)"
    fi

    # The two inventories are MERGED per site name, not stacked. The global
    # nwp.yml entry for a site frequently carries `live.enabled` and a domain
    # but no `remote_path` (the path lives in the per-site config). Treating the
    # global entry as authoritative and skipping the per-site one therefore
    # produced a declaration with an EMPTY path, which then failed to cover its
    # own served root — avc, cathnet, dir1 and mt were all reported as
    # UNDECLARED-ROOT while being perfectly well declared. A gate that cries
    # wolf on four of the estate's main sites is a gate nobody reads.
    local -A d_path=() d_domain=() d_srv=() d_ip=() d_src=() d_live=()
    local name cfg enabled srv srv_ip domain rpath directory

    local gcfg="$root/nwp.yml"
    if [ -f "$gcfg" ]; then
        while IFS= read -r name; do
            [ -n "$name" ] || continue
            enabled=$(n="$name" "$yq" -r '.sites[strenv(n)].live.enabled // ""' "$gcfg" 2>/dev/null)
            srv=$(n="$name" "$yq" -r '.sites[strenv(n)].live.server // ""' "$gcfg" 2>/dev/null)
            srv_ip=$(n="$name" "$yq" -r '.sites[strenv(n)].live.server_ip // ""' "$gcfg" 2>/dev/null)
            domain=$(n="$name" "$yq" -r '.sites[strenv(n)].live.domain // ""' "$gcfg" 2>/dev/null)
            rpath=$(n="$name" "$yq" -r '.sites[strenv(n)].live.remote_path // ""' "$gcfg" 2>/dev/null)
            directory=$(n="$name" "$yq" -r '.sites[strenv(n)].directory // ""' "$gcfg" 2>/dev/null)
            # A `directory:` is only a live docroot when it is a server path.
            # For most sites it is the local checkout under $HOME.
            [ -z "$rpath" ] && case "$directory" in /var/*|/srv/*) rpath="$directory" ;; esac
            [ "$enabled" = "true" ] || [ -n "$rpath" ] || continue
            d_path["$name"]="$rpath"; d_domain["$name"]="$domain"
            d_srv["$name"]="$srv";    d_ip["$name"]="$srv_ip"
            d_src["$name"]="nwp.yml"; d_live["$name"]="$enabled"
        done < <("$yq" -r '.sites // {} | keys | .[]' "$gcfg" 2>/dev/null)
    fi

    for cfg in "$root"/sites/*/.nwp.yml; do
        [ -f "$cfg" ] || continue
        name="$(basename "$(dirname "$cfg")")"
        srv=$("$yq" -r '.live.server // ""' "$cfg" 2>/dev/null)
        srv_ip=$("$yq" -r '.live.server_ip // ""' "$cfg" 2>/dev/null)
        domain=$("$yq" -r '.live.domain // ""' "$cfg" 2>/dev/null)
        rpath=$("$yq" -r '.live.remote_path // ""' "$cfg" 2>/dev/null)
        if [ -n "${d_path[$name]+x}" ]; then
            # Merge: the per-site config wins for any field it actually sets.
            [ -n "$rpath" ]  && d_path["$name"]="$rpath"
            [ -n "$domain" ] && d_domain["$name"]="$domain"
            [ -n "$srv" ]    && d_srv["$name"]="$srv"
            [ -n "$srv_ip" ] && d_ip["$name"]="$srv_ip"
            d_src["$name"]="nwp.yml + sites/${name}/.nwp.yml"
        else
            [ -n "$rpath" ] || continue
            d_path["$name"]="$rpath"; d_domain["$name"]="$domain"
            d_srv["$name"]="$srv";    d_ip["$name"]="$srv_ip"
            d_src["$name"]="sites/${name}/.nwp.yml"; d_live["$name"]="true"
        fi
    done

    # Attribute to this server, and record gating.
    local gated
    for name in "${!d_path[@]}"; do
        if   [ "${d_srv[$name]}" = "$server" ]; then :
        elif [ -n "$ip" ] && [ "${d_ip[$name]}" = "$ip" ]; then :
        elif [ -n "${d_domain[$name]}" ] && [[ " $served_names " == *" ${d_domain[$name]} "* ]]; then :
        else continue
        fi
        gated=no
        [ -f "$root/sites/$name/.nwp.yml" ] && gated=yes
        SR_DECL+=("${name}|${d_path[$name]}|${d_domain[$name]}|${gated}|${d_src[$name]}")
    done

    return 0
}

# A served root is covered by a declaration when the declared path IS the root
# or is an ANCESTOR of it. avc really is declared as /var/www/avc and really is
# served from /var/www/avc/html; string equality would emit a false
# UNDECLARED-ROOT, and a gate that cries wolf is a gate people learn to ignore
# — which is how the hand-maintained list came to be trusted in the first place.
served_roots_covered_by() {
    local rootpath="$1" declpath="$2"
    [ -n "$declpath" ] || return 1
    declpath="${declpath%/}"
    [ "$rootpath" = "$declpath" ] && return 0
    [[ "$rootpath" == "$declpath"/* ]] && return 0
    return 1
}
