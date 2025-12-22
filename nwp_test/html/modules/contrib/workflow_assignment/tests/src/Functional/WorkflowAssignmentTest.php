<?php

namespace Drupal\Tests\workflow_assignment\Functional;

use Drupal\Tests\BrowserTestBase;
use Drupal\workflow_assignment\Entity\WorkflowList;

/**
 * Tests workflow assignment functionality.
 *
 * @group workflow_assignment
 */
class WorkflowAssignmentTest extends BrowserTestBase {

  /**
   * {@inheritdoc}
   */
  protected $defaultTheme = 'stark';

  /**
   * {@inheritdoc}
   */
  protected static $modules = ['workflow_assignment', 'node', 'taxonomy', 'user'];

  /**
   * Test workflow creation.
   */
  public function testWorkflowCreation() {
    $workflow = WorkflowList::create([
      'id' => 'test_workflow',
      'label' => 'Test Workflow',
      'description' => 'Test workflow description',
    ]);
    $workflow->save();

    $loaded = WorkflowList::load('test_workflow');
    $this->assertNotNull($loaded);
    $this->assertEquals('Test Workflow', $loaded->label());
  }

  /**
   * Test destination locations.
   */
  public function testDestinationLocations() {
    // Check if destination_locations vocabulary exists
    $vocabulary = \Drupal::entityTypeManager()
      ->getStorage('taxonomy_vocabulary')
      ->load('destination_locations');
    $this->assertNotNull($vocabulary);

    // Check for default terms
    $terms = \Drupal::entityTypeManager()
      ->getStorage('taxonomy_term')
      ->loadByProperties([
        'vid' => 'destination_locations',
        'name' => 'Public',
      ]);
    $this->assertNotEmpty($terms);
  }

  /**
   * Test workflow tab access.
   */
  public function testWorkflowTabAccess() {
    // Create a user with permission
    $user = $this->drupalCreateUser([
      'view workflow list assignments',
      'access content',
    ]);
    $this->drupalLogin($user);

    // Enable workflow on article
    \Drupal::configFactory()
      ->getEditable('workflow_assignment.settings')
      ->set('enabled_content_types', ['article'])
      ->save();

    // Create article
    $node = $this->drupalCreateNode(['type' => 'article']);

    // Visit workflow tab
    $this->drupalGet('/node/' . $node->id() . '/workflow');
    $this->assertSession()->statusCodeEquals(200);
  }
}
