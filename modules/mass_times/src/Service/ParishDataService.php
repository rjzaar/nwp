<?php

namespace Drupal\mass_times\Service;

use Drupal\Core\Database\Connection;
use Drupal\Core\Entity\EntityTypeManagerInterface;

/**
 * Service for accessing parish data.
 */
class ParishDataService {

  /**
   * The entity type manager.
   *
   * @var \Drupal\Core\Entity\EntityTypeManagerInterface
   */
  protected $entityTypeManager;

  /**
   * The database connection.
   *
   * @var \Drupal\Core\Database\Connection
   */
  protected $database;

  /**
   * The proximity service.
   *
   * @var \Drupal\mass_times\Service\ProximityService
   */
  protected $proximity;

  /**
   * Constructs a ParishDataService.
   */
  public function __construct(EntityTypeManagerInterface $entity_type_manager, Connection $database, ProximityService $proximity) {
    $this->entityTypeManager = $entity_type_manager;
    $this->database = $database;
    $this->proximity = $proximity;
  }

  /**
   * Get all active parishes.
   *
   * @return \Drupal\node\NodeInterface[]
   *   Array of parish nodes.
   */
  public function getActiveParishes() {
    $nids = $this->entityTypeManager->getStorage('node')
      ->getQuery()
      ->condition('type', 'parish')
      ->condition('status', 1)
      ->accessCheck(FALSE)
      ->sort('title')
      ->execute();

    return $this->entityTypeManager->getStorage('node')->loadMultiple($nids);
  }

  /**
   * Get parishes within a radius of a point.
   *
   * @param float $lat
   *   Centre latitude.
   * @param float $lng
   *   Centre longitude.
   * @param float $radius_km
   *   Search radius in kilometres.
   *
   * @return \Drupal\node\NodeInterface[]
   *   Array of parish nodes within the radius, sorted by distance.
   */
  public function getParishesNear($lat, $lng, $radius_km) {
    $parishes = $this->getActiveParishes();
    $results = [];

    foreach ($parishes as $parish) {
      if (!$parish->hasField('field_location') || $parish->get('field_location')->isEmpty()) {
        continue;
      }

      $location = $parish->get('field_location')->first();
      $parish_lat = $location->get('lat')->getValue();
      $parish_lng = $location->get('lon')->getValue();

      $distance = $this->proximity->distanceKm($lat, $lng, $parish_lat, $parish_lng);
      if ($distance <= $radius_km) {
        $results[] = [
          'node' => $parish,
          'distance' => $distance,
        ];
      }
    }

    usort($results, fn($a, $b) => $a['distance'] <=> $b['distance']);
    return $results;
  }

  /**
   * Get the latest extraction for a parish.
   *
   * @param int $parish_nid
   *   The parish node ID.
   *
   * @return object|null
   *   The extraction record or null.
   */
  public function getLatestExtraction($parish_nid) {
    return $this->database->select('mass_times_extractions', 'e')
      ->fields('e')
      ->condition('parish_nid', $parish_nid)
      ->orderBy('created_at', 'DESC')
      ->range(0, 1)
      ->execute()
      ->fetchObject();
  }

}
