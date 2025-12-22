<?php

namespace Drupal\Tests\ginvite\Kernel;

use Drupal\KernelTests\Core\Entity\EntityKernelTestBase;

/**
 * Tests that all config provided by this module passes validation.
 *
 * @group ginvite
 */
class GroupInviteConfigTest extends EntityKernelTestBase {

  /**
   * Modules to enable.
   *
   * @var array
   */
  protected static $modules = [
    'views',
    'group',
    'options',
    'entity',
    'variationcache',
    'ginvite',
  ];

  /**
   * Tests that the module's config installs properly.
   */
  public function testConfig() {
    $this->installConfig(['ginvite']);
  }

}
