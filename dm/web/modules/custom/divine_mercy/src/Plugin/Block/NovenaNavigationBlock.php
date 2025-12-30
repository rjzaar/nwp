<?php

namespace Drupal\divine_mercy\Plugin\Block;

use Drupal\Core\Block\BlockBase;
use Drupal\Core\Plugin\ContainerFactoryPluginInterface;
use Drupal\divine_mercy\Service\NovenaService;
use Symfony\Component\DependencyInjection\ContainerInterface;

/**
 * Provides a novena day navigation block.
 *
 * @Block(
 *   id = "divine_mercy_novena_navigation",
 *   admin_label = @Translation("Novena Day Navigation"),
 *   category = @Translation("Divine Mercy")
 * )
 */
class NovenaNavigationBlock extends BlockBase implements ContainerFactoryPluginInterface {

  /**
   * The novena service.
   *
   * @var \Drupal\divine_mercy\Service\NovenaService
   */
  protected $novenaService;

  /**
   * Constructs a NovenaNavigationBlock object.
   *
   * @param array $configuration
   *   A configuration array containing information about the plugin instance.
   * @param string $plugin_id
   *   The plugin_id for the plugin instance.
   * @param mixed $plugin_definition
   *   The plugin implementation definition.
   * @param \Drupal\divine_mercy\Service\NovenaService $novena_service
   *   The novena service.
   */
  public function __construct(array $configuration, $plugin_id, $plugin_definition, NovenaService $novena_service) {
    parent::__construct($configuration, $plugin_id, $plugin_definition);
    $this->novenaService = $novena_service;
  }

  /**
   * {@inheritdoc}
   */
  public static function create(ContainerInterface $container, array $configuration, $plugin_id, $plugin_definition) {
    return new static(
      $configuration,
      $plugin_id,
      $plugin_definition,
      $container->get('divine_mercy.novena_service')
    );
  }

  /**
   * {@inheritdoc}
   */
  public function build() {
    $days = [];
    for ($i = 1; $i <= 9; $i++) {
      $days[$i] = [
        'number' => $i,
        'theme' => $this->novenaService->getDayTheme($i),
        'weekday' => $this->novenaService->getWeekdayForDay($i),
      ];
    }

    $current_day = $this->novenaService->getCurrentDayNumber();
    $secondary_day = $this->novenaService->getSecondaryDayNumber();

    return [
      '#theme' => 'divine_mercy_novena_navigation',
      '#days' => $days,
      '#current_day' => $current_day,
      '#secondary_day' => $secondary_day,
      '#attached' => [
        'library' => ['divine_mercy/novena-navigation'],
        'drupalSettings' => [
          'divineMercy' => [
            'currentDay' => $current_day,
            'secondaryDay' => $secondary_day,
          ],
        ],
      ],
      '#cache' => [
        'max-age' => 3600,
      ],
    ];
  }

}
