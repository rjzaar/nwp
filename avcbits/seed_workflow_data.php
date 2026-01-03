<?php

/**
 * @file
 * Seed script for workflow sample data.
 *
 * Run with: ddev drush php:script modules/custom/workflow_assignment/scripts/seed_workflow_data.php
 *
 * This single script handles everything:
 * - Installs entity types if needed
 * - Adds field_workflow_list to content types
 * - Creates destination locations vocabulary and terms
 * - Creates WorkflowList config entities (assigned to users, groups, destinations)
 * - Creates WorkflowTemplate entities
 * - Creates WorkflowAssignment entities on content (various completion states)
 */

use Drupal\taxonomy\Entity\Term;
use Drupal\taxonomy\Entity\Vocabulary;
use Drupal\field\Entity\FieldConfig;
use Drupal\field\Entity\FieldStorageConfig;

$entity_type_manager = \Drupal::entityTypeManager();

echo "=== Workflow Sample Data Seeder ===\n\n";

// Step 0: Install entity types if needed.
echo "Step 0: Installing entity types...\n";

$entity_update_manager = \Drupal::entityDefinitionUpdateManager();
$entity_types = ['workflow_list', 'workflow_template', 'workflow_assignment', 'workflow_task'];

foreach ($entity_types as $entity_type_id) {
  try {
    $definition = $entity_type_manager->getDefinition($entity_type_id, FALSE);
    if ($definition) {
      try {
        $storage = $entity_type_manager->getStorage($entity_type_id);
        $storage->getQuery()->accessCheck(FALSE)->count()->execute();
        echo "  Entity type exists: $entity_type_id\n";
      }
      catch (\Exception $e) {
        $entity_update_manager->installEntityType($definition);
        echo "  Installed entity type: $entity_type_id\n";
      }
    }
    else {
      echo "  Entity type not found: $entity_type_id\n";
    }
  }
  catch (\Exception $e) {
    echo "  Error with $entity_type_id: " . $e->getMessage() . "\n";
  }
}

// Step 0b: Add field_workflow_list to content types.
echo "\nStep 0b: Adding workflow field to content types...\n";

$content_types = ['topic', 'event'];

$field_storage = FieldStorageConfig::loadByName('node', 'field_workflow_list');
if (!$field_storage) {
  $field_storage = FieldStorageConfig::create([
    'field_name' => 'field_workflow_list',
    'entity_type' => 'node',
    'type' => 'entity_reference',
    'settings' => ['target_type' => 'workflow_assignment'],
    'cardinality' => -1,
  ]);
  $field_storage->save();
  echo "  Created field storage: field_workflow_list\n";
}
else {
  echo "  Field storage exists: field_workflow_list\n";
}

foreach ($content_types as $content_type) {
  $field_config = FieldConfig::loadByName('node', $content_type, 'field_workflow_list');
  if (!$field_config) {
    $field_config = FieldConfig::create([
      'field_storage' => $field_storage,
      'bundle' => $content_type,
      'label' => 'Workflow Assignments',
      'description' => 'Workflow assignments for this content.',
      'settings' => ['handler' => 'default', 'handler_settings' => []],
    ]);
    $field_config->save();
    echo "  Added field to: $content_type\n";
  }
  else {
    echo "  Field exists on: $content_type\n";
  }
}

// Step 1: Create destination_locations vocabulary and terms.
echo "\nStep 1: Setting up destination locations...\n";

$vocab = Vocabulary::load('destination_locations');
if (!$vocab) {
  $vocab = Vocabulary::create([
    'vid' => 'destination_locations',
    'name' => 'Destination Locations',
    'description' => 'Locations where content can be published or sent.',
  ]);
  $vocab->save();
  echo "  Created 'destination_locations' vocabulary.\n";
}

$destinations = [
  'public' => 'Public Website',
  'intranet' => 'Intranet Portal',
  'archive' => 'Archive System',
  'social' => 'Social Media',
];

$destination_ids = [];
foreach ($destinations as $key => $name) {
  $existing = $entity_type_manager->getStorage('taxonomy_term')
    ->loadByProperties(['vid' => 'destination_locations', 'name' => $name]);

  if (empty($existing)) {
    $term = Term::create(['vid' => 'destination_locations', 'name' => $name]);
    $term->save();
    $destination_ids[$key] = $term->id();
    echo "  Created destination: $name (ID: {$term->id()})\n";
  }
  else {
    $term = reset($existing);
    $destination_ids[$key] = $term->id();
    echo "  Destination exists: $name (ID: {$term->id()})\n";
  }
}

// Step 2: Create WorkflowList config entities.
echo "\nStep 2: Creating workflow lists...\n";

$workflow_lists = [
  // User-assigned workflows
  ['id' => 'content_review', 'label' => 'Content Review', 'description' => 'Initial review of content for accuracy and completeness.', 'assigned_type' => 'user', 'assigned_id' => 2, 'comments' => 'Check for spelling, grammar, and factual accuracy.'],
  ['id' => 'technical_review', 'label' => 'Technical Review', 'description' => 'Technical accuracy verification by subject matter expert.', 'assigned_type' => 'user', 'assigned_id' => 3, 'comments' => 'Verify technical specifications and procedures.'],
  ['id' => 'final_approval', 'label' => 'Final Approval', 'description' => 'Final sign-off before publication.', 'assigned_type' => 'user', 'assigned_id' => 1, 'comments' => 'Executive approval required for external publication.'],
  ['id' => 'legal_review', 'label' => 'Legal Review', 'description' => 'Legal compliance and liability review.', 'assigned_type' => 'user', 'assigned_id' => 4, 'comments' => 'Check for copyright, trademark, and regulatory compliance.'],
  // Group-assigned workflows
  ['id' => 'dev_team_review', 'label' => 'Development Team Review', 'description' => 'Code and architecture review by development team.', 'assigned_type' => 'group', 'assigned_id' => 1, 'comments' => 'Any team member can complete this review.'],
  ['id' => 'content_team_edit', 'label' => 'Content Team Edit', 'description' => 'Editorial review and polish by content team.', 'assigned_type' => 'group', 'assigned_id' => 2, 'comments' => 'Focus on readability and brand voice.'],
  ['id' => 'project_alpha_sign_off', 'label' => 'Project Alpha Sign-off', 'description' => 'Project-specific approval from Alpha team.', 'assigned_type' => 'group', 'assigned_id' => 3, 'comments' => 'Required for all Project Alpha deliverables.'],
  // Destination-assigned workflows
  ['id' => 'publish_public', 'label' => 'Publish to Public Website', 'description' => 'Ready for public website publication.', 'assigned_type' => 'destination', 'assigned_id' => $destination_ids['public'], 'comments' => 'Content must meet public accessibility standards.'],
  ['id' => 'publish_intranet', 'label' => 'Publish to Intranet', 'description' => 'Internal publication to company intranet.', 'assigned_type' => 'destination', 'assigned_id' => $destination_ids['intranet'], 'comments' => 'Internal use only - may contain confidential info.'],
  ['id' => 'archive_content', 'label' => 'Archive Content', 'description' => 'Move to long-term archive storage.', 'assigned_type' => 'destination', 'assigned_id' => $destination_ids['archive'], 'comments' => 'Ensure proper metadata for retrieval.'],
];

$created_lists = [];
$workflow_list_storage = $entity_type_manager->getStorage('workflow_list');

foreach ($workflow_lists as $list_data) {
  $existing = $workflow_list_storage->load($list_data['id']);
  if ($existing) {
    echo "  Exists: {$list_data['label']} ({$list_data['id']})\n";
    $created_lists[$list_data['id']] = $existing;
    continue;
  }

  $workflow_list = $workflow_list_storage->create($list_data);
  $workflow_list->save();
  $created_lists[$list_data['id']] = $workflow_list;
  echo "  Created: {$list_data['label']} ({$list_data['id']}) -> {$list_data['assigned_type']}\n";
}

// Step 3: Create WorkflowTemplate entities.
echo "\nStep 3: Creating workflow templates...\n";

$templates_data = [
  ['name' => 'Standard Publication Workflow', 'description' => 'Standard workflow for publishing content to the public website.', 'workflows' => ['content_review', 'technical_review', 'final_approval', 'publish_public']],
  ['name' => 'Internal Document Workflow', 'description' => 'Streamlined workflow for internal documentation.', 'workflows' => ['content_team_edit', 'publish_intranet']],
  ['name' => 'Legal Sensitive Content', 'description' => 'Extended workflow including legal review for sensitive content.', 'workflows' => ['content_review', 'legal_review', 'final_approval', 'publish_public']],
  ['name' => 'Technical Documentation', 'description' => 'Workflow for technical documentation requiring dev team review.', 'workflows' => ['dev_team_review', 'technical_review', 'content_team_edit', 'publish_intranet']],
  ['name' => 'Project Alpha Deliverable', 'description' => 'Full workflow for Project Alpha deliverables.', 'workflows' => ['content_review', 'dev_team_review', 'project_alpha_sign_off', 'final_approval']],
  ['name' => 'Archive Workflow', 'description' => 'Simple workflow for archiving outdated content.', 'workflows' => ['content_review', 'archive_content']],
];

$template_storage = $entity_type_manager->getStorage('workflow_template');

foreach ($templates_data as $template_data) {
  $existing = $template_storage->loadByProperties(['name' => $template_data['name']]);
  if (!empty($existing)) {
    $template = reset($existing);
    echo "  Exists: {$template_data['name']} (ID: {$template->id()})\n";
    continue;
  }

  $template = $template_storage->create(['name' => $template_data['name'], 'description' => $template_data['description'], 'uid' => 1]);
  $workflow_refs = [];
  foreach ($template_data['workflows'] as $workflow_id) {
    if (isset($created_lists[$workflow_id])) {
      $workflow_refs[] = ['target_id' => $workflow_id];
    }
  }
  $template->set('template_workflows', $workflow_refs);
  $template->save();
  echo "  Created: {$template_data['name']} (ID: {$template->id()}) with " . count($workflow_refs) . " workflows\n";
}

// Step 4: Create WorkflowAssignment entities on content.
echo "\nStep 4: Creating workflow assignments on content...\n";

$node_assignments = [
  // Node 1: Welcome to AV Commons - COMPLETED workflow
  1 => [
    ['title' => 'Initial Content Review', 'description' => 'Review the welcome page content for accuracy.', 'assigned_type' => 'user', 'assigned_user' => 2, 'completion' => 'completed', 'comments' => 'Reviewed and approved on Dec 15.', 'job_number' => 'WF-2024-001'],
    ['title' => 'Editorial Polish', 'description' => 'Final editorial review by content team.', 'assigned_type' => 'group', 'assigned_group' => 2, 'completion' => 'completed', 'comments' => 'Minor grammar fixes applied.', 'job_number' => 'WF-2024-001'],
    ['title' => 'Published to Website', 'description' => 'Content published to public website.', 'assigned_type' => 'destination', 'assigned_destination' => $destination_ids['public'], 'completion' => 'completed', 'comments' => 'Live on homepage.', 'job_number' => 'WF-2024-001'],
  ],
  // Node 2: Getting Started Guide - PARTIAL completion
  2 => [
    ['title' => 'Technical Accuracy Check', 'description' => 'Verify all technical instructions are correct.', 'assigned_type' => 'user', 'assigned_user' => 3, 'completion' => 'completed', 'comments' => 'All steps verified and tested.', 'job_number' => 'WF-2024-002'],
    ['title' => 'Dev Team Code Review', 'description' => 'Review any code samples in the guide.', 'assigned_type' => 'group', 'assigned_group' => 1, 'completion' => 'accepted', 'comments' => 'In progress - reviewing code samples.', 'job_number' => 'WF-2024-002'],
    ['title' => 'Final Approval', 'description' => 'Executive sign-off before publication.', 'assigned_type' => 'user', 'assigned_user' => 1, 'completion' => 'proposed', 'comments' => 'Waiting for dev team to complete review.', 'job_number' => 'WF-2024-002'],
    ['title' => 'Publish to Intranet', 'description' => 'Internal publication for staff access.', 'assigned_type' => 'destination', 'assigned_destination' => $destination_ids['intranet'], 'completion' => 'proposed', 'comments' => '', 'job_number' => 'WF-2024-002'],
  ],
  // Node 3: Team Collaboration Tips - STARTING (all proposed)
  3 => [
    ['title' => 'Content Team Edit', 'description' => 'Editorial review by content creators.', 'assigned_type' => 'group', 'assigned_group' => 2, 'completion' => 'proposed', 'comments' => 'Queued for review.', 'job_number' => 'WF-2024-003'],
    ['title' => 'Legal Review', 'description' => 'Check for any liability issues.', 'assigned_type' => 'user', 'assigned_user' => 4, 'completion' => 'proposed', 'comments' => '', 'job_number' => 'WF-2024-003'],
    ['title' => 'Publish to Public Site', 'description' => 'External publication.', 'assigned_type' => 'destination', 'assigned_destination' => $destination_ids['public'], 'completion' => 'proposed', 'comments' => '', 'job_number' => 'WF-2024-003'],
  ],
  // Node 4: Workflow Management Basics - MIXED
  4 => [
    ['title' => 'Subject Matter Review', 'description' => 'Review by workflow subject matter expert.', 'assigned_type' => 'user', 'assigned_user' => 5, 'completion' => 'completed', 'comments' => 'Excellent coverage of the basics.', 'job_number' => 'WF-2024-004'],
    ['title' => 'Project Alpha Approval', 'description' => 'Sign-off from Project Alpha team.', 'assigned_type' => 'group', 'assigned_group' => 3, 'completion' => 'accepted', 'comments' => 'Under review by project leads.', 'job_number' => 'WF-2024-004'],
    ['title' => 'Archive Copy', 'description' => 'Create archived version.', 'assigned_type' => 'destination', 'assigned_destination' => $destination_ids['archive'], 'completion' => 'proposed', 'comments' => '', 'job_number' => 'WF-2024-004'],
  ],
  // Node 5: Community Guidelines - Multiple users
  5 => [
    ['title' => 'Initial Draft Review', 'description' => 'First pass review of guidelines.', 'assigned_type' => 'user', 'assigned_user' => 2, 'completion' => 'completed', 'comments' => 'Good foundation, some clarifications needed.', 'job_number' => 'WF-2024-005'],
    ['title' => 'Legal Compliance Check', 'description' => 'Ensure guidelines meet legal requirements.', 'assigned_type' => 'user', 'assigned_user' => 4, 'completion' => 'completed', 'comments' => 'Compliant with all regulations.', 'job_number' => 'WF-2024-005'],
    ['title' => 'Community Manager Review', 'description' => 'Final review by community team.', 'assigned_type' => 'user', 'assigned_user' => 6, 'completion' => 'accepted', 'comments' => 'Reviewing feedback from community.', 'job_number' => 'WF-2024-005'],
    ['title' => 'Executive Approval', 'description' => 'Final sign-off from leadership.', 'assigned_type' => 'user', 'assigned_user' => 1, 'completion' => 'proposed', 'comments' => '', 'job_number' => 'WF-2024-005'],
  ],
  // Node 6: Weekly Team Sync - Group-heavy
  6 => [
    ['title' => 'Development Team Prep', 'description' => 'Dev team prepares status updates.', 'assigned_type' => 'group', 'assigned_group' => 1, 'completion' => 'completed', 'comments' => 'Sprint updates prepared.', 'job_number' => 'EVT-2024-001'],
    ['title' => 'Content Team Prep', 'description' => 'Content team prepares announcements.', 'assigned_type' => 'group', 'assigned_group' => 2, 'completion' => 'accepted', 'comments' => 'Drafting newsletter highlights.', 'job_number' => 'EVT-2024-001'],
    ['title' => 'Project Alpha Updates', 'description' => 'Alpha team project status.', 'assigned_type' => 'group', 'assigned_group' => 3, 'completion' => 'proposed', 'comments' => '', 'job_number' => 'EVT-2024-001'],
  ],
  // Node 7: AVC Training Session - Mixed destinations
  7 => [
    ['title' => 'Training Materials Review', 'description' => 'Review all training materials.', 'assigned_type' => 'user', 'assigned_user' => 3, 'completion' => 'completed', 'comments' => 'All slides and exercises verified.', 'job_number' => 'EVT-2024-002'],
    ['title' => 'Publish to Intranet', 'description' => 'Make materials available internally.', 'assigned_type' => 'destination', 'assigned_destination' => $destination_ids['intranet'], 'completion' => 'completed', 'comments' => 'Available at /training/avc.', 'job_number' => 'EVT-2024-002'],
    ['title' => 'Post-Session Archive', 'description' => 'Archive session recordings.', 'assigned_type' => 'destination', 'assigned_destination' => $destination_ids['archive'], 'completion' => 'proposed', 'comments' => 'Pending session completion.', 'job_number' => 'EVT-2024-002'],
  ],
  // Node 8: Community Meetup - Social media
  8 => [
    ['title' => 'Event Announcement Review', 'description' => 'Review meetup announcement.', 'assigned_type' => 'user', 'assigned_user' => 2, 'completion' => 'completed', 'comments' => 'Announcement approved.', 'job_number' => 'EVT-2024-003'],
    ['title' => 'Social Media Publish', 'description' => 'Post to social media channels.', 'assigned_type' => 'destination', 'assigned_destination' => $destination_ids['social'], 'completion' => 'accepted', 'comments' => 'Scheduled for posting.', 'job_number' => 'EVT-2024-003'],
    ['title' => 'Public Website Post', 'description' => 'Publish event to public website.', 'assigned_type' => 'destination', 'assigned_destination' => $destination_ids['public'], 'completion' => 'proposed', 'comments' => '', 'job_number' => 'EVT-2024-003'],
  ],
];

$assignment_count = 0;
$node_storage = $entity_type_manager->getStorage('node');
$assignment_storage = $entity_type_manager->getStorage('workflow_assignment');

foreach ($node_assignments as $nid => $assignments) {
  $node = $node_storage->load($nid);
  if (!$node) {
    echo "  Warning: Node $nid not found, skipping...\n";
    continue;
  }

  echo "  Node $nid: {$node->getTitle()}\n";

  $assignment_ids = [];
  foreach ($assignments as $a) {
    $assignment = $assignment_storage->create([
      'title' => $a['title'],
      'description' => $a['description'],
      'assigned_type' => $a['assigned_type'],
      'completion' => $a['completion'],
      'comments' => $a['comments'],
      'job_number' => $a['job_number'],
      'uid' => 1,
    ]);

    if ($a['assigned_type'] === 'user' && isset($a['assigned_user'])) {
      $assignment->set('assigned_user', $a['assigned_user']);
    }
    elseif ($a['assigned_type'] === 'group' && isset($a['assigned_group'])) {
      $assignment->set('assigned_group', $a['assigned_group']);
    }
    elseif ($a['assigned_type'] === 'destination' && isset($a['assigned_destination'])) {
      $assignment->set('assigned_destination', $a['assigned_destination']);
    }

    $assignment->save();
    $assignment_ids[] = ['target_id' => $assignment->id()];
    $assignment_count++;

    $icon = match($a['completion']) { 'completed' => '[DONE]', 'accepted' => '[IN PROGRESS]', 'proposed' => '[PENDING]', default => '[?]' };
    echo "    $icon {$a['title']} -> {$a['assigned_type']}\n";
  }

  if ($node->hasField('field_workflow_list')) {
    $node->set('field_workflow_list', $assignment_ids);
    $node->save();
    echo "    Attached " . count($assignment_ids) . " assignments to node.\n";
  }
  else {
    echo "    Warning: Node missing field_workflow_list field.\n";
  }
}

// Summary.
echo "\n=== Summary ===\n";
echo "Destinations: " . count($destinations) . "\n";
echo "Workflow lists: " . count($workflow_lists) . "\n";
echo "Templates: " . count($templates_data) . "\n";
echo "Assignments: $assignment_count\n";
echo "\nDone! View at:\n";
echo "  /admin/structure/workflow-list\n";
echo "  /admin/structure/workflow-template\n";
echo "  /node/{nid}/workflow\n";
