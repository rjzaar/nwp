<?php

namespace Drupal\avc_moodle_oauth\Controller;

use Drupal\Core\Controller\ControllerBase;
use Drupal\Core\Session\AccountProxyInterface;
use Drupal\user\Entity\User;
use Symfony\Component\DependencyInjection\ContainerInterface;
use Symfony\Component\HttpFoundation\JsonResponse;
use Symfony\Component\HttpFoundation\Request;

/**
 * Controller for OAuth2 UserInfo endpoint.
 *
 * This endpoint is called by Moodle after successful OAuth2 authentication
 * to retrieve user information. Implements OpenID Connect UserInfo spec.
 *
 * @see https://openid.net/specs/openid-connect-core-1_0.html#UserInfo
 */
class UserInfoController extends ControllerBase {

  /**
   * The current user.
   *
   * @var \Drupal\Core\Session\AccountProxyInterface
   */
  protected $currentUser;

  /**
   * Constructs a UserInfoController object.
   *
   * @param \Drupal\Core\Session\AccountProxyInterface $current_user
   *   The current user.
   */
  public function __construct(AccountProxyInterface $current_user) {
    $this->currentUser = $current_user;
  }

  /**
   * {@inheritdoc}
   */
  public static function create(ContainerInterface $container) {
    return new static(
      $container->get('current_user')
    );
  }

  /**
   * Returns user information for OAuth2.
   *
   * Validates the Bearer token, retrieves user information, and returns
   * OpenID Connect standard claims.
   *
   * @param \Symfony\Component\HttpFoundation\Request $request
   *   The request object.
   *
   * @return \Symfony\Component\HttpFoundation\JsonResponse
   *   JSON response with user information or error.
   */
  public function userInfo(Request $request) {
    // Get the access token from the Authorization header.
    $auth_header = $request->headers->get('Authorization');

    if (!$auth_header || !preg_match('/Bearer\s+(.*)$/i', $auth_header, $matches)) {
      return new JsonResponse([
        'error' => 'invalid_request',
        'error_description' => 'No access token provided',
      ], 401);
    }

    $access_token = $matches[1];

    // Validate the token and get user information.
    try {
      $token_storage = \Drupal::service('entity_type.manager')->getStorage('oauth2_token');
      $tokens = $token_storage->loadByProperties(['value' => $access_token]);

      if (empty($tokens)) {
        return new JsonResponse([
          'error' => 'invalid_token',
          'error_description' => 'Invalid access token',
        ], 401);
      }

      $token = reset($tokens);

      // Check if token is expired.
      if ($token->get('expire')->value < time()) {
        return new JsonResponse([
          'error' => 'invalid_token',
          'error_description' => 'Access token expired',
        ], 401);
      }

      // Get user entity.
      $user_id = $token->get('auth_user_id')->target_id;
      $user = User::load($user_id);

      if (!$user) {
        return new JsonResponse([
          'error' => 'invalid_token',
          'error_description' => 'User not found',
        ], 404);
      }

      // Build OpenID Connect UserInfo response.
      $user_info = [
        // Standard OpenID Connect claims.
        'sub' => (string) $user->id(),
        'name' => $user->getDisplayName(),
        'preferred_username' => $user->getAccountName(),
        'email' => $user->getEmail(),
        'email_verified' => TRUE,
      ];

      // Add given name and family name if available.
      if ($user->hasField('field_profile_first_name') && !$user->get('field_profile_first_name')->isEmpty()) {
        $user_info['given_name'] = $user->get('field_profile_first_name')->value;
      }

      if ($user->hasField('field_profile_last_name') && !$user->get('field_profile_last_name')->isEmpty()) {
        $user_info['family_name'] = $user->get('field_profile_last_name')->value;
      }

      // Add profile picture if available.
      $picture_url = $this->getUserPictureUrl($user);
      if ($picture_url) {
        $user_info['picture'] = $picture_url;
      }

      // Add custom AVC claims for guild integration.
      $guilds = $this->getUserGuilds($user);
      if (!empty($guilds)) {
        $user_info['guilds'] = $guilds;
      }

      $guild_roles = $this->getUserGuildRoles($user);
      if (!empty($guild_roles)) {
        $user_info['guild_roles'] = $guild_roles;
      }

      return new JsonResponse($user_info);

    }
    catch (\Exception $e) {
      \Drupal::logger('avc_moodle_oauth')->error('Error in userInfo endpoint: @message', [
        '@message' => $e->getMessage(),
      ]);

      return new JsonResponse([
        'error' => 'server_error',
        'error_description' => 'Internal server error',
      ], 500);
    }
  }

  /**
   * Get user's profile picture URL.
   *
   * @param \Drupal\user\Entity\User $account
   *   User account.
   *
   * @return string|null
   *   Absolute URL to profile picture or NULL.
   */
  protected function getUserPictureUrl(User $account) {
    // Check for user_picture field (standard Drupal).
    if ($account->hasField('user_picture') && !$account->get('user_picture')->isEmpty()) {
      $picture = $account->get('user_picture')->entity;
      if ($picture) {
        // Use Drupal 10 file_create_url replacement.
        $file_url_generator = \Drupal::service('file_url_generator');
        return $file_url_generator->generateAbsoluteString($picture->getFileUri());
      }
    }

    // Check for Open Social profile picture field.
    if ($account->hasField('field_profile_image') && !$account->get('field_profile_image')->isEmpty()) {
      $picture = $account->get('field_profile_image')->entity;
      if ($picture) {
        $file_url_generator = \Drupal::service('file_url_generator');
        return $file_url_generator->generateAbsoluteString($picture->getFileUri());
      }
    }

    return NULL;
  }

  /**
   * Get user's guild memberships.
   *
   * Returns an array of guild identifiers for guilds the user belongs to.
   *
   * @param \Drupal\user\Entity\User $account
   *   User account.
   *
   * @return array
   *   Array of guild data: ['guild_id' => name, ...].
   */
  protected function getUserGuilds(User $account) {
    $guilds = [];

    // Check if group module is installed.
    if (\Drupal::moduleHandler()->moduleExists('group')) {
      $group_membership_service = \Drupal::service('group.membership_loader');
      $group_memberships = $group_membership_service->loadByUser($account);

      foreach ($group_memberships as $membership) {
        $group = $membership->getGroup();
        $guilds[$group->id()] = $group->label();
      }
    }
    // Check if og (Organic Groups) module is installed.
    elseif (\Drupal::moduleHandler()->moduleExists('og')) {
      $og_memberships = \Drupal::service('og.membership_manager')->getMemberships($account->id());

      foreach ($og_memberships as $membership) {
        $group = $membership->getGroup();
        $guilds[$group->id()] = $group->label();
      }
    }

    return $guilds;
  }

  /**
   * Get user's roles within guilds.
   *
   * Returns role assignments for each guild the user belongs to.
   *
   * @param \Drupal\user\Entity\User $account
   *   User account.
   *
   * @return array
   *   Array of guild roles: ['guild_id' => ['role1', 'role2'], ...].
   */
  protected function getUserGuildRoles(User $account) {
    $guild_roles = [];

    // Check if group module is installed.
    if (\Drupal::moduleHandler()->moduleExists('group')) {
      $group_membership_service = \Drupal::service('group.membership_loader');
      $group_memberships = $group_membership_service->loadByUser($account);

      foreach ($group_memberships as $membership) {
        $group = $membership->getGroup();
        $roles = $membership->getRoles();

        $role_ids = [];
        foreach ($roles as $role) {
          $role_ids[] = $role->id();
        }

        if (!empty($role_ids)) {
          $guild_roles[$group->id()] = $role_ids;
        }
      }
    }
    // Check if og (Organic Groups) module is installed.
    elseif (\Drupal::moduleHandler()->moduleExists('og')) {
      $og_memberships = \Drupal::service('og.membership_manager')->getMemberships($account->id());

      foreach ($og_memberships as $membership) {
        $group = $membership->getGroup();
        $roles = $membership->getRoles();

        $role_ids = [];
        foreach ($roles as $role) {
          $role_ids[] = $role->getName();
        }

        if (!empty($role_ids)) {
          $guild_roles[$group->id()] = $role_ids;
        }
      }
    }

    return $guild_roles;
  }

}
