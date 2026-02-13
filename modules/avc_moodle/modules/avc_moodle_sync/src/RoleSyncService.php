<?php

namespace Drupal\avc_moodle_sync;

use Drupal\Core\Config\ConfigFactoryInterface;
use Drupal\Core\Entity\EntityTypeManagerInterface;
use Drupal\Core\Logger\LoggerChannelFactoryInterface;
use Drupal\user\Entity\User;

/**
 * Service for synchronizing AVC guild roles to Moodle.
 *
 * This service handles:
 * - Mapping guild roles to Moodle cohorts and roles
 * - Syncing individual users
 * - Syncing entire guilds
 * - Full sync operations
 */
class RoleSyncService {

  /**
   * The Moodle API client.
   *
   * @var \Drupal\avc_moodle_sync\MoodleApiClient
   */
  protected $moodleApi;

  /**
   * The config factory.
   *
   * @var \Drupal\Core\Config\ConfigFactoryInterface
   */
  protected $configFactory;

  /**
   * The entity type manager.
   *
   * @var \Drupal\Core\Entity\EntityTypeManagerInterface
   */
  protected $entityTypeManager;

  /**
   * The logger.
   *
   * @var \Psr\Log\LoggerInterface
   */
  protected $logger;

  /**
   * Constructs a RoleSyncService object.
   *
   * @param \Drupal\avc_moodle_sync\MoodleApiClient $moodle_api
   *   The Moodle API client.
   * @param \Drupal\Core\Config\ConfigFactoryInterface $config_factory
   *   The config factory.
   * @param \Drupal\Core\Entity\EntityTypeManagerInterface $entity_type_manager
   *   The entity type manager.
   * @param \Drupal\Core\Logger\LoggerChannelFactoryInterface $logger_factory
   *   The logger factory.
   */
  public function __construct(
    MoodleApiClient $moodle_api,
    ConfigFactoryInterface $config_factory,
    EntityTypeManagerInterface $entity_type_manager,
    LoggerChannelFactoryInterface $logger_factory
  ) {
    $this->moodleApi = $moodle_api;
    $this->configFactory = $config_factory;
    $this->entityTypeManager = $entity_type_manager;
    $this->logger = $logger_factory->get('avc_moodle_sync');
  }

  /**
   * Get sync configuration.
   *
   * @return \Drupal\Core\Config\ImmutableConfig
   *   The configuration object.
   */
  protected function getConfig() {
    return $this->configFactory->get('avc_moodle_sync.settings');
  }

  /**
   * Get role mapping configuration.
   *
   * Maps AVC guild roles to Moodle cohorts and roles.
   *
   * @return array
   *   Role mapping configuration.
   */
  protected function getRoleMapping() {
    $config = $this->getConfig();
    return $config->get('role_mapping') ?? [];
  }

  /**
   * Sync a single user's guild roles to Moodle.
   *
   * @param \Drupal\user\Entity\User $user
   *   The user to sync.
   *
   * @return bool
   *   TRUE on success, FALSE on failure.
   */
  public function syncUser(User $user) {
    $config = $this->getConfig();

    if (!$config->get('enable_sync')) {
      $this->logger->warning('Sync is disabled. Enable in settings to sync users.');
      return FALSE;
    }

    // Get Moodle user by email or username.
    $moodle_user = $this->moodleApi->getUserByEmail($user->getEmail());
    if (!$moodle_user) {
      $moodle_user = $this->moodleApi->getUserByUsername($user->getAccountName());
    }

    if (!$moodle_user) {
      $this->logger->warning('Moodle user not found for AVC user @user', [
        '@user' => $user->getAccountName(),
      ]);
      return FALSE;
    }

    $moodle_user_id = $moodle_user['id'];

    // Get user's guild memberships and roles.
    $guild_memberships = $this->getUserGuildMemberships($user);

    // Process each guild membership.
    $success = TRUE;
    foreach ($guild_memberships as $guild_id => $roles) {
      if (!$this->syncUserGuild($user, $moodle_user_id, $guild_id, $roles)) {
        $success = FALSE;
      }
    }

    // Remove user from cohorts they no longer belong to.
    $this->cleanupUserCohorts($moodle_user_id, array_keys($guild_memberships));

    if ($success) {
      $this->logger->info('Synced user @user to Moodle', [
        '@user' => $user->getAccountName(),
      ]);
    }

    return $success;
  }

  /**
   * Sync a user's membership in a single guild.
   *
   * @param \Drupal\user\Entity\User $user
   *   The user.
   * @param int $moodle_user_id
   *   Moodle user ID.
   * @param int $guild_id
   *   AVC guild ID.
   * @param array $roles
   *   Array of role IDs.
   *
   * @return bool
   *   TRUE on success, FALSE on failure.
   */
  protected function syncUserGuild($user, $moodle_user_id, $guild_id, array $roles) {
    $role_mapping = $this->getRoleMapping();

    // Get guild entity.
    if (\Drupal::moduleHandler()->moduleExists('group')) {
      $guild = $this->entityTypeManager->getStorage('group')->load($guild_id);
    }
    elseif (\Drupal::moduleHandler()->moduleExists('og')) {
      // OG support.
      $guild = $this->entityTypeManager->getStorage('node')->load($guild_id);
    }
    else {
      return FALSE;
    }

    if (!$guild) {
      return FALSE;
    }

    $guild_name = $guild->label();
    $success = TRUE;

    // Check if this guild has a mapping.
    if (isset($role_mapping[$guild_id]) || isset($role_mapping[$guild_name])) {
      $guild_mapping = $role_mapping[$guild_id] ?? $role_mapping[$guild_name];

      // Sync cohort membership.
      if (isset($guild_mapping['cohort'])) {
        $cohort = $this->moodleApi->getCohort($guild_mapping['cohort']);
        if ($cohort) {
          if (!$this->moodleApi->addUserToCohort($moodle_user_id, $cohort['id'])) {
            $success = FALSE;
          }
        }
      }

      // Sync role assignments.
      foreach ($roles as $role_id) {
        if (isset($guild_mapping['roles'][$role_id])) {
          $moodle_role_id = $guild_mapping['roles'][$role_id];
          if (!$this->moodleApi->assignRole($moodle_user_id, $moodle_role_id)) {
            $success = FALSE;
          }
        }
      }
    }

    return $success;
  }

  /**
   * Get user's guild memberships and roles.
   *
   * @param \Drupal\user\Entity\User $user
   *   The user.
   *
   * @return array
   *   Array of guild_id => [role_ids].
   */
  protected function getUserGuildMemberships(User $user) {
    $memberships = [];

    // Group module support.
    if (\Drupal::moduleHandler()->moduleExists('group')) {
      $group_membership_service = \Drupal::service('group.membership_loader');
      $group_memberships = $group_membership_service->loadByUser($user);

      foreach ($group_memberships as $membership) {
        $group = $membership->getGroup();
        $roles = $membership->getRoles();

        $role_ids = [];
        foreach ($roles as $role) {
          $role_ids[] = $role->id();
        }

        $memberships[$group->id()] = $role_ids;
      }
    }
    // Organic Groups support.
    elseif (\Drupal::moduleHandler()->moduleExists('og')) {
      $og_memberships = \Drupal::service('og.membership_manager')->getMemberships($user->id());

      foreach ($og_memberships as $membership) {
        $group = $membership->getGroup();
        $roles = $membership->getRoles();

        $role_ids = [];
        foreach ($roles as $role) {
          $role_ids[] = $role->getName();
        }

        $memberships[$group->id()] = $role_ids;
      }
    }

    return $memberships;
  }

  /**
   * Remove user from Moodle cohorts they no longer belong to.
   *
   * @param int $moodle_user_id
   *   Moodle user ID.
   * @param array $current_guild_ids
   *   Array of current guild IDs.
   *
   * @return bool
   *   TRUE on success.
   */
  protected function cleanupUserCohorts($moodle_user_id, array $current_guild_ids) {
    // Get all cohorts user is currently in.
    $user_cohorts = $this->moodleApi->getUserCohorts($moodle_user_id);
    $role_mapping = $this->getRoleMapping();

    // Build list of cohorts user should be in.
    $should_be_in_cohorts = [];
    foreach ($current_guild_ids as $guild_id) {
      if (isset($role_mapping[$guild_id]['cohort'])) {
        $cohort = $this->moodleApi->getCohort($role_mapping[$guild_id]['cohort']);
        if ($cohort) {
          $should_be_in_cohorts[] = $cohort['id'];
        }
      }
    }

    // Remove from cohorts they shouldn't be in.
    foreach ($user_cohorts as $cohort_id) {
      if (!in_array($cohort_id, $should_be_in_cohorts)) {
        $this->moodleApi->removeUserFromCohort($moodle_user_id, $cohort_id);
      }
    }

    return TRUE;
  }

  /**
   * Sync all members of a guild.
   *
   * @param int $guild_id
   *   Guild ID.
   *
   * @return array
   *   Array with 'success' and 'failed' counts.
   */
  public function syncGuild($guild_id) {
    $result = ['success' => 0, 'failed' => 0];

    // Get guild entity.
    if (\Drupal::moduleHandler()->moduleExists('group')) {
      $guild = $this->entityTypeManager->getStorage('group')->load($guild_id);
      if (!$guild) {
        return $result;
      }

      // Get all members.
      $membership_service = \Drupal::service('group.membership_loader');
      $memberships = $membership_service->loadByGroup($guild);

      foreach ($memberships as $membership) {
        $user = $membership->getUser();
        if ($this->syncUser($user)) {
          $result['success']++;
        }
        else {
          $result['failed']++;
        }
      }
    }
    elseif (\Drupal::moduleHandler()->moduleExists('og')) {
      // OG support.
      $guild = $this->entityTypeManager->getStorage('node')->load($guild_id);
      if (!$guild) {
        return $result;
      }

      $members = \Drupal::service('og.membership_manager')->getGroupMemberIds($guild);
      foreach ($members as $user_id) {
        $user = User::load($user_id);
        if ($user && $this->syncUser($user)) {
          $result['success']++;
        }
        else {
          $result['failed']++;
        }
      }
    }

    $this->logger->info('Synced guild @guild: @success success, @failed failed', [
      '@guild' => $guild_id,
      '@success' => $result['success'],
      '@failed' => $result['failed'],
    ]);

    return $result;
  }

  /**
   * Perform full sync of all guilds and users.
   *
   * @return array
   *   Array with 'guilds', 'success', and 'failed' counts.
   */
  public function fullSync() {
    $result = ['guilds' => 0, 'success' => 0, 'failed' => 0];
    $role_mapping = $this->getRoleMapping();

    // Get all mapped guilds.
    $guild_ids = array_keys($role_mapping);

    foreach ($guild_ids as $guild_id) {
      $guild_result = $this->syncGuild($guild_id);
      $result['guilds']++;
      $result['success'] += $guild_result['success'];
      $result['failed'] += $guild_result['failed'];
    }

    $this->logger->info('Full sync completed: @guilds guilds, @success users synced, @failed failed', [
      '@guilds' => $result['guilds'],
      '@success' => $result['success'],
      '@failed' => $result['failed'],
    ]);

    return $result;
  }

}
