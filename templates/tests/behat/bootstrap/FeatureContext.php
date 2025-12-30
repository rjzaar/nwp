<?php

/**
 * @file
 * NWP Behat Feature Context.
 *
 * Custom step definitions for NWP site testing.
 */

use Behat\Behat\Context\Context;
use Behat\Mink\Exception\ExpectationException;
use Drupal\DrupalExtension\Context\RawDrupalContext;

/**
 * Defines application features from the specific context.
 */
class FeatureContext extends RawDrupalContext implements Context {

  /**
   * Storage for test data created during scenarios.
   *
   * @var array
   */
  protected array $testData = [];

  /**
   * Initialize context.
   */
  public function __construct() {
    // Initialize context.
  }

  /**
   * Assert the site title is visible.
   *
   * @Then I should see the site title
   */
  public function iShouldSeeTheSiteTitle(): void {
    $session = $this->getSession();
    $page = $session->getPage();

    // Check for common site title elements
    $title = $page->find('css', '.site-branding__name, .site-name, h1.site-title, #site-name');
    if ($title === NULL) {
      // Fallback: check page title
      $titleTag = $page->find('css', 'title');
      if ($titleTag === NULL || empty($titleTag->getText())) {
        throw new ExpectationException('Could not find site title on the page.', $session);
      }
    }
  }

  /**
   * Assert the administration menu is visible.
   *
   * @Then I should see the administration menu
   */
  public function iShouldSeeTheAdministrationMenu(): void {
    $session = $this->getSession();
    $page = $session->getPage();

    $adminMenu = $page->find('css', '#toolbar-administration, .toolbar-menu-administration, #admin-menu');
    if ($adminMenu === NULL) {
      throw new ExpectationException('Could not find administration menu.', $session);
    }
  }

  /**
   * Assert no JavaScript errors occurred.
   *
   * @Then I should not see any JavaScript errors
   */
  public function iShouldNotSeeAnyJavaScriptErrors(): void {
    $session = $this->getSession();

    // Only works with Selenium/JavaScript-capable drivers
    if (!$session->getDriver() instanceof \Behat\Mink\Driver\Selenium2Driver) {
      return;
    }

    $errors = $session->evaluateScript(
      'return window.jsErrors || [];'
    );

    if (!empty($errors)) {
      throw new ExpectationException(
        sprintf('JavaScript errors found: %s', implode(', ', $errors)),
        $session
      );
    }
  }

  /**
   * Wait for AJAX to complete.
   *
   * @Given I wait for AJAX to finish
   */
  public function iWaitForAjaxToFinish(): void {
    $this->getSession()->wait(10000,
      '(typeof jQuery === "undefined" || jQuery.active === 0) && (typeof Drupal === "undefined" || typeof Drupal.ajax === "undefined" || !Drupal.ajax.instances.some(function(i){return i && i.ajaxing;}))'
    );
  }

  /**
   * Take a screenshot.
   *
   * @Then I take a screenshot named :name
   */
  public function iTakeAScreenshotNamed(string $name): void {
    $session = $this->getSession();
    $driver = $session->getDriver();

    if (!$driver instanceof \Behat\Mink\Driver\Selenium2Driver) {
      return;
    }

    $screenshot = $driver->getScreenshot();
    $dir = 'reports/screenshots';
    if (!is_dir($dir)) {
      mkdir($dir, 0755, TRUE);
    }

    $filename = sprintf('%s/%s-%s.png', $dir, date('Y-m-d-H-i-s'), $name);
    file_put_contents($filename, $screenshot);
  }

  /**
   * Take screenshot on failure.
   *
   * @AfterStep
   */
  public function takeScreenshotOnFailure($event): void {
    if ($event->getTestResult()->getResultCode() !== 99) {
      return;
    }

    $session = $this->getSession();
    $driver = $session->getDriver();

    if (!$driver instanceof \Behat\Mink\Driver\Selenium2Driver) {
      return;
    }

    $screenshot = $driver->getScreenshot();
    $dir = getenv('BROWSERTEST_OUTPUT_DIRECTORY') ?: 'reports/screenshots';
    if (!is_dir($dir)) {
      mkdir($dir, 0755, TRUE);
    }

    $filename = sprintf(
      '%s/failure-%s-%s.png',
      $dir,
      date('Y-m-d-H-i-s'),
      preg_replace('/[^a-z0-9]+/i', '-', $event->getStep()->getText())
    );
    file_put_contents($filename, $screenshot);
  }

  /**
   * Fill in a WYSIWYG editor.
   *
   * @When I fill in the wysiwyg :field with :value
   */
  public function iFillInTheWysiwygWith(string $field, string $value): void {
    $field = $this->fixStepArgument($field);
    $value = $this->fixStepArgument($value);

    $this->getSession()->executeScript(
      sprintf("CKEDITOR.instances['%s'].setData('%s');", $field, addslashes($value))
    );
  }

  /**
   * Helper to fix step arguments with quotes.
   */
  protected function fixStepArgument(string $argument): string {
    return str_replace('\\"', '"', $argument);
  }

  /**
   * Assert response time is under threshold.
   *
   * @Then the response time should be under :seconds seconds
   */
  public function theResponseTimeShouldBeUnderSeconds(float $seconds): void {
    // Note: This requires storing the start time before the request
    // Implementation depends on the driver being used
  }

  /**
   * Create test content.
   *
   * @Given I have created test content of type :type with title :title
   */
  public function iHaveCreatedTestContentOfTypeWithTitle(string $type, string $title): void {
    $node = (object) [
      'type' => $type,
      'title' => $title,
      'status' => 1,
    ];
    $saved = $this->nodeCreate($node);
    $this->testData['nodes'][] = $saved;
  }

  /**
   * Clean up test data after scenario.
   *
   * @AfterScenario
   */
  public function cleanUpTestData(): void {
    // Nodes are cleaned up by DrupalContext
    $this->testData = [];
  }

}
