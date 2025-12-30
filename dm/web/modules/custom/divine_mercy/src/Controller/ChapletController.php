<?php

namespace Drupal\divine_mercy\Controller;

use Drupal\Core\Controller\ControllerBase;
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
   * Constructs a ChapletController object.
   *
   * @param \Drupal\divine_mercy\Service\PrayerService $prayer_service
   *   The prayer service.
   * @param \Drupal\divine_mercy\Service\NovenaService $novena_service
   *   The novena service.
   */
  public function __construct(PrayerService $prayer_service, NovenaService $novena_service) {
    $this->prayerService = $prayer_service;
    $this->novenaService = $novena_service;
  }

  /**
   * {@inheritdoc}
   */
  public static function create(ContainerInterface $container) {
    return new static(
      $container->get('divine_mercy.prayer_service'),
      $container->get('divine_mercy.novena_service')
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

    $build = [
      '#theme' => 'divine_mercy_chaplet',
      '#prayers' => $chaplet ? $chaplet['prayers'] : [],
      '#current_day' => $current_day,
      '#settings' => [
        'default_font_size' => $config->get('default_font_size') ?? 100,
        'enable_adoration_video' => $config->get('enable_adoration_video') ?? TRUE,
      ],
      '#attached' => [
        'library' => [
          'divine_mercy/divine-mercy',
          'divine_mercy/font-size-control',
          'divine_mercy/expandable-sections',
        ],
        'drupalSettings' => [
          'divineMercy' => [
            'currentDay' => $current_day,
            'defaultFontSize' => $config->get('default_font_size') ?? 100,
          ],
        ],
      ],
      '#cache' => [
        'tags' => ['node_list:prayer', 'node_list:prayer_collection'],
        'contexts' => ['languages', 'user.permissions'],
      ],
    ];

    return $build;
  }

}
