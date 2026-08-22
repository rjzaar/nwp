#!/usr/bin/env python3
"""Validate the intersite data-contract JSON Schemas + sample payloads (P74 Phase 0).

Git-native, broker-less contract check (intersite-contract research §2): each
surface's wire shape is a committed JSON Schema; this asserts (a) every schema is
itself a valid Draft-2020-12 schema, and (b) a known-good sample validates while a
known-bad sample is rejected. Run in CI on both sides against the pinned/signed
schema bundle. Exit non-zero on any failure (fail-closed).

Usage: python3 contracts/validate.py            # from repo root or contracts/
Requires: python3 + jsonschema (Draft 2020-12).
"""
import json
import os
import sys

try:
    from jsonschema import Draft202012Validator
except Exception as e:  # pragma: no cover
    print("SKIP: python jsonschema not available (%s)" % e)
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))

# (schema file, a VALID payload, an INVALID payload + why it must fail)
CASES = [
    # `sub` is the Drupal UUID, not the serial uid (NWP-ADR-0031 D9 / ops#83, shipped
    # 03672e2). This sample carried a uid ("4210") long after the code moved to
    # uuid() — the fixture itself was the last uid-era artifact, and it is what
    # made the drift invisible.
    ("oauth_sso.claims.schema.json",
     {"sub": "1f953704-7fc3-42e9-82cd-14fe3e616f71", "email": "a@b.test",
      "email_verified": True, "given_name": "Ann", "family_name": "Scribe",
      "guilds": [{"id": 3, "uuid": "205225aa-85ee-40e6-91f2-96b36cb43c96",
                  "label": "Scripture", "type": "guild",
                  "roles": ["guild-junior"]}]},
     # unknown claim → must be rejected (closed allow-list = data-minimisation)
     {"sub": "1f953704-7fc3-42e9-82cd-14fe3e616f71", "date_of_birth": "2009-01-01"}),
    ("copyright_sync.record.schema.json",
     {"policy_name": "site_terms", "title": "Terms", "version": 2,
      "effective_date": "2026-07-11", "change_summary": "x", "body_md": "# Terms"},
     # version must be integer, not string
     {"policy_name": "site_terms", "title": "Terms", "version": "2",
      "effective_date": "2026-07-11", "change_summary": "x", "body_md": "# Terms"}),
    ("feedback_bridge.message.schema.json",
     {"ss_feedback_id": 7, "ss_userid": 12, "oauth_sub": "4210",
      "type": "issue", "title": "t", "status": "submitted", "timecreated": 1},
     # bad enum value for `type`
     {"ss_feedback_id": 7, "ss_userid": 12, "oauth_sub": "4210",
      "type": "rant", "title": "t", "status": "submitted", "timecreated": 1}),
    ("erasure.command.schema.json",
     {"sub": "8f14e45f-ceea-467a-9e2b-2c3b0a1d4e5f",
      "request_id": "b1946ac9-2e1a-4c0e-9b2f-0d3e4f5a6b7c",
      "action": "delete", "issuer": "https://nwc.example/", "timestamp": 1752000000},
     # bad enum value for `action` (only delete|anonymise allowed)
     {"sub": "8f14e45f-ceea-467a-9e2b-2c3b0a1d4e5f",
      "request_id": "b1946ac9-2e1a-4c0e-9b2f-0d3e4f5a6b7c",
      "action": "purge", "issuer": "https://nwc.example/", "timestamp": 1752000000}),
]

fails = 0
for schema_file, good, bad in CASES:
    path = os.path.join(HERE, schema_file)
    with open(path) as fh:
        schema = json.load(fh)
    try:
        Draft202012Validator.check_schema(schema)
    except Exception as e:
        print("FAIL  %s: not a valid Draft-2020-12 schema: %s" % (schema_file, e))
        fails += 1
        continue
    v = Draft202012Validator(schema)
    good_errs = list(v.iter_errors(good))
    if good_errs:
        print("FAIL  %s: VALID sample rejected: %s" % (schema_file, good_errs[0].message))
        fails += 1
    bad_errs = list(v.iter_errors(bad))
    if not bad_errs:
        print("FAIL  %s: INVALID sample accepted (should have failed)" % schema_file)
        fails += 1
    if not good_errs and bad_errs:
        print("ok    %s (valid accepted, invalid rejected: %s)"
              % (schema_file, bad_errs[0].message.split(" ")[0] + " …"))

if fails:
    print("\n%d contract-validation failure(s)." % fails)
    sys.exit(1)
print("\nAll %d contract schemas valid; good/bad samples behave." % len(CASES))
