<?php

namespace Drupal\avc_moodle_data;

use Drupal\Core\Config\ConfigFactoryInterface;
use Drupal\Core\Logger\LoggerChannelFactoryInterface;
use Drupal\Core\Cache\CacheBackendInterface;
use GuzzleHttp\ClientInterface;
use GuzzleHttp\Exception\RequestException;

/**
 * Service for fetching Moodle user data.
 *
 * Retrieves badges, course completions, and other user data from Moodle.
 */
class MoodleDataService {

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
   * The cache backend.
   *
   * @var \Drupal\Core\Cache\CacheBackendInterface
   */
  protected $cache;

  /**
   * Constructs a MoodleDataService object.
   */
  public function __construct(
    ConfigFactoryInterface $config_factory,
    ClientInterface $http_client,
    LoggerChannelFactoryInterface $logger_factory,
    CacheBackendInterface $cache
  ) {
    $this->configFactory = $config_factory;
    $this->httpClient = $http_client;
    $this->logger = $logger_factory->get('avc_moodle_data');
    $this->cache = $cache;
  }

  /**
   * Call Moodle Web Services API.
   */
  protected function callApi($function, array $params = []) {
    $config = $this->configFactory->get('avc_moodle_data.settings');
    $moodle_url = $config->get('moodle_url');
    $token = $config->get('webservice_token');

    if (empty($moodle_url) || empty($token)) {
      return FALSE;
    }

    $url = rtrim($moodle_url, '/') . '/webservice/rest/server.php';
    $query = array_merge([
      'wstoken' => $token,
      'wsfunction' => $function,
      'moodlewsrestformat' => 'json',
    ], $params);

    try {
      $response = $this->httpClient->post($url, [
        'form_params' => $query,
        'timeout' => 15,
      ]);
      return json_decode($response->getBody()->getContents(), TRUE);
    }
    catch (RequestException $e) {
      $this->logger->error('Moodle API error: @message', ['@message' => $e->getMessage()]);
      return FALSE;
    }
  }

  /**
   * Get user badges from Moodle.
   */
  public function getUserBadges($moodle_user_id) {
    $cid = "avc_moodle_data:badges:{$moodle_user_id}";
    if ($cached = $this->cache->get($cid)) {
      return $cached->data;
    }

    $result = $this->callApi('core_badges_get_user_badges', [
      'userid' => $moodle_user_id,
    ]);

    if ($result && isset($result['badges'])) {
      $this->cache->set($cid, $result['badges'], time() + 3600);
      return $result['badges'];
    }

    return [];
  }

  /**
   * Get user course completions from Moodle.
   */
  public function getCourseCompletions($moodle_user_id) {
    $cid = "avc_moodle_data:completions:{$moodle_user_id}";
    if ($cached = $this->cache->get($cid)) {
      return $cached->data;
    }

    $result = $this->callApi('core_completion_get_course_completion_status', [
      'userid' => $moodle_user_id,
    ]);

    if ($result) {
      $this->cache->set($cid, $result, time() + 1800);
      return $result;
    }

    return [];
  }

}
