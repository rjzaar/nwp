<?php

namespace Drupal\divine_mercy\Service;

use Drupal\Core\Config\ConfigFactoryInterface;
use Drupal\Core\Entity\EntityTypeManagerInterface;

/**
 * Service for managing Divine Mercy Novena.
 */
class NovenaService {

  /**
   * The entity type manager.
   *
   * @var \Drupal\Core\Entity\EntityTypeManagerInterface
   */
  protected $entityTypeManager;

  /**
   * The config factory.
   *
   * @var \Drupal\Core\Config\ConfigFactoryInterface
   */
  protected $configFactory;

  /**
   * Mapping of day of week to novena day.
   *
   * Friday = Day 1 (start of new novena)
   * Saturday = Day 2
   * Sunday = Day 3
   * etc.
   *
   * @var array
   */
  protected $dayMapping = [
    5 => 1, // Friday
    6 => 2, // Saturday
    0 => 3, // Sunday
    1 => 4, // Monday
    2 => 5, // Tuesday
    3 => 6, // Wednesday
    4 => 7, // Thursday
  ];

  /**
   * Constructs a NovenaService object.
   *
   * @param \Drupal\Core\Entity\EntityTypeManagerInterface $entity_type_manager
   *   The entity type manager.
   * @param \Drupal\Core\Config\ConfigFactoryInterface $config_factory
   *   The config factory.
   */
  public function __construct(EntityTypeManagerInterface $entity_type_manager, ConfigFactoryInterface $config_factory) {
    $this->entityTypeManager = $entity_type_manager;
    $this->configFactory = $config_factory;
  }

  /**
   * Get all novena days.
   *
   * @return \Drupal\node\NodeInterface[]
   *   Array of novena day nodes, keyed by day number.
   */
  public function getAllDays() {
    $storage = $this->entityTypeManager->getStorage('node');
    $query = $storage->getQuery()
      ->condition('type', 'novena_day')
      ->condition('status', 1)
      ->sort('field_day_number', 'ASC')
      ->accessCheck(TRUE);

    $nids = $query->execute();
    $nodes = $storage->loadMultiple($nids);

    // Key by day number.
    $days = [];
    foreach ($nodes as $node) {
      if ($node->hasField('field_day_number') && !$node->get('field_day_number')->isEmpty()) {
        $day_number = $node->get('field_day_number')->value;
        $days[$day_number] = $node;
      }
    }

    return $days;
  }

  /**
   * Get a specific novena day.
   *
   * @param int $day_number
   *   The day number (1-9).
   *
   * @return \Drupal\node\NodeInterface|null
   *   The novena day node or null.
   */
  public function getDay($day_number) {
    $storage = $this->entityTypeManager->getStorage('node');
    $query = $storage->getQuery()
      ->condition('type', 'novena_day')
      ->condition('status', 1)
      ->condition('field_day_number', $day_number)
      ->range(0, 1)
      ->accessCheck(TRUE);

    $nids = $query->execute();
    if (!empty($nids)) {
      return $storage->load(reset($nids));
    }

    return NULL;
  }

  /**
   * Get the current novena day based on today's date.
   *
   * @return int
   *   The current day number (1-9).
   */
  public function getCurrentDayNumber() {
    $day_of_week = (int) date('w'); // 0 = Sunday, 6 = Saturday
    return $this->dayMapping[$day_of_week] ?? 1;
  }

  /**
   * Get the secondary novena day (for Friday/Saturday overlap).
   *
   * On Friday, we show Day 8 (end of previous) and Day 1 (start of new).
   * On Saturday, we show Day 9 (end of previous) and Day 2 (start of new).
   *
   * @return int|null
   *   The secondary day number or null if not applicable.
   */
  public function getSecondaryDayNumber() {
    $primary = $this->getCurrentDayNumber();

    // Only on Friday (Day 1) and Saturday (Day 2) do we show overlap.
    if ($primary === 1) {
      return 8; // Show Day 8 from previous novena.
    }
    if ($primary === 2) {
      return 9; // Show Day 9 from previous novena.
    }

    return NULL;
  }

  /**
   * Get the current novena day node.
   *
   * @return \Drupal\node\NodeInterface|null
   *   The current day's node.
   */
  public function getCurrentDay() {
    return $this->getDay($this->getCurrentDayNumber());
  }

  /**
   * Get the theme for a specific day.
   *
   * @param int $day_number
   *   The day number (1-9).
   *
   * @return string
   *   The theme for that day.
   */
  public function getDayTheme($day_number) {
    $themes = [
      1 => 'All Mankind, Especially Sinners',
      2 => 'Priests and Religious',
      3 => 'Devout and Faithful Souls',
      4 => 'Those Who Do Not Believe',
      5 => 'Separated Brethren',
      6 => 'Meek and Humble Souls',
      7 => 'Those Who Venerate Divine Mercy',
      8 => 'Souls in Purgatory',
      9 => 'Lukewarm Souls',
    ];

    return $themes[$day_number] ?? '';
  }

  /**
   * Get the weekday name for a novena day.
   *
   * @param int $day_number
   *   The day number (1-9).
   *
   * @return string
   *   The weekday name.
   */
  public function getWeekdayForDay($day_number) {
    $weekdays = [
      1 => 'Friday',
      2 => 'Saturday',
      3 => 'Sunday',
      4 => 'Monday',
      5 => 'Tuesday',
      6 => 'Wednesday',
      7 => 'Thursday',
      8 => 'Friday',
      9 => 'Saturday',
    ];

    return $weekdays[$day_number] ?? '';
  }

}
