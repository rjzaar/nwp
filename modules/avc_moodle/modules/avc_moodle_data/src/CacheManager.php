<?php

namespace Drupal\avc_moodle_data;

use Drupal\Core\Cache\CacheBackendInterface;
use Drupal\Core\Config\ConfigFactoryInterface;

/**
 * Cache manager for Moodle data.
 */
class CacheManager {

  protected $cache;
  protected $configFactory;

  public function __construct(CacheBackendInterface $cache, ConfigFactoryInterface $config_factory) {
    $this->cache = $cache;
    $this->configFactory = $config_factory;
  }

  /**
   * Invalidate cache for a user.
   */
  public function invalidateUser($user_id) {
    $this->cache->delete("avc_moodle_data:badges:{$user_id}");
    $this->cache->delete("avc_moodle_data:completions:{$user_id}");
  }

  /**
   * Clear all Moodle data cache.
   */
  public function clearAll() {
    $this->cache->deleteAll();
  }

}
