<?php

namespace Drupal\avc_moodle_sync;

use Drupal\Core\Config\ConfigFactoryInterface;
use Drupal\Core\Logger\LoggerChannelFactoryInterface;
use GuzzleHttp\ClientInterface;
use GuzzleHttp\Exception\RequestException;

/**
 * Moodle Web Services API client.
 *
 * Provides methods to interact with Moodle Web Services API for:
 * - User management
 * - Cohort management
 * - Role assignments
 */
class MoodleApiClient {

  /**
   * The config factory.
   *
   * @var \Drupal\Core\Config\ConfigFactoryInterface
   */
  protected $configFactory;

  /**
   * The HTTP client.
   *
   * @var \GuzzleHttp\ClientInterface
   */
  protected $httpClient;

  /**
   * The logger.
   *
   * @var \Psr\Log\LoggerInterface
   */
  protected $logger;

  /**
   * Constructs a MoodleApiClient object.
   *
   * @param \Drupal\Core\Config\ConfigFactoryInterface $config_factory
   *   The config factory.
   * @param \GuzzleHttp\ClientInterface $http_client
   *   The HTTP client.
   * @param \Drupal\Core\Logger\LoggerChannelFactoryInterface $logger_factory
   *   The logger factory.
   */
  public function __construct(
    ConfigFactoryInterface $config_factory,
    ClientInterface $http_client,
    LoggerChannelFactoryInterface $logger_factory
  ) {
    $this->configFactory = $config_factory;
    $this->httpClient = $http_client;
    $this->logger = $logger_factory->get('avc_moodle_sync');
  }

  /**
   * Get Moodle configuration.
   *
   * @return \Drupal\Core\Config\ImmutableConfig
   *   The configuration object.
   */
  protected function getConfig() {
    return $this->configFactory->get('avc_moodle_sync.settings');
  }

  /**
   * Make a Moodle Web Services API call.
   *
   * @param string $function
   *   The Moodle web service function name.
   * @param array $params
   *   Function parameters.
   *
   * @return mixed
   *   The API response data or FALSE on error.
   */
  protected function callApi($function, array $params = []) {
    $config = $this->getConfig();
    $moodle_url = $config->get('moodle_url');
    $token = $config->get('webservice_token');

    if (empty($moodle_url) || empty($token)) {
      $this->logger->error('Moodle URL or webservice token not configured');
      return FALSE;
    }

    $url = rtrim($moodle_url, '/') . '/webservice/rest/server.php';

    // Build query parameters.
    $query = [
      'wstoken' => $token,
      'wsfunction' => $function,
      'moodlewsrestformat' => 'json',
    ];

    // Merge function parameters.
    $query = array_merge($query, $params);

    try {
      $response = $this->httpClient->post($url, [
        'form_params' => $query,
        'timeout' => 30,
      ]);

      $body = $response->getBody()->getContents();
      $data = json_decode($body, TRUE);

      // Check for Moodle error response.
      if (isset($data['exception'])) {
        $this->logger->error('Moodle API error: @message', [
          '@message' => $data['message'] ?? $data['exception'],
        ]);
        return FALSE;
      }

      return $data;
    }
    catch (RequestException $e) {
      $this->logger->error('Moodle API request failed: @message', [
        '@message' => $e->getMessage(),
      ]);
      return FALSE;
    }
  }

  /**
   * Test the API connection and token.
   *
   * @return bool
   *   TRUE if connection successful, FALSE otherwise.
   */
  public function testConnection() {
    $result = $this->callApi('core_webservice_get_site_info');
    return $result !== FALSE;
  }

  /**
   * Get Moodle user by username.
   *
   * @param string $username
   *   The username.
   *
   * @return array|false
   *   User data array or FALSE if not found.
   */
  public function getUserByUsername($username) {
    $result = $this->callApi('core_user_get_users', [
      'criteria[0][key]' => 'username',
      'criteria[0][value]' => $username,
    ]);

    if ($result && isset($result['users']) && !empty($result['users'])) {
      return $result['users'][0];
    }

    return FALSE;
  }

  /**
   * Get Moodle user by email.
   *
   * @param string $email
   *   The email address.
   *
   * @return array|false
   *   User data array or FALSE if not found.
   */
  public function getUserByEmail($email) {
    $result = $this->callApi('core_user_get_users', [
      'criteria[0][key]' => 'email',
      'criteria[0][value]' => $email,
    ]);

    if ($result && isset($result['users']) && !empty($result['users'])) {
      return $result['users'][0];
    }

    return FALSE;
  }

  /**
   * Get cohort by name or idnumber.
   *
   * @param string $identifier
   *   The cohort name or idnumber.
   *
   * @return array|false
   *   Cohort data array or FALSE if not found.
   */
  public function getCohort($identifier) {
    // Try by idnumber first (more reliable).
    $result = $this->callApi('core_cohort_search_cohorts', [
      'query' => $identifier,
      'context[contextid]' => 1, // System context.
    ]);

    if ($result && isset($result['cohorts']) && !empty($result['cohorts'])) {
      foreach ($result['cohorts'] as $cohort) {
        if ($cohort['idnumber'] === $identifier || $cohort['name'] === $identifier) {
          return $cohort;
        }
      }
    }

    return FALSE;
  }

  /**
   * Add user to cohort.
   *
   * @param int $user_id
   *   Moodle user ID.
   * @param int $cohort_id
   *   Moodle cohort ID.
   *
   * @return bool
   *   TRUE on success, FALSE on failure.
   */
  public function addUserToCohort($user_id, $cohort_id) {
    $result = $this->callApi('core_cohort_add_cohort_members', [
      'members[0][cohorttype][type]' => 'id',
      'members[0][cohorttype][value]' => $cohort_id,
      'members[0][usertype][type]' => 'id',
      'members[0][usertype][value]' => $user_id,
    ]);

    if ($result !== FALSE) {
      $this->logger->info('Added user @user to cohort @cohort', [
        '@user' => $user_id,
        '@cohort' => $cohort_id,
      ]);
      return TRUE;
    }

    return FALSE;
  }

  /**
   * Remove user from cohort.
   *
   * @param int $user_id
   *   Moodle user ID.
   * @param int $cohort_id
   *   Moodle cohort ID.
   *
   * @return bool
   *   TRUE on success, FALSE on failure.
   */
  public function removeUserFromCohort($user_id, $cohort_id) {
    $result = $this->callApi('core_cohort_delete_cohort_members', [
      'members[0][cohortid]' => $cohort_id,
      'members[0][userid]' => $user_id,
    ]);

    if ($result !== FALSE) {
      $this->logger->info('Removed user @user from cohort @cohort', [
        '@user' => $user_id,
        '@cohort' => $cohort_id,
      ]);
      return TRUE;
    }

    return FALSE;
  }

  /**
   * Assign role to user in context.
   *
   * @param int $user_id
   *   Moodle user ID.
   * @param int $role_id
   *   Moodle role ID.
   * @param int $context_id
   *   Context ID (default: 1 for system context).
   *
   * @return bool
   *   TRUE on success, FALSE on failure.
   */
  public function assignRole($user_id, $role_id, $context_id = 1) {
    $result = $this->callApi('core_role_assign_roles', [
      'assignments[0][roleid]' => $role_id,
      'assignments[0][userid]' => $user_id,
      'assignments[0][contextid]' => $context_id,
    ]);

    if ($result !== FALSE) {
      $this->logger->info('Assigned role @role to user @user in context @context', [
        '@role' => $role_id,
        '@user' => $user_id,
        '@context' => $context_id,
      ]);
      return TRUE;
    }

    return FALSE;
  }

  /**
   * Unassign role from user in context.
   *
   * @param int $user_id
   *   Moodle user ID.
   * @param int $role_id
   *   Moodle role ID.
   * @param int $context_id
   *   Context ID (default: 1 for system context).
   *
   * @return bool
   *   TRUE on success, FALSE on failure.
   */
  public function unassignRole($user_id, $role_id, $context_id = 1) {
    $result = $this->callApi('core_role_unassign_roles', [
      'unassignments[0][roleid]' => $role_id,
      'unassignments[0][userid]' => $user_id,
      'unassignments[0][contextid]' => $context_id,
    ]);

    if ($result !== FALSE) {
      $this->logger->info('Unassigned role @role from user @user in context @context', [
        '@role' => $role_id,
        '@user' => $user_id,
        '@context' => $context_id,
      ]);
      return TRUE;
    }

    return FALSE;
  }

  /**
   * Get user's cohort memberships.
   *
   * @param int $user_id
   *   Moodle user ID.
   *
   * @return array
   *   Array of cohort IDs.
   */
  public function getUserCohorts($user_id) {
    $result = $this->callApi('core_cohort_get_cohort_members', [
      'cohortids[0]' => 0, // Get all cohorts.
    ]);

    $user_cohorts = [];
    if ($result && isset($result[0]['userids'])) {
      foreach ($result as $cohort) {
        if (in_array($user_id, $cohort['userids'])) {
          $user_cohorts[] = $cohort['cohortid'];
        }
      }
    }

    return $user_cohorts;
  }

}
