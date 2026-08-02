#!/usr/bin/env bats
# scripts/demo/ssd-restore-catalogue-content.php — the quiz/audio recovery merge.
#
# WHY THIS EXISTS: the converter that fed mod_depthcontent
# (~/dir/courses_v3/build/build_json.py, pre-e9c596f) emitted only the four base
# keys {id, title, session, depths} and dropped quiz_items entirely. The fix
# landed 2026-07-09 but the JSON was never rebuilt before the 2026-07-11 mbz
# export, so the 55 courses imported to ssd on 2026-08-02 carried 0 quiz items —
# proven live: all 247 imported rows decoded to exactly that base shape.
#
# This restore is PURELY ADDITIVE, and these tests pin the two properties that
# make it safe to run against a live demo site:
#   1. it adds quiz_items/audio and NEVER rewrites depth prose or video — depth
#      prose on live carries the ops#90 <details> XSS sanitisation, and rolling
#      that back would reintroduce a stored-XSS fix regression;
#   2. every document it produces passes the ONE schema validator we have
#      (ssd-seed-courses.php's, derived from the reader) — because the reader
#      fatals on a bare-string quiz option (view.php:533, PHP 8 TypeError).
#
# It is also idempotent: a second merge over its own output changes nothing,
# which is what makes re-running after a golden reset a no-op.

setup() {
  PROJECT_ROOT="$( cd "${BATS_TEST_DIRNAME}/../.." && pwd )"
  RESTORE="$PROJECT_ROOT/scripts/demo/ssd-restore-catalogue-content.php"
  WRAPPER="$PROJECT_ROOT/scripts/demo/ssd-restore-catalogue-content.sh"
  VALIDATOR="$PROJECT_ROOT/scripts/demo/ssd-seed-courses.php"
  PAYLOAD="$PROJECT_ROOT/servers/live/demo/ssd-catalogue-content.json"
  WORK="$BATS_TEST_TMPDIR/w"
  mkdir -p "$WORK"
}

# Fail closed when php is missing — a skip reports `ok`, and that is how schema
# tests silently vanish on an under-provisioned runner.
require_php() {
  if command -v php >/dev/null 2>&1; then return 0; fi
  if [ "${NWP_ALLOW_MISSING_PHP:-0}" = "1" ]; then
    skip "php-cli absent and NWP_ALLOW_MISSING_PHP=1 was set deliberately"
  fi
  echo "php-cli is NOT installed on this runner; this test FAILS rather than reporting 'ok'." >&2
  return 1
}

# A row in exactly the shape the 2026-07-11 mbz produced: the four base keys,
# a video block inside depths (which the base shape always carried), and no
# quiz_items at all.
write_prefix_shape_dump() {
  cat > "$WORK/dump.json" <<'JSON'
[{"id":999,"lpid":"A1.01","content_json":"{\"id\":\"A1.01\",\"title\":\"Every baptised person is called to holiness\",\"session\":1,\"depths\":{\"short\":{\"summary\":\"SHORT-PROSE-SENTINEL\"},\"standard\":{\"text\":\"STANDARD-PROSE-SENTINEL\",\"video\":{\"youtube_id\":\"lrgODcWOjnQ\",\"start\":\"1:05\"}}}}"}]
JSON
}

merge_local() {
  php "$RESTORE" --merge-local="$WORK/dump.json" --payload="$PAYLOAD" \
      --out-dir="$WORK/merged" --manifest="$WORK/manifest.json"
}

@test "shipped payload is a well-formed {_meta, content} envelope" {
  require_php
  [ -f "$PAYLOAD" ]
  run php -r '$p=json_decode(file_get_contents($argv[1]),true);
    if(!is_array($p)||!isset($p["content"])||!is_array($p["content"])){exit(1);}
    if(count($p["content"])<1){exit(1);}
    echo count($p["content"]);' "$PAYLOAD"
  [ "$status" -eq 0 ]
  [ "$output" -gt 0 ]
}

@test "every quiz item in the shipped payload satisfies the reader contract" {
  require_php
  # view.php:529-537 reads $opt['correct'] unguarded — a bare-string option is a
  # PHP 8 TypeError (fatal page). view.php:103-108 restricts difficulty.
  run php -r '
    $p=json_decode(file_get_contents($argv[1]),true);
    $ok=["standard","longer","detailed","advanced"]; $bad=0;
    foreach($p["content"] as $lp=>$e){
      foreach(($e["quiz_items"]??[]) as $q){
        if(!is_array($q)){$bad++;continue;}
        if(!isset($q["question"])||!isset($q["type"])){$bad++;}
        if(isset($q["difficulty"])&&!in_array($q["difficulty"],$ok,true)){$bad++;}
        if(($q["type"]??"")==="multichoice"){
          $c=0;
          foreach(($q["options"]??[]) as $o){
            if(!is_array($o)){$bad++;continue;}
            if(!isset($o["text"])||!array_key_exists("correct",$o)){$bad++;}
            if(!empty($o["correct"])){$c++;}
          }
          if($c<1){$bad++;}
        }
      }
    }
    echo $bad;' "$PAYLOAD"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "merge turns the pre-fix base shape into a schema-valid document" {
  require_php
  write_prefix_shape_dump
  run merge_local
  [ "$status" -eq 0 ]
  [[ "$output" == *"changed=1"* ]]
  [ -f "$WORK/merged/row-999.json" ]
  # The ONE validator, not a second copy of the schema.
  run php "$VALIDATOR" --validate-file="$WORK/merged/row-999.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SCHEMA-OK"* ]]
}

@test "merge is ADDITIVE: depth prose and the video block survive untouched" {
  require_php
  write_prefix_shape_dump
  merge_local
  run php -r '$d=json_decode(file_get_contents($argv[1]),true);
    if($d["depths"]["short"]["summary"]!=="SHORT-PROSE-SENTINEL"){echo "short-prose-lost";exit(1);}
    if($d["depths"]["standard"]["text"]!=="STANDARD-PROSE-SENTINEL"){echo "standard-prose-lost";exit(1);}
    if(($d["depths"]["standard"]["video"]["youtube_id"]??"")!=="lrgODcWOjnQ"){echo "video-lost";exit(1);}
    if(($d["depths"]["standard"]["video"]["start"]??"")!=="1:05"){echo "video-clip-lost";exit(1);}
    if($d["title"]!=="Every baptised person is called to holiness"){echo "title-changed";exit(1);}
    if((int)$d["session"]!==1){echo "session-changed";exit(1);}
    echo "preserved";' "$WORK/merged/row-999.json"
  [ "$status" -eq 0 ]
  [ "$output" = "preserved" ]
}

@test "merge actually adds the quiz items it was run for" {
  require_php
  write_prefix_shape_dump
  merge_local
  run php -r '$d=json_decode(file_get_contents($argv[1]),true);
    echo is_array($d["quiz_items"]??null) ? count($d["quiz_items"]) : 0;' "$WORK/merged/row-999.json"
  [ "$status" -eq 0 ]
  [ "$output" -gt 0 ]
}

@test "merge is idempotent: re-merging its own output changes nothing" {
  require_php
  write_prefix_shape_dump
  merge_local
  first="$(cat "$WORK/merged/row-999.json")"
  # Feed the merged document back in as the live row.
  php -r '$j=file_get_contents($argv[1]);
    echo json_encode([["id"=>999,"lpid"=>"A1.01","content_json"=>$j]]);' \
    "$WORK/merged/row-999.json" > "$WORK/dump.json"
  rm -rf "$WORK/merged"
  run merge_local
  [ "$status" -eq 0 ]
  [[ "$output" == *"changed=0"* ]]
  [[ "$output" == *"already-current=1"* ]]
  # And nothing was emitted for re-application.
  [ ! -f "$WORK/merged/row-999.json" ]
}

@test "manifest records a sha256 that matches the merged bytes (the apply gate)" {
  require_php
  write_prefix_shape_dump
  merge_local
  run php -r '$m=json_decode(file_get_contents($argv[1]),true);
    $r=$m["rows"][0];
    $h=hash("sha256",file_get_contents($argv[2]));
    echo ($r["sha256"]===$h && (int)$r["id"]===999) ? "match" : "MISMATCH";' \
    "$WORK/manifest.json" "$WORK/merged/row-999.json"
  [ "$status" -eq 0 ]
  [ "$output" = "match" ]
}

@test "a row with no payload entry is left alone, not blanked" {
  require_php
  cat > "$WORK/dump.json" <<'JSON'
[{"id":1001,"lpid":"ZZ.99","content_json":"{\"id\":\"ZZ.99\",\"title\":\"Not in the corpus\",\"session\":1,\"depths\":{\"short\":{\"summary\":\"x\"}}}"}]
JSON
  run merge_local
  [ "$status" -eq 0 ]
  [[ "$output" == *"no-payload-entry=1"* ]]
  [ ! -f "$WORK/merged/row-1001.json" ]
}

@test "a row whose live content_json does not decode is skipped, not written" {
  require_php
  cat > "$WORK/dump.json" <<'JSON'
[{"id":1002,"lpid":"A1.01","content_json":"{ this is not json"}]
JSON
  run merge_local
  [ "$status" -eq 0 ]
  [ ! -f "$WORK/merged/row-1002.json" ]
}

@test "the on-box phases refuse to run with no payload spliced in" {
  require_php
  # Straight `php file.php` with no --merge-local reaches the bootstrap; without
  # a Moodle root it must exit non-zero rather than proceed to write anything.
  cd "$WORK"
  run php "$RESTORE" --check
  [ "$status" -ne 0 ]
}

@test "wrapper refuses a prod tier and an unknown option" {
  run bash "$WRAPPER" --site=ssd --tier=prod --check
  [ "$status" -ne 0 ]
  [[ "$output" == *"REFUSED"* ]]

  run bash "$WRAPPER" --nonsense
  [ "$status" -ne 0 ]
}

@test "wrapper refuses a payload path that does not exist" {
  run bash "$WRAPPER" --site=ssd --tier=dev --payload=/nonexistent/payload.json --check
  [ "$status" -ne 0 ]
  [[ "$output" == *"REFUSED"* ]]
}

@test "shell and php sources parse" {
  require_php
  run bash -n "$WRAPPER"
  [ "$status" -eq 0 ]
  run php -l "$RESTORE"
  [ "$status" -eq 0 ]
}
