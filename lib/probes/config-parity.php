<?php

/**
 * @file
 * Config-parity probe — nwp/ops#145.
 *
 * Every enabled module ships its default config in `config/install/`. Drupal
 * reads that directory exactly ONCE, at module-install time, and
 * ConfigInstaller SILENTLY SKIPS any item whose dependencies are not met at the
 * instant it is processed. Under `drush site:install` / `drush recipe` config
 * syncing is ON for the whole run, so a large slice of the shipped config can
 * be skipped without a single error. The site boots and looks healthy while
 * missing content types, webforms, help topics, roles.
 *
 * That is exactly how the 2026-07-25 nwd parity rebuild produced a site 99
 * config entities short of nwc — including the `/apply` webform the homepage
 * links to. Nothing failed; nothing warned; `pl demo golden` then froze the
 * incomplete site into the image the nightly reset restores.
 *
 * This probe compares what is SHIPPED IN CODE against what is in ACTIVE CONFIG
 * and reports the difference. It reads only; it changes nothing.
 *
 * Two scopes are reported separately, because they carry different authority.
 * The discriminator is a `custom/` segment in the extension path, which is how
 * this fleet separates site-owned code from vendored code
 * (`modules/custom/nwc/...` and `profiles/custom/...` vs `modules/contrib/...`,
 * `profiles/contrib/...`, `core/...`):
 *
 *   custom — config shipped by the site's OWN modules. This is the site's
 *            definition of itself (content types, the /apply webform, help
 *            topics, growth tiers, roles). It is generated from the same repo
 *            as the site and nobody prunes it by hand, so any absence here is a
 *            build defect. This is the gating number.
 *   vendor — config shipped by core/contrib. Operators legitimately delete
 *            these (webform alone ships ~40 `webform_options.*` lists most
 *            sites never use), so a non-zero count here is normal and is
 *            reported for information only. As of 2026-07-26 nwc and nwd both
 *            sit at 53, i.e. it is a shared baseline, not per-site drift.
 *
 * Output (stable, line-oriented, parsed by lib/demo.sh:demo_config_parity):
 *
 *   MISSING <scope> <config.name> <providing_module>
 *   ...
 *   TOTAL_CUSTOM <n>
 *   TOTAL_VENDOR <n>
 *
 * `TOTAL_CUSTOM 0` is the pass signal. The absence of a TOTAL_CUSTOM line
 * means the probe itself did not complete and MUST be treated as a failure by
 * the caller (fail-closed) — never as a pass.
 *
 * Remedy for nwc-profile sites: `drush nwc:config-heal` (nwc_core), which
 * re-runs installDefaultConfig outside the syncing window. It only creates
 * config that is absent, so it is idempotent.
 *
 * Run with: drush php:script config-parity.php
 */

$module_handler = \Drupal::service('module_handler');
$module_list = \Drupal::service('extension.list.module');
$root = \Drupal::root();

$missing = [];

foreach (array_keys($module_handler->getModuleList()) as $module) {
  try {
    $path = $module_list->getPath($module);
    $dir = $root . '/' . $path . '/config/install';
  }
  catch (\Throwable $e) {
    // A module whose path cannot be resolved is a separate problem; the
    // extension system will already be shouting about it.
    continue;
  }
  if (!is_dir($dir)) {
    continue;
  }

  // Site-owned code lives under a `custom/` directory segment; everything else
  // (core/, modules/contrib/, profiles/contrib/) is vendored.
  $scope = preg_match('#(^|/)custom/#', $path) ? 'custom' : 'vendor';

  // Only the top level: nested directories under config/install are seed data
  // for a module's own installer (e.g. nwc_guild's guilds/*.yml), not config
  // objects, and must not be reported as missing config.
  foreach (glob($dir . '/*.yml') as $file) {
    $name = basename($file, '.yml');
    // isNew() is TRUE when the config object does not exist in active storage.
    if (\Drupal::config($name)->isNew()) {
      $missing[$name] = [$scope, $module];
    }
  }
}

ksort($missing);
$counts = ['custom' => 0, 'vendor' => 0];
foreach ($missing as $name => [$scope, $module]) {
  printf("MISSING %s %s %s\n", $scope, $name, $module);
  $counts[$scope]++;
}
printf("TOTAL_CUSTOM %d\n", $counts['custom']);
printf("TOTAL_VENDOR %d\n", $counts['vendor']);
