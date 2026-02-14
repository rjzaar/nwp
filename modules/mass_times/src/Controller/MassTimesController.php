<?php

namespace Drupal\mass_times\Controller;

use Drupal\Core\Controller\ControllerBase;
use Drupal\Core\Database\Connection;
use Drupal\mass_times\Service\ParishDataService;
use Symfony\Component\DependencyInjection\ContainerInterface;

/**
 * Controller for Mass Times pages.
 */
class MassTimesController extends ControllerBase {

  /**
   * The database connection.
   *
   * @var \Drupal\Core\Database\Connection
   */
  protected $database;

  /**
   * The parish data service.
   *
   * @var \Drupal\mass_times\Service\ParishDataService
   */
  protected $parishData;

  /**
   * Constructs a MassTimesController.
   */
  public function __construct(Connection $database, ParishDataService $parish_data) {
    $this->database = $database;
    $this->parishData = $parish_data;
  }

  /**
   * {@inheritdoc}
   */
  public static function create(ContainerInterface $container) {
    return new static(
      $container->get('database'),
      $container->get('mass_times.parish_data')
    );
  }

  /**
   * Public parish map page.
   */
  public function map() {
    $config = $this->config('mass_times.settings');
    $centre_lat = $config->get('centre_lat');
    $centre_lng = $config->get('centre_lng');
    $radius_km = $config->get('radius_km');

    $parishes = $this->parishData->getParishesNear($centre_lat, $centre_lng, $radius_km);

    $markers = [];
    foreach ($parishes as $result) {
      $node = $result['node'];
      if (!$node->hasField('field_location') || $node->get('field_location')->isEmpty()) {
        continue;
      }
      $location = $node->get('field_location')->first();
      $markers[] = [
        'title' => $node->getTitle(),
        'lat' => $location->get('lat')->getValue(),
        'lng' => $location->get('lon')->getValue(),
        'distance' => round($result['distance'], 1),
        'url' => $node->toUrl()->toString(),
      ];
    }

    return [
      '#theme' => 'mass_times_parish_map',
      '#centre_lat' => $centre_lat,
      '#centre_lng' => $centre_lng,
      '#radius_km' => $radius_km,
      '#parishes' => $markers,
      '#attached' => [
        'library' => ['mass_times/parish_map'],
      ],
      '#cache' => ['max-age' => 86400],
    ];
  }

  /**
   * Admin dashboard showing extraction status.
   */
  public function adminDashboard() {
    $build = [];

    // Parish count.
    $parish_count = $this->entityTypeManager()
      ->getStorage('node')
      ->getQuery()
      ->condition('type', 'parish')
      ->accessCheck(FALSE)
      ->count()
      ->execute();

    // Recent extractions.
    $recent_extractions = $this->database->select('mass_times_extractions', 'e')
      ->fields('e')
      ->orderBy('created_at', 'DESC')
      ->range(0, 10)
      ->execute()
      ->fetchAll();

    // Tier distribution.
    $tier_counts = [];
    foreach ([1, 2, 3] as $tier) {
      $tier_counts[$tier] = (int) $this->database->select('mass_times_extractions', 'e')
        ->condition('extraction_tier', $tier)
        ->countQuery()
        ->execute()
        ->fetchField();
    }

    // Pending user reports.
    $pending_reports = (int) $this->database->select('mass_times_user_reports', 'r')
      ->condition('status', 'new')
      ->countQuery()
      ->execute()
      ->fetchField();

    $build['summary'] = [
      '#type' => 'container',
      '#attributes' => ['class' => ['mass-times-summary']],
      'parishes' => [
        '#markup' => '<div class="summary-item"><strong>' . $this->t('Parishes:') . '</strong> ' . $parish_count . '</div>',
      ],
      'tier_distribution' => [
        '#markup' => '<div class="summary-item"><strong>' . $this->t('Tier Distribution:') . '</strong> '
          . $this->t('T1: @t1, T2: @t2, T3: @t3', [
            '@t1' => $tier_counts[1],
            '@t2' => $tier_counts[2],
            '@t3' => $tier_counts[3],
          ]) . '</div>',
      ],
      'reports' => [
        '#markup' => '<div class="summary-item"><strong>' . $this->t('Pending Reports:') . '</strong> ' . $pending_reports . '</div>',
      ],
    ];

    // Recent extractions table.
    $header = [
      $this->t('Parish'),
      $this->t('Tier'),
      $this->t('Status'),
      $this->t('Confidence'),
      $this->t('Date'),
    ];

    $rows = [];
    foreach ($recent_extractions as $extraction) {
      $parish_name = '—';
      if ($extraction->parish_nid) {
        $node = $this->entityTypeManager()->getStorage('node')->load($extraction->parish_nid);
        if ($node) {
          $parish_name = $node->getTitle();
        }
      }
      $rows[] = [
        $parish_name,
        'Tier ' . $extraction->extraction_tier,
        $extraction->validation_status ?? '—',
        $extraction->confidence_score ? number_format($extraction->confidence_score * 100) . '%' : '—',
        $extraction->created_at ?? '—',
      ];
    }

    $build['extractions'] = [
      '#type' => 'table',
      '#header' => $header,
      '#rows' => $rows,
      '#empty' => $this->t('No extractions yet. Run the extraction pipeline to populate data.'),
      '#caption' => $this->t('Recent Extractions'),
    ];

    return $build;
  }

}
