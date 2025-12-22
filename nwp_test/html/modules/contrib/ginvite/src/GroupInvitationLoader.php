<?php

namespace Drupal\ginvite;

use Drupal\Core\Entity\EntityTypeManagerInterface;
use Drupal\Core\Session\AccountInterface;
use Drupal\ginvite\GroupInvitation as GroupInvitationWrapper;
use Drupal\ginvite\Plugin\GroupContentEnabler\GroupInvitation;
use Drupal\group\Entity\GroupInterface;

/**
 * Loader for wrapped GroupContent entities using the 'group_invitation' plugin.
 */
class GroupInvitationLoader implements GroupInvitationLoaderInterface {

  /**
   * The entity type manager.
   *
   * @var \Drupal\Core\Entity\EntityTypeManagerInterface
   */
  protected $entityTypeManager;

  /**
   * The current user's account object.
   *
   * @var \Drupal\Core\Session\AccountInterface
   */
  protected $currentUser;

  /**
   * The group content type storage.
   *
   * @var \Drupal\group\Entity\Storage\GroupContentTypeStorageInterface
   */
  protected $groupContentTypeStorage;

  /**
   * The group content storage.
   *
   * @var \Drupal\group\Entity\Storage\GroupContentStorageInterface
   */
  protected $groupContentStorage;

  /**
   * Constructs a new GroupTypeController.
   *
   * @param \Drupal\Core\Entity\EntityTypeManagerInterface $entity_type_manager
   *   The entity type manager.
   * @param \Drupal\Core\Session\AccountInterface $current_user
   *   The current user.
   */
  public function __construct(EntityTypeManagerInterface $entity_type_manager, AccountInterface $current_user) {
    $this->entityTypeManager = $entity_type_manager;
    $this->currentUser = $current_user;
    $this->groupContentTypeStorage = $this->entityTypeManager->getStorage('group_content_type');
    $this->groupContentStorage = $this->entityTypeManager->getStorage('group_content');
  }

  /**
   * Load group content entities and wrap in a GroupInvitation object.
   *
   * @param array $filters
   *   An associative array where the keys are the property names and the
   *   values are the values those properties must have.
   *
   * @return \Drupal\ginvite\GroupInvitation[]
   *   A list of GroupInvitation wrapper objects.
   */
  protected function loadGroupInvitations(array $filters) {
    $group_invitations = [];

    $entities = $this->groupContentStorage->loadByProperties($filters);
    foreach ($entities as $group_content) {
      $group_invitations[] = new GroupInvitationWrapper($group_content);
    }

    return $group_invitations;
  }

  /**
   * {@inheritdoc}
   */
  public function load(GroupInterface $group, AccountInterface $account) {
    $group_invitations = $this->loadByProperties([
      'entity_id' => $account->id(),
      'gid' => $group->id(),
    ]);
    return $group_invitations ? reset($group_invitations) : FALSE;
  }

  /**
   * {@inheritdoc}
   */
  public function loadByGroup(GroupInterface $group, $roles = NULL, $mail = NULL, $status = GroupInvitation::INVITATION_PENDING) {
    $filters = [
      'invitation_status' => $status,
      'gid' => $group->id(),
    ];

    if (isset($roles)) {
      $filters['group_roles'] = (array) $roles;
    }
    if (isset($mail)) {
      $filters['invitee_mail'] = $mail;
    }

    return $this->loadByProperties($filters);
  }

  /**
   * {@inheritdoc}
   */
  public function loadByUser(AccountInterface $account = NULL, $roles = NULL, $status = GroupInvitation::INVITATION_PENDING) {
    if (!isset($account)) {
      $account = $this->currentUser;
    }

    if ($account->isAnonymous() || !$account->getEmail()) {
      return [];
    }

    $filters = [
      'entity_id' => $account->id(),
      'invitation_status' => $status,
      'invitee_mail' => $account->getEmail(),
    ];

    if (isset($roles)) {
      $filters['group_roles'] = (array) $roles;
    }

    return $this->loadByProperties($filters);
  }

  /**
   * {@inheritdoc}
   */
  public function loadByProperties(array $filters = []) {
    // Try to load all possible invitation group content for the user.
    $group_content_type_ids = $this->loadGroupContentTypeIds();
    if (empty($group_content_type_ids)) {
      return [];
    }

    $filters['type'] = $group_content_type_ids;
    return $this->loadGroupInvitations($filters);
  }

  /**
   * Load group content type ids.
   *
   * @return array
   *   Group content type ids.
   */
  protected function loadGroupContentTypeIds() {
    $group_content_type_ids = [];
    // Load all group content types for the invitation group relation plugin.
    $group_content_types = $this->entityTypeManager
      ->getStorage('group_content_type')
      ->loadByProperties(['content_plugin' => 'group_invitation']);

    // If none were found, there can be no invitations either.
    if (empty($group_content_types)) {
      return $group_content_type_ids;
    }

    foreach ($group_content_types as $group_content_type) {
      $group_content_type_ids[] = $group_content_type->id();
    }

    return $group_content_type_ids;
  }

}
