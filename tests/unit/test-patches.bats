#!/usr/bin/env bats
# =============================================================================
# tests/unit/test-patches.bats — `pl patches` (nwp/ops#223)
# =============================================================================
# ops#223 is an Art. 17 blocker whose fix is a composer patch to contrib
# (goalgorilla/open_social). That makes "is the patch still applied?" a
# security question, not housekeeping: a `composer update` that quietly drops
# it restores a fatal on the right-to-erasure path, and nothing in the estate
# was watching for that.
#
# The load-bearing assertion here is NOT-APPLIED. A declaration in composer.json
# is a claim about the built tree; the only way to know is to look at the tree.
# A check that verified the declaration alone would go green on precisely the
# state it exists to catch — patch written down, code unpatched — which is what
# a dropped patch looks like from the outside.
#
# Second load-bearing assertion: FILE MISSING. nwd-project tracks only
# composer.json and .gitignore, so its patches/ directory is untracked and a
# fresh clone declares patches it does not carry. That is a real, current state
# in this estate, and it must be red.
#
# Anti-vacuity: an unparseable composer.json must exit 2 (CANNOT-VERIFY), never
# 0. "No problems found" over a corpus that could not be read is the failure
# mode `pl moodle core-patch` was already bitten by (2026-07-27) and this verb
# inherits its refusal.
#
# Self-contained fixtures; no network, no live site, no composer.
# =============================================================================

PATCHES_SH="${BATS_TEST_DIRNAME}/../../scripts/commands/patches.sh"

setup() {
  TMP="$(mktemp -d)"
  export PROJECT_ROOT="${TMP}/nwp"
  PROJ="${PROJECT_ROOT}/sites/demo/dev"
  PKG="${PROJ}/html/modules/contrib/widget"
  mkdir -p "${PKG}/src" "${PROJ}/patches"

  # The upstream file, unpatched.
  cat > "${PKG}/src/Widget.php" <<'PHP'
<?php

class Widget {

  public function go($thing) {
    return $thing->id();
  }

}
PHP

  # A patch that null-guards it.
  cat > "${PROJ}/patches/widget-null-guard.patch" <<'PATCH'
Guard the dereference.

--- a/src/Widget.php
+++ b/src/Widget.php
@@ -3,6 +3,9 @@
 class Widget {

   public function go($thing) {
+    if ($thing === NULL) {
+      return NULL;
+    }
     return $thing->id();
   }

PATCH

  cat > "${PROJ}/composer.json" <<'JSON'
{
  "name": "demo/project",
  "extra": {
    "installer-paths": {
      "html/modules/contrib/{$name}": ["type:drupal-module"]
    },
    "enable-patching": true,
    "composer-exit-on-patch-failure": true,
    "patches": {
      "drupal/widget": {
        "Guard the dereference": "patches/widget-null-guard.patch"
      }
    }
  }
}
JSON
}

teardown() {
  [ -n "${TMP:-}" ] && rm -rf "${TMP}"
}

apply_the_patch() {
  ( cd "${PKG}" && patch -p1 --silent < "${PROJ}/patches/widget-null-guard.patch" )
}

# --- THE LOAD-BEARING ONE -----------------------------------------------------

@test "declared but NOT applied in the built tree is RED" {
  run "${PATCHES_SH}" demo --tier=dev
  [ "$status" -eq 1 ]
  [[ "$output" == *"NOT APPLIED"* ]]
  [[ "$output" == *"NOT in the built tree"* ]]
}

@test "declared AND applied is GREEN" {
  apply_the_patch
  run "${PATCHES_SH}" demo --tier=dev
  [ "$status" -eq 0 ]
  [[ "$output" == *"APPLIED"* ]]
  [[ "$output" != *"NOT APPLIED"* ]]
}

@test "a patch that stops applying (upstream moved) goes back to RED" {
  apply_the_patch
  run "${PATCHES_SH}" demo --tier=dev
  [ "$status" -eq 0 ]

  # Simulate `composer update` pulling a new upstream that reverts the file:
  # the declaration is untouched, the code is not patched.
  cat > "${PKG}/src/Widget.php" <<'PHP'
<?php

class Widget {

  public function go($thing) {
    return $thing->id();
  }

}
PHP
  run "${PATCHES_SH}" demo --tier=dev
  [ "$status" -eq 1 ]
  [[ "$output" == *"NOT APPLIED"* ]]
}

# --- Declaration integrity ----------------------------------------------------

@test "a declared patch file that does not exist is RED" {
  rm "${PROJ}/patches/widget-null-guard.patch"
  run "${PATCHES_SH}" demo --tier=dev
  [ "$status" -eq 1 ]
  [[ "$output" == *"FILE MISSING"* ]]
  [[ "$output" == *"fresh clone"* ]]
}

@test "enable-patching false is RED even when the code happens to be patched" {
  apply_the_patch
  sed -i 's/"enable-patching": true/"enable-patching": false/' "${PROJ}/composer.json"
  run "${PATCHES_SH}" demo --tier=dev
  [ "$status" -eq 1 ]
  [[ "$output" == *"enable-patching"* ]]
  [[ "$output" == *"NOT SET"* ]]
}

@test "composer-exit-on-patch-failure false is RED — that flag is the whole guarantee" {
  apply_the_patch
  sed -i 's/"composer-exit-on-patch-failure": true/"composer-exit-on-patch-failure": false/' "${PROJ}/composer.json"
  run "${PATCHES_SH}" demo --tier=dev
  [ "$status" -eq 1 ]
  [[ "$output" == *"composer-exit-on-patch-failure"* ]]
}

# --- Anti-vacuity -------------------------------------------------------------

@test "an unparseable composer.json is CANNOT-VERIFY (exit 2), never a pass" {
  echo '{ this is not json' > "${PROJ}/composer.json"
  run "${PATCHES_SH}" demo --tier=dev
  [ "$status" -eq 2 ]
  [[ "$output" == *"CANNOT-VERIFY"* ]]
  [[ "$output" == *"not a declaration that is empty"* ]]
}

@test "a missing project directory is CANNOT-VERIFY (exit 2), never a pass" {
  run "${PATCHES_SH}" nosuchsite --tier=dev
  [ "$status" -eq 2 ]
  [[ "$output" == *"CANNOT-VERIFY"* ]]
}

@test "an unbuilt package directory is RED, not silently skipped" {
  rm -rf "${PKG}"
  run "${PATCHES_SH}" demo --tier=dev
  [ "$status" -eq 1 ]
  [[ "$output" == *"CANNOT-VERIFY"* ]]
  [[ "$output" == *"composer install"* ]]
}

@test "a project with no patches declared is GREEN and says so" {
  cat > "${PROJ}/composer.json" <<'JSON'
{ "name": "demo/project", "extra": { "enable-patching": true, "composer-exit-on-patch-failure": true } }
JSON
  run "${PATCHES_SH}" demo --tier=dev
  [ "$status" -eq 0 ]
  [[ "$output" == *"no contrib patches declared"* ]]
}

@test "a remote URL patch is reported as unverifiable, not as applied" {
  cat > "${PROJ}/composer.json" <<'JSON'
{
  "name": "demo/project",
  "extra": {
    "installer-paths": { "html/modules/contrib/{$name}": ["type:drupal-module"] },
    "enable-patching": true,
    "composer-exit-on-patch-failure": true,
    "patches": {
      "drupal/widget": {
        "Some d.o issue": "https://www.drupal.org/files/issues/x.patch"
      }
    }
  }
}
JSON
  run "${PATCHES_SH}" demo --tier=dev
  [[ "$output" == *"REMOTE"* ]]
  [[ "$output" != *"[APPLIED]"* ]]
}

# --- Interface ----------------------------------------------------------------

@test "an unknown tier is refused" {
  run "${PATCHES_SH}" demo --tier=prod
  [ "$status" -eq 2 ]
  [[ "$output" == *"Unknown tier"* ]]
}

@test "--help exits 0 and documents the reverse dry-run" {
  run "${PATCHES_SH}" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"reverse dry-run"* ]]
}
