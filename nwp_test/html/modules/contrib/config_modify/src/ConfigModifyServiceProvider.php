<?php

declare(strict_types=1);

namespace Drupal\config_modify;

use Drupal\Core\Config\ConfigInstaller as OriginalConfigInstaller;
use Drupal\Core\DependencyInjection\ContainerBuilder;
use Drupal\Core\DependencyInjection\ServiceProviderBase;

/**
 * Overwrite the `config.installer` service.
 *
 * @internal
 */
class ConfigModifyServiceProvider extends ServiceProviderBase {

  /**
   * {@inheritdoc}
   */
  public function alter(ContainerBuilder $container) : void {
    // Replace the config installer class with our own.
    if ($container->hasDefinition("config.installer")) {
      $definition = $container->getDefinition("config.installer");

      // Ideally we'd decorate the config installer class and pass-through all
      // the methods we don't care about to whatever class implements them.
      // However, Drupal's config installer calls `$this->installOptionalConfig`
      // which is the hook we care about, so that doesn't work with the
      // decoration pattern. This imposes some limitations on our module.
      if ($definition->getClass() !== OriginalConfigInstaller::class) {
        throw new \RuntimeException("config_modify is not compatible with modules that overwrite the ConfigInstaller class themselves.");
      }

      $definition->setClass(ConfigInstaller::class);
    }

    // We must replace the update_helper's Updater since we want to execute
    // update definitions we've loaded ourselves outside of `config/update`.
    if ($container->hasDefinition("update_helper.updater")) {
      $container->getDefinition("update_helper.updater")->setClass(Updater::class);
    }
  }

}
