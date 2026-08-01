#!/bin/bash
# tests/fixtures/mbz/make-mbz.sh — build a tiny fixture .mbz (tgz flavour, the
# shape the 2026-07-11 ss export set actually uses) containing just a
# moodle_backup.xml, for `pl moodle course restore` unit tests.
#
#   make-mbz.sh <out.mbz> <shortname> <users-mode>
#     users-mode: 0        users=0, anonymize=0   (the shippable shape)
#                 1        users=1, anonymize=0   (PII — must be refused)
#                 missing  no `users` setting     (unprovable — must be refused)
#                 anon     users=1, anonymize=1   (anonymised — allowed)
#
# The XML mirrors the real structure closely enough for the verb's parser:
# root-level <setting> blocks and <original_course_shortname> inside
# <information>, matching a verified real backup from
# sites/ss/backups/course-mbz-2026-07-11/.
set -euo pipefail

out="$1"; sn="$2"; mode="${3:-0}"

users_xml='<setting><level>root</level><name>users</name><value>0</value></setting>'
anon_xml='<setting><level>root</level><name>anonymize</name><value>0</value></setting>'
case "$mode" in
    0)       ;;
    1)       users_xml='<setting><level>root</level><name>users</name><value>1</value></setting>' ;;
    missing) users_xml='' ;;
    anon)    users_xml='<setting><level>root</level><name>users</name><value>1</value></setting>'
             anon_xml='<setting><level>root</level><name>anonymize</name><value>1</value></setting>' ;;
    *) echo "unknown users-mode: $mode" >&2; exit 2 ;;
esac

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/moodle_backup.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<moodle_backup>
  <information>
    <name>$(basename "$out")</name>
    <moodle_version>2024042212.01</moodle_version>
    <moodle_release>4.4.12+ (Build: 20251212)</moodle_release>
    <backup_version>2024042200</backup_version>
    <original_wwwroot>https://fixture.example.org</original_wwwroot>
    <original_course_id>10</original_course_id>
    <original_course_format>topics</original_course_format>
    <original_course_fullname>Fixture course ${sn}</original_course_fullname>
    <original_course_shortname>${sn}</original_course_shortname>
    <settings>
      <setting><level>root</level><name>filename</name><value>$(basename "$out")</value></setting>
      ${users_xml}
      ${anon_xml}
      <setting><level>root</level><name>role_assignments</name><value>0</value></setting>
    </settings>
  </information>
</moodle_backup>
EOF

tar -C "$tmp" -czf "$out" moodle_backup.xml
