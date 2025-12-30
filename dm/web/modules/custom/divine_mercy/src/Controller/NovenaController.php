<?php

namespace Drupal\divine_mercy\Controller;

use Drupal\Core\Controller\ControllerBase;
use Drupal\divine_mercy\Service\NovenaService;
use Symfony\Component\DependencyInjection\ContainerInterface;

/**
 * Controller for displaying the Divine Mercy Novena.
 */
class NovenaController extends ControllerBase {

  /**
   * The novena service.
   *
   * @var \Drupal\divine_mercy\Service\NovenaService
   */
  protected $novenaService;

  /**
   * Constructs a NovenaController object.
   *
   * @param \Drupal\divine_mercy\Service\NovenaService $novena_service
   *   The novena service.
   */
  public function __construct(NovenaService $novena_service) {
    $this->novenaService = $novena_service;
  }

  /**
   * {@inheritdoc}
   */
  public static function create(ContainerInterface $container) {
    return new static(
      $container->get('divine_mercy.novena_service')
    );
  }

  /**
   * Displays the Divine Mercy Novena overview.
   *
   * @return array
   *   A render array.
   */
  public function display() {
    $days = $this->novenaService->getAllDays();
    $current_day = $this->novenaService->getCurrentDayNumber();
    $secondary_day = $this->novenaService->getSecondaryDayNumber();

    $build = [
      '#theme' => 'divine_mercy_novena_navigation',
      '#days' => $days,
      '#current_day' => $current_day,
      '#secondary_day' => $secondary_day,
      '#attached' => [
        'library' => [
          'divine_mercy/divine-mercy',
          'divine_mercy/novena-navigation',
        ],
        'drupalSettings' => [
          'divineMercy' => [
            'currentDay' => $current_day,
            'secondaryDay' => $secondary_day,
          ],
        ],
      ],
      '#cache' => [
        'tags' => ['node_list:novena_day'],
        'contexts' => ['languages', 'user.permissions'],
        'max-age' => 3600, // Cache for 1 hour since day changes.
      ],
    ];

    // Add the current day's content.
    $current_day_node = $this->novenaService->getCurrentDay();
    if ($current_day_node) {
      $build['current_day_content'] = [
        '#theme' => 'divine_mercy_novena_day',
        '#day' => $current_day_node,
        '#day_number' => $current_day,
        '#theme_text' => $this->novenaService->getDayTheme($current_day),
        '#intention' => $current_day_node->hasField('field_intention') ? $current_day_node->get('field_intention')->value : '',
        '#prayer' => $current_day_node->hasField('field_prayer') ? $current_day_node->get('field_prayer')->value : '',
      ];
    }

    return $build;
  }

  /**
   * Displays a specific novena day.
   *
   * @param int $day
   *   The day number (1-9).
   *
   * @return array
   *   A render array.
   */
  public function displayDay($day) {
    $day_node = $this->novenaService->getDay($day);

    if (!$day_node) {
      throw new \Symfony\Component\HttpKernel\Exception\NotFoundHttpException();
    }

    $build = [
      '#theme' => 'divine_mercy_novena_day',
      '#day' => $day_node,
      '#day_number' => $day,
      '#theme_text' => $this->novenaService->getDayTheme($day),
      '#intention' => $day_node->hasField('field_intention') ? $day_node->get('field_intention')->value : '',
      '#prayer' => $day_node->hasField('field_prayer') ? $day_node->get('field_prayer')->value : '',
      '#attached' => [
        'library' => [
          'divine_mercy/divine-mercy',
          'divine_mercy/font-size-control',
        ],
      ],
      '#cache' => [
        'tags' => $day_node->getCacheTags(),
        'contexts' => ['languages', 'user.permissions'],
      ],
    ];

    return $build;
  }

  /**
   * Title callback for novena day page.
   *
   * @param int $day
   *   The day number.
   *
   * @return string
   *   The page title.
   */
  public function getDayTitle($day) {
    $theme = $this->novenaService->getDayTheme($day);
    return $this->t('Day @day - @theme', [
      '@day' => $day,
      '@theme' => $theme,
    ]);
  }

}
