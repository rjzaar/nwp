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
class InstallTest extends KernelTestBase {

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
    'test_config_modify',
    'test_config_modify_enable',
  ];

  /**
   * {@inheritdoc}
   */
  protected function setUp() : void {
    parent::setUp();

    $this->moduleInstaller = \Drupal::service("module_installer");

    $this->installConfig(["test_config_modify", "test_config_modify_enable"]);
  }

  /**
   * Installation of the config_modify module should not apply anything.
   */
  public function testModuleInstallRunsModification() : void {
    $this->moduleInstaller->install(["config_modify"]);

    $updated_config = $this->config("test_config_modify.settings");
    $this->assertEquals(["test_config_modify.settings_when_create"], $this->config("config_modify.applied")->get("files"));
    $this->assertFalse($updated_config->get("change_me"));
    $this->assertFalse($updated_config->get("remain"));
  }

}
