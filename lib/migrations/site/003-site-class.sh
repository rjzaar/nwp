#!/bin/bash
# lib/migrations/site/003-site-class.sh
#
# NWP-ADR-0036 / nwp/ops#153: add the per-site `class:` key — the third axis, beside
# `canonical:` (content flow) and `maturity:` (code flow). Class answers "what IS
# this site, and therefore which DATA invariants apply to it?"
#
# THIS MIGRATION DELIBERATELY GUESSES NOTHING.
#
# It adds the key as null and nothing else. Auto-classifying would be the exact
# failure this axis exists to prevent: writing `class: service` onto a Moodle
# site the migration has never looked inside is a machine asserting "this site
# has no members" on no evidence — and under NWP-ADR-0036 that assertion is what
# switches the Art.9 consent gate off. A null key is honest ("nobody has said
# yet") and fails closed everywhere it is consulted.
#
# The authoritative declaration is the TRACKED classes/<site>.class.yml. This key
# is the cross-check: if it is ever set and disagrees with the tracked file,
# siteclass_of() returns `contradictory:` and every consulting gate refuses.
# That is why the migration writes null rather than skipping the key entirely —
# an absent key is invisible, a null key is a visible unanswered question.
#
# shellcheck disable=SC2034  # functions sourced by migrate-schema.sh

migrate_002_to_003() {
    local site_dir="$1"
    local config="$2"

    local site_name
    site_name=$(basename "$site_dir")

    # Idempotent: if a class is already declared, leave it entirely alone.
    local existing
    existing=$(yq eval '.class // ""' "$config" 2>/dev/null)
    if [[ -n "$existing" && "$existing" != "null" ]]; then
        echo "  $site_name already declares class: $existing — left unchanged"
        yq eval -i '.schema_version = 3' "$config"
        return 0
    fi

    # Add the key as null — an unanswered question, not a default.
    yq eval -i '.class = null' "$config"

    # A comment the operator will actually see when they open the file.
    yq eval -i '.class line_comment = "NWP-ADR-0036: member-paired|member-standalone|demo|service — declare via `pl class set '"$site_name"' <class>`; authoritative copy is classes/'"$site_name"'.class.yml"' "$config" 2>/dev/null || true

    yq eval -i '.schema_version = 3' "$config"

    echo "  $site_name: added class: (unset — declare with 'pl class set $site_name <class>')"
    return 0
}
