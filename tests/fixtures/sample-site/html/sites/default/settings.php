<?php
/**
 * @file
 * Test Drupal settings file - FIXTURE ONLY
 *
 * This is a minimal settings.php for testing purposes.
 * NOT for production use.
 */

// Test database configuration
$databases['default']['default'] = [
  'database' => 'db',
  'username' => 'db',
  'password' => 'db',
  'host' => 'db',
  'port' => '3306',
  'driver' => 'mysql',
  'prefix' => '',
  'collation' => 'utf8mb4_general_ci',
];

// Test site configuration
$settings['hash_salt'] = 'test_hash_salt_for_testing_only_12345';
$settings['config_sync_directory'] = '../config/sync';
$settings['file_private_path'] = '../private';

// Test environment indicator
$config['environment_indicator.indicator']['bg_color'] = '#00FF00';
$config['environment_indicator.indicator']['fg_color'] = '#000000';
$config['environment_indicator.indicator']['name'] = 'Test';
