<?php

namespace Drupal\ginvite\Event;

/**
 * Event related with user registered invitation.
 *
 * @package Drupal\ginvite\Event
 */
class UserRegisteredFromInvitationEvent extends InvitationBaseEvent {

  const EVENT_NAME = 'user_registered_from_invitation';

}
