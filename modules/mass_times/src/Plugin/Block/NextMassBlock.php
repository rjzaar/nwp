<?php

namespace Drupal\mass_times\Plugin\Block;

use Drupal\Core\Block\BlockBase;
use Drupal\Core\Database\Connection;
use Drupal\Core\Plugin\ContainerFactoryPluginInterface;
use Symfony\Component\DependencyInjection\ContainerInterface;

/**
 * Displays the next upcoming mass time.
 *
 * @Block(
 *   id = "mass_times_next_mass",
 *   admin_label = @Translation("Next Mass"),
 *   category = @Translation("Mass Times"),
 * )
 */
class NextMassBlock extends BlockBase implements ContainerFactoryPluginInterface {

  /**
   * The database connection.
   *
   * @var \Drupal\Core\Database\Connection
   */
  protected $database;

  /**
   * Constructs a NextMassBlock.
   */
  public function __construct(array $configuration, $plugin_id, $plugin_definition, Connection $database) {
    parent::__construct($configuration, $plugin_id, $plugin_definition);
    $this->database = $database;
  }

  /**
   * {@inheritdoc}
   */
  public static function create(ContainerInterface $container, array $configuration, $plugin_id, $plugin_definition) {
    return new static(
      $configuration,
      $plugin_id,
      $plugin_definition,
      $container->get('database')
    );
  }

  /**
   * {@inheritdoc}
   */
  public function build() {
    $now = new \DateTime('now', new \DateTimeZone('Australia/Melbourne'));
    $current_day = $now->format('l');
    $current_time = $now->format('H:i');
    $day_order = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    $current_day_index = array_search($current_day, $day_order);

    // Get the latest confirmed extractions for all parishes.
    $extractions = $this->database->select('mass_times_extractions', 'e')
      ->fields('e', ['parish_nid', 'extracted_json'])
      ->condition('validation_status', 'confirmed')
      ->orderBy('created_at', 'DESC')
      ->execute()
      ->fetchAll();

    // Deduplicate to latest per parish.
    $parish_extractions = [];
    foreach ($extractions as $row) {
      if (!isset($parish_extractions[$row->parish_nid])) {
        $parish_extractions[$row->parish_nid] = $row;
      }
    }

    // Find the next mass across all parishes.
    $next_masses = [];
    foreach ($parish_extractions as $nid => $row) {
      $times = json_decode($row->extracted_json, TRUE);
      if (!is_array($times)) {
        continue;
      }
      foreach ($times as $entry) {
        $day = $entry['day'] ?? '';
        $time = $entry['time'] ?? '';
        if (!$day || !$time) {
          continue;
        }
        $day_index = array_search($day, $day_order);
        if ($day_index === FALSE) {
          continue;
        }
        // Calculate days until this mass.
        $days_ahead = ($day_index - $current_day_index + 7) % 7;
        if ($days_ahead === 0 && $time <= $current_time) {
          $days_ahead = 7;
        }
        $next_masses[] = [
          'parish_nid' => $nid,
          'day' => $day,
          'time' => $time,
          'type' => $entry['mass_type'] ?? 'Regular',
          'days_ahead' => $days_ahead,
          'sort_key' => sprintf('%d_%s', $days_ahead, $time),
        ];
      }
    }

    usort($next_masses, fn($a, $b) => strcmp($a['sort_key'], $b['sort_key']));
    $upcoming = array_slice($next_masses, 0, 5);

    if (empty($upcoming)) {
      return [
        '#markup' => '<p>' . $this->t('No upcoming mass times available.') . '</p>',
        '#cache' => ['max-age' => 3600],
      ];
    }

    $items = [];
    $node_storage = \Drupal::entityTypeManager()->getStorage('node');
    foreach ($upcoming as $mass) {
      $node = $node_storage->load($mass['parish_nid']);
      $parish_name = $node ? $node->getTitle() : '—';
      $label = $mass['days_ahead'] === 0
        ? $this->t('Today')
        : ($mass['days_ahead'] === 1 ? $this->t('Tomorrow') : $mass['day']);
      $items[] = [
        '#markup' => '<div class="next-mass-item"><strong>' . $label . ' ' . $mass['time'] . '</strong> — ' . $parish_name . '</div>',
      ];
    }

    return [
      '#theme' => 'item_list',
      '#items' => $items,
      '#title' => $this->t('Next Masses'),
      '#cache' => ['max-age' => 900],
    ];
  }

}
