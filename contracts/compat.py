#!/usr/bin/env python3
"""P74 Phase 3 — expand-and-contract (BACKWARD) schema-compat checker.

Compares an OLD intersite data-contract JSON Schema to a NEW one and fails
(exit 1) when the change would break existing consumers/producers — i.e. it is
NOT backward-compatible under the expand-and-contract rule:

  BREAKING (fail):  a property removed · a type narrowed/changed · a new
                    required field · an enum value dropped · additionalProperties
                    tightened (true -> false).
  COMPATIBLE (ok):  adding OPTIONAL properties · widening an enum · adding an
                    enum value — the "expand" phase old consumers tolerate.

The check recurses through object `properties` and array `items`, so nested
shapes (e.g. `guilds[].id`) are covered. Pure stdlib — no jsonschema needed
(the sibling validate.py owns full schema validation; this only diffs shapes).

Usage:  python3 contracts/compat.py [--json] OLD.json NEW.json
Exit:   0 = backward-compatible · 1 = breaking · 2 = usage / parse error.
"""
import json
import sys


def _eff_addprops(schema):
    # Absent additionalProperties defaults to true (open) in JSON Schema.
    return schema.get("additionalProperties", True)


def _child(path, name):
    return name if not path else f"{path}.{name}"


def check(old, new, path, issues):
    """Append a human message to `issues` for each backward-incompatible change."""
    if not isinstance(old, dict) or not isinstance(new, dict):
        return
    label = path or "<root>"

    # Type change — treated as a narrowing (fail-closed; the gate is conservative).
    ot, nt = old.get("type"), new.get("type")
    if ot is not None and nt is not None and ot != nt:
        issues.append(f"{label}: type narrowed ({ot} -> {nt})")

    # Enum value(s) dropped (removing an allowed value breaks old data).
    if isinstance(old.get("enum"), list) and isinstance(new.get("enum"), list):
        dropped = [v for v in old["enum"] if v not in new["enum"]]
        if dropped:
            issues.append(f"{label}: enum value(s) dropped ({dropped})")

    # additionalProperties tightened (true -> false) rejects previously-valid docs.
    if _eff_addprops(old) is True and _eff_addprops(new) is False:
        issues.append(f"{label}: additionalProperties tightened (true -> false)")

    # New required property (old producers may not send it).
    oreq = set(old.get("required", []) or [])
    nreq = set(new.get("required", []) or [])
    for r in sorted(nreq - oreq):
        issues.append(f"{_child(path, r)}: new required property '{r}'")

    # Properties: removed → breaking; present → recurse.
    oprops = old.get("properties", {}) or {}
    nprops = new.get("properties", {}) or {}
    for name, oschema in oprops.items():
        cp = _child(path, name)
        if name not in nprops:
            issues.append(f"{cp}: property removed")
        elif isinstance(oschema, dict):
            check(oschema, nprops[name], cp, issues)

    # Array items: recurse (nested narrowing like guilds[].id).
    oi, ni = old.get("items"), new.get("items")
    if isinstance(oi, dict) and isinstance(ni, dict):
        check(oi, ni, f"{path}[]", issues)


def main(argv):
    as_json = False
    args = []
    for a in argv[1:]:
        if a == "--json":
            as_json = True
        else:
            args.append(a)
    if len(args) != 2:
        print("usage: compat.py [--json] OLD.json NEW.json", file=sys.stderr)
        return 2
    try:
        old = json.load(open(args[0]))
        new = json.load(open(args[1]))
    except Exception as e:  # parse / read error
        print(f"ERROR: cannot parse schema: {e}", file=sys.stderr)
        return 2

    issues = []
    check(old, new, "", issues)
    compatible = not issues

    if as_json:
        print(json.dumps({"compatible": compatible, "issues": issues}, indent=2))
    elif compatible:
        print("compatible: the new schema is backward-compatible with the old. ✓")
    else:
        print("BREAKING: the new schema is NOT backward-compatible with the old:")
        for i in issues:
            print(f"  - {i}")

    return 0 if compatible else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
