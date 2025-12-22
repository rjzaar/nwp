<?php

declare(strict_types=1);

namespace Drupal\Tests\config_modify\Kernel;

use Drupal\Core\Extension\ModuleInstallerInterface;
use Drupal\KernelTests\KernelTestBase;

/**
 * Test that the config_modify module correctly updates config.
 *
 * @group config_modify
 */
class ModifyTest extends KernelTestBase {

  /**
   * The Drupal module installer.
   */
  protected ModuleInstallerInterface $moduleInstaller;

  /**
   * {@inheritdoc}
   */
  protected static $modules = [
    'config',
    'config_update',
    'update_helper',
    'config_modify',
  ];

  /**
   * {@inheritdoc}
   */
  protected function setUp() : void {
    parent::setUp();

    $this->moduleInstaller = \Drupal::service("module_installer");

    $this->installConfig(["config_modify"]);
  }

  /**
   * Installation of a module should cause modifications to be run.
   */
  public function testModuleInstallRunsModification() : void {
    $this->moduleInstaller->install(["test_config_modify"]);
    $this->assertEquals([], $this->config("config_modify.applied")->get("files"), "Config Modify files were already applied at the start of the test.");

    $this->moduleInstaller->install(["test_config_modify_enable"]);

    $updated_config = $this->config("test_config_modify.settings");
    $this->assertEquals(["test_config_modify.settings_when_create"], $this->config("config_modify.applied")->get("files"));
    $this->assertTrue($updated_config->get("change_me"));
    $this->assertFalse($updated_config->get("remain"));
  }

}
