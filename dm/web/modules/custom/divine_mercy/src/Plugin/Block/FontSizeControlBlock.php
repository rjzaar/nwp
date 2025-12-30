<?php

namespace Drupal\divine_mercy\Plugin\Block;

use Drupal\Core\Block\BlockBase;
use Drupal\Core\Config\ConfigFactoryInterface;
use Drupal\Core\Plugin\ContainerFactoryPluginInterface;
use Symfony\Component\DependencyInjection\ContainerInterface;

/**
 * Provides a font size control block.
 *
 * @Block(
 *   id = "divine_mercy_font_size_control",
 *   admin_label = @Translation("Font Size Control"),
 *   category = @Translation("Divine Mercy")
 * )
 */
class FontSizeControlBlock extends BlockBase implements ContainerFactoryPluginInterface {

  /**
   * The config factory.
   *
   * @var \Drupal\Core\Config\ConfigFactoryInterface
   */
  protected $configFactory;

  /**
   * Constructs a FontSizeControlBlock object.
   *
   * @param array $configuration
   *   A configuration array containing information about the plugin instance.
   * @param string $plugin_id
   *   The plugin_id for the plugin instance.
   * @param mixed $plugin_definition
   *   The plugin implementation definition.
   * @param \Drupal\Core\Config\ConfigFactoryInterface $config_factory
   *   The config factory.
   */
  public function __construct(array $configuration, $plugin_id, $plugin_definition, ConfigFactoryInterface $config_factory) {
    parent::__construct($configuration, $plugin_id, $plugin_definition);
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
      $container->get('config.factory')
    );
  }

  /**
   * {@inheritdoc}
   */
  public function build() {
    $config = $this->configFactory->get('divine_mercy.settings');

    return [
      '#theme' => 'divine_mercy_font_size_control',
      '#min_size' => 50,
      '#max_size' => 200,
      '#default_size' => $config->get('default_font_size') ?? 100,
      '#attached' => [
        'library' => ['divine_mercy/font-size-control'],
        'drupalSettings' => [
          'divineMercy' => [
            'defaultFontSize' => $config->get('default_font_size') ?? 100,
          ],
        ],
      ],
    ];
  }

}
