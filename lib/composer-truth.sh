#!/bin/bash
################################################################################
# lib/composer-truth.sh — is the code on disk the code the lock says it is?
#
# ops#236. `pl audit` runs `composer audit --locked`, which reads composer.lock.
# The lock is a DECLARATION. The code that executes is `vendor/`.
#
# WHAT HAPPENED, 2026-08-02, during the guzzle remediation (ops#231). nwc's
# html/core was a dirty SOURCE install. composer refused to replace it, ABORTED
# mid-operation, and left composer.lock recording guzzle 7.15.2 while vendor/
# still held the vulnerable 7.12.3. `pl audit` would have read the lock and
# certified nwc CLEAN while the vulnerable library was the code actually running.
#
# THE DANGEROUS SHAPE, stated plainly: this is not a missing check. It is a
# PASSING check over the wrong artifact — the same family as the max_input_vars
# remedy applied to a SAPI Moodle never uses, and the stick backup that
# faithfully captured the wrong host. A red result gets investigated; a green one
# ends the conversation.
#
# It matters more now than it did: an auto-fix loop consuming this signal would
# close security findings on sites still running vulnerable code.
#
# `vendor/composer/installed.json` is the on-disk truth — composer writes it as
# the final step of an install, so a divergence from the lock is itself a
# FINDING: it means an install aborted, or someone edited vendor/ by hand.
#
# Pure: reads two files, prints findings, returns 1 when they disagree. No
# network, no ddev, no composer binary — so it can be exercised on fixtures.
################################################################################

# _ct_py — the JSON reading is done in python3 because composer's files are
# large and deeply nested, and a shell/regex reader of a JSON document is how a
# checker comes to disagree with the thing it is checking.
_ct_have_python(){ command -v python3 >/dev/null 2>&1; }

# composer_truth_compare <composer.lock> <vendor/composer/installed.json>
#
# Prints one line per divergence:
#     VERSION  <pkg>  lock=<v>  vendor=<v>
#     MISSING  <pkg>  lock=<v>  vendor=absent
#     EXTRA    <pkg>  lock=absent  vendor=<v>
#
# Exit codes — three answers, never two:
#   0  lock and vendor agree on every package
#   1  they DIVERGE (findings printed)
#   2  CANNOT VERIFY — a file is missing/unreadable, or python3 is absent
#
# 2 is not 0. A site whose vendor tree cannot be read has not been checked, and
# reporting that as agreement is the same vacuous pass this file exists to end.
composer_truth_compare() {
    local lock="${1:-}" installed="${2:-}"
    if ! _ct_have_python; then
        echo "CANNOT-VERIFY  python3 is not available to read composer's JSON"
        return 2
    fi
    if [ ! -r "$lock" ]; then
        echo "CANNOT-VERIFY  composer.lock not readable at: ${lock:-<unset>}"
        return 2
    fi
    if [ ! -r "$installed" ]; then
        echo "CANNOT-VERIFY  vendor/composer/installed.json not readable at: ${installed:-<unset>}"
        echo "               (no vendor tree = nothing was verified, NOT 'nothing wrong')"
        return 2
    fi

    local out rc=0
    out=$(python3 - "$lock" "$installed" <<'PY'
import json, sys

def load(path):
    with open(path, encoding='utf-8') as fh:
        return json.load(fh)

try:
    lock = load(sys.argv[1])
    inst = load(sys.argv[2])
except Exception as e:                      # noqa: BLE001 - any parse failure is "cannot verify"
    print("CANNOT-VERIFY  %s" % e)
    sys.exit(2)

def pkgmap(entries):
    out = {}
    for p in entries or []:
        n, v = p.get("name"), p.get("version")
        if n and v:
            out[n] = v
    return out

lock_pkgs = {}
lock_pkgs.update(pkgmap(lock.get("packages")))
lock_pkgs.update(pkgmap(lock.get("packages-dev")))

# installed.json is a bare list in composer 1.x and {"packages": [...]} in 2.x.
inst_raw = inst.get("packages") if isinstance(inst, dict) else inst
inst_pkgs = pkgmap(inst_raw)

findings = []
for name in sorted(set(lock_pkgs) | set(inst_pkgs)):
    lv, iv = lock_pkgs.get(name), inst_pkgs.get(name)
    if lv and iv and lv != iv:
        findings.append("VERSION  %-44s lock=%-16s vendor=%s" % (name, lv, iv))
    elif lv and not iv:
        findings.append("MISSING  %-44s lock=%-16s vendor=absent" % (name, lv))
    elif iv and not lv:
        findings.append("EXTRA    %-44s lock=absent          vendor=%s" % (name, iv))

for f in findings:
    print(f)
sys.exit(1 if findings else 0)
PY
    ) || rc=$?
    [ -n "$out" ] && printf '%s\n' "$out"
    return "$rc"
}

# composer_truth_paths <project_root> — echo "<lock> <installed.json>" for the
# usual Drupal/composer layout, so callers do not each invent the paths.
composer_truth_paths() {
    local root="${1%/}"
    printf '%s %s' "${root}/composer.lock" "${root}/vendor/composer/installed.json"
}
