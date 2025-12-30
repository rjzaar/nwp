<?php

namespace Drupal\divine_mercy\Service;

use Drupal\Core\Database\Connection;
use Drupal\Core\Entity\EntityTypeManagerInterface;

/**
 * Service for managing prayer content.
 */
class PrayerService {

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
   * Constructs a PrayerService object.
   *
   * @param \Drupal\Core\Entity\EntityTypeManagerInterface $entity_type_manager
   *   The entity type manager.
   * @param \Drupal\Core\Database\Connection $database
   *   The database connection.
   */
  public function __construct(EntityTypeManagerInterface $entity_type_manager, Connection $database) {
    $this->entityTypeManager = $entity_type_manager;
    $this->database = $database;
  }

  /**
   * Get all prayers ordered by their order field.
   *
   * @param string|null $type
   *   Optional prayer type to filter by.
   *
   * @return \Drupal\node\NodeInterface[]
   *   Array of prayer nodes.
   */
  public function getPrayers($type = NULL) {
    $storage = $this->entityTypeManager->getStorage('node');
    $query = $storage->getQuery()
      ->condition('type', 'prayer')
      ->condition('status', 1)
      ->sort('field_prayer_order', 'ASC')
      ->accessCheck(TRUE);

    if ($type) {
      $query->condition('field_prayer_type.entity.name', $type);
    }

    $nids = $query->execute();
    return $storage->loadMultiple($nids);
  }

  /**
   * Get a prayer collection with all its prayers.
   *
   * @param int $collection_id
   *   The node ID of the prayer collection.
   *
   * @return array
   *   Array containing 'collection' and 'prayers' keys.
   */
  public function getCollection($collection_id) {
    $storage = $this->entityTypeManager->getStorage('node');
    $collection = $storage->load($collection_id);

    if (!$collection || $collection->bundle() !== 'prayer_collection') {
      return NULL;
    }

    $prayers = [];
    if ($collection->hasField('field_prayers') && !$collection->get('field_prayers')->isEmpty()) {
      foreach ($collection->get('field_prayers') as $item) {
        $prayer = $item->entity;
        if ($prayer && $prayer->isPublished()) {
          $prayers[] = $prayer;
        }
      }
    }

    return [
      'collection' => $collection,
      'prayers' => $prayers,
    ];
  }

  /**
   * Get the main Divine Mercy Chaplet collection.
   *
   * @return array|null
   *   The collection data or null if not found.
   */
  public function getChaplet() {
    $storage = $this->entityTypeManager->getStorage('node');
    $query = $storage->getQuery()
      ->condition('type', 'prayer_collection')
      ->condition('title', 'Divine Mercy Chaplet')
      ->condition('status', 1)
      ->range(0, 1)
      ->accessCheck(TRUE);

    $nids = $query->execute();
    if (!empty($nids)) {
      return $this->getCollection(reset($nids));
    }

    return NULL;
  }

  /**
   * Get prayers by category.
   *
   * @param string $category
   *   The category name (e.g., 'leader', 'response', 'full').
   *
   * @return \Drupal\node\NodeInterface[]
   *   Array of prayer nodes.
   */
  public function getPrayersByCategory($category) {
    $storage = $this->entityTypeManager->getStorage('node');
    $query = $storage->getQuery()
      ->condition('type', 'prayer')
      ->condition('status', 1)
      ->condition('field_prayer_category.entity.name', $category)
      ->sort('field_prayer_order', 'ASC')
      ->accessCheck(TRUE);

    $nids = $query->execute();
    return $storage->loadMultiple($nids);
  }

}
