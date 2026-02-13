<?php

namespace Drupal\avc_moodle_oauth\Form;

use Drupal\Core\Form\ConfigFormBase;
use Drupal\Core\Form\FormStateInterface;

/**
 * Configuration form for AVC Moodle OAuth Provider.
 *
 * This form allows administrators to configure OAuth2 settings for
 * Moodle integration.
 */
class SettingsForm extends ConfigFormBase {

  /**
   * {@inheritdoc}
   */
  protected function getEditableConfigNames() {
    return ['avc_moodle_oauth.settings'];
  }

  /**
   * {@inheritdoc}
   */
  public function getFormId() {
    return 'avc_moodle_oauth_settings';
  }

  /**
   * {@inheritdoc}
   */
  public function buildForm(array $form, FormStateInterface $form_state) {
    $config = $this->config('avc_moodle_oauth.settings');

    $form['info'] = [
      '#type' => 'markup',
      '#markup' => $this->t('<h2>AVC Moodle OAuth2 Provider Settings</h2>
        <p>This module extends Simple OAuth to provide OAuth2 authentication for Moodle integration.</p>
        <h3>Setup Instructions:</h3>
        <ol>
          <li>Install and enable the <strong>Simple OAuth</strong> module</li>
          <li>Generate OAuth2 keys at <a href="/admin/config/people/simple_oauth">/admin/config/people/simple_oauth</a></li>
          <li>Create an OAuth2 Client at <a href="/admin/config/people/simple_oauth/clients">/admin/config/people/simple_oauth/clients</a></li>
          <li>Note the Client ID and Client Secret for Moodle configuration</li>
          <li>Configure your Moodle instance with the endpoints below</li>
        </ol>
        <h3>OAuth2 Endpoints:</h3>
        <ul>
          <li><strong>Authorization URL:</strong> <code>' . $GLOBALS['base_url'] . '/oauth/authorize</code></li>
          <li><strong>Token URL:</strong> <code>' . $GLOBALS['base_url'] . '/oauth/token</code></li>
          <li><strong>User Info URL:</strong> <code>' . $GLOBALS['base_url'] . '/oauth/userinfo</code></li>
        </ul>'),
    ];

    $form['moodle_settings'] = [
      '#type' => 'fieldset',
      '#title' => $this->t('Moodle Integration Settings'),
    ];

    $form['moodle_settings']['moodle_url'] = [
      '#type' => 'url',
      '#title' => $this->t('Moodle URL'),
      '#default_value' => $config->get('moodle_url'),
      '#description' => $this->t('The base URL of your Moodle installation (e.g., https://moodle.example.com).'),
      '#required' => FALSE,
    ];

    $form['moodle_settings']['enable_auto_provisioning'] = [
      '#type' => 'checkbox',
      '#title' => $this->t('Enable automatic user provisioning'),
      '#default_value' => $config->get('enable_auto_provisioning') ?? TRUE,
      '#description' => $this->t('Automatically create Moodle accounts for AVC users on first login.'),
    ];

    $form['oauth_settings'] = [
      '#type' => 'fieldset',
      '#title' => $this->t('OAuth2 Token Settings'),
    ];

    $form['oauth_settings']['token_lifetime'] = [
      '#type' => 'number',
      '#title' => $this->t('Access token lifetime'),
      '#default_value' => $config->get('token_lifetime') ?? 3600,
      '#description' => $this->t('Access token lifetime in seconds (default: 3600 = 1 hour).'),
      '#min' => 300,
      '#max' => 86400,
      '#required' => TRUE,
    ];

    $form['oauth_settings']['refresh_token_lifetime'] = [
      '#type' => 'number',
      '#title' => $this->t('Refresh token lifetime'),
      '#default_value' => $config->get('refresh_token_lifetime') ?? 1209600,
      '#description' => $this->t('Refresh token lifetime in seconds (default: 1209600 = 14 days).'),
      '#min' => 3600,
      '#max' => 2592000,
      '#required' => TRUE,
    ];

    $form['user_info_settings'] = [
      '#type' => 'fieldset',
      '#title' => $this->t('UserInfo Endpoint Settings'),
    ];

    $form['user_info_settings']['include_guilds'] = [
      '#type' => 'checkbox',
      '#title' => $this->t('Include guild memberships in UserInfo'),
      '#default_value' => $config->get('include_guilds') ?? TRUE,
      '#description' => $this->t('Include user guild memberships in the OAuth2 UserInfo response.'),
    ];

    $form['user_info_settings']['include_guild_roles'] = [
      '#type' => 'checkbox',
      '#title' => $this->t('Include guild roles in UserInfo'),
      '#default_value' => $config->get('include_guild_roles') ?? TRUE,
      '#description' => $this->t('Include user guild roles in the OAuth2 UserInfo response.'),
    ];

    $form['user_info_settings']['include_profile_picture'] = [
      '#type' => 'checkbox',
      '#title' => $this->t('Include profile picture in UserInfo'),
      '#default_value' => $config->get('include_profile_picture') ?? TRUE,
      '#description' => $this->t('Include user profile picture URL in the OAuth2 UserInfo response.'),
    ];

    $form['advanced'] = [
      '#type' => 'details',
      '#title' => $this->t('Advanced Settings'),
      '#open' => FALSE,
    ];

    $form['advanced']['enable_logging'] = [
      '#type' => 'checkbox',
      '#title' => $this->t('Enable debug logging'),
      '#default_value' => $config->get('enable_logging') ?? FALSE,
      '#description' => $this->t('Log OAuth2 requests and responses for debugging. <strong>Warning:</strong> This may log sensitive information.'),
    ];

    return parent::buildForm($form, $form_state);
  }

  /**
   * {@inheritdoc}
   */
  public function validateForm(array &$form, FormStateInterface $form_state) {
    parent::validateForm($form, $form_state);

    // Validate Moodle URL format if provided.
    $moodle_url = $form_state->getValue('moodle_url');
    if (!empty($moodle_url)) {
      if (!filter_var($moodle_url, FILTER_VALIDATE_URL)) {
        $form_state->setErrorByName('moodle_url', $this->t('Please enter a valid URL.'));
      }
    }

    // Validate token lifetimes.
    $token_lifetime = $form_state->getValue('token_lifetime');
    if ($token_lifetime < 300 || $token_lifetime > 86400) {
      $form_state->setErrorByName('token_lifetime', $this->t('Access token lifetime must be between 300 seconds (5 minutes) and 86400 seconds (24 hours).'));
    }

    $refresh_token_lifetime = $form_state->getValue('refresh_token_lifetime');
    if ($refresh_token_lifetime < 3600 || $refresh_token_lifetime > 2592000) {
      $form_state->setErrorByName('refresh_token_lifetime', $this->t('Refresh token lifetime must be between 3600 seconds (1 hour) and 2592000 seconds (30 days).'));
    }
  }

  /**
   * {@inheritdoc}
   */
  public function submitForm(array &$form, FormStateInterface $form_state) {
    $this->config('avc_moodle_oauth.settings')
      ->set('moodle_url', $form_state->getValue('moodle_url'))
      ->set('enable_auto_provisioning', $form_state->getValue('enable_auto_provisioning'))
      ->set('token_lifetime', $form_state->getValue('token_lifetime'))
      ->set('refresh_token_lifetime', $form_state->getValue('refresh_token_lifetime'))
      ->set('include_guilds', $form_state->getValue('include_guilds'))
      ->set('include_guild_roles', $form_state->getValue('include_guild_roles'))
      ->set('include_profile_picture', $form_state->getValue('include_profile_picture'))
      ->set('enable_logging', $form_state->getValue('enable_logging'))
      ->save();

    parent::submitForm($form, $form_state);
  }

}
