<?php

/**
 * @file
 * READ-ONLY verification for the ops#328 clip-corpus import.
 *
 * Renders the two pages the operator actually looks at and counts what they
 * would show, rather than inferring "the page must be fine" from row counts:
 *
 *   /admin/nwc/videos    Drupal\nwc_video\Controller\VideoController::overview
 *   /admin/review/clips  Drupal\nwc_clip_review\Controller\ReviewQueueController::queue
 *
 * Writes nothing. Run via:
 *   pl drush <site> --tier=live --execute --script=scripts/demo/nwd-clip-corpus-verify.php
 */

$etm = \Drupal::entityTypeManager();

function nwc328_count(string $type): int {
  try {
    return (int) \Drupal::entityTypeManager()->getStorage($type)->getQuery()
      ->accessCheck(FALSE)->count()->execute();
  }
  catch (\Throwable $e) {
    return -1;
  }
}

echo "=== row counts ===\n";
foreach (['video_asset', 'clip_choice', 'lp_review_slot', 'video_snippet', 'clip_suggestion'] as $t) {
  printf("%-16s %d\n", $t, nwc328_count($t));
}

echo "\n=== /admin/nwc/videos (VideoController::overview) ===\n";
$overview = \Drupal::classResolver(\Drupal\nwc_video\Controller\VideoController::class)->overview();
$rows = $overview['#rows'] ?? [];
printf("table rows: %d\n", count($rows));
foreach (array_slice($rows, 0, 3) as $r) {
  echo '  | ' . implode(' | ', array_map('strval', $r)) . "\n";
}

echo "\n=== /admin/review/clips (ReviewQueueController::queue) ===\n";
$queue = \Drupal::classResolver(\Drupal\nwc_clip_review\Controller\ReviewQueueController::class)->queue();
$qrows = $queue['#rows'] ?? [];
printf("queue rows (capped at 100 by the controller): %d\n", count($qrows));
foreach (array_slice($qrows, 0, 3) as $r) {
  printf("  slot %s  %s/%s/%s  status=%s\n", $r['id'], $r['course_id'], $r['lp_id'], $r['depth'], $r['status']);
}

echo "\n=== candidates per slot (what the deep review shows) ===\n";
$slot_storage = $etm->getStorage('lp_review_slot');
$slot_service = \Drupal::service('nwc_clip_review.slot_service');
$ids = $slot_storage->getQuery()->accessCheck(FALSE)->execute();
$with = 0;
$total = 0;
$sample = NULL;
foreach ($slot_storage->loadMultiple($ids) as $slot) {
  $cands = $slot_service->candidates($slot, 100);
  $n = count($cands);
  $total += $n;
  if ($n > 0) {
    $with++;
    if ($sample === NULL) {
      $sample = [$slot, $cands];
    }
  }
}
printf("slots: %d — with >=1 candidate: %d — candidate snippets total: %d\n", count($ids), $with, $total);
if ($sample) {
  [$slot, $cands] = $sample;
  printf("sample slot %s (%s/%s/%s), current_clip=%s, %d candidates:\n",
    $slot->id(), $slot->get('course_id')->value, $slot->get('lp_id')->value,
    $slot->get('depth')->value,
    $slot->get('current_clip')->target_id ?: 'NONE', count($cands));
  $i = 0;
  foreach ($cands as $c) {
    if ($i++ >= 3) {
      break;
    }
    printf("   ep %s  %.1f-%.1fs  quality=%s  yt=%s  preview=%s\n",
      $c->get('episode')->value,
      (float) $c->get('start_s')->value,
      (float) $c->get('end_s')->value,
      $c->get('quality')->value,
      $c->get('youtube_id')->value ?: '-',
      substr((string) $c->get('preview_text')->value, 0, 50));
  }
}
