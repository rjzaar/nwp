#!/usr/bin/env bats
# lib/server-assets.sh — `pl server assets` (static image-host handover, 2026-08-22).
#
# WHY THIS VERB EXISTS
# --------------------
# `pl server vhost --create` writes the nginx server block for a declared root.
# Nothing then put CONTENT in that root, so the handover's Step 1 was:
#
#     rsync … gitlab@<box>:/tmp/summit-2026/
#     ssh … 'sudo cp /tmp/summit-2026/*.png /var/www/img/summit-2026/ && sudo chown …'
#
# which is the scp + sudo cp idiom CLAUDE.md names as FORBIDDEN and which
# already caused one recorded live violation (ops#149, 2026-07-28). A verb that
# creates a docroot and cannot fill it just relocates the hand-run step.
#
# Everything here runs against LOCAL fixtures. The plan is computed from a
# measured inventory of the target, never assumed — so the whole thing is
# provable with no ssh and no box.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TMP="$(mktemp -d)"
  SRC="${TMP}/src"
  mkdir -p "${SRC}/summit-2026"
  printf 'PNGDATA-one'   > "${SRC}/summit-2026/a.png"
  printf 'PNGDATA-two'   > "${SRC}/summit-2026/b.png"
  source "${REPO_ROOT}/lib/server-assets.sh"
}

teardown() { rm -rf "${TMP}"; }

# ── the target root is validated before anything is sent ────────────────────

@test "a relative or metacharacter-bearing root is REFUSED" {
  # This path is interpolated into a remote script that runs under sudo. A root
  # carrying `;` or `..` would run arbitrary commands as root on the box that
  # serves GitLab.
  run assets_validate_root 'var/www/img'
  [ "$status" -eq 2 ]
  [[ "$output" == *"REFUSED"* ]]

  run assets_validate_root '/var/www/img; rm -rf /'
  [ "$status" -eq 2 ]
  [[ "$output" == *"REFUSED"* ]]

  run assets_validate_root '/var/www/../etc'
  [ "$status" -eq 2 ]
  [[ "$output" == *"REFUSED"* ]]

  run assets_validate_root ''
  [ "$status" -eq 2 ]
  [[ "$output" == *"REFUSED"* ]]
}

@test "a plain absolute root is accepted" {
  run assets_validate_root '/var/www/img'
  [ "$status" -eq 0 ]
}

@test "the root / is REFUSED however it is spelled" {
  # chown -R www-data / is not a recoverable mistake.
  run assets_validate_root '/'
  [ "$status" -eq 2 ]
  run assets_validate_root '/var'
  [ "$status" -eq 2 ]
  [[ "$output" == *"REFUSED"* ]]
}

# ── the local inventory ─────────────────────────────────────────────────────

@test "the local inventory lists every file with its size and digest" {
  run assets_local_inventory "${SRC}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"summit-2026/a.png"* ]]
  [[ "$output" == *"summit-2026/b.png"* ]]
  # size and sha256 are what make the plan a measurement rather than a guess
  [[ "$output" == *"11"* ]]
  local sha; sha=$(sha256sum "${SRC}/summit-2026/a.png" | cut -d' ' -f1)
  [[ "$output" == *"${sha}"* ]]
}

@test "an empty source directory is REFUSED, not silently a no-op push" {
  mkdir -p "${TMP}/empty"
  run assets_local_inventory "${TMP}/empty"
  [ "$status" -eq 2 ]
  [[ "$output" == *"REFUSED"* ]]
  [[ "$output" == *"no files"* ]]
}

@test "a source that does not exist is REFUSED" {
  run assets_local_inventory "${TMP}/nope"
  [ "$status" -eq 2 ]
  [[ "$output" == *"REFUSED"* ]]
}

# ── the plan is a DIFF against measured remote state ────────────────────────

@test "a file absent on the target is planned as NEW" {
  local_inv=$(assets_local_inventory "${SRC}")
  run assets_plan "$local_inv" ""          # target inventory empty = nothing there
  [ "$status" -eq 0 ]
  [[ "$output" == *"NEW       summit-2026/a.png"* ]]
  [[ "$output" == *"NEW       summit-2026/b.png"* ]]
}

@test "a byte-identical file is planned as UNCHANGED and is not resent" {
  local_inv=$(assets_local_inventory "${SRC}")
  run assets_plan "$local_inv" "$local_inv"
  [ "$status" -eq 0 ]
  [[ "$output" == *"UNCHANGED summit-2026/a.png"* ]]
  [[ "$output" != *"NEW "* ]]
  [[ "$output" != *"REPLACE"* ]]
}

@test "a file whose digest differs is planned as REPLACE — the cache-busting warning case" {
  # Publishing a different image under the SAME name leaves browsers holding the
  # old one for the whole Cache-Control window. The plan must say so out loud
  # rather than quietly overwriting.
  local_inv=$(assets_local_inventory "${SRC}")
  remote_inv=$(printf '%s\n' "$local_inv" | sed 's/^\([^ ]*\) \([^ ]*\) /\1 deadbeef /')
  run assets_plan "$local_inv" "$remote_inv"
  [ "$status" -eq 0 ]
  [[ "$output" == *"REPLACE   summit-2026/a.png"* ]]
}

@test "a file present ONLY on the target is reported, never silently deleted" {
  local_inv=$(assets_local_inventory "${SRC}")
  remote_inv=$(printf '%s\n%s' "$local_inv" "999 abc123 summit-2026/orphan.png")
  run assets_plan "$local_inv" "$remote_inv"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ONLY-ON-TARGET"* ]]
  [[ "$output" == *"orphan.png"* ]]
  # This verb ADDS. It must never emit a delete the operator did not ask for.
  [[ "$output" != *"DELETE"* ]]
}

# ── the push script ─────────────────────────────────────────────────────────

@test "the push script creates the docroot, sets ownership and sane modes" {
  run assets_push_script /var/www/img www-data
  [ "$status" -eq 0 ]
  [[ "$output" == *"mkdir -p"* ]]
  [[ "$output" == *"/var/www/img"* ]]
  [[ "$output" == *"chown"* ]]
  [[ "$output" == *"www-data"* ]]
  [[ "$output" == *"755"* ]]
  [[ "$output" == *"644"* ]]
}

@test "the push script never deletes anything on the target" {
  run assets_push_script /var/www/img www-data
  [[ "$output" != *"rm -rf \"\$root\""* ]]
  [[ "$output" != *"--delete"* ]]
}

@test "END-TO-END: the push script actually lands the files, unpacked, from stdin" {
  # Drive the real script against a local directory with a `sudo` that just
  # execs. If this cannot place a file, the verb is decorative.
  mkdir -p "${TMP}/bin"
  cat > "${TMP}/bin/sudo" <<'EOF'
#!/usr/bin/env bash
while [ "${1#-}" != "$1" ]; do shift; done
exec "$@"
EOF
  # chown to a real group we are allowed to use; www-data may not exist here.
  chmod +x "${TMP}/bin/sudo"
  local dest="${TMP}/dest"
  local script; script="$(assets_push_script "${dest}" "$(id -un):$(id -gn)")"
  tar -C "${SRC}" -cf "${TMP}/payload.tar" .
  run bash -c "PATH='${TMP}/bin:$PATH'; $script" < "${TMP}/payload.tar"
  [ "$status" -eq 0 ]
  [ -f "${dest}/summit-2026/a.png" ]
  [ "$(cat "${dest}/summit-2026/a.png")" = "PNGDATA-one" ]
  # readable by the web server
  [ "$(stat -c '%a' "${dest}/summit-2026/a.png")" = "644" ]
  [ "$(stat -c '%a' "${dest}/summit-2026")" = "755" ]
}

@test "END-TO-END: an empty payload is REFUSED and the target is not touched" {
  mkdir -p "${TMP}/bin"
  cat > "${TMP}/bin/sudo" <<'EOF'
#!/usr/bin/env bash
while [ "${1#-}" != "$1" ]; do shift; done
exec "$@"
EOF
  chmod +x "${TMP}/bin/sudo"
  local dest="${TMP}/dest2"
  local script; script="$(assets_push_script "${dest}" "$(id -un):$(id -gn)")"
  run bash -c "PATH='${TMP}/bin:$PATH'; $script" < /dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *"REFUSED"* ]]
  # The refusal must come BEFORE the target is created, not after.
  [ ! -e "${dest}" ]
}

# ── the remote inventory probe is fixed and read-only ───────────────────────

@test "the inventory probe takes nothing from argv but the validated root" {
  run assets_inventory_script /var/www/img
  [ "$status" -eq 0 ]
  [[ "$output" == *"/var/www/img"* ]]
  [[ "$output" == *"sha256sum"* ]]
  # read-only: it must not be able to write
  [[ "$output" != *"mkdir"* ]]
  [[ "$output" != *"chown"* ]]
  [[ "$output" != *"rm "* ]]
}

@test "a target directory that does not exist yet reads as EMPTY, not as an error" {
  # A first push is the normal case: the docroot has never existed.
  mkdir -p "${TMP}/bin"
  cat > "${TMP}/bin/sudo" <<'EOF'
#!/usr/bin/env bash
while [ "${1#-}" != "$1" ]; do shift; done
exec "$@"
EOF
  chmod +x "${TMP}/bin/sudo"
  local script; script="$(assets_inventory_script "${TMP}/absent")"
  run bash -c "PATH='${TMP}/bin:$PATH'; $script"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ASSETSINV v1"* ]]
}

@test "an inventory that did not run is CANNOT VERIFY, never 'the target is empty'" {
  # Blindness must not become "everything is NEW", which would silently
  # overwrite a docroot the probe simply failed to read.
  run assets_parse_inventory "some junk that is not a v1 inventory"
  [ "$status" -eq 3 ]
  [[ "$output" == *"CANNOT VERIFY"* ]]
}

@test "a well-formed empty inventory really is empty" {
  run assets_parse_inventory "ASSETSINV v1"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a NON-EMPTY inventory survives parsing — the banner is stripped, the rows are not" {
  # REGRESSION (found on the live box, 2026-08-22, first re-run after a
  # successful push). The parser was `sed '1,/ASSETSINV v1/d'`. With the banner
  # on line 1 that range starts at line 1 and hunts for a SECOND match from line
  # 2 on; there is never a second banner, so sed deleted to end of file and
  # every inventory came back EMPTY.
  #
  # The damage that hides: an empty target inventory grades every file NEW, so
  # the verb re-pushed content that was already byte-identical and would have
  # reported a docroot full of files as untouched. Only the empty case was
  # tested, and the empty case passes either way — a check that could not fail.
  local raw
  raw=$'ASSETSINV v1\n101662 abc123 summit-2026/a.png\n434671 def456 summit-2026/b.png'
  run assets_parse_inventory "$raw"
  [ "$status" -eq 0 ]
  [[ "$output" == *"summit-2026/a.png"* ]]
  [[ "$output" == *"summit-2026/b.png"* ]]
  [[ "$output" == *"abc123"* ]]
  [[ "$output" != *"ASSETSINV"* ]]
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 2 ]
}

@test "REGRESSION: a pushed file is UNCHANGED on the next run, not NEW again" {
  # The end-to-end shape of the same bug: push, re-read, re-plan. If the parser
  # drops the rows, this says NEW and the verb never converges.
  local local_inv target_raw target_inv plan
  local_inv=$(assets_local_inventory "${SRC}")
  target_raw="ASSETSINV v1"$'\n'"${local_inv}"
  target_inv=$(assets_parse_inventory "$target_raw")
  plan=$(assets_plan "$local_inv" "$target_inv")
  [[ "$plan" == *"UNCHANGED summit-2026/a.png"* ]]
  [[ "$plan" != *"NEW "* ]]
  run assets_plan_counts "$plan"
  [ "$output" = "0 0 2 0" ]
}
