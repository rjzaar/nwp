<?php

namespace Drupal\Tests\exif_orientation\Functional;

use Drupal\Tests\BrowserTestBase;
use Drupal\Core\File\FileSystemInterface;
use Drupal\Core\Site\Settings;
use Drupal\file\Entity\File;

/**
 * @file
 * Tests for exif_orientation.module.
 */

/**
 * Tests exif_orientation module.
 *
 * @group exif_orientation
 */
class ExifOrientationTest extends BrowserTestBase {

  /**
   * The profile to install as a basis for testing.
   *
   * Using the standard profile to test user picture config provided by the
   * standard profile.
   *
   * @var string
   */
  protected $profile = 'standard';


  /**
   * {@inheritdoc}
   */
  protected $defaultTheme = 'stark';

  /**
   * Admin user account.
   *
   * @var \Drupal\user\Entity\User
   */
  protected $adminUser;

  /**
   * Modules to enable.
   *
   * @var array
   */
  protected static $modules = ['system', 'image', 'exif_orientation'];

  /**
   * The image factory service.
   *
   * @var \Drupal\Core\Image\ImageFactory
   */
  protected $imageFactory;

  /**
   * {@inheritdoc}
   */
  public static function getInfo() {
    return [
      'name' => 'Exif Orientation',
      'description' => 'Tests automatic image orientation.',
      'group' => 'Exif Orientation',
    ];
  }

  /**
   * {@inheritdoc}
   */
  public function setUp(): void {
    parent::setUp();
    $this->adminUser = $this->drupalCreateUser([
      'administer site configuration',
    ]);
    $this->drupalLogin($this->adminUser);

    // Test if directories specified in settings exist in filesystem.
    $file_dir = Settings::get('file_public_path');
    \Drupal::service('file_system')->prepareDirectory($file_dir, FileSystemInterface::CREATE_DIRECTORY);

    $picture_dir = \Drupal::state()->get('user_picture_path', 'pictures');
    $picture_path = $file_dir . $picture_dir;

    \Drupal::service('file_system')->prepareDirectory($picture_path, FileSystemInterface::CREATE_DIRECTORY);
    $directory_writable = is_writable($picture_path);
    $this->assertTrue($directory_writable, "The directory $picture_path doesn't exist or is not writable. Further tests won't be made.");

    $this->imageFactory = $this->container->get('image.factory');
  }

  /**
   * Tests Image toolkit setup form.
   */
  public function testToolkitSetupForm() {
    // Get form.
    $this->drupalGet('admin/config/media/image-toolkit');

    // Test that default toolkit is GD.
    $this->assertSession()->fieldValueEquals('image_toolkit', 'gd');

    // Test changing the jpeg image quality.
    $edit = ['gd[image_jpeg_quality]' => '98'];
    $this->submitForm($edit, 'Save configuration');
    $this->assertEquals('98', $this->config('system.image.gd')->get('jpeg_quality'));
  }

  /**
   * Test auto rotation of uploaded user profile pictures.
   */
  public function testUserPicture() {
    $this->drupalLogin($this->adminUser);
    $this->assertSession()->statusCodeEquals(200);
    // No user picture style or dimensions.
    $file = $this->saveUserPicture('dummy');
    $this->assertImageIsRotated($file);
  }

  /**
   * Uploads a user picture.
   */
  private function saveUserPicture($image) {
    $test_file_path = \Drupal::service('extension.list.module')->getPath('exif_orientation') . '/tests/rotate90cw.jpg';
    $edit = ['files[user_picture_0]' => \Drupal::service('file_system')->realpath($test_file_path)];
    $uid = $this->adminUser->id();
    $this->drupalGet('user/' . $uid . '/edit');
    $this->submitForm($edit, 'Save');

    // Load actual user data from database.
    $user_storage = $this->container->get('entity_type.manager')->getStorage('user');
    $user_storage->resetCache([$this->adminUser->id()]);

    $account = $user_storage->load($this->adminUser->id());
    return File::load($account->user_picture->target_id);
  }

  /**
   * Verify that an image is landscape and has a red top left corner.
   */
  private function assertImageIsRotated($file) {
    $img = \Drupal::service('image.factory')->get($file->getFileUri());
    // Test the aspect ratio.
    $this->assertTrue($img->getWidth() > $img->getHeight(), 'The image format is landscape.');

    // Verify the rotation by color inspection.
    $rgb = imagecolorat($img->getToolkit()->getResource(), 10, 10);
    $r = ($rgb >> 16) & 0xFF;
    $g = ($rgb >> 8) & 0xFF;
    $b = $rgb & 0xFF;
    // The top left corner should be red.
    $this->assertTrue(abs($r - 255) < 5, 'Red color component is close to 255.');
    $this->assertTrue($g < 5, 'Green color component is close to 0.');
    $this->assertTrue($b < 5, 'Blue color component is close to 0.');
  }

}
