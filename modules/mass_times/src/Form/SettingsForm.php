<?php

namespace Drupal\mass_times\Form;

use Drupal\Core\Form\ConfigFormBase;
use Drupal\Core\Form\FormStateInterface;

/**
 * Settings form for Mass Times module.
 */
class SettingsForm extends ConfigFormBase {

  /**
   * {@inheritdoc}
   */
  protected function getEditableConfigNames() {
    return ['mass_times.settings'];
  }

  /**
   * {@inheritdoc}
   */
  public function getFormId() {
    return 'mass_times_settings';
  }

  /**
   * {@inheritdoc}
   */
  public function buildForm(array $form, FormStateInterface $form_state) {
    $config = $this->config('mass_times.settings');

    $form['centre_lat'] = [
      '#type' => 'number',
      '#title' => $this->t('Centre Latitude'),
      '#default_value' => $config->get('centre_lat'),
      '#step' => 0.0001,
      '#min' => -90,
      '#max' => 90,
      '#required' => TRUE,
    ];

    $form['centre_lng'] = [
      '#type' => 'number',
      '#title' => $this->t('Centre Longitude'),
      '#default_value' => $config->get('centre_lng'),
      '#step' => 0.0001,
      '#min' => -180,
      '#max' => 180,
      '#required' => TRUE,
    ];

    $form['radius_km'] = [
      '#type' => 'number',
      '#title' => $this->t('Radius (km)'),
      '#default_value' => $config->get('radius_km'),
      '#min' => 1,
      '#max' => 100,
      '#required' => TRUE,
    ];

    $form['shadow_mode'] = [
      '#type' => 'checkbox',
      '#title' => $this->t('Shadow Mode'),
      '#description' => $this->t('When enabled, all extracted data is flagged as provisional and not published to users.'),
      '#default_value' => $config->get('shadow_mode'),
    ];

    return parent::buildForm($form, $form_state);
  }

  /**
   * {@inheritdoc}
   */
  public function submitForm(array &$form, FormStateInterface $form_state) {
    $this->config('mass_times.settings')
      ->set('centre_lat', $form_state->getValue('centre_lat'))
      ->set('centre_lng', $form_state->getValue('centre_lng'))
      ->set('radius_km', $form_state->getValue('radius_km'))
      ->set('shadow_mode', $form_state->getValue('shadow_mode'))
      ->save();

    parent::submitForm($form, $form_state);
  }

}
