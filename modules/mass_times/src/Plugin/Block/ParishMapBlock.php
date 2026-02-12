<?php

namespace Drupal\mass_times\Plugin\Block;

use Drupal\Core\Block\BlockBase;
use Drupal\Core\Config\ConfigFactoryInterface;
use Drupal\Core\Plugin\ContainerFactoryPluginInterface;
use Drupal\mass_times\Service\ParishDataService;
use Symfony\Component\DependencyInjection\ContainerInterface;

/**
 * Displays a map of parishes with mass times.
 *
 * @Block(
 *   id = "mass_times_parish_map",
 *   admin_label = @Translation("Parish Map"),
 *   category = @Translation("Mass Times"),
 * )
 */
class ParishMapBlock extends BlockBase implements ContainerFactoryPluginInterface {

  /**
   * The parish data service.
   *
   * @var \Drupal\mass_times\Service\ParishDataService
   */
  protected $parishData;

  /**
   * The config factory.
   *
   * @var \Drupal\Core\Config\ConfigFactoryInterface
   */
  protected $configFactory;

  /**
   * Constructs a ParishMapBlock.
   */
  public function __construct(array $configuration, $plugin_id, $plugin_definition, ParishDataService $parish_data, ConfigFactoryInterface $config_factory) {
    parent::__construct($configuration, $plugin_id, $plugin_definition);
    $this->parishData = $parish_data;
    $this->configFactory = $config_factory;
  }

  /**
   * {@inheritdoc}
   */
  public static function create(ContainerInterface $container, array $configuration, $plugin_id, $plugin_definition) {
    return new static(
      $configuration,
      $plugin_id,
      $plugin_definition,
      $container->get('mass_times.parish_data'),
      $container->get('config.factory')
    );
  }

  /**
   * {@inheritdoc}
   */
  public function build() {
    $config = $this->configFactory->get('mass_times.settings');
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
      '#cache' => ['max-age' => 86400],
    ];
  }

}
