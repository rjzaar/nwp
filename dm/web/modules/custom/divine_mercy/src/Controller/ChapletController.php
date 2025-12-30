<?php

namespace Drupal\divine_mercy\Controller;

use Drupal\Core\Controller\ControllerBase;
use Drupal\Core\Entity\EntityTypeManagerInterface;
use Drupal\divine_mercy\Service\PrayerService;
use Drupal\divine_mercy\Service\NovenaService;
use Symfony\Component\DependencyInjection\ContainerInterface;

/**
 * Controller for displaying the Divine Mercy Chaplet.
 */
class ChapletController extends ControllerBase {

  /**
   * The prayer service.
   *
   * @var \Drupal\divine_mercy\Service\PrayerService
   */
  protected $prayerService;

  /**
   * The novena service.
   *
   * @var \Drupal\divine_mercy\Service\NovenaService
   */
  protected $novenaService;

  /**
   * The entity type manager.
   *
   * @var \Drupal\Core\Entity\EntityTypeManagerInterface
   */
  protected $entityTypeManager;

  /**
   * Constructs a ChapletController object.
   *
   * @param \Drupal\divine_mercy\Service\PrayerService $prayer_service
   *   The prayer service.
   * @param \Drupal\divine_mercy\Service\NovenaService $novena_service
   *   The novena service.
   * @param \Drupal\Core\Entity\EntityTypeManagerInterface $entity_type_manager
   *   The entity type manager.
   */
  public function __construct(PrayerService $prayer_service, NovenaService $novena_service, EntityTypeManagerInterface $entity_type_manager) {
    $this->prayerService = $prayer_service;
    $this->novenaService = $novena_service;
    $this->entityTypeManager = $entity_type_manager;
  }

  /**
   * {@inheritdoc}
   */
  public static function create(ContainerInterface $container) {
    return new static(
      $container->get('divine_mercy.prayer_service'),
      $container->get('divine_mercy.novena_service'),
      $container->get('entity_type.manager')
    );
  }

  /**
   * Displays the Divine Mercy Chaplet.
   *
   * @return array
   *   A render array.
   */
  public function display() {
    $chaplet = $this->prayerService->getChaplet();
    $current_day = $this->novenaService->getCurrentDayNumber();
    $config = $this->config('divine_mercy.settings');

    // Load reflection sets.
    $reflection_sets = $this->getReflectionSets();

    // Load adoration channels if enabled.
    $adoration_enabled = $config->get('enable_adoration_video') ?? TRUE;
    $adoration_channels = [];
    if ($adoration_enabled) {
      $adoration_channels = $config->get('adoration_channels') ?? $this->getDefaultAdorationChannels();
    }

    $build = [
      '#theme' => 'divine_mercy_chaplet',
      '#prayers' => $chaplet ? $chaplet['prayers'] : [],
      '#reflection_sets' => $reflection_sets,
      '#current_day' => $current_day,
      '#adoration_enabled' => $adoration_enabled,
      '#adoration_channels' => $adoration_channels,
      '#settings' => [
        'default_font_size' => $config->get('default_font_size') ?? 100,
        'enable_adoration_video' => $adoration_enabled,
      ],
      '#attached' => [
        'library' => [
          'divine_mercy/divine-mercy',
          'divine_mercy/font-size-control',
          'divine_mercy/expandable-sections',
          'divine_mercy/reflection-selector',
          'divine_mercy/eucharist-adoration',
        ],
        'drupalSettings' => [
          'divineMercy' => [
            'currentDay' => $current_day,
            'defaultFontSize' => $config->get('default_font_size') ?? 100,
            'reflectionSets' => $reflection_sets,
          ],
        ],
      ],
      '#cache' => [
        'tags' => ['node_list:prayer', 'node_list:prayer_collection', 'node_list:reflection_set'],
        'contexts' => ['languages', 'user.permissions'],
      ],
    ];

    return $build;
  }

  /**
   * Get all reflection sets with their decade content.
   *
   * @return array
   *   Array of reflection sets with decades.
   */
  protected function getReflectionSets() {
    $storage = $this->entityTypeManager->getStorage('node');
    $query = $storage->getQuery()
      ->condition('type', 'reflection_set')
      ->condition('status', 1)
      ->sort('title', 'ASC')
      ->accessCheck(TRUE);

    $nids = $query->execute();
    $nodes = $storage->loadMultiple($nids);

    $sets = [];
    foreach ($nodes as $node) {
      $decades = [];
      if ($node->hasField('field_decade_reflections')) {
        foreach ($node->get('field_decade_reflections') as $delta => $item) {
          $reflections = explode("\n", $item->value);
          $decades[$delta + 1] = array_map('trim', $reflections);
        }
      }

      $sets[] = [
        'id' => $node->id(),
        'title' => $node->label(),
        'decades' => $decades,
      ];
    }

    return $sets;
  }

  /**
   * Get default adoration channels.
   *
   * @return array
   *   Array of channel configurations.
   */
  protected function getDefaultAdorationChannels() {
    return [
      [
        'name' => 'EWTN Poland Adoration',
        'url' => 'https://www.youtube.com/embed/Orc7lHFSqNY?si=bS-V3R0OYUHlNVEx',
        'location' => 'Poland',
      ],
      [
        'name' => 'Our Lady of Sorrows Church',
        'url' => 'https://www.youtube.com/embed/am72_e-h9d8',
        'location' => 'Birmingham, Alabama, USA',
      ],
      [
        'name' => 'Our Lady of Guadalupe',
        'url' => 'https://www.youtube.com/embed/72jejHn35ds',
        'location' => 'Doral, Florida, USA',
      ],
    ];
  }

}
