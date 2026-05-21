#!/usr/bin/env bash
# agent-loop.sh — drive the GitLab-issue -> Claude-PR -> deploy loop.
#
# Run from cron or by hand. Picks one eligible open issue per invocation
# (configurable via AGENT_LOOP_MAX_PER_RUN), spawns `claude -p` headless on
# a fresh worktree, opens a merge request on success, and records state in
# /home/rob/nwp/.agent-loop.state.json.
#
# Honours kill switch /home/rob/nwp/.loop-paused — exit 0 cleanly if present.
#
# Required env:
#   GITLAB_TOKEN   — personal access token with api scope on git.nwpcode.org
#
# Optional env:
#   AGENT_LOOP_DAILY_CAP        (default 5)
#   AGENT_LOOP_MAX_PER_RUN      (default 1)
#   AGENT_LOOP_MAX_AGE_DAYS     (default 30)
#   AGENT_LOOP_MAX_RETRIES      (default 3)
#   AGENT_LOOP_KEEP_FAILED      (default 1; set to 0 to clean failed worktrees)
#   AGENT_LOOP_DRY_RUN          (default 0; set to 1 to skip claude + push)
#   AGENT_LOOP_GITLAB_BASE_URL  (default https://git.nwpcode.org)
#   AGENT_LOOP_PROJECT_IDS      (default "16"; comma-separated list)
#   CLAUDE_BIN                  (default "claude")
#
# Exits 0 always so cron stays happy. Real errors land in the log file.

set -euo pipefail

NWP_ROOT="${NWP_ROOT:-/home/rob/nwp}"
KILL_SWITCH="${NWP_ROOT}/.loop-paused"
STATE_FILE="${NWP_ROOT}/.agent-loop.state.json"
LOG_DIR="${NWP_ROOT}/logs"
LOG_FILE="${LOG_DIR}/agent-loop.log"
WORK_ROOT="/tmp/agent-work"

DAILY_CAP="${AGENT_LOOP_DAILY_CAP:-5}"
MAX_PER_RUN="${AGENT_LOOP_MAX_PER_RUN:-1}"
MAX_AGE_DAYS="${AGENT_LOOP_MAX_AGE_DAYS:-30}"
MAX_RETRIES="${AGENT_LOOP_MAX_RETRIES:-3}"
KEEP_FAILED="${AGENT_LOOP_KEEP_FAILED:-1}"
DRY_RUN="${AGENT_LOOP_DRY_RUN:-0}"
GITLAB_BASE_URL="${AGENT_LOOP_GITLAB_BASE_URL:-https://git.nwpcode.org}"
PROJECT_IDS="${AGENT_LOOP_PROJECT_IDS:-16}"
CLAUDE_BIN="${CLAUDE_BIN:-claude}"

mkdir -p "$LOG_DIR" "$WORK_ROOT"

log() {
  printf '[%s] %s\n' "$(date -Iseconds)" "$*" | tee -a "$LOG_FILE"
}

# Redact GITLAB_TOKEN out of any leaked output paths.
redact() {
  sed -E "s/$(printf '%s' "${GITLAB_TOKEN:-NEVER_MATCH}" | sed 's/[][\.|$/*^+?()]/\\&/g')/<redacted>/g"
}

ok_or_exit_clean() {
  # Cron must never see a non-zero — we exit 0 even when something went wrong.
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    log "WARN: shell exited rc=$rc (suppressing to keep cron green)"
  fi
  exit 0
}
trap ok_or_exit_clean EXIT

if [[ -f "$KILL_SWITCH" ]]; then
  log "kill switch present at $KILL_SWITCH — exiting clean"
  exit 0
fi

if [[ -z "${GITLAB_TOKEN:-}" ]]; then
  log "ERROR: GITLAB_TOKEN not set; refusing to run"
  exit 0
fi

# Initialise state file if missing.
if [[ ! -f "$STATE_FILE" ]]; then
  log "state file missing, creating empty at $STATE_FILE"
  printf '%s\n' '{"daily":{}, "retry_count":{}, "last_run":null}' > "$STATE_FILE"
fi

today_key="$(date -u +%Y-%m-%d)"

# --- helpers ------------------------------------------------------------

gitlab_curl() {
  # Usage: gitlab_curl <method> <path> [data]
  local method="$1" path="$2" data="${3:-}"
  local url="${GITLAB_BASE_URL}${path}"
  if [[ -n "$data" ]]; then
    curl -sS --fail-with-body -X "$method" \
      -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
      -H "Content-Type: application/json" \
      --data "$data" "$url"
  else
    curl -sS --fail-with-body -X "$method" \
      -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
      "$url"
  fi
}

# Returns local checkout path for a project_id. Always under .agent-checkouts/
# (gitignored, outside sites/) so the loop never resets the operator's
# working tree. The directory is created on first use via `git clone`
# (see the loop body below).
#
# We deliberately do NOT point this at sites/nwc/dev/html/profiles/custom/nwc
# any more, even though that directory is a valid clone of nwp/nwc. The loop
# does `git checkout main` + `git pull` inside the resolved path, which
# silently switches the operator off whatever feature branch they had
# checked out. Surfaced during the power-user fast-path test on 2026-05-21.
project_local_path() {
  local pid="$1"
  echo "${NWP_ROOT}/.agent-checkouts/p${pid}"
}

# Returns SSH URL for a project_id by hitting the API.
project_ssh_url() {
  local pid="$1"
  gitlab_curl GET "/api/v4/projects/${pid}" \
    | python3 -c 'import sys,json; print(json.load(sys.stdin).get("ssh_url_to_repo",""))'
}

# Count PRs already opened today (from state file).
prs_today() {
  python3 - "$STATE_FILE" "$today_key" <<'PY'
import json, sys, pathlib
p = pathlib.Path(sys.argv[1])
key = sys.argv[2]
d = json.loads(p.read_text() or "{}")
print(d.get("daily", {}).get(key, 0))
PY
}

state_bump_daily() {
  python3 - "$STATE_FILE" "$today_key" <<'PY'
import json, sys, pathlib
p = pathlib.Path(sys.argv[1])
key = sys.argv[2]
d = json.loads(p.read_text() or "{}")
d.setdefault("daily", {})
d["daily"][key] = int(d["daily"].get(key, 0)) + 1
p.write_text(json.dumps(d, indent=2) + "\n")
PY
}

state_get_retry() {
  python3 - "$STATE_FILE" "$1" <<'PY'
import json, sys, pathlib
p = pathlib.Path(sys.argv[1])
issue_key = sys.argv[2]
d = json.loads(p.read_text() or "{}")
print(int(d.get("retry_count", {}).get(issue_key, 0)))
PY
}

state_bump_retry() {
  python3 - "$STATE_FILE" "$1" <<'PY'
import json, sys, pathlib
p = pathlib.Path(sys.argv[1])
issue_key = sys.argv[2]
d = json.loads(p.read_text() or "{}")
d.setdefault("retry_count", {})
d["retry_count"][issue_key] = int(d["retry_count"].get(issue_key, 0)) + 1
p.write_text(json.dumps(d, indent=2) + "\n")
PY
}

state_set_last_run() {
  python3 - "$STATE_FILE" "$1" <<'PY'
import json, sys, pathlib
p = pathlib.Path(sys.argv[1])
d = json.loads(p.read_text() or "{}")
d["last_run"] = sys.argv[2]
p.write_text(json.dumps(d, indent=2) + "\n")
PY
}

# --- main loop ---------------------------------------------------------

log "agent-loop start (max_per_run=${MAX_PER_RUN} daily_cap=${DAILY_CAP} projects=${PROJECT_IDS} dry_run=${DRY_RUN})"
state_set_last_run "$(date -Iseconds)"

count_today="$(prs_today)"
if (( count_today >= DAILY_CAP )); then
  log "daily cap reached (${count_today}/${DAILY_CAP}) — exiting clean"
  exit 0
fi

cutoff_iso="$(date -u -d "${MAX_AGE_DAYS} days ago" +%Y-%m-%dT%H:%M:%SZ)"
log "issue cutoff: not older than $cutoff_iso"

processed=0
IFS=',' read -r -a project_arr <<<"$PROJECT_IDS"

for pid in "${project_arr[@]}"; do
  if (( processed >= MAX_PER_RUN )); then
    break
  fi
  log "polling project $pid for label=agent-eligible, state=opened"
  issues_json="$(gitlab_curl GET "/api/v4/projects/${pid}/issues?state=opened&labels=agent-eligible&per_page=20&order_by=created_at&sort=asc" 2>>"$LOG_FILE" || echo '[]')"
  count="$(printf '%s' "$issues_json" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(len(d) if isinstance(d,list) else 0)')"
  log "  project $pid: ${count} candidate issue(s)"

  issue_ids_csv="$(printf '%s' "$issues_json" \
    | python3 -c 'import sys,json; d=json.load(sys.stdin); print(",".join(str(i["iid"]) for i in d) if isinstance(d,list) else "")')"
  IFS=',' read -r -a iid_arr <<<"$issue_ids_csv"

  for iid in "${iid_arr[@]}"; do
    [[ -z "$iid" ]] && continue
    if (( processed >= MAX_PER_RUN )); then
      break
    fi

    issue_key="${pid}#${iid}"
    log "  examining ${issue_key}"

    issue_one="$(printf '%s' "$issues_json" \
      | python3 -c 'import sys,json; iid=int(sys.argv[1]); d=json.load(sys.stdin); [print(json.dumps(i)) for i in d if i["iid"]==iid]' "$iid")"
    if [[ -z "$issue_one" ]]; then
      log "    skip: could not isolate issue json"
      continue
    fi

    # Age check.
    created_at="$(printf '%s' "$issue_one" | python3 -c 'import sys,json; print(json.load(sys.stdin)["created_at"])')"
    if [[ "$created_at" < "$cutoff_iso" ]]; then
      log "    skip: issue is older than ${MAX_AGE_DAYS}d ($created_at)"
      continue
    fi

    # Has linked MR?
    mrs_json="$(gitlab_curl GET "/api/v4/projects/${pid}/issues/${iid}/related_merge_requests" 2>>"$LOG_FILE" || echo '[]')"
    open_mr_count="$(printf '%s' "$mrs_json" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(sum(1 for m in (d if isinstance(d,list) else []) if m.get("state")=="opened"))')"
    if (( open_mr_count > 0 )); then
      log "    skip: ${open_mr_count} open MR(s) already linked"
      continue
    fi

    # Retry budget.
    retries="$(state_get_retry "$issue_key")"
    if (( retries >= MAX_RETRIES )); then
      log "    skip: retry budget exhausted (${retries}/${MAX_RETRIES})"
      continue
    fi

    # Need a local checkout path.
    local_path="$(project_local_path "$pid")"
    if [[ -z "$local_path" || ! -d "$local_path/.git" ]]; then
      # First run for this project: clone into the dedicated dir. Hidden
      # dot-dir at the repo root so it's gitignored by default (the repo's
      # .gitignore uses an aggressive whitelist) and stays well away from
      # the operator's sites/ tree.
      mkdir -p "$(dirname "$local_path")"
      if [[ ! -d "$local_path/.git" ]]; then
        ssh_url="$(project_ssh_url "$pid")"
        if [[ -z "$ssh_url" ]]; then
          log "    skip: no local path AND no SSH URL for project ${pid}"
          continue
        fi
        log "    cloning $ssh_url -> $local_path"
        GIT_SSH_COMMAND="ssh -i ~/.ssh/nwp -o IdentitiesOnly=yes" \
          git clone "$ssh_url" "$local_path" >>"$LOG_FILE" 2>&1 || {
            log "    skip: clone failed"; continue;
          }
      fi
    fi

    # Refresh main.
    log "    refreshing main in $local_path"
    (
      cd "$local_path"
      GIT_SSH_COMMAND="ssh -i ~/.ssh/nwp -o IdentitiesOnly=yes" git fetch origin >>"$LOG_FILE" 2>&1
      git checkout main >>"$LOG_FILE" 2>&1 || git checkout -b main origin/main >>"$LOG_FILE" 2>&1
      GIT_SSH_COMMAND="ssh -i ~/.ssh/nwp -o IdentitiesOnly=yes" git pull --ff-only origin main >>"$LOG_FILE" 2>&1 || true
    ) || log "    WARN: refresh-main returned non-zero (continuing)"

    # Build worktree.
    branch="agent/issue-${iid}"
    work_dir="${WORK_ROOT}/p${pid}-issue-${iid}"
    if [[ -d "$work_dir" ]]; then
      log "    cleaning stale worktree dir $work_dir"
      (cd "$local_path" && git worktree remove --force "$work_dir" >>"$LOG_FILE" 2>&1 || true)
      rm -rf "$work_dir"
    fi
    log "    creating worktree $work_dir on $branch"
    (
      cd "$local_path"
      # If branch already exists locally, drop it so we start clean.
      git branch -D "$branch" >>"$LOG_FILE" 2>&1 || true
      git worktree add "$work_dir" -b "$branch" main
    ) >>"$LOG_FILE" 2>&1 || {
      log "    skip: worktree add failed"
      state_bump_retry "$issue_key"
      continue
    }

    title="$(printf '%s' "$issue_one" | python3 -c 'import sys,json; print(json.load(sys.stdin)["title"])')"
    description="$(printf '%s' "$issue_one" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("description","") or "")')"
    web_url="$(printf '%s' "$issue_one" | python3 -c 'import sys,json; print(json.load(sys.stdin)["web_url"])')"

    # Extract the tier marker from the issue's labels (set by drush
    # nwc-feedback:sync-to-gitlab as tier-1 / tier-2 / tier-3). Map to
    # T1/T2/T3 so the deploy script can read "Tier: T<n>" from MR body.
    tier="$(printf '%s' "$issue_one" | python3 -c '
import sys, json
labels = json.load(sys.stdin).get("labels", []) or []
m = {"tier-1": "T1", "tier-2": "T2", "tier-3": "T3"}
for label in labels:
    if label in m:
        print(m[label]); break
else:
    print("T2")
')"

    # Compose the prompt.
    cat >"${work_dir}/PROMPT.md" <<EOF
# Agent-loop task: project ${pid}, issue ${iid}

You are running headless inside the NWC agent loop. Your job is to make the
minimum change required to resolve the linked GitLab issue, on a clean
\`${branch}\` branch already checked out at this working directory.

## Working directory

\`${work_dir}\`

This is a \`git worktree\` of \`${local_path}\`. Stay inside this directory.
DO NOT touch files outside it. DO NOT run \`git push\` — the loop driver does
that for you after it inspects your changes.

## Issue ${iid}: ${title}

URL: ${web_url}

### Description

${description}

## What to do

1. Re-read the issue body carefully.
2. Find the file(s) that need changing. If the typo / fix described in the
   issue is not present in the codebase, write a short explanatory note as
   \`AGENT-NOTE.md\` at the repo root saying what you searched for and why no
   change was applied, then stop. The driver will see no diff and back out.
3. Make the smallest possible change. Do not refactor or "improve" code that
   isn't directly part of the fix.
4. Stage and commit your change with a message of the form
   \`[agent-loop] fix(issue-${iid}): <one-line summary>\`. Use a heredoc so
   the message is multi-line if useful. Sign off with
   \`Co-Authored-By: Claude (agent-loop) <noreply@anthropic.com>\`.
5. DO NOT push. The driver will push and open the MR.

## Repo-specific testing conventions (MUST READ before writing tests)

This is a Drupal install profile (\`profiles/custom/nwc/\`). All custom
modules live at \`profiles/custom/nwc/modules/nwc_features/<module>/\`.
That nesting affects which PHPUnit base class will work:

- **Kernel tests (\`KernelTestBase\`) WORK** for profile-nested modules.
  They bypass Drupal's profile-extension filter. List modules in
  \`static \$modules\`; they will be loaded.
- **BrowserTestBase / WebDriverTestBase tests DO NOT WORK** out of the
  box. Drupal's ExtensionDiscovery filters out modules under
  \`profiles/custom/nwc/modules/\` when the active test profile is
  \`testing\` (the BrowserTestBase default). Setting
  \`protected \$profile = 'nwc';\` would fix discovery but triggers a
  full Open Social install per test — too slow, frequently flaky.

**Pattern:** for new tests, prefer \`KernelTestBase\` and assert on
service contracts via mocks (use \`\\Drupal\\Core\\DependencyInjection\\ContainerBuilder\`
+ \`\$this->createMock()\`). Look at
\`profiles/custom/nwc/modules/nwc_features/nwc_editorial/tests/src/Kernel/StateMachineTest.php\`
as the reference template — it covers the editorial state machine
end-to-end without browser overhead.

**When you DO need a browser:** add a Behat scenario under
\`profiles/custom/nwc/modules/nwc_features/<module>/tests/src/Behat/\`
instead of a PHPUnit Functional test. Behat is configured at the
project root (\`behat.yml.dist\`) and runs against the live ddev site,
which has the nwc profile already installed.

**Other gotchas:**

- The Feedback entity has a \`guild_id\` reference to the contrib \`group\`
  module. Do NOT \`installEntitySchema('feedback')\` in a kernel test
  unless you also list \`group\` in \`\$modules\` — and that drags in heavy
  dependencies. Prefer mock-based assertions on the service contract.
- All NWC entities reference the \`user\` entity type. Install user
  schema (\`\$this->installEntitySchema('user')\`) before touching any
  entity that has an author/owner field.
- The \`workflow_assignment\` module is required by \`nwc_core\`; list
  both in \`\$modules\` when testing modules that depend on nwc_core.

## Test commands (run before committing — these MUST pass)

\`\`\`bash
# From inside the worktree (you are at the profile root):
PROFILE=\$(pwd)

# Kernel test on the changed module (substitute the module name):
ddev exec "cd /var/www/html && vendor/bin/phpunit -c /var/www/html/phpunit.xml \\
  /var/www/html/html/profiles/custom/nwc/modules/nwc_features/<module>/tests/src/Kernel/"

# Editorial baseline must remain green:
ddev exec "cd /var/www/html && vendor/bin/phpunit -c /var/www/html/phpunit.xml \\
  /var/www/html/html/profiles/custom/nwc/modules/nwc_features/nwc_editorial/tests/src/Kernel/"
\`\`\`

If tests fail and the fix is unclear, write \`AGENT-NOTE.md\` explaining
what you tried and stop. Do NOT commit a known-broken test — the
reviewer will reject it anyway and the loop wastes a retry budget.

If no tests apply, that is OK — keep the change small enough that a
human reviewer (Greg) can eyeball it.

EOF

    log "    spawning claude on $work_dir"
    claude_log="${work_dir}/CLAUDE.log"
    set +e
    if [[ "$DRY_RUN" == "1" ]]; then
      log "    DRY_RUN=1 — skipping claude invocation"
      claude_rc=0
      printf 'DRY_RUN — no claude executed\n' >"$claude_log"
    else
      (
        cd "$work_dir"
        "$CLAUDE_BIN" -p "$(cat PROMPT.md)" \
          --dangerously-skip-permissions \
          --output-format text
      ) >"$claude_log" 2>&1
      claude_rc=$?
    fi
    set -e

    if (( claude_rc != 0 )); then
      log "    claude failed rc=$claude_rc — see $claude_log"
      state_bump_retry "$issue_key"
      tail_log="$(tail -n 40 "$claude_log" 2>/dev/null | redact)"
      comment_body=$(printf 'Agent-loop attempt failed.\n\nlast log tail:\n```\n%s\n```' "$tail_log")
      gitlab_curl POST "/api/v4/projects/${pid}/issues/${iid}/notes" \
        "$(python3 -c 'import json,sys; print(json.dumps({"body": sys.stdin.read()}))' <<<"$comment_body")" \
        >>"$LOG_FILE" 2>&1 || true
      new_retries="$(state_get_retry "$issue_key")"
      if (( new_retries >= MAX_RETRIES )); then
        log "    removing agent-eligible label after $new_retries retries"
        gitlab_curl PUT "/api/v4/projects/${pid}/issues/${iid}" \
          '{"remove_labels":"agent-eligible"}' >>"$LOG_FILE" 2>&1 || true
      fi
      if [[ "$KEEP_FAILED" != "1" ]]; then
        (cd "$local_path" && git worktree remove --force "$work_dir" >>"$LOG_FILE" 2>&1 || true)
      fi
      processed=$((processed + 1))
      continue
    fi

    # Check if claude actually committed anything.
    head_main="$(cd "$local_path" && git rev-parse main)"
    head_branch="$(cd "$work_dir" && git rev-parse HEAD)"
    if [[ "$head_main" == "$head_branch" ]]; then
      log "    claude produced no commits (HEAD==main) — leaving worktree for inspection"
      gitlab_curl POST "/api/v4/projects/${pid}/issues/${iid}/notes" \
        '{"body":"Agent-loop ran but produced no commits. See AGENT-NOTE.md on the agent host if present. No MR opened."}' \
        >>"$LOG_FILE" 2>&1 || true
      processed=$((processed + 1))
      continue
    fi

    # Push branch.
    if [[ "$DRY_RUN" == "1" ]]; then
      log "    DRY_RUN=1 — skipping git push + MR open"
      processed=$((processed + 1))
      continue
    fi
    log "    pushing branch $branch"
    push_rc=0
    (
      cd "$work_dir"
      GIT_SSH_COMMAND="ssh -i ~/.ssh/nwp -o IdentitiesOnly=yes" \
        git push -u origin "$branch"
    ) >>"$LOG_FILE" 2>&1 || push_rc=$?
    if (( push_rc != 0 )); then
      log "    push failed rc=$push_rc"
      state_bump_retry "$issue_key"
      processed=$((processed + 1))
      continue
    fi

    # Compose a structured MR description with the 9 sections required by
    # docs/onboarding/pr-review-checklist.md. The deploy-on-merge.sh script
    # parses "Tier: T<n>" out of this body to decide auto-vs-manual live.
    diff_stat="$(cd "$work_dir" && git diff --stat HEAD~1 2>/dev/null | head -20 || true)"
    diff_files="$(cd "$work_dir" && git diff --name-only HEAD~1 2>/dev/null | head -20 || true)"
    # Full commit message — earlier we used `head -5` which clipped paragraphs
    # mid-sentence in the MR body. Capture the whole body; the MR description
    # tolerates length better than truncation.
    commit_msg="$(cd "$work_dir" && git log -1 --format='%B' 2>/dev/null || true)"
    mr_payload="$(python3 -c '
import json, sys, os
branch, title, iid, tier, web_url, diff_stat, diff_files, commit_msg = sys.argv[1:9]
files_lines = []
for f in (diff_files or "").splitlines():
    if f.strip():
        files_lines.append(f"- `{f.strip()}`")
files_block = "\n".join(files_lines) if files_lines else "_(no files reported)_"
description = (
    f"Closes #{iid} ({web_url})\n"
    f"\n"
    f"**Tier:** {tier}\n"
    f"\n"
    f"## What changed\n"
    f"{commit_msg.strip() or title}\n"
    f"\n"
    f"## Why\n"
    f"See the linked issue body for the user-reported failure mode.\n"
    f"\n"
    f"## Files changed\n"
    f"{files_block}\n"
    f"\n"
    f"## Diff stat\n"
    f"```\n{diff_stat}\n```\n"
    f"\n"
    f"## Tests added/modified\n"
    f"See files-changed list above; any path under `tests/` is new or modified test coverage.\n"
    f"\n"
    f"## Test results\n"
    f"Agent did not run the full Behat+PHPUnit suite locally. Reviewer must verify CI green before approving.\n"
    f"\n"
    f"## Rollback plan\n"
    f"`git revert <merge-sha>`. No schema migration in this diff (verify in Files changed if unsure).\n"
    f"\n"
    f"## Self-flags\n"
    f"_(Agent-loop has limited self-awareness. Reviewer must scan the diff for: ⚠ auth touch, ⚠ schema migration, ⚠ ADR change, ⚠ cross-site bridge.)_\n"
    f"\n"
    f"---\n"
    f"_Opened by agent-loop. Human review required; this MR will NOT auto-merge._\n"
)
print(json.dumps({
  "source_branch": branch,
  "target_branch": "main",
  "title": "[agent-loop] " + title,
  "description": description,
  "labels": tier,
  "remove_source_branch": True,
}))' "$branch" "$title" "$iid" "$tier" "$web_url" "$diff_stat" "$diff_files" "$commit_msg")"
    mr_resp="$(gitlab_curl POST "/api/v4/projects/${pid}/merge_requests" "$mr_payload" 2>>"$LOG_FILE" || echo '{}')"
    mr_url="$(printf '%s' "$mr_resp" | python3 -c 'import sys,json
try: d=json.load(sys.stdin); print(d.get("web_url",""))
except Exception: print("")')"
    if [[ -z "$mr_url" ]]; then
      log "    MR creation likely failed (no web_url in response)"
      state_bump_retry "$issue_key"
      processed=$((processed + 1))
      continue
    fi
    log "    MR opened: $mr_url"

    # Annotate the issue + label + bump daily.
    gitlab_curl POST "/api/v4/projects/${pid}/issues/${iid}/notes" \
      "$(python3 -c 'import json,sys; print(json.dumps({"body": "Agent-loop opened MR: " + sys.argv[1]}))' "$mr_url")" \
      >>"$LOG_FILE" 2>&1 || true
    gitlab_curl PUT "/api/v4/projects/${pid}/issues/${iid}" \
      '{"add_labels":"pr-opened"}' >>"$LOG_FILE" 2>&1 || true
    state_bump_daily

    # Cleanup successful worktree.
    (cd "$local_path" && git worktree remove --force "$work_dir" >>"$LOG_FILE" 2>&1 || true)
    processed=$((processed + 1))
  done
done

log "agent-loop done (processed=${processed})"
exit 0
