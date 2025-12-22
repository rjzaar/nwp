<?php

namespace Drupal\simple_oauth\Drush\Commands;

use Drupal\Component\DependencyInjection\ContainerInterface;
use Drupal\Core\File\FileSystemInterface;
use Drupal\simple_oauth\Service\Exception\ExtensionNotLoadedException;
use Drupal\simple_oauth\Service\Exception\FilesystemValidationException;
use Drupal\simple_oauth\Service\KeyGeneratorService;
use Drush\Commands\DrushCommands;

/**
 * Drush commands for Simple OAuth.
 */
class SimpleOauthCommands extends DrushCommands {

  /**
   * The key generator.
   *
   * @var \Drupal\simple_oauth\Service\KeyGeneratorService
   */
  private KeyGeneratorService $keygen;

  /**
   * The file system.
   *
   * @var \Drupal\Core\File\FileSystemInterface
   */
  private FileSystemInterface $fileSystem;

  /**
   * SimpleOauthCommands constructor.
   *
   * @param \Drupal\simple_oauth\Service\KeyGeneratorService $keygen
   *   The key generator service.
   * @param \Drupal\Core\File\FileSystemInterface $file_system
   *   The file handler.
   */
  public function __construct(KeyGeneratorService $keygen, FileSystemInterface $file_system) {
    parent::__construct();
    $this->keygen = $keygen;
    $this->fileSystem = $file_system;
  }

  /**
   * {@inheritdoc}
   */
  public static function create(ContainerInterface $container): self {
    return new static(
      $container->get('simple_oauth.key.generator'),
      $container->get('file_system')
    );
  }

  /**
   * Checks whether the give uri is a directory, without throwing errors.
   *
   * @param string $uri
   *   The uri to check.
   *
   * @return bool
   *   TRUE if it's a directory. FALSE otherwise.
   */
  private function isDirectory(string $uri): bool {
    return @is_dir($uri);
  }

  /**
   * Generate Oauth2 Keys.
   *
   * @param string $keypath
   *   The full path were the key files will be saved.
   *
   * @usage simple-oauth:generate-keys /var/www/drupal-example.org/keys
   *   Creates the keys in the /var/www/drupal-example.org/keys directory.
   *
   * @command simple-oauth:generate-keys
   * @aliases so:generate-keys, sogk
   *
   * @validate-module-enabled simple_oauth
   */
  public function generateKeys(string $keypath) {
    if (!$this->isDirectory($keypath)) {
      if (!$this->fileSystem->mkdir($keypath, NULL, TRUE) || !$this->isDirectory($keypath)) {
        $this->logger()->error(sprintf('Directory at "%s" could not be created.', $keypath));
        return;
      }
    }
    $keys_path = $this->fileSystem->realpath($keypath);

    try {
      $this->keygen->generateKeys($keys_path);
      $this->logger()->notice(
        'Keys successfully generated at {path}.',
        ['path' => $keypath]
      );
    }
    catch (FilesystemValidationException | ExtensionNotLoadedException $e) {
      $this->logger()->error($e->getMessage());
    }
  }

}
