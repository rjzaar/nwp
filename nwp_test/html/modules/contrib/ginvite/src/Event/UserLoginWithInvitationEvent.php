<?php

namespace Drupal\ginvite\Event;

/**
 * Event related with user login with invitation.
 *
 * @package Drupal\ginvite\Event
 */
class UserLoginWithInvitationEvent extends InvitationBaseEvent {

  const EVENT_NAME = 'user_login_with_invitation';

}
