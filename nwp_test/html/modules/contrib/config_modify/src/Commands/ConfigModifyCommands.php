<?php

declare(strict_types=1);

namespace Drupal\config_modify\Commands;

use Composer\Question\StrictConfirmationQuestion;
use Drupal\config_modify\Util\UpdateDefinitionCreator;
use Drupal\Core\Config\ConfigFactoryInterface;
use Drupal\Core\Config\ExtensionInstallStorage;
use Drupal\Core\Config\StorageInterface;
use Drupal\Core\Extension\Extension;
use Drupal\Core\Extension\ModuleExtensionList;
use Drupal\Core\File\FileSystem;
use Drupal\Core\Serialization\Yaml;
use DrupalCodeGenerator\Validator\Chained;
use DrupalCodeGenerator\Validator\MachineName;
use DrupalCodeGenerator\Validator\Required;
use Drush\Attributes as CLI;
use Drush\Commands\DrushCommands;
use Symfony\Component\Console\Question\ChoiceQuestion;
use Symfony\Component\Console\Question\ConfirmationQuestion;
use Symfony\Component\Console\Question\Question;

/**
 * Drush commands for the config modify module.
 */
class ConfigModifyCommands extends DrushCommands {

  /**
   * Create a new instance for the commands.
   *
   * @param \Drupal\config_modify\Util\UpdateDefinitionCreator $updateDefinitionCreator
   *   The update definition difference calculator service.
   * @param \Drupal\Core\File\FileSystem $fileSystem
   *   The Drupal file system service.
   * @param \Drupal\Core\Extension\ModuleExtensionList $extensionList
   *   The Drupal module extension list.
   * @param \Drupal\Core\Config\ConfigFactoryInterface $configFactory
   *   The Drupal config factory.
   * @param \Drupal\Core\Config\StorageInterface $configStorage
   *   The Drupal config storage.
   * @param string $installProfile
   *   The install profile that's installed.
   * @param string $drupalRoot
   *   The root of the Drupal application.
   */
  public function __construct(
    protected UpdateDefinitionCreator $updateDefinitionCreator,
    protected FileSystem $fileSystem,
    protected ModuleExtensionList $extensionList,
    protected ConfigFactoryInterface $configFactory,
    protected StorageInterface $configStorage,
    protected string $installProfile,
    protected string $drupalRoot,
  ) {
    parent::__construct();
  }

  /**
   * Register newly added configurations before updates are run.
   */
  #[CLI\Command(name: 'config-modify:pre-update', aliases: ['cmpu'])]
  #[CLI\Help(description: "Register any newly added config modify files that match the current requirements as applied so that they don't cause errors during updates.")]
  #[CLI\Usage(name: 'drush config-modify:pre-update')]
  public function preUpdate() : void {
    \Drupal::service("config.installer")->markAvailableModificationsAsApplied();
  }

  /**
   * Create a config/modify file.
   */
  #[CLI\Command(name: 'config-modify:create', aliases: ['cmc'])]
  #[CLI\Help(description: 'Create a new config modification file.')]
  #[CLI\Usage(name: 'drush config_modify:create')]
  public function createModifyFile() : int {
    $module = $this->getTargetModule();
    $modification_name = $this->getModificationName();

    $path = "{$this->drupalRoot}/{$module->getPath()}/config/modify";
    $filename = "{$module->getName()}.$modification_name.yml";
    if (file_exists("$path/$filename") && !$this->promptReplace("{$module->getPath()}/config/modify/$filename")) {
      $this->io()->writeln("Not overwriting file, done.");
      return self::EXIT_SUCCESS;
    }

    $to_database = $this->getModifyToDatabase();
    $config_names = $this->getIncludedConfig();

    $dependencies = $this->getDependencies();

    $storage_install = new ExtensionInstallStorage($this->configStorage, 'config/install', '', TRUE, $this->installProfile);
    $storage_optional = new ExtensionInstallStorage($this->configStorage, 'config/optional', '', TRUE, $this->installProfile);

    $modifications = [];

    foreach ($config_names as $config_name) {
      $database_config = $this->configFactory->getEditable($config_name)->getRawData();

      $disk_config = $storage_install->read($config_name) ?: $storage_optional->read($config_name);
      assert($disk_config !== TRUE);
      if ($disk_config === FALSE) {
        $this->io()->warning("Config '$config_name' not found on disk, skipping...");
        continue;
      }

      $diff = $to_database
        ? $this->updateDefinitionCreator->produceDiff($disk_config, $database_config, ['uuid', '_core'])
        : $this->updateDefinitionCreator->produceDiff($database_config, $disk_config, ['uuid', '_core']);

      if ($diff === []) {
        $this->io()->warning("Config '$config_name' is unchanged, skipping...");
        continue;
      }

      $modifications[$config_name] = $diff;
    }

    if ($modifications === []) {
      $this->io()->error("No changes found.");
      return self::EXIT_FAILURE;
    }

    $output = [];
    if ($dependencies !== []) {
      $output['dependencies'] = $dependencies;
    }
    $output['items'] = $modifications;

    $this->fileSystem->prepareDirectory($path, $this->fileSystem::CREATE_DIRECTORY | $this->fileSystem::MODIFY_PERMISSIONS);
    $this->fileSystem->saveData(Yaml::encode($output), "$path/$filename", $this->fileSystem::EXISTS_REPLACE);

    return self::EXIT_SUCCESS;
  }

  /**
   * Get the module the config/modify file should live in.
   *
   * @return \Drupal\Core\Extension\Extension
   *   The chosen extension.
   */
  protected function getTargetModule() : Extension {
    $extensions = $this->getExtensions();
    $question = new ChoiceQuestion(
      'What module should contain the config modification file?',
      array_keys($extensions),
    );

    return $extensions[$this->io()->askQuestion($question)];
  }

  /**
   * Get the name of the config/modify file without the module name or .yml.
   *
   * @return string
   *   The name of the config/modify file.
   */
  protected function getModificationName() : string {
    $question = new Question('Enter the machine name for the modification', NULL);
    $question->setValidator(new Chained(new Required(), new MachineName()));

    $name = $this->io()->askQuestion($question);
    assert(is_string($name));
    return $name;
  }

  /**
   * Check whether the existing file should be replaced.
   *
   * @param string $filename
   *   The name of the file to replace.
   *
   * @return bool
   *   TRUE if the file should be replaced, FALSE otherwise.
   */
  protected function promptReplace(string $filename) : bool {
    $question = new StrictConfirmationQuestion("File '$filename' already exists, do you want to replace it?", FALSE);
    $replace = $this->io()->askQuestion($question);
    assert(is_bool($replace));
    return $replace;
  }

  /**
   * Get the direction in which to create the update definition.
   *
   * @return bool
   *   TRUE if the direction is "from disk to database", FALSE otherwise.
   */
  protected function getModifyToDatabase() : bool {
    $question = new ChoiceQuestion(
      "Select update definition direction",
      [
        'from disk to database',
        'from database to disk',
      ],
      'from disk to database',
    );
    return $this->io()->askQuestion($question) === 'from disk to database';
  }

  /**
   * Get the configuration files to include in the config/modify file.
   *
   * @return array
   *   A list of configuration names.
   */
  protected function getIncludedConfig() : array {
    $question = new ChoiceQuestion(
      "Select configuration to include",
      $this->configFactory->listAll(),
    );
    $question->setMultiselect(TRUE);

    $config = $this->io()->askQuestion($question);
    assert(is_array($config) && $config !== []);
    return $config;
  }

  /**
   * Get additional dependencies for the config/modify file.
   *
   * @return array{ modules?: array, config?: array }
   *   The dependencies to add to the config/modify file.
   */
  protected function getDependencies() : array {
    $dependencies = [];

    $question = new ConfirmationQuestion("Require any modules to be active for the modification to be applied (the module providing the original configuration file is already required)?");
    if ($this->io()->askQuestion($question)) {
      $question = new ChoiceQuestion("Modules", [""] + array_keys($this->extensionList->getList()));
      $question->setMultiselect(TRUE);

      $modules = $this->io()->askQuestion($question);
      assert(is_array($modules));
      $dependencies['modules'] = $modules;
    }

    $question = new ConfirmationQuestion("Require any other config objects to exist (the config items selected for modification are automatically required)?");
    if ($this->io()->askQuestion($question)) {
      $question = new ChoiceQuestion("Config objects", [""] + $this->configFactory->listAll());
      $question->setMultiselect(TRUE);

      $config = $this->io()->askQuestion($question);
      assert(is_array($config));
      $dependencies['config'] = $config;
    }

    return $dependencies;
  }

  /**
   * Get installed non_core extensions.
   *
   * @return \Drupal\Core\Extension\Extension[]
   *   The list of installed non-core extensions keyed by the extension name.
   */
  protected function getExtensions(): array {
    $extensions = array_filter($this->extensionList->getList(),
      static function ($extension): bool {
        return (isset($extension->origin) && $extension->origin !== 'core');
      });

    ksort($extensions);
    return $extensions;
  }

}
