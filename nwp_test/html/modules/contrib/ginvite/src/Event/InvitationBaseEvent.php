<?php

namespace Drupal\ginvite\Event;

use Drupal\Component\EventDispatcher\Event;
use Drupal\ginvite\GroupInvitation;

/**
 * Base invitation event.
 *
 * @package Drupal\ginvite\Event
 */
class InvitationBaseEvent extends Event {

  /**
   * The group invitation.
   *
   * @var \Drupal\ginvite\GroupInvitation
   */
  protected $groupInvitation;

  /**
   * Constructs the object.
   *
   * @param \Drupal\ginvite\GroupInvitation $group_invitation
   *   The group invitation.
   */
  public function __construct(GroupInvitation $group_invitation) {
    $this->groupInvitation = $group_invitation;
  }

  /**
   * Get the group invitation.
   *
   * @return \Drupal\ginvite\GroupInvitation
   *   The group invitation.
   */
  public function getGroupInvitation(): GroupInvitation {
    return $this->groupInvitation;
  }

}
