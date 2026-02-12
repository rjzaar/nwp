<?php

namespace Drupal\mass_times\Commands;

use Drupal\Core\Database\Connection;
use Drupal\Core\Entity\EntityTypeManagerInterface;
use Drush\Commands\DrushCommands;

/**
 * Drush commands for Mass Times module.
 */
class MassTimesCommands extends DrushCommands {

  /**
   * The database connection.
   *
   * @var \Drupal\Core\Database\Connection
   */
  protected $database;

  /**
   * The entity type manager.
   *
   * @var \Drupal\Core\Entity\EntityTypeManagerInterface
   */
  protected $entityTypeManager;

  /**
   * Constructs MassTimesCommands.
   */
  public function __construct(Connection $database, EntityTypeManagerInterface $entity_type_manager) {
    parent::__construct();
    $this->database = $database;
    $this->entityTypeManager = $entity_type_manager;
  }

  /**
   * Show mass times extraction status.
   *
   * @command mass-times:status
   * @aliases mt-status
   */
  public function status(): void {
    // Parish count.
    $parish_count = $this->entityTypeManager->getStorage('node')
      ->getQuery()
      ->condition('type', 'parish')
      ->accessCheck(FALSE)
      ->count()
      ->execute();

    // Extraction counts by tier.
    $tier_counts = [];
    foreach ([1, 2, 3] as $tier) {
      $tier_counts[$tier] = (int) $this->database->select('mass_times_extractions', 'e')
        ->condition('extraction_tier', $tier)
        ->countQuery()
        ->execute()
        ->fetchField();
    }

    // Pending reports.
    $pending_reports = (int) $this->database->select('mass_times_user_reports', 'r')
      ->condition('status', 'new')
      ->countQuery()
      ->execute()
      ->fetchField();

    $this->io()->title('Mass Times Status');
    $this->io()->listing([
      "Parishes: $parish_count",
      "Extractions — T1: {$tier_counts[1]}, T2: {$tier_counts[2]}, T3: {$tier_counts[3]}",
      "Pending reports: $pending_reports",
    ]);
  }

  /**
   * Import extraction results from JSON file.
   *
   * @param string $file
   *   Path to the JSON results file.
   *
   * @command mass-times:import
   * @aliases mt-import
   */
  public function import(string $file): void {
    if (!file_exists($file)) {
      $this->logger()->error("File not found: $file");
      return;
    }

    $data = json_decode(file_get_contents($file), TRUE);
    if (!is_array($data)) {
      $this->logger()->error("Invalid JSON in $file");
      return;
    }

    $imported = 0;
    foreach ($data as $result) {
      $parish_id = $result['parish_id'] ?? '';
      if (!$parish_id) {
        continue;
      }

      // Look up the parish node by slug field or title.
      $nids = $this->entityTypeManager->getStorage('node')
        ->getQuery()
        ->condition('type', 'parish')
        ->condition('field_parish_slug', $parish_id)
        ->accessCheck(FALSE)
        ->execute();

      if (empty($nids)) {
        $this->logger()->warning("Parish not found: $parish_id");
        continue;
      }

      $nid = reset($nids);

      $this->database->insert('mass_times_extractions')
        ->fields([
          'parish_nid' => $nid,
          'extraction_tier' => $result['tier'] ?? 2,
          'raw_content_hash' => $result['content_hash'] ?? '',
          'extracted_json' => json_encode($result['times'] ?? []),
          'confidence_score' => $result['confidence'] ?? 0.0,
          'validation_status' => $result['validation_status'] ?? 'provisional',
          'llm_model' => $result['llm_model'] ?? NULL,
          'llm_cost_usd' => $result['llm_cost_usd'] ?? 0.0,
          'created_at' => date('Y-m-d H:i:s'),
        ])
        ->execute();

      $imported++;
    }

    $this->logger()->success("Imported $imported extraction results.");
  }

  /**
   * List recent extraction diffs (changes).
   *
   * @param int $limit
   *   Number of diffs to show.
   *
   * @command mass-times:diffs
   * @aliases mt-diffs
   * @option limit Number of diffs to show.
   */
  public function diffs(int $limit = 20): void {
    $diffs = $this->database->select('mass_times_diffs', 'd')
      ->fields('d')
      ->orderBy('d.id', 'DESC')
      ->range(0, $limit)
      ->execute()
      ->fetchAll();

    if (empty($diffs)) {
      $this->io()->note('No diffs recorded yet.');
      return;
    }

    $rows = [];
    foreach ($diffs as $diff) {
      $extraction = $this->database->select('mass_times_extractions', 'e')
        ->fields('e', ['parish_nid', 'created_at'])
        ->condition('id', $diff->extraction_id)
        ->execute()
        ->fetchObject();

      $parish_name = '—';
      if ($extraction && $extraction->parish_nid) {
        $node = $this->entityTypeManager->getStorage('node')->load($extraction->parish_nid);
        if ($node) {
          $parish_name = $node->getTitle();
        }
      }

      $rows[] = [
        $diff->id,
        $parish_name,
        $diff->change_type ?? '—',
        $extraction->created_at ?? '—',
      ];
    }

    $this->io()->table(['ID', 'Parish', 'Change Type', 'Date'], $rows);
  }

  /**
   * List pending user reports.
   *
   * @command mass-times:reports
   * @aliases mt-reports
   */
  public function reports(): void {
    $reports = $this->database->select('mass_times_user_reports', 'r')
      ->fields('r')
      ->condition('status', 'new')
      ->orderBy('created_at', 'DESC')
      ->execute()
      ->fetchAll();

    if (empty($reports)) {
      $this->io()->success('No pending reports.');
      return;
    }

    $rows = [];
    foreach ($reports as $report) {
      $node = $this->entityTypeManager->getStorage('node')->load($report->parish_nid);
      $parish_name = $node ? $node->getTitle() : '—';
      $rows[] = [
        $report->id,
        $parish_name,
        $report->report_type ?? '—',
        mb_substr($report->description ?? '', 0, 60),
        $report->created_at ?? '—',
      ];
    }

    $this->io()->table(['ID', 'Parish', 'Type', 'Description', 'Date'], $rows);
  }

  /**
   * Resolve a user report.
   *
   * @param int $report_id
   *   The report ID to resolve.
   * @param string $notes
   *   Resolution notes.
   *
   * @command mass-times:resolve
   * @aliases mt-resolve
   */
  public function resolve(int $report_id, string $notes = ''): void {
    $updated = $this->database->update('mass_times_user_reports')
      ->fields([
        'status' => 'resolved',
        'resolution_notes' => $notes,
        'resolved_at' => date('Y-m-d H:i:s'),
      ])
      ->condition('id', $report_id)
      ->execute();

    if ($updated) {
      $this->logger()->success("Report #$report_id resolved.");
    }
    else {
      $this->logger()->error("Report #$report_id not found.");
    }
  }

}
