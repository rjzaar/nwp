#!/usr/bin/env bats
# Item 2 (oversight-honesty): executing an item must not permanently disarm the
# check behind it.
#
# Defect this locks down: lib/todo-tui.sh mapped an SSL item to
# `sudo certbot renew` and `eval`ed it ON THE WORKSTATION. The certs live on
# 97.107.137.88. certbot on the laptop finds nothing to renew and exits 0, so the
# TUI called `add_to_ignored "$id" "Executed"` — and `add_to_ignored` writes NO
# `expires` key from that path. Result: the site's certificate-expiry check was
# permanently disarmed at exactly the moment it mattered.
#
# Contract now:
#   - the EXECUTE path always writes an `expires` (a suppression is a snooze,
#     never a deletion)
#   - SSL has no local exec command until a remote verb exists
#   - `tui_is_executable` is false for an action string that is not a command

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../.."
  TMP="$BATS_TEST_TMPDIR/supp"
  mkdir -p "$TMP"
}

@test "the SSL branch does not map to a local 'sudo certbot renew'" {
  # The certs are on the box; running certbot here is a no-op that exits 0.
  run grep -n 'sudo certbot renew' "$ROOT/lib/todo-tui.sh"
  [ "$status" -ne 0 ]
}

@test "tui_get_exec_command returns empty for an SSL item (no remote verb yet)" {
  run bash -c '
    set +e
    source "'"$ROOT"'/lib/todo-tui.sh" 2>/dev/null
    tui_get_exec_command "{\"id\":\"SSL-avc\",\"category\":\"SSL\",\"action\":\"\"}"
  '
  echo "[$output]"
  [ -z "$(printf %s "$output" | tr -d '[:space:]')" ]
}

@test "tui_is_executable is false for a prose action string" {
  run bash -c '
    set +e
    source "'"$ROOT"'/lib/todo-tui.sh" 2>/dev/null
    if tui_is_executable "{\"id\":\"LBK-x\",\"category\":\"LBK\",\"action\":\"ssh into nwpcode and check the cron\"}"; then
      echo EXECUTABLE
    else
      echo NOT_EXECUTABLE
    fi
  '
  echo "$output"
  [ "$output" = "NOT_EXECUTABLE" ]
}

@test "tui_is_executable is TRUE for a real pl verb action string" {
  run bash -c '
    set +e
    source "'"$ROOT"'/lib/todo-tui.sh" 2>/dev/null
    if tui_is_executable "{\"id\":\"BAK-x\",\"category\":\"BAK\",\"action\":\"pl backup avc\"}"; then
      echo EXECUTABLE
    else
      echo NOT_EXECUTABLE
    fi
  '
  echo "$output"
  [ "$output" = "EXECUTABLE" ]
}

@test "add_to_ignored from the EXECUTE path writes a non-empty expires" {
  cat > "$TMP/nwp.yml" <<'EOF'
settings:
  todo:
    ignored: []
EOF
  run bash -c '
    set +e
    PROJECT_ROOT="'"$ROOT"'"
    CONFIG_FILE="'"$TMP"'/nwp.yml"
    source "'"$ROOT"'/lib/ui.sh" 2>/dev/null
    source "'"$ROOT"'/scripts/commands/todo.sh" 2>/dev/null
    CONFIG_FILE="'"$TMP"'/nwp.yml"
    todo_suppress_after_execute "SSL-avc" "Executed"
  '
  echo "$output"
  run yq eval '.settings.todo.ignored[0].expires' "$TMP/nwp.yml"
  echo "expires=[$output]"
  [ -n "$output" ]
  [ "$output" != "null" ]
}

@test "an EXPIRED suppression no longer hides its item" {
  # Found while fixing the snooze: `expires` was WRITE-ONLY. todo_is_ignored
  # matched on id alone, so a "snoozed" item was suppressed forever anyway and
  # the expiry key was pure decoration. A snooze that never wakes up is the same
  # defect as a permanent ignore.
  cat > "$TMP/nwp.yml" <<'EOF'
settings:
  todo:
    ignored:
      - id: SSL-avc
        reason: Executed
        expires: "2020-01-01T00:00:00Z"
EOF
  run bash -c '
    set +e
    source "'"$ROOT"'/lib/todo-checks.sh"
    TODO_CONFIG_FILE="'"$TMP"'/nwp.yml"
    if todo_is_ignored SSL-avc; then echo IGNORED; else echo VISIBLE; fi
  '
  echo "$output"
  [ "$output" = "VISIBLE" ]
}

@test "an UNEXPIRED suppression still hides its item" {
  cat > "$TMP/nwp.yml" <<'EOF'
settings:
  todo:
    ignored:
      - id: SSL-avc
        reason: Executed
        expires: "2099-01-01T00:00:00Z"
EOF
  run bash -c '
    set +e
    source "'"$ROOT"'/lib/todo-checks.sh"
    TODO_CONFIG_FILE="'"$TMP"'/nwp.yml"
    if todo_is_ignored SSL-avc; then echo IGNORED; else echo VISIBLE; fi
  '
  echo "$output"
  [ "$output" = "IGNORED" ]
}

@test "a suppression with no expires at all still hides its item (permanent ignore)" {
  cat > "$TMP/nwp.yml" <<'EOF'
settings:
  todo:
    ignored:
      - id: GWK-x
        reason: Manual ignore
EOF
  run bash -c '
    set +e
    source "'"$ROOT"'/lib/todo-checks.sh"
    TODO_CONFIG_FILE="'"$TMP"'/nwp.yml"
    if todo_is_ignored GWK-x; then echo IGNORED; else echo VISIBLE; fi
  '
  echo "$output"
  [ "$output" = "IGNORED" ]
}

@test "a manual 'pl todo ignore' with no expiry is still permitted (explicit operator choice)" {
  cat > "$TMP/nwp.yml" <<'EOF'
settings:
  todo:
    ignored: []
EOF
  run bash -c '
    set +e
    PROJECT_ROOT="'"$ROOT"'"
    CONFIG_FILE="'"$TMP"'/nwp.yml"
    source "'"$ROOT"'/lib/ui.sh" 2>/dev/null
    source "'"$ROOT"'/scripts/commands/todo.sh" 2>/dev/null
    CONFIG_FILE="'"$TMP"'/nwp.yml"
    add_to_ignored "GWK-x" "Manual ignore"
  '
  run yq eval '.settings.todo.ignored[0].id' "$TMP/nwp.yml"
  [ "$output" = "GWK-x" ]
}
