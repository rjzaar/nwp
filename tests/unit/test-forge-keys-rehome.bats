#!/usr/bin/env bats
#
# tests/unit/test-forge-keys-rehome.bats — `pl forge keys rehome`, the ops#331
# migration verb, plus the write half of the application plane (NWP-ADR-0038
# §Migration step 3: `pl forge keys|user|members`).
#
# THE DEFECT THIS GUARDS
# ----------------------
# GitLab user `root` (id 1) carries THREE SSH keys, and each one is a machine:
# the dev workstation (titled, misleadingly, "NWP Backup Key"), met, and mini.
# Every push from all three is indistinguishable from the forge superuser's.
# Moving them is the remediation — and the move itself is the dangerous part,
# because of a property MEASURED on this instance on 2026-08-11:
#
#   POST /users/mini/keys with a blob already on user root returns
#     {"message":{"fingerprint_sha256":["has already been taken"]}}
#
# GitLab enforces SSH-key uniqueness INSTANCE-WIDE. So "add to the new home,
# confirm, then delete from root" — the obviously safe order, and the order
# ops#331's own remediation note prescribes — IS NOT AVAILABLE. A rehome is
# necessarily DELETE-then-ADD, with a window in which the key authenticates to
# no account at all. Everything in this file is about that window:
#
#   [W1] Nothing is deleted until the destination has been PROVEN to exist and
#        a restorable backup has been written.
#   [W2] The window contains exactly two API calls — DELETE then ADD — with no
#        prompting, no resolution and no file I/O between them.
#   [W3] Any failure inside the window ROLLS BACK by re-adding to the source,
#        and says it rolled back.
#   [W4] A rollback that itself fails SCREAMS: the backup path and the exact
#        `pl` command that repairs it by hand, never a bare non-zero exit.
#   [W5] "The ADD reported success" is not evidence. The target's key list is
#        re-read and the FINGERPRINT matched; a lying 201 is a failure.
#
# WHY IT IS ALL MOCKED. The live forge is the estate's only GitLab; a test that
# deleted a real key to prove the rollback works would be the incident it is
# meant to prevent. `curl` is shadowed by a stub on PATH implementing just
# enough of the GitLab API — including its uniqueness rule — with failure
# injection knobs. Every case below therefore runs offline, on every host, with
# no credential, and CAN fail: the red run is in the MR description.
#
# The keys are real ed25519 keys generated in setup_file, so the fingerprints
# the verb computes are computed by ssh-keygen from the blob, exactly as they
# are against the real API (the API does not return a fingerprint on this
# endpoint — ops#331's mapping comment had to compute them the same way).

setup_file() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  export REPO_ROOT
  # Three real keys: workstation, met, mini — the ops#331 cast.
  local n
  for n in ws met mini spare; do
    ssh-keygen -q -t ed25519 -N '' -C "${n}@fixture" -f "${BATS_FILE_TMPDIR}/${n}" </dev/null
  done
}

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  FORGE="${REPO_ROOT}/scripts/commands/forge.sh"
  TMP="${BATS_TEST_TMPDIR}"

  # ── the fake forge ───────────────────────────────────────────────────────
  export FAKE="${TMP}/forge-state"; mkdir -p "$FAKE"
  export REQ_LOG="${FAKE}/requests.log"; : > "$REQ_LOG"
  export ARGV_LOG="${FAKE}/argv.log";    : > "$ARGV_LOG"

  # users.tsv: id <TAB> username
  printf '1\troot\n7\tmini\n11\trjzaar\n38\tnwp-forge-admin\n' > "${FAKE}/users.tsv"
  # root holds the three machine keys, exactly as measured 2026-08-10.
  {
    printf '1\tNWP Backup Key\t%s\n'    "$(cat "${BATS_FILE_TMPDIR}/ws.pub")"
    printf '3\tmetabox (Carlo)\t%s\n'   "$(cat "${BATS_FILE_TMPDIR}/met.pub")"
    printf '4\tnwp-agent-loop@mini\t%s\n' "$(cat "${BATS_FILE_TMPDIR}/mini.pub")"
  } > "${FAKE}/keys-1.tsv"
  : > "${FAKE}/keys-7.tsv"
  : > "${FAKE}/keys-11.tsv"
  : > "${FAKE}/keys-38.tsv"
  printf '9\n' > "${FAKE}/next-key-id"

  export FP_WS FP_MET FP_MINI
  FP_WS="$(ssh-keygen -lf "${BATS_FILE_TMPDIR}/ws.pub"   | awk '{print $2}')"
  FP_MET="$(ssh-keygen -lf "${BATS_FILE_TMPDIR}/met.pub"  | awk '{print $2}')"
  FP_MINI="$(ssh-keygen -lf "${BATS_FILE_TMPDIR}/mini.pub" | awk '{print $2}')"

  export STUBBIN="${TMP}/bin"; mkdir -p "$STUBBIN"
  cat > "${STUBBIN}/curl" <<'STUB'
#!/usr/bin/env bash
# A very small GitLab: users, user SSH keys (with INSTANCE-WIDE uniqueness),
# memberships, and /application/settings. Failure injection via FAKE_* env.
printf '%s\n' "$*" >> "$ARGV_LOG"
method=GET; url=""; body_file=""; cfg=""
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  case "${args[$i]}" in
    -X) method="${args[$((i+1))]}" ;;
    -K) cfg="${args[$((i+1))]}" ;;
    --data-binary) body_file="${args[$((i+1))]#@}" ;;
    https://*) url="${args[$i]}" ;;
  esac
done
printf '%s %s\n' "$method" "$url" >> "$REQ_LOG"
# The token must arrive in the 0600 config file and NOWHERE else.
[ -n "$cfg" ] && cp "$cfg" "${FAKE}/last-curl-cfg"

path="${url#*/api/v4}"
emit() { printf '%s\n%s' "$1" "$2"; exit 0; }   # body \n http_code

uid_of() { awk -F'\t' -v u="$1" '$2==u{print $1}' "${FAKE}/users.tsv" | head -1; }
keys_json() { # uid
  local f="${FAKE}/keys-$1.tsv" out="[" first=1
  [ -f "$f" ] || { printf '[]'; return; }
  while IFS=$'\t' read -r id title blob; do
    [ -n "$id" ] || continue
    [ "$first" -eq 1 ] || out+=","
    first=0
    out+="{\"id\":${id},\"title\":\"${title}\",\"key\":\"${blob}\",\"created_at\":\"2025-12-30T00:00:00.000Z\"}"
  done < "$f"
  printf '%s]' "$out"
}
blob_exists_anywhere() { # "type base64"
  # `local` on the read variables is load-bearing: without it the loop
  # clobbers the caller's $id/$title/$blob and the stub files the new key
  # under the wrong user — which is exactly what it did on first writing.
  local want="$1" f id title blob
  for f in "${FAKE}"/keys-*.tsv; do
    [ -f "$f" ] || continue
    while IFS=$'\t' read -r id title blob; do
      [ -n "$blob" ] || continue
      [ "$(awk '{print $1" "$2}' <<<"$blob")" = "$want" ] && return 0
    done < "$f"
  done
  return 1
}

case "$method $path" in
  "GET /application/settings"*)
      [ -n "${FAKE_NOT_ADMIN:-}" ] && emit '{"message":"403 Forbidden"}' 403
      emit '{"default_projects_limit":100}' 200 ;;
  "GET /user")
      emit '{"id":38,"username":"nwp-forge-admin","is_admin":true}' 200 ;;
  "GET /users?username="*)
      u="${path#*username=}"; u="${u%%&*}"
      id="$(uid_of "$u")"
      [ -z "$id" ] && emit '[]' 200
      emit "[{\"id\":${id},\"username\":\"${u}\",\"name\":\"${u}\",\"state\":\"active\"}]" 200 ;;
  "GET /users/"*"/keys")
      id="${path#/users/}"; id="${id%/keys}"
      emit "$(keys_json "$id")" 200 ;;
  "GET /users/"[0-9]*)
      id="${path#/users/}"
      u="$(awk -F'\t' -v i="$id" '$1==i{print $2}' "${FAKE}/users.tsv" | head -1)"
      [ -z "$u" ] && emit '{"message":"404 User Not Found"}' 404
      emit "{\"id\":${id},\"username\":\"${u}\",\"name\":\"${u}\",\"state\":\"active\"}" 200 ;;
  "POST /users/"*"/keys")
      id="${path#/users/}"; id="${id%/keys}"
      if [ -n "${FAKE_ADD_FAIL_FOR:-}" ] && \
         { [ "${FAKE_ADD_FAIL_FOR}" = "$id" ] || [ "${FAKE_ADD_FAIL_FOR}" = "any" ]; }; then
        emit '{"message":{"key":["is invalid"]}}' 400
      fi
      blob="$(sed -n 's/.*"key"[ ]*:[ ]*"\([^"]*\)".*/\1/p' "$body_file")"
      title="$(sed -n 's/.*"title"[ ]*:[ ]*"\([^"]*\)".*/\1/p' "$body_file")"
      short="$(awk '{print $1" "$2}' <<<"$blob")"
      if blob_exists_anywhere "$short"; then
        emit '{"message":{"fingerprint_sha256":["has already been taken"]}}' 400
      fi
      # FAKE_ADD_LIES_FOR=<uid>: report 201 and store NOTHING for that user —
      # the lying-201 case [W5]. Scoped to one user on purpose, so the ROLLBACK
      # to the source still works and 3e measures the verify-then-rollback path
      # rather than collapsing into 3d's rollback-failure path.
      if [ "${FAKE_ADD_LIES_FOR:-}" != "$id" ]; then
        nid="$(cat "${FAKE}/next-key-id")"; printf '%s\n' "$((nid+1))" > "${FAKE}/next-key-id"
        printf '%s\t%s\t%s\n' "$nid" "$title" "$blob" >> "${FAKE}/keys-${id}.tsv"
      else
        nid="$(cat "${FAKE}/next-key-id")"
      fi
      emit "{\"id\":${nid},\"title\":\"${title}\",\"key\":\"${blob}\"}" 201 ;;
  "DELETE /users/"*"/keys/"*)
      rest="${path#/users/}"; id="${rest%%/keys/*}"; kid="${rest##*/keys/}"
      [ -n "${FAKE_DELETE_FAIL:-}" ] && emit '{"message":"500 Internal Server Error"}' 500
      grep -v "^${kid}"$'\t' "${FAKE}/keys-${id}.tsv" > "${FAKE}/.t" 2>/dev/null || true
      mv "${FAKE}/.t" "${FAKE}/keys-${id}.tsv"
      emit '' 204 ;;
  "POST /users")
      name="$(sed -n 's/.*"username"[ ]*:[ ]*"\([^"]*\)".*/\1/p' "$body_file")"
      [ -n "$(uid_of "$name")" ] && emit '{"message":{"username":["has already been taken"]}}' 409
      nid=90; printf '%s\t%s\n' "$nid" "$name" >> "${FAKE}/users.tsv"; : > "${FAKE}/keys-${nid}.tsv"
      emit "{\"id\":${nid},\"username\":\"${name}\"}" 201 ;;
  "GET /projects/"*"/members/all"*|"GET /groups/"*"/members/all"*)
      emit '[{"id":11,"username":"rjzaar","access_level":50}]' 200 ;;
  "GET /projects/nwp%2Fnwp"|"GET /projects/nwp%2Fops")
      emit '{"id":21,"path_with_namespace":"nwp/nwp"}' 200 ;;
  "GET /projects/"*)   emit '{"message":"404 Project Not Found"}' 404 ;;
  "GET /groups/nwp")   emit '{"id":9,"full_path":"nwp"}' 200 ;;
  "GET /groups/"*)     emit '{"message":"404 Group Not Found"}' 404 ;;
  "POST /projects/"*"/members"|"POST /groups/"*"/members")
      lvl="$(sed -n 's/.*"access_level"[ ]*:[ ]*\([0-9]*\).*/\1/p' "$body_file")"
      usr="$(sed -n 's/.*"user_id"[ ]*:[ ]*\([0-9]*\).*/\1/p' "$body_file")"
      printf 'MEMBER %s %s\n' "$usr" "$lvl" >> "$REQ_LOG"
      emit "{\"id\":${usr},\"access_level\":${lvl}}" 201 ;;
  *) emit '{"message":"stub: unrouted"}' 418 ;;
esac
STUB
  chmod +x "${STUBBIN}/curl"

  # ── credential + host ────────────────────────────────────────────────────
  export TOKEN_FILE="${TMP}/forge-admin.token"
  printf 'fixture-token-not-a-real-credential\n' > "$TOKEN_FILE"
  chmod 600 "$TOKEN_FILE"
  export BACKUP_DIR="${TMP}/backups"
}

_forge() {
  PATH="${STUBBIN}:${PATH}" \
  NWP_FORGE_ADMIN_TOKEN="$TOKEN_FILE" \
  NWP_FORGE_API_HOST="git.fixture.invalid" \
  NWP_FORGE_KEY_BACKUP_DIR="$BACKUP_DIR" \
  run "$FORGE" "$@"
}

_writes_sent()  { grep -cE '^(DELETE|POST) ' "$REQ_LOG" || true; }
_deletes_sent() { grep -c '^DELETE '        "$REQ_LOG" || true; }
_adds_sent()    { grep -c '^POST '          "$REQ_LOG" || true; }
_root_has()     { grep -c "$1" "${FAKE}/keys-1.tsv" || true; }
_user_key_count() { awk 'NF' "${FAKE}/keys-$1.tsv" | wc -l | tr -d ' '; }

################################################################################
# [W1] preflight — nothing moves until the destination is proven
################################################################################

@test "1a dry-run is the DEFAULT: no write request leaves the process" {
  _forge keys rehome 4 --to=mini
  [ "$status" -eq 0 ]
  [ "$(_writes_sent)" = "0" ]
  [[ "$output" == *"DRY RUN"* ]]
  [ "$(_user_key_count 1)" = "3" ]
  [ "$(_user_key_count 7)" = "0" ]
}

@test "1b the dry run NAMES what moves, from whom, to whom — the impact manifest" {
  _forge keys rehome 4 --to=mini
  [ "$status" -eq 0 ]
  [[ "$output" == *"nwp-agent-loop@mini"* ]]   # the key, by title
  [[ "$output" == *"$FP_MINI"* ]]              # by fingerprint, computed not recalled
  [[ "$output" == *"root"* ]]                  # from
  [[ "$output" == *"mini"* ]]                  # to
}

@test "1c the dry run writes NO backup file either — dry-run touches nothing" {
  _forge keys rehome 4 --to=mini
  [ "$status" -eq 0 ]
  run bash -c "ls '$BACKUP_DIR' 2>/dev/null | wc -l"
  [ "${output// /}" = "0" ]
}

@test "1d an UNKNOWN target user refuses BEFORE anything is deleted" {
  _forge keys rehome 4 --to=met --execute --yes
  [ "$status" -ne 0 ]
  [ "$(_deletes_sent)" = "0" ]
  [ "$(_user_key_count 1)" = "3" ]
  [[ "$output" == *"no such user"* ]]
  [[ "$output" == *"met"* ]]
  [[ "$output" == *"pl forge user create"* ]]   # the fixing verb, named
}

@test "1e an AMBIGUOUS selector refuses and names every candidate" {
  # A prefix short enough to match more than one key must never pick one.
  _forge keys rehome SHA256 --to=mini --execute --yes
  [ "$status" -eq 2 ]
  [ "$(_writes_sent)" = "0" ]
  [[ "$output" == *"AMBIGUOUS"* ]]
  [[ "$output" == *"NWP Backup Key"* ]]
  [[ "$output" == *"nwp-agent-loop@mini"* ]]
}

@test "1f a selector matching NOTHING refuses and lists what the source does hold" {
  _forge keys rehome SHA256:nosuchkeyatall --to=mini --execute --yes
  [ "$status" -ne 0 ]
  [ "$(_writes_sent)" = "0" ]
  [[ "$output" == *"no key"* ]]
  [[ "$output" == *"metabox (Carlo)"* ]]
}

@test "1g an ABSENT admin credential is CANNOT VERIFY (2), by name, with no writes" {
  PATH="${STUBBIN}:${PATH}" \
  NWP_FORGE_ADMIN_TOKEN="${TMP}/definitely-not-there.token" \
  NWP_FORGE_API_HOST="git.fixture.invalid" \
  NWP_FORGE_KEY_BACKUP_DIR="$BACKUP_DIR" \
  run "$FORGE" keys rehome 4 --to=mini --execute --yes
  [ "$status" -eq 2 ]
  [ "$(_writes_sent)" = "0" ]
  [[ "$output" == *"gitlab_forge_admin"* ]]
  [[ "$output" == *"definitely-not-there.token"* ]]
  [[ "$output" == *"pl secrets steps"* ]]
}

@test "1h a PRESENT but NON-ADMIN credential is CANNOT VERIFY (2), with no writes" {
  # The safety net for this whole operation is that keys can be restored over
  # the API. A token that cannot administer users is not that net.
  FAKE_NOT_ADMIN=1 _forge keys rehome 4 --to=mini --execute --yes
  [ "$status" -eq 2 ]
  [ "$(_writes_sent)" = "0" ]
  [[ "$output" == *"not an instance admin"* ]]
}

@test "1i the operation states what is NOT at risk — box shell access" {
  # Measured 2026-08-11: ~/.ssh/gitlab_linode authenticates to gitlab@<box> via
  # that box's authorized_keys, which no GitLab-user key change touches. An
  # operator watching a scary step is entitled to know that.
  _forge keys rehome 1 --to=rjzaar
  [ "$status" -eq 0 ]
  [[ "$output" == *"NOT AT RISK"* ]]
  [[ "$output" == *"authorized_keys"* ]]
}

################################################################################
# [W2]/[W5] the happy path
################################################################################

@test "2a --execute --yes moves the key: gone from root, present on the target" {
  _forge keys rehome 4 --to=mini --execute --yes
  [ "$status" -eq 0 ]
  [ "$(_user_key_count 1)" = "2" ]
  [ "$(_user_key_count 7)" = "1" ]
  grep -q "$(awk '{print $2}' "${BATS_FILE_TMPDIR}/mini.pub")" "${FAKE}/keys-7.tsv"
  [[ "$output" == *"VERIFIED"* ]]
}

@test "2b the window is exactly DELETE then ADD, in that order, adjacent" {
  # Everything else — resolution, backup, confirm — happens BEFORE the DELETE.
  _forge keys rehome 4 --to=mini --execute --yes
  [ "$status" -eq 0 ]
  run bash -c "grep -nE '^(DELETE|POST) ' '$REQ_LOG' | head -2 | cut -d: -f2- | cut -d' ' -f1 | tr '\n' ' '"
  [ "$output" = "DELETE POST " ]
  # and no request of any kind between them
  local d p
  d="$(grep -n '^DELETE ' "$REQ_LOG" | head -1 | cut -d: -f1)"
  p="$(grep -n '^POST '   "$REQ_LOG" | head -1 | cut -d: -f1)"
  [ "$((p - d))" -eq 1 ]
}

@test "2c the backup is written BEFORE the delete and holds the restorable blob" {
  _forge keys rehome 4 --to=mini --execute --yes
  [ "$status" -eq 0 ]
  local f; f="$(ls "$BACKUP_DIR"/*.json | head -1)"
  [ -s "$f" ]
  run jq -r '.keys[] | select(.id==4) | .key' "$f"
  [ "$output" = "$(cat "${BATS_FILE_TMPDIR}/mini.pub")" ]
  run jq -r '.user.username' "$f"
  [ "$output" = "root" ]
  [[ "${lines[*]}" != *"fixture-token"* ]]
}

@test "2d --title renames the key on its new home" {
  _forge keys rehome 4 --to=mini --title='mini agent loop' --execute --yes
  [ "$status" -eq 0 ]
  grep -q 'mini agent loop' "${FAKE}/keys-7.tsv"
}

@test "2e a key ALREADY on the target is reported and nothing is deleted" {
  # Idempotence: re-running the migration must not delete a key from its new
  # home in order to "move" it again.
  _forge keys rehome 4 --to=mini --execute --yes
  [ "$status" -eq 0 ]
  : > "$REQ_LOG"
  _forge keys rehome "$FP_MINI" --to=mini --execute --yes
  [ "$status" -eq 0 ]
  [ "$(_writes_sent)" = "0" ]
  [[ "$output" == *"already"* ]]
}

@test "2f the token never reaches argv — only the 0600 curl config" {
  _forge keys rehome 4 --to=mini --execute --yes
  [ "$status" -eq 0 ]
  run grep -c 'fixture-token-not-a-real-credential' "$ARGV_LOG"
  [ "$output" = "0" ]
  # negative control: it DID travel, in the config file
  run grep -c 'fixture-token-not-a-real-credential' "${FAKE}/last-curl-cfg"
  [ "$output" = "1" ]
  # and never in the operator-visible output
  [[ "$output" != *"fixture-token-not-a-real-credential"* ]]
}

@test "2g without --yes, a wrong typed confirmation aborts before any write" {
  run bash -c "printf 'no\n' | env PATH='${STUBBIN}:${PATH}' \
    NWP_FORGE_ADMIN_TOKEN='$TOKEN_FILE' NWP_FORGE_API_HOST='git.fixture.invalid' \
    NWP_FORGE_KEY_BACKUP_DIR='$BACKUP_DIR' '$FORGE' keys rehome 4 --to=mini --execute"
  [ "$status" -eq 1 ]
  [[ "$output" == *"NOTHING was changed"* ]]
  [ "$(_writes_sent)" = "0" ]
  [ "$(_user_key_count 1)" = "3" ]
  # …and no snapshot either: the confirm is asked BEFORE the backup, so a
  # refused confirm leaves no litter.
  run bash -c "ls '$BACKUP_DIR' 2>/dev/null | wc -l"
  [ "${output// /}" = "0" ]
}

@test "2h without --yes, typing the exact transition performs it" {
  # The negative control for 2g: the confirm is a real gate, not a wall.
  run bash -c "printf 'root->mini\n' | env PATH='${STUBBIN}:${PATH}' \
    NWP_FORGE_ADMIN_TOKEN='$TOKEN_FILE' NWP_FORGE_API_HOST='git.fixture.invalid' \
    NWP_FORGE_KEY_BACKUP_DIR='$BACKUP_DIR' '$FORGE' keys rehome 4 --to=mini --execute"
  [ "$status" -eq 0 ]
  [ "$(_user_key_count 7)" = "1" ]
}

################################################################################
# [W3]/[W4] failure inside the window
################################################################################

@test "3a ADD fails after DELETE succeeded → ROLLS BACK and says so" {
  FAKE_ADD_FAIL_FOR=7 _forge keys rehome 4 --to=mini --execute --yes
  [ "$status" -eq 1 ]
  [[ "$output" == *"ROLLED BACK"* ]]
  # the decisive assertion is the EFFECT, not the word: root has it again
  [ "$(_user_key_count 1)" = "3" ]
  grep -q "$(awk '{print $2}' "${BATS_FILE_TMPDIR}/mini.pub")" "${FAKE}/keys-1.tsv"
  [ "$(_user_key_count 7)" = "0" ]
}

@test "3b the rollback is VERIFIED, not merely attempted" {
  FAKE_ADD_FAIL_FOR=7 _forge keys rehome 4 --to=mini --execute --yes
  [ "$status" -eq 1 ]
  # a GET of the source's keys after the re-add — proof it re-read reality
  run bash -c "grep -n 'GET .*/users/1/keys' '$REQ_LOG' | tail -1 | cut -d: -f1"
  local last_get="$output"
  run bash -c "grep -n 'POST .*/users/1/keys' '$REQ_LOG' | tail -1 | cut -d: -f1"
  [ "$last_get" -gt "$output" ]
}

@test "3c a failed DELETE aborts with nothing changed and no ADD attempted" {
  FAKE_DELETE_FAIL=1 _forge keys rehome 4 --to=mini --execute --yes
  [ "$status" -eq 1 ]
  [ "$(_adds_sent)" = "0" ]
  [ "$(_user_key_count 1)" = "3" ]
  [[ "$output" == *"nothing was changed"* ]]
}

@test "3d ROLLBACK ITSELF FAILS → screams, names the backup file and the repair command" {
  # Both adds fail: the one to the target, and the restoring one to the source.
  # This is the worst case the verb can reach — the key is on NO account — and
  # a bare non-zero exit here would leave an operator with no way back.
  FAKE_ADD_FAIL_FOR=any _forge keys rehome 4 --to=mini --execute --yes
  [ "$status" -eq 1 ]
  [[ "$output" == *"ROLLBACK FAILED"* ]]
  [[ "$output" == *"authenticates to NO account"* ]]
  [[ "$output" == *"pl forge keys restore"* ]]
  local f; f="$(ls "$BACKUP_DIR"/*.json | head -1)"
  [[ "$output" == *"$f"* ]]                # the backup, by absolute path
  [[ "$output" != *"curl "* ]]             # a pl command, not a curl incantation
  [ "$(_user_key_count 1)" = "2" ]         # and it does NOT pretend otherwise
}

@test "3e VERIFICATION MISMATCH: a lying 201 is a failure and rolls back" {
  # [W5]. The stub returns 201 Created and stores nothing — exactly what a
  # partially-applied write, a proxy, or a replica lag looks like from here.
  FAKE_ADD_LIES_FOR=7 _forge keys rehome 4 --to=mini --execute --yes
  [ "$status" -eq 1 ]
  [[ "$output" == *"VERIFY"* ]]
  [[ "$output" == *"ROLLED BACK"* ]]
  [ "$(_user_key_count 1)" = "3" ]
  [ "$(_user_key_count 7)" = "0" ]
}

@test "3f the success phrase exists, and the lying 201 does not earn it" {
  # Negative control for 3e. Asserted in BOTH directions on purpose: a bare
  # "the output does not contain VERIFIED" passes vacuously against any tree
  # that never prints it — which is exactly how this case scored green before
  # the verb existed. So: prove the phrase is real first, then prove it is
  # withheld.
  _forge keys rehome 4 --to=mini --execute --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"VERIFIED — the key is now on"* ]]
  # reset the fixture and re-run against a forge that lies
  printf '4\tnwp-agent-loop@mini\t%s\n' "$(cat "${BATS_FILE_TMPDIR}/mini.pub")" >> "${FAKE}/keys-1.tsv"
  : > "${FAKE}/keys-7.tsv"
  FAKE_ADD_LIES_FOR=7 _forge keys rehome 4 --to=mini --execute --yes
  [[ "$output" != *"VERIFIED — the key is now on"* ]]
}

################################################################################
# backup / restore — the standalone half of the safety net
################################################################################

@test "4a keys backup snapshots every key of a user, with fingerprints" {
  _forge keys backup root --out="${TMP}/root.json"
  [ "$status" -eq 0 ]
  run jq -r '.keys | length' "${TMP}/root.json"
  [ "$output" = "3" ]
  run jq -r '.keys[] | select(.id==3) | .fingerprint_sha256' "${TMP}/root.json"
  [ "$output" = "$FP_MET" ]
}

@test "4b keys backup of an unknown user is a named refusal, not an empty file" {
  _forge keys backup met --out="${TMP}/met.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no such user"* ]]
  [ ! -f "${TMP}/met.json" ]
}

@test "4c keys restore puts a key back from a backup (the manual repair path)" {
  _forge keys backup root --out="${TMP}/root.json"
  [ "$status" -eq 0 ]
  # simulate the catastrophe: the key is gone from everywhere
  grep -v $'^4\t' "${FAKE}/keys-1.tsv" > "${FAKE}/t" && mv "${FAKE}/t" "${FAKE}/keys-1.tsv"
  [ "$(_user_key_count 1)" = "2" ]
  _forge keys restore "${TMP}/root.json" --key-id=4 --execute --yes
  [ "$status" -eq 0 ]
  [ "$(_user_key_count 1)" = "3" ]
  grep -q "$(awk '{print $2}' "${BATS_FILE_TMPDIR}/mini.pub")" "${FAKE}/keys-1.tsv"
}

@test "4d keys restore is dry-run by default" {
  _forge keys backup root --out="${TMP}/root.json"
  grep -v $'^4\t' "${FAKE}/keys-1.tsv" > "${FAKE}/t" && mv "${FAKE}/t" "${FAKE}/keys-1.tsv"
  : > "$REQ_LOG"
  _forge keys restore "${TMP}/root.json" --key-id=4
  [ "$status" -eq 0 ]
  [ "$(_writes_sent)" = "0" ]
  [[ "$output" == *"DRY RUN"* ]]
}

@test "4e keys verify answers the question the coordinator asks after each step" {
  _forge keys verify mini "$FP_MINI"
  [ "$status" -eq 1 ]                       # not there yet
  [[ "$output" == *"NOT on"* ]]
  _forge keys rehome 4 --to=mini --execute --yes
  [ "$status" -eq 0 ]
  _forge keys verify mini "$FP_MINI"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PRESENT"* ]]
}

@test "4f keys verify on an unreadable credential is 2, never a cheerful 0" {
  PATH="${STUBBIN}:${PATH}" NWP_FORGE_ADMIN_TOKEN="${TMP}/nope" \
    NWP_FORGE_API_HOST="git.fixture.invalid" run "$FORGE" keys verify mini "$FP_MINI"
  [ "$status" -eq 2 ]
  # "exited 2" alone is the blind-negation shape — an unknown subcommand exits
  # 2 as well, and did, when this case was first written against the stub. The
  # refusal must NAME the missing credential and the file it looked in.
  [[ "$output" == *"CANNOT VERIFY"* ]]
  [[ "$output" == *"${TMP}/nope"* ]]
}

################################################################################
# the two verbs the migration needs alongside `keys`
################################################################################

@test "5a user create is dry-run by default and creates on --execute" {
  _forge user create met --name='met (metabox)' --email=met@example.invalid
  [ "$status" -eq 0 ]
  [ "$(_writes_sent)" = "0" ]
  [[ "$output" == *"DRY RUN"* ]]
  _forge user create met --name='met (metabox)' --email=met@example.invalid --execute --yes
  [ "$status" -eq 0 ]
  run grep -c $'\tmet$' "${FAKE}/users.tsv"
  [ "$output" = "1" ]
}

@test "5b user create refuses without --name/--email rather than inventing them" {
  _forge user create met --execute --yes
  [ "$status" -eq 2 ]
  [ "$(_writes_sent)" = "0" ]
  [[ "$output" == *"--name"* ]]
}

@test "5c user create never puts a password on argv or in the output" {
  _forge user create met --name='met' --email=met@example.invalid --execute --yes
  [ "$status" -eq 0 ]
  run grep -ci 'password' "$ARGV_LOG"
  [ "$output" = "0" ]
}

@test "5d user create is REFUSED without a credential, by name" {
  PATH="${STUBBIN}:${PATH}" NWP_FORGE_ADMIN_TOKEN="${TMP}/nope" \
    NWP_FORGE_API_HOST="git.fixture.invalid" \
    run "$FORGE" user create met --name=m --email=m@example.invalid --execute --yes
  [ "$status" -eq 2 ]
  [ "$(_writes_sent)" = "0" ]
  [[ "$output" == *"gitlab_forge_admin"* ]]
  # …and it is the REFUSAL that says so, not the usage text: `usage()` also
  # prints the registry id, so this case passed against a tree where
  # `pl forge user` was not a subcommand at all. The token path it actually
  # looked in cannot come from usage.
  [[ "$output" == *"${TMP}/nope"* ]]
}

@test "6a members add is dry-run by default, then adds at the named level" {
  _forge members add nwp/nwp mini --level=developer
  [ "$status" -eq 0 ]
  [ "$(_writes_sent)" = "0" ]
  _forge members add nwp/nwp mini --level=developer --execute --yes
  [ "$status" -eq 0 ]
  grep -q '^MEMBER 7 30$' "$REQ_LOG"
}

@test "6b members add resolves a GROUP path as well as a project" {
  _forge members add nwp mini --level=reporter --execute --yes
  [ "$status" -eq 0 ]
  grep -q 'POST .*/groups/nwp/members' "$REQ_LOG"
  grep -q '^MEMBER 7 20$' "$REQ_LOG"
}

@test "6c members add REFUSES owner/maintainer-by-typo rather than guessing a level" {
  _forge members add nwp/nwp mini --level=owner --execute --yes
  [ "$status" -eq 2 ]
  [ "$(_writes_sent)" = "0" ]
  [[ "$output" == *"reporter"* ]]
}

@test "6d members add on a path that is neither project nor group is CANNOT VERIFY" {
  _forge members add nwp/nosuch mini --level=reporter --execute --yes
  [ "$status" -eq 2 ]
  [ "$(_writes_sent)" = "0" ]
  [[ "$output" == *"neither a project nor a group"* ]]
}

@test "6e members add without a credential refuses by name, no writes" {
  PATH="${STUBBIN}:${PATH}" NWP_FORGE_ADMIN_TOKEN="${TMP}/nope" \
    NWP_FORGE_API_HOST="git.fixture.invalid" \
    run "$FORGE" members add nwp/nwp mini --level=reporter --execute --yes
  [ "$status" -eq 2 ]
  [ "$(_writes_sent)" = "0" ]
  [[ "$output" == *"gitlab_forge_admin"* ]]
  [[ "$output" == *"${TMP}/nope"* ]]
}

################################################################################
# structural
################################################################################

@test "7a forge.sh is bash -n clean and the help lists every new verb" {
  run bash -n "$FORGE"
  [ "$status" -eq 0 ]
  run "$FORGE" --help
  [ "$status" -eq 0 ]
  local v
  for v in 'keys backup' 'keys rehome' 'keys restore' 'keys verify' 'user create' 'members add'; do
    [[ "$output" == *"$v"* ]]
  done
}

@test "7b the rehome verb never shells out to ssh — the app plane is REST-only" {
  # SSH to this box is jailed to git verbs ('Disallowed command'), so an ssh
  # fallback here could only ever be a lie. A grep-for-ABSENCE passes
  # vacuously against a function that does not exist — and did, before the
  # verb was written — so assert the subject is there first.
  local body; body="$(sed -n '/^cmd_keys_rehome/,/^}/p' "$FORGE")"
  [ -n "$body" ]
  run bash -c "printf '%s\n' \"\$1\" | grep -c 'DELETE' " _ "$body"
  [ "$output" -ge 1 ]                       # it is the real function
  run bash -c "printf '%s\n' \"\$1\" | grep -cE '(^|[^_[:alnum:]])ssh '" _ "$body"
  [ "$output" = "0" ]
}
