#!/usr/bin/env python3
"""Derive the EXACT package set carrying a security advisory, from
`composer audit --locked --format=json` on stdin. One name per line.

    exit 0  the document was understood; 0+ package names printed
    exit 2  CANNOT VERIFY — the document could not be understood. NOT "clean".

See lib/security-scope.sh for the why. Kept as its own file (like
lib/rag-render.py and lib/audit-record.py) rather than a heredoc inside the
shell function, because `python3 - <<'PY'` puts the PROGRAM on stdin and so
leaves sys.stdin.read() empty — every input then looked like "the audit did not
run". That bug made four fail-closed tests pass for the wrong reason, which is
the blind-negation shape CLAUDE.md warns about: they asserted exit 2, and got
exit 2, but never from the input they claimed to be testing.
"""
import sys, json, re


def cannot(msg):
    print("CANNOT VERIFY: %s" % msg)
    sys.exit(2)


def root_pinners(composer_json_path):
    """Read `composer why <pkg>` output on stdin; print the requirers that are
    ROOT REQUIREMENTS of this project.

    WHY THIS SECOND MODE EXISTS. Naming the advisory package is not enough to
    update it. On a real site, `composer update drupal/core --with-dependencies` reported
    "Nothing to modify in lock file" and exited 0 — a completely silent no-op —
    because drupal/core is pinned to an exact version by drupal/core-recommended,
    which is a ROOT requirement and so is never touched unless it is named:

        drupal/core-recommended 10.6.12 requires drupal/core (10.6.12)

    So the scoped update ran, changed nothing, and the advisory count stayed at
    15. That is the same swallowed-verdict shape as an unreadable audit, one
    layer down: the command succeeded at doing nothing.

    The fix stays derived-from-measurement rather than a `drupal/core-recommended`
    special case: ask composer who requires the package, and update any of those
    that the project itself requires. That generalises to any metapackage
    (drupal/core-recommended, symfony/symfony, a distro profile) without anyone
    having to predict it.
    """
    try:
        root = json.load(open(composer_json_path))
    except Exception as e:
        cannot("cannot read root requirements from %s (%s)" % (composer_json_path, e))
    reqs = set(root.get("require", {})) | set(root.get("require-dev", {}))
    if not reqs:
        cannot("%s declares no 'require' block — root requirements unknown"
               % composer_json_path)

    raw = sys.stdin.read()
    # `composer why` prints:  <requirer> <version> requires <pkg> (<constraint>)
    LINE = re.compile(
        r"^\s*([A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*)"
        r"\s+\S+\s+requires\s+\S+\s+\(([^)]*)\)")

    # ONLY EXACT PINS. Being a root requirement is not enough to be a blocker:
    # on a real Drupal site ~200 packages require drupal/core, and a dozen of
    # them are root requirements with constraints like "^9.5 || ^10 || ^11".
    # Those admit the fixed version already — naming them updates packages that
    # were never in the way, which is the blanket update by the back door. The
    # first cut of this rule did exactly that: it grew a scoped update from
    # 6 packages to 17, dragging in drupal/webform 6.2.10 => 6.3.0 for a Guzzle
    # advisory.
    #
    # An EXACT constraint ("10.6.12", "1.19.0", "3.0.0-beta4") is the one that
    # genuinely pins, and it is the shape a metapackage uses:
    #     drupal/core-recommended 10.6.12 requires drupal/core (10.6.12)
    #     a frozen site profile  0.3.1   requires drupal/paragraphs (1.19.0)
    EXACT = re.compile(r"^v?\d+(?:\.\d+)*(?:[-+][0-9A-Za-z.-]+)?$")

    out = []
    for line in raw.splitlines():
        m = LINE.match(line)
        if not m:
            continue
        requirer, constraint = m.group(1), m.group(2).strip()
        if requirer in reqs and EXACT.match(constraint) and requirer not in out:
            out.append(requirer)
    for n in sorted(out):
        print(n)
    return 0


def main():
    if "--requirers" in sys.argv:
        i = sys.argv.index("--root-json")
        return root_pinners(sys.argv[i + 1])

    raw = sys.stdin.read()

    if not raw.strip():
        cannot("composer audit produced no output at all — the audit did not run")

    # composer/ddev often prepend human text to, or emit instead of, the JSON.
    # Take the first {...} block if the whole thing does not parse; if neither
    # works, that is a measurement we failed to take, not an empty result.
    doc = None
    try:
        doc = json.loads(raw)
    except Exception:
        m = re.search(r"\{.*\}", raw, re.S)
        if m:
            try:
                doc = json.loads(m.group(0))
            except Exception:
                doc = None
    if doc is None:
        cannot("composer audit output is not JSON (first 120 chars: %r)" % raw[:120].strip())

    if not isinstance(doc, dict) or "advisories" not in doc:
        # {} parses fine. Parseability is not comprehension: a schema change
        # upstream must surface as "I no longer understand this", never "clean".
        cannot("composer audit JSON has no 'advisories' key — schema not understood, "
               "so an empty package list would be a guess")

    adv = doc["advisories"]
    if not isinstance(adv, dict):
        cannot("'advisories' is %s, expected an object" % type(adv).__name__)

    # These names are interpolated into a composer command line. Anything that
    # is not a plain vendor/package is refused outright rather than quoted and
    # hoped for — a branch that "handles" odd input is how injection survives.
    SAFE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$")
    names = sorted(adv.keys())
    bad = [n for n in names if not SAFE.match(n)]
    if bad:
        cannot("refusing package name(s) that are not vendor/package: %r" % bad[:3])

    for n in names:
        print(n)
    return 0


if __name__ == "__main__":
    sys.exit(main())
