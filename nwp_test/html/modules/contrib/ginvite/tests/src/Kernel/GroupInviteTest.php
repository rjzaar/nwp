<?php

namespace Drupal\Tests\ginvite\Kernel;

use Drupal\group\Entity\GroupContent;
use Drupal\Tests\group\Kernel\GroupKernelTestBase;

/**
 * Tests the general behavior of group content group_invitation.
 *
 * @group ginvite
 */
class GroupInviteTest extends GroupKernelTestBase {

  /**
   * The invitation loader.
   *
   * @var \Drupal\ginvite\GroupInvitationLoaderInterface
   */
  protected $invitationLoader;

  /**
   * The entity type manager.
   *
   * @var \Drupal\Core\Entity\EntityTypeManagerInterface
   */
  protected $entityTypeManager;

  /**
   * The group we will use to test methods on.
   *
   * @var \Drupal\group\Entity\Group
   */
  protected $group;

  /**
   * The group content type for group membership request.
   *
   * @var \Drupal\group\Entity\GroupContentTypeInterface
   */
  protected $groupContentType;

  /**
   * Modules to enable.
   *
   * @var array
   */
  protected static $modules = [
    'ginvite',
    'user',
    'system',
  ];

  /**
   * {@inheritdoc}
   */
  protected function setUp(): void {
    parent::setUp();

    $this->installSchema('user', ['users_data']);
    $this->installEntitySchema('user');

    $this->installConfig([
      'ginvite',
    ]);

    $this->invitationLoader = $this->container->get('ginvite.invitation_loader');
    $this->entityTypeManager = $this->container->get('entity_type.manager');

    $this->group = $this->createGroup();

    $config = [
      'group_cardinality' => 0,
      'entity_cardinality' => 1,
      'remove_invitation' => 0,
    ];
    // Enable group membership request group content plugin.
    $this->groupContentType = $this->entityTypeManager->getStorage('group_content_type')->createFromPlugin($this->group->getGroupType(), 'group_invitation', $config);
    $this->groupContentType->save();
  }

  /**
   * Test group invitation removal with disabled settings.
   */
  public function testRequestRemovalWithDisabledSettings() {
    $account = $this->createUser();

    // Add an invitation.
    $this->createInvitation($this->group, $account);

    // Add the user as member.
    $this->group->addMember($account);

    // Since removal is enabled we should not find any invitations.
    $group_invitations = $this->invitationLoader->loadByProperties([
      'gid' => $this->group->id(),
      'entity_id' => $account->id(),
    ]);
    $this->assertCount(1, $group_invitations);
  }

  /**
   * Test group invitation removal with enabled settings.
   */
  public function testInvitationRemovalWithEnabledSettings() {
    $config = [
      'group_cardinality' => 0,
      'entity_cardinality' => 1,
      'remove_invitation' => 1,
    ];
    $this->groupContentType->updateContentPlugin($config);
    $account = $this->createUser();

    // Add an invitation.
    $this->createInvitation($this->group, $account);

    // Add the user as member.
    $this->group->addMember($account);

    // Since removal is enabled we should not find any invitations.
    $group_invitations = $this->invitationLoader->loadByProperties([
      'gid' => $this->group->id(),
      'entity_id' => $account->id(),
    ]);
    $this->assertCount(0, $group_invitations);
  }

  /**
   * Test autoacception of invitations.
   */
  public function testInvitationAutoAcception() {
    $config = [
      'group_cardinality' => 0,
      'entity_cardinality' => 1,
      'autoaccept_invitees' => 1,
    ];
    $this->groupContentType->updateContentPlugin($config);
    $account = $this->createUser();

    // Add an invitation.
    $this->createInvitation($this->group, $account);

    // It will call the same function, which is called during the login.
    $account->save();

    $member = $this->group->getMember($account);
    $this->assertNotNull($member);
  }

  /**
   * Creates group invitation.
   *
   * @param \Drupal\group\Entity\Group $group
   *   Group.
   * @param \Drupal\user\UserInterface $user
   *   User.
   *
   * @return \Drupal\group\Entity\GroupContent
   *   Group content invitation.
   */
  private function createInvitation($group, $user) {
    $group_content = GroupContent::create([
      'type' => $group
        ->getGroupType()
        ->getContentPlugin('group_invitation')
        ->getContentTypeConfigId(),
      'gid' => $group->id(),
      'entity_id' => $user->id(),
      'invitee_mail' => $user->get,
    ]);

    $group_content->save();
    return $group_content;
  }

  /**
   * Test user removal.
   */
  public function testUserRemoval() {
    $account = $this->createUser();
    $user_id = $account->id();

    // Add an invitation.
    $this->createInvitation($this->group, $account);

    $account->delete();

    // When user removed the invitations, should be removed too.
    $group_invitations = $this->invitationLoader->loadByProperties([
      'gid' => $this->group->id(),
      'entity_id' => $user_id,
    ]);
    $this->assertCount(0, $group_invitations);
  }

}
