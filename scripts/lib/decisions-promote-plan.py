#!/usr/bin/env python3
"""The pure planner behind `pl decisions promote` (ops#305, ruling A).

stdin:  JSON {"description": str, "labels": [str], "gate": str}
stdout: JSON {"already_promoted": bool, "needs_label": bool,
              "new_description": str|null}

Rules, in the order they protect things:
  - An existing ``## Decision`` block is NEVER rewritten — the verb makes
    promotion cheap, it does not take over authorship of a question somebody
    already wrote.
  - A blockless issue gets the scaffold PREPENDED and the original description
    kept in full below a rule — the diagnosis stays with the issue.
  - ``--block-file`` supplies a real block instead of the TODO scaffold; it
    must itself start with ``## Decision``, because silently accepting prose
    would recreate the unreadable-red-entry problem the verb exists to solve.
  - Already labelled + already blocked reports ``already_promoted`` so the
    caller can say "nothing to do" instead of writing a no-op to the tracker.

Pure by design: no network, no clock, no environment — the same testability
seam as decisions-render.py.
"""
import json
import re
import sys

NEEDS_LABEL = "needs-decision"

SCAFFOLD = """## Decision

**Gate:** {gate}

**What:** TODO — one sentence: what is being chosen, in plain language.

**Options:**
- **A. TODO.** What it is; its cost.
- **B. TODO.** What it is; its cost.

**Recommend:** TODO — which option and why.

**Unblocks:** TODO — what can proceed once this is answered.
"""


def has_block(description: str) -> bool:
    return re.search(r"^## Decision\b", description or "", re.MULTILINE) is not None


def main() -> int:
    blockfile = None
    for arg in sys.argv[1:]:
        if arg.startswith("--block-file="):
            blockfile = arg.split("=", 1)[1]
        else:
            print(f"unknown argument: {arg}", file=sys.stderr)
            return 2

    payload = json.load(sys.stdin)
    description = payload.get("description") or ""
    labels = payload.get("labels") or []
    gate = payload.get("gate") or "shapes-design"

    block = None
    if blockfile is not None:
        with open(blockfile, encoding="utf-8") as fh:
            block = fh.read()
        if not block.lstrip().startswith("## Decision"):
            print("REFUSED: --block-file must contain a '## Decision' block — "
                  "prose here would produce exactly the unreadable red entry "
                  "this verb exists to prevent.", file=sys.stderr)
            return 1

    labelled = NEEDS_LABEL in labels
    blocked = has_block(description)

    new_description = None
    if not blocked:
        head = block if block is not None else SCAFFOLD.format(gate=gate)
        new_description = head.rstrip() + "\n\n---\n\n" + description

    print(json.dumps({
        "already_promoted": labelled and blocked,
        "needs_label": not labelled,
        "new_description": new_description,
    }))
    return 0


if __name__ == "__main__":
    sys.exit(main())
