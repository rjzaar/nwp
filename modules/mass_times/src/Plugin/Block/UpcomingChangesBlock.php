<?php

namespace Drupal\mass_times\Plugin\Block;

use Drupal\Core\Block\BlockBase;
use Drupal\Core\Database\Connection;
use Drupal\Core\Entity\EntityTypeManagerInterface;
use Drupal\Core\Plugin\ContainerFactoryPluginInterface;
use Symfony\Component\DependencyInjection\ContainerInterface;

/**
 * Displays recent changes to mass times.
 *
 * @Block(
 *   id = "mass_times_upcoming_changes",
 *   admin_label = @Translation("Upcoming Mass Time Changes"),
 *   category = @Translation("Mass Times"),
 * )
 */
class UpcomingChangesBlock extends BlockBase implements ContainerFactoryPluginInterface {

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
   * Constructs an UpcomingChangesBlock.
   */
  public function __construct(array $configuration, $plugin_id, $plugin_definition, Connection $database, EntityTypeManagerInterface $entity_type_manager) {
    parent::__construct($configuration, $plugin_id, $plugin_definition);
    $this->database = $database;
    $this->entityTypeManager = $entity_type_manager;
  }

  /**
   * {@inheritdoc}
   */
  public static function create(ContainerInterface $container, array $configuration, $plugin_id, $plugin_definition) {
    return new static(
      $configuration,
      $plugin_id,
      $plugin_definition,
      $container->get('database'),
      $container->get('entity_type.manager')
    );
  }

  /**
   * {@inheritdoc}
   */
  public function build() {
    // Get recent diffs that indicate actual changes.
    $diffs = $this->database->select('mass_times_diffs', 'd')
      ->fields('d')
      ->condition('change_type', 'no_change', '<>')
      ->orderBy('d.id', 'DESC')
      ->range(0, 10)
      ->execute()
      ->fetchAll();

    if (empty($diffs)) {
      return [
        '#markup' => '<p>' . $this->t('No recent changes to mass times.') . '</p>',
        '#cache' => ['max-age' => 3600],
      ];
    }

    $rows = [];
    foreach ($diffs as $diff) {
      // Load the extraction to get the parish.
      $extraction = $this->database->select('mass_times_extractions', 'e')
        ->fields('e', ['parish_nid', 'created_at'])
        ->condition('id', $diff->extraction_id)
        ->execute()
        ->fetchObject();

      if (!$extraction) {
        continue;
      }

      $node = $this->entityTypeManager->getStorage('node')->load($extraction->parish_nid);
      $parish_name = $node ? $node->getTitle() : '—';

      $changes = json_decode($diff->changes_json, TRUE);
      $summary = is_array($changes) ? $this->summariseChanges($changes) : $diff->change_type;

      $rows[] = [
        $parish_name,
        $summary,
        $extraction->created_at ?? '—',
      ];
    }

    return [
      '#type' => 'table',
      '#header' => [
        $this->t('Parish'),
        $this->t('Change'),
        $this->t('Detected'),
      ],
      '#rows' => $rows,
      '#empty' => $this->t('No recent changes.'),
      '#cache' => ['max-age' => 3600],
    ];
  }

  /**
   * Summarise a changes array into a human-readable string.
   */
  protected function summariseChanges(array $changes): string {
    $parts = [];
    $added = $changes['added'] ?? [];
    $removed = $changes['removed'] ?? [];
    $modified = $changes['modified'] ?? [];

    if ($added) {
      $parts[] = count($added) . ' added';
    }
    if ($removed) {
      $parts[] = count($removed) . ' removed';
    }
    if ($modified) {
      $parts[] = count($modified) . ' modified';
    }

    return $parts ? implode(', ', $parts) : 'Updated';
  }

}
