<?php

namespace Drupal\avc_moodle_sync\Form;

use Drupal\Core\Form\ConfigFormBase;
use Drupal\Core\Form\FormStateInterface;

/**
 * Configuration form for AVC Moodle Sync.
 */
class SettingsForm extends ConfigFormBase {

  /**
   * {@inheritdoc}
   */
  protected function getEditableConfigNames() {
    return ['avc_moodle_sync.settings'];
  }

  /**
   * {@inheritdoc}
   */
  public function getFormId() {
    return 'avc_moodle_sync_settings';
  }

  /**
   * {@inheritdoc}
   */
  public function buildForm(array $form, FormStateInterface $form_state) {
    $config = $this->config('avc_moodle_sync.settings');

    $form['info'] = [
      '#type' => 'markup',
      '#markup' => $this->t('<h2>AVC Moodle Role Synchronization</h2>
        <p>This module synchronizes AVC guild roles to Moodle cohorts and roles.</p>
        <h3>Prerequisites:</h3>
        <ul>
          <li>Moodle Web Services must be enabled</li>
          <li>A webservice token with appropriate permissions</li>
          <li>Cohorts and roles configured in Moodle</li>
        </ul>'),
    ];

    $form['connection'] = [
      '#type' => 'fieldset',
      '#title' => $this->t('Moodle Connection'),
    ];

    $form['connection']['moodle_url'] = [
      '#type' => 'url',
      '#title' => $this->t('Moodle URL'),
      '#default_value' => $config->get('moodle_url'),
      '#description' => $this->t('The base URL of your Moodle installation (e.g., https://moodle.example.com).'),
      '#required' => TRUE,
    ];

    $form['connection']['webservice_token'] = [
      '#type' => 'textfield',
      '#title' => $this->t('Webservice Token'),
      '#default_value' => $config->get('webservice_token'),
      '#description' => $this->t('Moodle webservice token with permissions for user, cohort, and role management.'),
      '#required' => TRUE,
      '#attributes' => [
        'autocomplete' => 'off',
      ],
    ];

    $form['sync_settings'] = [
      '#type' => 'fieldset',
      '#title' => $this->t('Sync Settings'),
    ];

    $form['sync_settings']['enable_sync'] = [
      '#type' => 'checkbox',
      '#title' => $this->t('Enable synchronization'),
      '#default_value' => $config->get('enable_sync') ?? FALSE,
      '#description' => $this->t('Master switch for all synchronization operations.'),
    ];

    $form['sync_settings']['enable_automatic_sync'] = [
      '#type' => 'checkbox',
      '#title' => $this->t('Enable automatic synchronization'),
      '#default_value' => $config->get('enable_automatic_sync') ?? FALSE,
      '#description' => $this->t('Automatically sync users when guild memberships change.'),
      '#states' => [
        'visible' => [
          ':input[name="enable_sync"]' => ['checked' => TRUE],
        ],
      ],
    ];

    $form['sync_settings']['sync_on_login'] = [
      '#type' => 'checkbox',
      '#title' => $this->t('Sync on user login'),
      '#default_value' => $config->get('sync_on_login') ?? FALSE,
      '#description' => $this->t('Sync user roles when they log in to AVC.'),
      '#states' => [
        'visible' => [
          ':input[name="enable_sync"]' => ['checked' => TRUE],
        ],
      ],
    ];

    $form['role_mapping'] = [
      '#type' => 'fieldset',
      '#title' => $this->t('Role Mapping'),
      '#description' => $this->t('Map AVC guilds and roles to Moodle cohorts and roles. Use YAML format.'),
    ];

    $form['role_mapping']['role_mapping_yaml'] = [
      '#type' => 'textarea',
      '#title' => $this->t('Role Mapping Configuration'),
      '#default_value' => $this->formatRoleMappingForDisplay($config->get('role_mapping')),
      '#rows' => 20,
      '#description' => $this->t('Example:<br><pre>
guild_1:
  cohort: "avc-members"
  roles:
    member: 5
    leader: 3
guild_2:
  cohort: "avc-premium"
  roles:
    member: 5
    admin: 4
</pre>'),
    ];

    $form['advanced'] = [
      '#type' => 'details',
      '#title' => $this->t('Advanced Settings'),
      '#open' => FALSE,
    ];

    $form['advanced']['batch_size'] = [
      '#type' => 'number',
      '#title' => $this->t('Batch size'),
      '#default_value' => $config->get('batch_size') ?? 50,
      '#description' => $this->t('Number of users to sync in each batch operation.'),
      '#min' => 1,
      '#max' => 500,
    ];

    $form['advanced']['enable_logging'] = [
      '#type' => 'checkbox',
      '#title' => $this->t('Enable debug logging'),
      '#default_value' => $config->get('enable_logging') ?? FALSE,
      '#description' => $this->t('Log all sync operations for debugging.'),
    ];

    return parent::buildForm($form, $form_state);
  }

  /**
   * {@inheritdoc}
   */
  public function validateForm(array &$form, FormStateInterface $form_state) {
    parent::validateForm($form, $form_state);

    // Validate Moodle URL.
    $moodle_url = $form_state->getValue('moodle_url');
    if (!filter_var($moodle_url, FILTER_VALIDATE_URL)) {
      $form_state->setErrorByName('moodle_url', $this->t('Please enter a valid URL.'));
    }

    // Validate YAML format for role mapping.
    $yaml = $form_state->getValue('role_mapping_yaml');
    if (!empty($yaml)) {
      try {
        $parsed = \Symfony\Component\Yaml\Yaml::parse($yaml);
        if (!is_array($parsed)) {
          $form_state->setErrorByName('role_mapping_yaml', $this->t('Role mapping must be valid YAML.'));
        }
      }
      catch (\Exception $e) {
        $form_state->setErrorByName('role_mapping_yaml', $this->t('Invalid YAML syntax: @message', [
          '@message' => $e->getMessage(),
        ]));
      }
    }
  }

  /**
   * {@inheritdoc}
   */
  public function submitForm(array &$form, FormStateInterface $form_state) {
    // Parse YAML role mapping.
    $yaml = $form_state->getValue('role_mapping_yaml');
    $role_mapping = [];
    if (!empty($yaml)) {
      try {
        $role_mapping = \Symfony\Component\Yaml\Yaml::parse($yaml);
      }
      catch (\Exception $e) {
        // Already validated, shouldn't happen.
        \Drupal::logger('avc_moodle_sync')->error('Failed to parse role mapping YAML: @message', [
          '@message' => $e->getMessage(),
        ]);
      }
    }

    $this->config('avc_moodle_sync.settings')
      ->set('moodle_url', $form_state->getValue('moodle_url'))
      ->set('webservice_token', $form_state->getValue('webservice_token'))
      ->set('enable_sync', $form_state->getValue('enable_sync'))
      ->set('enable_automatic_sync', $form_state->getValue('enable_automatic_sync'))
      ->set('sync_on_login', $form_state->getValue('sync_on_login'))
      ->set('role_mapping', $role_mapping)
      ->set('batch_size', $form_state->getValue('batch_size'))
      ->set('enable_logging', $form_state->getValue('enable_logging'))
      ->save();

    parent::submitForm($form, $form_state);
  }

  /**
   * Format role mapping array for display in textarea.
   *
   * @param array $role_mapping
   *   Role mapping array.
   *
   * @return string
   *   YAML formatted string.
   */
  protected function formatRoleMappingForDisplay($role_mapping) {
    if (empty($role_mapping)) {
      return '';
    }

    return \Symfony\Component\Yaml\Yaml::dump($role_mapping, 4, 2);
  }

}
