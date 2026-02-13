<?php

namespace Drupal\avc_moodle_sync\EventSubscriber;

use Drupal\avc_moodle_sync\RoleSyncService;
use Drupal\user\Entity\User;
use Symfony\Component\EventDispatcher\EventSubscriberInterface;

/**
 * Event subscriber for guild membership changes.
 *
 * Listens for group/guild membership events and triggers automatic sync.
 */
class GuildMembershipSubscriber implements EventSubscriberInterface {

  /**
   * The role sync service.
   *
   * @var \Drupal\avc_moodle_sync\RoleSyncService
   */
  protected $roleSyncService;

  /**
   * Constructs a GuildMembershipSubscriber object.
   *
   * @param \Drupal\avc_moodle_sync\RoleSyncService $role_sync_service
   *   The role sync service.
   */
  public function __construct(RoleSyncService $role_sync_service) {
    $this->roleSyncService = $role_sync_service;
  }

  /**
   * {@inheritdoc}
   */
  public static function getSubscribedEvents() {
    $events = [];

    // Group module events.
    if (class_exists('\Drupal\group\Event\GroupMembershipEvent')) {
      $events['group.membership.added'] = ['onGroupMembershipChange', 0];
      $events['group.membership.updated'] = ['onGroupMembershipChange', 0];
      $events['group.membership.removed'] = ['onGroupMembershipChange', 0];
    }

    // OG (Organic Groups) module events.
    if (class_exists('\Drupal\og\Event\OgMembershipEvent')) {
      $events[\Drupal\og\Event\OgMembershipEvent::MEMBERSHIP_INSERT] = ['onOgMembershipChange', 0];
      $events[\Drupal\og\Event\OgMembershipEvent::MEMBERSHIP_UPDATE] = ['onOgMembershipChange', 0];
      $events[\Drupal\og\Event\OgMembershipEvent::MEMBERSHIP_DELETE] = ['onOgMembershipChange', 0];
    }

    return $events;
  }

  /**
   * Responds to group membership changes (Group module).
   *
   * @param \Drupal\group\Event\GroupMembershipEvent $event
   *   The group membership event.
   */
  public function onGroupMembershipChange($event) {
    // Check if automatic sync is enabled.
    $config = \Drupal::config('avc_moodle_sync.settings');
    if (!$config->get('enable_automatic_sync')) {
      return;
    }

    // Get the membership and user.
    $membership = $event->getMembership();
    $user = $membership->getUser();

    if ($user) {
      // Sync user asynchronously to avoid blocking the request.
      $this->syncUserAsync($user);
    }
  }

  /**
   * Responds to OG membership changes (Organic Groups module).
   *
   * @param \Drupal\og\Event\OgMembershipEvent $event
   *   The OG membership event.
   */
  public function onOgMembershipChange($event) {
    // Check if automatic sync is enabled.
    $config = \Drupal::config('avc_moodle_sync.settings');
    if (!$config->get('enable_automatic_sync')) {
      return;
    }

    // Get the membership and user.
    $membership = $event->getMembership();
    $user_id = $membership->getOwnerId();
    $user = User::load($user_id);

    if ($user) {
      // Sync user asynchronously to avoid blocking the request.
      $this->syncUserAsync($user);
    }
  }

  /**
   * Sync user asynchronously using queue.
   *
   * @param \Drupal\user\Entity\User $user
   *   The user to sync.
   */
  protected function syncUserAsync(User $user) {
    // Get the queue.
    $queue = \Drupal::queue('avc_moodle_sync_user');

    // Add user to queue for processing.
    $item = [
      'user_id' => $user->id(),
      'timestamp' => time(),
    ];

    $queue->createItem($item);

    \Drupal::logger('avc_moodle_sync')->info('Queued user @user for Moodle sync', [
      '@user' => $user->getAccountName(),
    ]);
  }

}
