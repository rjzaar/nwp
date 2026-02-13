<?php

namespace Drupal\avc_moodle_sync\Commands;

use Drupal\avc_moodle_sync\MoodleApiClient;
use Drupal\avc_moodle_sync\RoleSyncService;
use Drupal\Core\Entity\EntityTypeManagerInterface;
use Drupal\user\Entity\User;
use Drush\Commands\DrushCommands;

/**
 * Drush commands for AVC Moodle synchronization.
 */
class SyncCommands extends DrushCommands {

  /**
   * The role sync service.
   *
   * @var \Drupal\avc_moodle_sync\RoleSyncService
   */
  protected $roleSyncService;

  /**
   * The Moodle API client.
   *
   * @var \Drupal\avc_moodle_sync\MoodleApiClient
   */
  protected $moodleApi;

  /**
   * The entity type manager.
   *
   * @var \Drupal\Core\Entity\EntityTypeManagerInterface
   */
  protected $entityTypeManager;

  /**
   * Constructs a SyncCommands object.
   *
   * @param \Drupal\avc_moodle_sync\RoleSyncService $role_sync_service
   *   The role sync service.
   * @param \Drupal\avc_moodle_sync\MoodleApiClient $moodle_api
   *   The Moodle API client.
   * @param \Drupal\Core\Entity\EntityTypeManagerInterface $entity_type_manager
   *   The entity type manager.
   */
  public function __construct(
    RoleSyncService $role_sync_service,
    MoodleApiClient $moodle_api,
    EntityTypeManagerInterface $entity_type_manager
  ) {
    parent::__construct();
    $this->roleSyncService = $role_sync_service;
    $this->moodleApi = $moodle_api;
    $this->entityTypeManager = $entity_type_manager;
  }

  /**
   * Test Moodle API connection.
   *
   * @command avc-moodle:test-connection
   * @aliases avc-moodle-test
   * @usage avc-moodle:test-connection
   *   Test the connection to Moodle Web Services API.
   */
  public function testConnection() {
    $this->output()->writeln('Testing Moodle API connection...');

    if ($this->moodleApi->testConnection()) {
      $this->output()->writeln('<info>✓ Connection successful!</info>');
      return DrushCommands::EXIT_SUCCESS;
    }
    else {
      $this->output()->writeln('<error>✗ Connection failed. Check configuration and logs.</error>');
      return DrushCommands::EXIT_FAILURE;
    }
  }

  /**
   * Test Moodle API token validity.
   *
   * @command avc-moodle:test-token
   * @aliases avc-moodle-token
   * @usage avc-moodle:test-token
   *   Test if the Moodle webservice token is valid.
   */
  public function testToken() {
    $this->output()->writeln('Testing Moodle webservice token...');

    $result = $this->moodleApi->testConnection();
    if ($result) {
      $this->output()->writeln('<info>✓ Token is valid!</info>');
      return DrushCommands::EXIT_SUCCESS;
    }
    else {
      $this->output()->writeln('<error>✗ Token is invalid or API error. Check logs.</error>');
      return DrushCommands::EXIT_FAILURE;
    }
  }

  /**
   * Sync a specific user to Moodle.
   *
   * @param string $user_identifier
   *   User ID, username, or email.
   *
   * @command avc-moodle:sync-user
   * @aliases avc-moodle-user
   * @usage avc-moodle:sync-user 1
   *   Sync user with ID 1.
   * @usage avc-moodle:sync-user admin
   *   Sync user with username 'admin'.
   * @usage avc-moodle:sync-user user@example.com
   *   Sync user with email 'user@example.com'.
   */
  public function syncUser($user_identifier) {
    $user = $this->loadUser($user_identifier);

    if (!$user) {
      $this->output()->writeln("<error>User '$user_identifier' not found.</error>");
      return DrushCommands::EXIT_FAILURE;
    }

    $this->output()->writeln("Syncing user: {$user->getAccountName()} ({$user->id()})");

    if ($this->roleSyncService->syncUser($user)) {
      $this->output()->writeln('<info>✓ User synced successfully!</info>');
      return DrushCommands::EXIT_SUCCESS;
    }
    else {
      $this->output()->writeln('<error>✗ User sync failed. Check logs.</error>');
      return DrushCommands::EXIT_FAILURE;
    }
  }

  /**
   * Sync all members of a specific guild.
   *
   * @param string $guild_identifier
   *   Guild ID or name.
   *
   * @command avc-moodle:sync-guild
   * @aliases avc-moodle-guild
   * @usage avc-moodle:sync-guild 5
   *   Sync guild with ID 5.
   * @usage avc-moodle:sync-guild "My Guild"
   *   Sync guild named "My Guild".
   */
  public function syncGuild($guild_identifier) {
    $guild = $this->loadGuild($guild_identifier);

    if (!$guild) {
      $this->output()->writeln("<error>Guild '$guild_identifier' not found.</error>");
      return DrushCommands::EXIT_FAILURE;
    }

    $this->output()->writeln("Syncing guild: {$guild->label()} ({$guild->id()})");

    $result = $this->roleSyncService->syncGuild($guild->id());

    $this->output()->writeln("<info>✓ Guild synced!</info>");
    $this->output()->writeln("  Success: {$result['success']}");
    $this->output()->writeln("  Failed: {$result['failed']}");

    return $result['failed'] > 0 ? DrushCommands::EXIT_FAILURE : DrushCommands::EXIT_SUCCESS;
  }

  /**
   * Perform full sync of all guilds and users.
   *
   * @command avc-moodle:sync-all
   * @aliases avc-moodle-full-sync
   * @option dry-run Show what would be synced without making changes.
   * @usage avc-moodle:sync-all
   *   Sync all guilds and users to Moodle.
   * @usage avc-moodle:sync-all --dry-run
   *   Show what would be synced without making changes.
   */
  public function syncAll($options = ['dry-run' => FALSE]) {
    if ($options['dry-run']) {
      $this->output()->writeln('<comment>DRY RUN - No changes will be made</comment>');
    }

    $this->output()->writeln('Starting full sync...');

    if (!$options['dry-run']) {
      $result = $this->roleSyncService->fullSync();

      $this->output()->writeln('<info>✓ Full sync completed!</info>');
      $this->output()->writeln("  Guilds synced: {$result['guilds']}");
      $this->output()->writeln("  Users success: {$result['success']}");
      $this->output()->writeln("  Users failed: {$result['failed']}");

      return $result['failed'] > 0 ? DrushCommands::EXIT_FAILURE : DrushCommands::EXIT_SUCCESS;
    }

    return DrushCommands::EXIT_SUCCESS;
  }

  /**
   * Show sync status and configuration.
   *
   * @command avc-moodle:status
   * @aliases avc-moodle-status
   * @usage avc-moodle:status
   *   Show sync configuration and status.
   */
  public function status() {
    $config = \Drupal::config('avc_moodle_sync.settings');

    $this->output()->writeln('<info>AVC Moodle Sync Status</info>');
    $this->output()->writeln('');
    $this->output()->writeln('Configuration:');
    $this->output()->writeln('  Moodle URL: ' . ($config->get('moodle_url') ?: '<none>'));
    $this->output()->writeln('  Sync enabled: ' . ($config->get('enable_sync') ? 'Yes' : 'No'));
    $this->output()->writeln('  Automatic sync: ' . ($config->get('enable_automatic_sync') ? 'Yes' : 'No'));
    $this->output()->writeln('');

    // Test connection.
    $this->output()->writeln('Testing connection...');
    if ($this->moodleApi->testConnection()) {
      $this->output()->writeln('  <info>✓ Connected to Moodle</info>');
    }
    else {
      $this->output()->writeln('  <error>✗ Cannot connect to Moodle</error>');
    }

    return DrushCommands::EXIT_SUCCESS;
  }

  /**
   * Load user by ID, username, or email.
   *
   * @param string $identifier
   *   User identifier.
   *
   * @return \Drupal\user\Entity\User|null
   *   User entity or NULL.
   */
  protected function loadUser($identifier) {
    // Try loading by ID first.
    if (is_numeric($identifier)) {
      $user = User::load($identifier);
      if ($user) {
        return $user;
      }
    }

    // Try by username.
    $users = $this->entityTypeManager->getStorage('user')->loadByProperties([
      'name' => $identifier,
    ]);
    if (!empty($users)) {
      return reset($users);
    }

    // Try by email.
    $users = $this->entityTypeManager->getStorage('user')->loadByProperties([
      'mail' => $identifier,
    ]);
    if (!empty($users)) {
      return reset($users);
    }

    return NULL;
  }

  /**
   * Load guild by ID or name.
   *
   * @param string $identifier
   *   Guild identifier.
   *
   * @return \Drupal\Core\Entity\EntityInterface|null
   *   Guild entity or NULL.
   */
  protected function loadGuild($identifier) {
    // Determine entity type based on installed modules.
    $entity_type = 'group';
    if (!\Drupal::moduleHandler()->moduleExists('group')) {
      $entity_type = 'node'; // OG uses nodes.
    }

    // Try loading by ID first.
    if (is_numeric($identifier)) {
      $guild = $this->entityTypeManager->getStorage($entity_type)->load($identifier);
      if ($guild) {
        return $guild;
      }
    }

    // Try by label/title.
    $field = $entity_type === 'group' ? 'label' : 'title';
    $guilds = $this->entityTypeManager->getStorage($entity_type)->loadByProperties([
      $field => $identifier,
    ]);
    if (!empty($guilds)) {
      return reset($guilds);
    }

    return NULL;
  }

}
