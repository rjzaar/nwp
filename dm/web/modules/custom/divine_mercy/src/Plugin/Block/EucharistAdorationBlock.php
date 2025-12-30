<?php

namespace Drupal\divine_mercy\Plugin\Block;

use Drupal\Core\Block\BlockBase;
use Drupal\Core\Config\ConfigFactoryInterface;
use Drupal\Core\Form\FormStateInterface;
use Drupal\Core\Plugin\ContainerFactoryPluginInterface;
use Symfony\Component\DependencyInjection\ContainerInterface;

/**
 * Provides a Eucharist adoration video block.
 *
 * @Block(
 *   id = "divine_mercy_eucharist_adoration",
 *   admin_label = @Translation("Eucharist Adoration Video"),
 *   category = @Translation("Divine Mercy")
 * )
 */
class EucharistAdorationBlock extends BlockBase implements ContainerFactoryPluginInterface {

  /**
   * The config factory.
   *
   * @var \Drupal\Core\Config\ConfigFactoryInterface
   */
  protected $configFactory;

  /**
   * Constructs an EucharistAdorationBlock object.
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
  public function defaultConfiguration() {
    return [
      'position' => 'fixed',
      'show_selector' => TRUE,
    ];
  }

  /**
   * {@inheritdoc}
   */
  public function blockForm($form, FormStateInterface $form_state) {
    $form['position'] = [
      '#type' => 'select',
      '#title' => $this->t('Position'),
      '#options' => [
        'fixed' => $this->t('Fixed (top right corner)'),
        'inline' => $this->t('Inline (within page flow)'),
      ],
      '#default_value' => $this->configuration['position'],
    ];

    $form['show_selector'] = [
      '#type' => 'checkbox',
      '#title' => $this->t('Show channel selector'),
      '#description' => $this->t('Allow users to choose from multiple adoration channels.'),
      '#default_value' => $this->configuration['show_selector'],
    ];

    return $form;
  }

  /**
   * {@inheritdoc}
   */
  public function blockSubmit($form, FormStateInterface $form_state) {
    $this->configuration['position'] = $form_state->getValue('position');
    $this->configuration['show_selector'] = $form_state->getValue('show_selector');
  }

  /**
   * {@inheritdoc}
   */
  public function build() {
    $config = $this->configFactory->get('divine_mercy.settings');

    if (!$config->get('enable_adoration_video')) {
      return [];
    }

    $channels = $config->get('adoration_channels') ?? $this->getDefaultChannels();

    return [
      '#theme' => 'divine_mercy_eucharist_adoration',
      '#channels' => $channels,
      '#position' => $this->configuration['position'],
      '#show_selector' => $this->configuration['show_selector'],
      '#default_channel' => !empty($channels) ? $channels[0]['url'] : '',
      '#attached' => [
        'library' => ['divine_mercy/eucharist-adoration'],
      ],
    ];
  }

  /**
   * Get default adoration channels.
   *
   * @return array
   *   Array of channel configurations.
   */
  protected function getDefaultChannels() {
    return [
      [
        'name' => 'EWTN Adoration Chapel',
        'url' => 'https://www.youtube.com/embed/ERgZBLqEyYE',
        'location' => 'Irondale, Alabama, USA',
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
