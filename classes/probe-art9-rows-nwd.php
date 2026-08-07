<?php
// nwd Art.9 formation-rows probe v2 (ops#234): counts Art.9 (Tier A) entities
// per the erasure registry, split into rows owned by DEMO-FENCED accounts
// (@demo.invalid — synthetic by construction, wiped nightly) vs rows owned by
// anyone else. The demo-class claim is about the LATTER being zero.
use Drupal\nwc_privacy\Service\Art9ErasureService;

$reg = Art9ErasureService::art9EntityFields();
if (empty($reg)) { fwrite(STDERR, "CANNOT VERIFY: empty art9 registry\n"); exit(2); }
$etm = \Drupal::entityTypeManager();
$fencedtotal = 0; $realtotal = 0;
foreach ($reg as $type => $uidfields) {
  if (!$etm->hasDefinition($type)) { printf("%s: no-definition\n", $type); continue; }
  $storage = $etm->getStorage($type);
  $ids = $storage->getQuery()->accessCheck(FALSE)->execute();
  $fenced = 0; $real = 0;
  foreach ($storage->loadMultiple($ids) as $e) {
    $isfenced = FALSE;
    foreach ((array) $uidfields as $f) {
      if (!$e->hasField($f) || $e->get($f)->isEmpty()) { continue; }
      $u = \Drupal\user\Entity\User::load((int) $e->get($f)->target_id ?: (int) $e->get($f)->value);
      if ($u && str_ends_with((string) $u->getEmail(), '@demo.invalid')) { $isfenced = TRUE; break; }
    }
    $isfenced ? $fenced++ : $real++;
  }
  if ($fenced + $real > 0) { printf("%s: fenced=%d real=%d\n", $type, $fenced, $real); }
  $fencedtotal += $fenced; $realtotal += $real;
}
printf("fenced_total: %d\nreal_total: %d\n", $fencedtotal, $realtotal);
