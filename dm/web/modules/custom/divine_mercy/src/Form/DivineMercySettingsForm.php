<?php

namespace Drupal\divine_mercy\Form;

use Drupal\Core\Form\ConfigFormBase;
use Drupal\Core\Form\FormStateInterface;

/**
 * Configuration form for Divine Mercy module.
 */
class DivineMercySettingsForm extends ConfigFormBase {

  /**
   * {@inheritdoc}
   */
  public function getFormId() {
    return 'divine_mercy_settings_form';
  }

  /**
   * {@inheritdoc}
   */
  protected function getEditableConfigNames() {
    return ['divine_mercy.settings'];
  }

  /**
   * {@inheritdoc}
   */
  public function buildForm(array $form, FormStateInterface $form_state) {
    $config = $this->config('divine_mercy.settings');

    $form['display'] = [
      '#type' => 'fieldset',
      '#title' => $this->t('Display Settings'),
    ];

    $form['display']['default_font_size'] = [
      '#type' => 'number',
      '#title' => $this->t('Default Font Size (%)'),
      '#description' => $this->t('Default font size percentage for prayer text (50-200).'),
      '#default_value' => $config->get('default_font_size') ?? 100,
      '#min' => 50,
      '#max' => 200,
    ];

    $form['display']['enable_adoration_video'] = [
      '#type' => 'checkbox',
      '#title' => $this->t('Enable Eucharist Adoration Video'),
      '#description' => $this->t('Show the live Eucharist adoration video embed.'),
      '#default_value' => $config->get('enable_adoration_video') ?? TRUE,
    ];

    $form['novena'] = [
      '#type' => 'fieldset',
      '#title' => $this->t('Novena Settings'),
    ];

    $form['novena']['novena_start_day'] = [
      '#type' => 'select',
      '#title' => $this->t('Novena Start Day'),
      '#description' => $this->t('The day of the week when a new novena begins.'),
      '#options' => [
        0 => $this->t('Sunday'),
        1 => $this->t('Monday'),
        2 => $this->t('Tuesday'),
        3 => $this->t('Wednesday'),
        4 => $this->t('Thursday'),
        5 => $this->t('Friday'),
        6 => $this->t('Saturday'),
      ],
      '#default_value' => $config->get('novena_start_day') ?? 5,
    ];

    $form['adoration_channels'] = [
      '#type' => 'fieldset',
      '#title' => $this->t('Adoration Video Channels'),
      '#description' => $this->t('Configure available live Eucharist adoration video feeds.'),
    ];

    $channels = $config->get('adoration_channels') ?? $this->getDefaultChannels();
    $form['adoration_channels']['channels'] = [
      '#type' => 'textarea',
      '#title' => $this->t('Channels (YAML format)'),
      '#description' => $this->t('One channel per line in format: name|url|location'),
      '#default_value' => $this->formatChannelsForTextarea($channels),
      '#rows' => 10,
    ];

    return parent::buildForm($form, $form_state);
  }

  /**
   * {@inheritdoc}
   */
  public function submitForm(array &$form, FormStateInterface $form_state) {
    $this->config('divine_mercy.settings')
      ->set('default_font_size', $form_state->getValue('default_font_size'))
      ->set('enable_adoration_video', $form_state->getValue('enable_adoration_video'))
      ->set('novena_start_day', $form_state->getValue('novena_start_day'))
      ->set('adoration_channels', $this->parseChannelsFromTextarea($form_state->getValue('channels')))
      ->save();

    parent::submitForm($form, $form_state);
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
        'name' => 'Our Lady of Sorrows Church, Birmingham AL',
        'url' => 'https://www.youtube.com/embed/am72_e-h9d8',
        'location' => 'Birmingham, Alabama, USA',
      ],
      [
        'name' => 'Our Lady of Guadalupe, Doral Florida',
        'url' => 'https://www.youtube.com/embed/72jejHn35ds',
        'location' => 'Doral, Florida, USA',
      ],
      [
        'name' => 'EWTN Adoration Chapel',
        'url' => 'https://www.youtube.com/embed/ERgZBLqEyYE',
        'location' => 'Irondale, Alabama, USA',
      ],
    ];
  }

  /**
   * Format channels array for textarea display.
   *
   * @param array $channels
   *   The channels array.
   *
   * @return string
   *   Formatted text.
   */
  protected function formatChannelsForTextarea(array $channels) {
    $lines = [];
    foreach ($channels as $channel) {
      $lines[] = $channel['name'] . '|' . $channel['url'] . '|' . ($channel['location'] ?? '');
    }
    return implode("\n", $lines);
  }

  /**
   * Parse channels from textarea input.
   *
   * @param string $text
   *   The textarea content.
   *
   * @return array
   *   Parsed channels array.
   */
  protected function parseChannelsFromTextarea($text) {
    $channels = [];
    $lines = explode("\n", trim($text));
    foreach ($lines as $line) {
      $line = trim($line);
      if (empty($line)) {
        continue;
      }
      $parts = explode('|', $line);
      if (count($parts) >= 2) {
        $channels[] = [
          'name' => trim($parts[0]),
          'url' => trim($parts[1]),
          'location' => isset($parts[2]) ? trim($parts[2]) : '',
        ];
      }
    }
    return $channels;
  }

}
