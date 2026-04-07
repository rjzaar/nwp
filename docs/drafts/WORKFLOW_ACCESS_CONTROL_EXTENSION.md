# Workflow-Based Access Control Extension for AVC

**Status:** DRAFT
**Created:** January 11, 2026
**Module:** workflow_assignment
**Purpose:** Restrict node access to only workflow participants during active workflow

---

## Overview

This extension adds node-level access control based on workflow participation. When a node has an active workflow, only the following users can access it:

1. **Node author** - Always has access to their own content
2. **Current stage assignee** - User assigned to the active workflow task
3. **Group members** - Members of the group assigned to the active workflow task
4. **Workflow administrators** - Users with `administer workflow tasks` permission

---

## Architecture

```
User requests node/123
        ↓
hook_node_access() called
        ↓
WorkflowAccessManager::checkAccess()
        ↓
┌─────────────────────────────────────┐
│ 1. Has active workflow tasks?       │
│    NO  → AccessResult::neutral()    │
│    YES → Continue                   │
├─────────────────────────────────────┤
│ 2. Is user the node author?         │
│    YES → AccessResult::allowed()    │
│    NO  → Continue                   │
├─────────────────────────────────────┤
│ 3. Is user a workflow admin?        │
│    YES → AccessResult::allowed()    │
│    NO  → Continue                   │
├─────────────────────────────────────┤
│ 4. Is user assigned to active task? │
│    - Direct user assignment?        │
│    - Member of assigned group?      │
│    YES → AccessResult::allowed()    │
│    NO  → Continue                   │
├─────────────────────────────────────┤
│ 5. Has user completed a task?       │
│    YES → AccessResult::allowed()    │
│         (read-only suggested)       │
│    NO  → AccessResult::forbidden()  │
└─────────────────────────────────────┘
```

---

## File Structure

```
workflow_assignment/
├── src/
│   ├── Access/
│   │   ├── NodeWorkflowAccessCheck.php      # Existing
│   │   └── WorkflowAccessManager.php        # NEW - Core access logic
│   ├── Service/
│   │   └── WorkflowParticipantResolver.php  # NEW - Resolves participants
│   └── EventSubscriber/
│       └── WorkflowAccessSubscriber.php     # NEW - Cache invalidation
├── workflow_assignment.module               # Modified - Add hook_node_access
├── workflow_assignment.services.yml         # Modified - Register services
└── config/
    └── install/
        └── workflow_assignment.settings.yml # Modified - Access settings
```

---

## Implementation

### 1. WorkflowParticipantResolver Service

```php
<?php

namespace Drupal\workflow_assignment\Service;

use Drupal\Core\Entity\EntityTypeManagerInterface;
use Drupal\Core\Session\AccountInterface;
use Drupal\group\GroupMembershipLoaderInterface;
use Drupal\node\NodeInterface;

/**
 * Resolves workflow participants for access control.
 */
class WorkflowParticipantResolver {

  /**
   * The entity type manager.
   *
   * @var \Drupal\Core\Entity\EntityTypeManagerInterface
   */
  protected $entityTypeManager;

  /**
   * The group membership loader.
   *
   * @var \Drupal\group\GroupMembershipLoaderInterface|null
   */
  protected $groupMembershipLoader;

  /**
   * Constructs a WorkflowParticipantResolver.
   */
  public function __construct(
    EntityTypeManagerInterface $entity_type_manager,
    GroupMembershipLoaderInterface $group_membership_loader = NULL
  ) {
    $this->entityTypeManager = $entity_type_manager;
    $this->groupMembershipLoader = $group_membership_loader;
  }

  /**
   * Get all active workflow tasks for a node.
   *
   * @param \Drupal\node\NodeInterface $node
   *   The node to check.
   *
   * @return \Drupal\workflow_assignment\Entity\WorkflowTaskInterface[]
   *   Array of active workflow tasks.
   */
  public function getActiveWorkflowTasks(NodeInterface $node): array {
    $storage = $this->entityTypeManager->getStorage('workflow_task');

    $query = $storage->getQuery()
      ->accessCheck(FALSE) // We're doing our own access check
      ->condition('node_id', $node->id())
      ->condition('status', ['pending', 'in_progress'], 'IN')
      ->sort('weight', 'ASC');

    $ids = $query->execute();

    return $ids ? $storage->loadMultiple($ids) : [];
  }

  /**
   * Get the current (lowest weight pending/in_progress) task.
   *
   * @param \Drupal\node\NodeInterface $node
   *   The node to check.
   *
   * @return \Drupal\workflow_assignment\Entity\WorkflowTaskInterface|null
   *   The current task or NULL.
   */
  public function getCurrentTask(NodeInterface $node) {
    $tasks = $this->getActiveWorkflowTasks($node);
    return reset($tasks) ?: NULL;
  }

  /**
   * Get all workflow tasks (including completed) for a node.
   *
   * @param \Drupal\node\NodeInterface $node
   *   The node to check.
   *
   * @return \Drupal\workflow_assignment\Entity\WorkflowTaskInterface[]
   *   Array of all workflow tasks.
   */
  public function getAllWorkflowTasks(NodeInterface $node): array {
    $storage = $this->entityTypeManager->getStorage('workflow_task');

    $query = $storage->getQuery()
      ->accessCheck(FALSE)
      ->condition('node_id', $node->id())
      ->sort('weight', 'ASC');

    $ids = $query->execute();

    return $ids ? $storage->loadMultiple($ids) : [];
  }

  /**
   * Check if user is a participant in any workflow task.
   *
   * @param \Drupal\node\NodeInterface $node
   *   The node to check.
   * @param \Drupal\Core\Session\AccountInterface $account
   *   The user account.
   * @param bool $active_only
   *   If TRUE, only check active tasks. If FALSE, include completed.
   *
   * @return bool
   *   TRUE if user is a participant.
   */
  public function isParticipant(NodeInterface $node, AccountInterface $account, bool $active_only = FALSE): bool {
    $tasks = $active_only
      ? $this->getActiveWorkflowTasks($node)
      : $this->getAllWorkflowTasks($node);

    foreach ($tasks as $task) {
      if ($this->isAssignedToTask($task, $account)) {
        return TRUE;
      }
    }

    return FALSE;
  }

  /**
   * Check if user is assigned to a specific task.
   *
   * @param \Drupal\workflow_assignment\Entity\WorkflowTaskInterface $task
   *   The workflow task.
   * @param \Drupal\Core\Session\AccountInterface $account
   *   The user account.
   *
   * @return bool
   *   TRUE if user is assigned to this task.
   */
  public function isAssignedToTask($task, AccountInterface $account): bool {
    $assigned_type = $task->get('assigned_type')->value;

    switch ($assigned_type) {
      case 'user':
        $assigned_user = $task->get('assigned_user')->target_id;
        return $assigned_user && (int) $assigned_user === (int) $account->id();

      case 'group':
        return $this->isUserInAssignedGroup($task, $account);

      case 'destination':
        // Destination assignments typically don't restrict access
        // They represent where content goes after workflow
        return FALSE;
    }

    return FALSE;
  }

  /**
   * Check if user is a member of the assigned group.
   *
   * @param \Drupal\workflow_assignment\Entity\WorkflowTaskInterface $task
   *   The workflow task.
   * @param \Drupal\Core\Session\AccountInterface $account
   *   The user account.
   *
   * @return bool
   *   TRUE if user is in the assigned group.
   */
  protected function isUserInAssignedGroup($task, AccountInterface $account): bool {
    $group_id = $task->get('assigned_group')->target_id;

    if (!$group_id || !$this->groupMembershipLoader) {
      return FALSE;
    }

    try {
      $group = $this->entityTypeManager->getStorage('group')->load($group_id);
      if (!$group) {
        return FALSE;
      }

      $membership = $this->groupMembershipLoader->load($group, $account);
      return $membership !== NULL;
    }
    catch (\Exception $e) {
      // Log error but don't crash access check
      \Drupal::logger('workflow_assignment')->error(
        'Error checking group membership: @message',
        ['@message' => $e->getMessage()]
      );
      return FALSE;
    }
  }

  /**
   * Check if user has completed a task for this node.
   *
   * @param \Drupal\node\NodeInterface $node
   *   The node to check.
   * @param \Drupal\Core\Session\AccountInterface $account
   *   The user account.
   *
   * @return bool
   *   TRUE if user completed a task.
   */
  public function hasCompletedTask(NodeInterface $node, AccountInterface $account): bool {
    $storage = $this->entityTypeManager->getStorage('workflow_task');

    $query = $storage->getQuery()
      ->accessCheck(FALSE)
      ->condition('node_id', $node->id())
      ->condition('status', 'completed')
      ->condition('assigned_type', 'user')
      ->condition('assigned_user', $account->id());

    return (bool) $query->count()->execute();
  }

  /**
   * Get cache tags for workflow access.
   *
   * @param \Drupal\node\NodeInterface $node
   *   The node.
   *
   * @return array
   *   Array of cache tags.
   */
  public function getAccessCacheTags(NodeInterface $node): array {
    $tags = ['workflow_task_list:' . $node->id()];

    foreach ($this->getAllWorkflowTasks($node) as $task) {
      $tags[] = 'workflow_task:' . $task->id();
    }

    return $tags;
  }

}
```

---

### 2. WorkflowAccessManager Service

```php
<?php

namespace Drupal\workflow_assignment\Access;

use Drupal\Core\Access\AccessResult;
use Drupal\Core\Access\AccessResultInterface;
use Drupal\Core\Config\ConfigFactoryInterface;
use Drupal\Core\Session\AccountInterface;
use Drupal\node\NodeInterface;
use Drupal\workflow_assignment\Service\WorkflowParticipantResolver;

/**
 * Manages workflow-based access control for nodes.
 */
class WorkflowAccessManager {

  /**
   * The participant resolver.
   *
   * @var \Drupal\workflow_assignment\Service\WorkflowParticipantResolver
   */
  protected $participantResolver;

  /**
   * The config factory.
   *
   * @var \Drupal\Core\Config\ConfigFactoryInterface
   */
  protected $configFactory;

  /**
   * Constructs a WorkflowAccessManager.
   */
  public function __construct(
    WorkflowParticipantResolver $participant_resolver,
    ConfigFactoryInterface $config_factory
  ) {
    $this->participantResolver = $participant_resolver;
    $this->configFactory = $config_factory;
  }

  /**
   * Check if workflow-based access control applies to this node type.
   *
   * @param \Drupal\node\NodeInterface $node
   *   The node to check.
   *
   * @return bool
   *   TRUE if workflow access control applies.
   */
  public function appliesTo(NodeInterface $node): bool {
    $config = $this->configFactory->get('workflow_assignment.settings');
    $enabled_types = $config->get('enabled_content_types') ?? [];
    $access_control_types = $config->get('workflow_access_control_types') ?? [];

    $bundle = $node->bundle();

    // Must be enabled for workflows AND have access control enabled
    return in_array($bundle, $enabled_types) && in_array($bundle, $access_control_types);
  }

  /**
   * Check workflow-based access for a node.
   *
   * @param \Drupal\node\NodeInterface $node
   *   The node to check access for.
   * @param string $operation
   *   The operation (view, update, delete).
   * @param \Drupal\Core\Session\AccountInterface $account
   *   The user account.
   *
   * @return \Drupal\Core\Access\AccessResultInterface
   *   The access result.
   */
  public function checkAccess(NodeInterface $node, string $operation, AccountInterface $account): AccessResultInterface {
    // Only apply to configured content types
    if (!$this->appliesTo($node)) {
      return AccessResult::neutral()
        ->addCacheableDependency($node)
        ->addCacheTags(['config:workflow_assignment.settings']);
    }

    // Check if node has active workflow
    $active_tasks = $this->participantResolver->getActiveWorkflowTasks($node);

    if (empty($active_tasks)) {
      // No active workflow - use normal access
      return AccessResult::neutral()
        ->addCacheableDependency($node)
        ->addCacheTags($this->participantResolver->getAccessCacheTags($node));
    }

    // Build cache metadata
    $cache_tags = $this->participantResolver->getAccessCacheTags($node);
    $cache_tags[] = 'config:workflow_assignment.settings';

    // 1. Node author always has access
    if ($node->getOwnerId() === (int) $account->id()) {
      return AccessResult::allowed()
        ->addCacheableDependency($node)
        ->addCacheContexts(['user'])
        ->addCacheTags($cache_tags);
    }

    // 2. Workflow administrators have access
    if ($account->hasPermission('administer workflow tasks')) {
      return AccessResult::allowed()
        ->addCacheableDependency($node)
        ->addCacheContexts(['user.permissions'])
        ->addCacheTags($cache_tags);
    }

    // 3. Current task assignee has access
    $current_task = $this->participantResolver->getCurrentTask($node);
    if ($current_task && $this->participantResolver->isAssignedToTask($current_task, $account)) {
      return $this->getAllowedWithEditCheck($node, $operation, $account, $cache_tags);
    }

    // 4. Any workflow participant (past or present) has read access
    if ($operation === 'view' && $this->participantResolver->isParticipant($node, $account, FALSE)) {
      return AccessResult::allowed()
        ->addCacheableDependency($node)
        ->addCacheContexts(['user'])
        ->addCacheTags($cache_tags);
    }

    // 5. Not a participant - deny access during active workflow
    return AccessResult::forbidden('Access restricted to workflow participants.')
      ->addCacheableDependency($node)
      ->addCacheContexts(['user'])
      ->addCacheTags($cache_tags);
  }

  /**
   * Return allowed access with edit permission check.
   *
   * @param \Drupal\node\NodeInterface $node
   *   The node.
   * @param string $operation
   *   The operation.
   * @param \Drupal\Core\Session\AccountInterface $account
   *   The account.
   * @param array $cache_tags
   *   Cache tags.
   *
   * @return \Drupal\Core\Access\AccessResultInterface
   *   The access result.
   */
  protected function getAllowedWithEditCheck(NodeInterface $node, string $operation, AccountInterface $account, array $cache_tags): AccessResultInterface {
    // View is always allowed for current assignee
    if ($operation === 'view') {
      return AccessResult::allowed()
        ->addCacheableDependency($node)
        ->addCacheContexts(['user'])
        ->addCacheTags($cache_tags);
    }

    // Edit requires additional permission
    if ($operation === 'update') {
      $can_edit = $account->hasPermission('edit own workflow tasks')
        || $account->hasPermission('edit any avc assets');

      return $can_edit
        ? AccessResult::allowed()
            ->addCacheableDependency($node)
            ->addCacheContexts(['user', 'user.permissions'])
            ->addCacheTags($cache_tags)
        : AccessResult::neutral()
            ->addCacheableDependency($node)
            ->addCacheContexts(['user.permissions'])
            ->addCacheTags($cache_tags);
    }

    // Delete - typically restricted during workflow
    if ($operation === 'delete') {
      return AccessResult::forbidden('Cannot delete content with active workflow.')
        ->addCacheableDependency($node)
        ->addCacheTags($cache_tags);
    }

    return AccessResult::neutral();
  }

}
```

---

### 3. Module Hook Implementation

Add to `workflow_assignment.module`:

```php
<?php

use Drupal\Core\Access\AccessResult;
use Drupal\Core\Session\AccountInterface;
use Drupal\node\NodeInterface;

/**
 * Implements hook_node_access().
 *
 * Restricts access to nodes with active workflows to only:
 * - Node author
 * - Workflow administrators
 * - Users assigned to the current workflow task
 * - Members of groups assigned to the current task
 * - Past workflow participants (view only)
 */
function workflow_assignment_node_access(NodeInterface $node, $operation, AccountInterface $account) {
  // Only check view, update, delete operations
  if (!in_array($operation, ['view', 'update', 'delete'])) {
    return AccessResult::neutral();
  }

  /** @var \Drupal\workflow_assignment\Access\WorkflowAccessManager $access_manager */
  $access_manager = \Drupal::service('workflow_assignment.access_manager');

  return $access_manager->checkAccess($node, $operation, $account);
}

/**
 * Implements hook_entity_presave().
 *
 * Invalidate access cache when workflow tasks change.
 */
function workflow_assignment_workflow_task_presave($entity) {
  if ($entity->hasField('node_id') && $entity->get('node_id')->target_id) {
    $node_id = $entity->get('node_id')->target_id;
    \Drupal\Core\Cache\Cache::invalidateTags(['workflow_task_list:' . $node_id]);
  }
}

/**
 * Implements hook_entity_delete().
 *
 * Invalidate access cache when workflow tasks are deleted.
 */
function workflow_assignment_workflow_task_delete($entity) {
  if ($entity->hasField('node_id') && $entity->get('node_id')->target_id) {
    $node_id = $entity->get('node_id')->target_id;
    \Drupal\Core\Cache\Cache::invalidateTags(['workflow_task_list:' . $node_id]);
  }
}
```

---

### 4. Services Configuration

Update `workflow_assignment.services.yml`:

```yaml
services:
  # Existing services...
  workflow_assignment.notification:
    class: Drupal\workflow_assignment\Service\WorkflowNotificationService
    arguments: ['@entity_type.manager', '@plugin.manager.mail', '@current_user']

  workflow_assignment.history_logger:
    class: Drupal\workflow_assignment\Service\WorkflowHistoryLogger
    arguments: ['@database', '@current_user', '@datetime.time']

  access_check.workflow.node_has_field:
    class: Drupal\workflow_assignment\Access\NodeWorkflowAccessCheck
    arguments: ['@config.factory']
    tags:
      - { name: access_check, applies_to: _node_has_workflow_field }

  # NEW services
  workflow_assignment.participant_resolver:
    class: Drupal\workflow_assignment\Service\WorkflowParticipantResolver
    arguments:
      - '@entity_type.manager'
      - '@?group.membership_loader'

  workflow_assignment.access_manager:
    class: Drupal\workflow_assignment\Access\WorkflowAccessManager
    arguments:
      - '@workflow_assignment.participant_resolver'
      - '@config.factory'
```

---

### 5. Configuration Schema

Add `config/schema/workflow_assignment.schema.yml`:

```yaml
workflow_assignment.settings:
  type: config_object
  label: 'Workflow Assignment settings'
  mapping:
    enabled_content_types:
      type: sequence
      label: 'Content types enabled for workflows'
      sequence:
        type: string
        label: 'Content type machine name'
    workflow_access_control_types:
      type: sequence
      label: 'Content types with workflow-based access control'
      sequence:
        type: string
        label: 'Content type machine name'
    allow_past_participants_view:
      type: boolean
      label: 'Allow past workflow participants to view content'
    restrict_delete_during_workflow:
      type: boolean
      label: 'Prevent deletion during active workflow'
```

---

### 6. Settings Form Update

Add to settings form (`src/Form/WorkflowAssignmentSettingsForm.php`):

```php
/**
 * Workflow access control settings.
 */
$form['access_control'] = [
  '#type' => 'details',
  '#title' => $this->t('Workflow Access Control'),
  '#open' => TRUE,
];

$form['access_control']['workflow_access_control_types'] = [
  '#type' => 'checkboxes',
  '#title' => $this->t('Enable workflow-based access control'),
  '#description' => $this->t('Content types where access is restricted to workflow participants during active workflow.'),
  '#options' => $content_type_options,
  '#default_value' => $config->get('workflow_access_control_types') ?? [],
];

$form['access_control']['allow_past_participants_view'] = [
  '#type' => 'checkbox',
  '#title' => $this->t('Allow past participants to view content'),
  '#description' => $this->t('Users who have completed a workflow task can still view (but not edit) the content.'),
  '#default_value' => $config->get('allow_past_participants_view') ?? TRUE,
];

$form['access_control']['restrict_delete_during_workflow'] = [
  '#type' => 'checkbox',
  '#title' => $this->t('Prevent deletion during active workflow'),
  '#description' => $this->t('Content cannot be deleted while it has active workflow tasks.'),
  '#default_value' => $config->get('restrict_delete_during_workflow') ?? TRUE,
];
```

---

## Revision-Aware Access (Optional Enhancement)

If you need users to only see the revision they're assigned to:

```php
/**
 * Implements hook_node_revision_access().
 */
function workflow_assignment_node_revision_access(NodeInterface $node, $operation, AccountInterface $account) {
  // Get the revision the user is assigned to
  $participant_resolver = \Drupal::service('workflow_assignment.participant_resolver');
  $current_task = $participant_resolver->getCurrentTask($node);

  if (!$current_task) {
    return AccessResult::neutral();
  }

  // Check if this revision was created when user's task was active
  $task_created = $current_task->getCreatedTime();
  $revision_created = $node->getRevisionCreationTime();

  // User can only see revisions created after their task was assigned
  if ($revision_created >= $task_created) {
    return AccessResult::neutral(); // Let other access checks decide
  }

  // Earlier revisions are hidden from non-admins
  if (!$account->hasPermission('administer workflow tasks')) {
    return AccessResult::forbidden('This revision predates your workflow assignment.');
  }

  return AccessResult::neutral();
}
```

---

## Access Flow Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                     NODE ACCESS REQUEST                         │
│                     node/123 (view)                             │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│ Is content type enabled for workflow access control?            │
│ Config: workflow_access_control_types                           │
└─────────────────────────────────────────────────────────────────┘
          │                                    │
          │ NO                                 │ YES
          ▼                                    ▼
┌──────────────────┐              ┌─────────────────────────────┐
│ AccessResult::   │              │ Has active workflow tasks?  │
│ neutral()        │              └─────────────────────────────┘
│ (normal access)  │                    │              │
└──────────────────┘                    │ NO           │ YES
                                        ▼              ▼
                           ┌──────────────────┐  ┌──────────────┐
                           │ AccessResult::   │  │ Check user   │
                           │ neutral()        │  │ participation│
                           └──────────────────┘  └──────────────┘
                                                        │
                    ┌───────────────────────────────────┼───────────┐
                    │                   │               │           │
                    ▼                   ▼               ▼           ▼
            ┌─────────────┐    ┌─────────────┐  ┌───────────┐ ┌──────────┐
            │ Is author?  │    │ Is admin?   │  │ Assigned  │ │ Past     │
            │             │    │ (administer │  │ to current│ │ partici- │
            │             │    │  workflow   │  │ task?     │ │ pant?    │
            │             │    │  tasks)     │  │           │ │          │
            └─────────────┘    └─────────────┘  └───────────┘ └──────────┘
                    │                   │               │           │
                    │ YES               │ YES           │ YES       │ YES
                    ▼                   ▼               ▼           │ (view)
            ┌─────────────────────────────────────────────┐        ▼
            │           AccessResult::allowed()           │ ┌───────────┐
            │      Full access to view/edit content       │ │ View only │
            └─────────────────────────────────────────────┘ │ allowed   │
                                                            └───────────┘
                    │ NO (all checks)
                    ▼
            ┌─────────────────────────────────────────────┐
            │     AccessResult::forbidden()               │
            │   "Access restricted to workflow            │
            │    participants."                           │
            └─────────────────────────────────────────────┘
```

---

## Testing

### Manual Testing Checklist

```
[ ] Create AVC resource as Author
[ ] Add workflow with User A assigned to stage 1
[ ] Verify Author can view/edit
[ ] Verify User A can view/edit
[ ] Verify User B (not assigned) CANNOT view
[ ] Verify Admin can view/edit
[ ] Complete stage 1 (User A)
[ ] Verify User A can still view (read-only)
[ ] Add User B to stage 2
[ ] Verify User B can now view/edit
[ ] Verify User A can view but not edit
[ ] Complete all stages
[ ] Verify normal access resumes
```

### Automated Test

```php
<?php

namespace Drupal\Tests\workflow_assignment\Kernel;

use Drupal\KernelTests\KernelTestBase;
use Drupal\node\Entity\Node;
use Drupal\user\Entity\User;

/**
 * Tests workflow-based access control.
 *
 * @group workflow_assignment
 */
class WorkflowAccessTest extends KernelTestBase {

  protected static $modules = [
    'node',
    'user',
    'workflow_assignment',
    // ... other required modules
  ];

  /**
   * Test that non-participants cannot access nodes with active workflow.
   */
  public function testNonParticipantDenied() {
    $author = User::create(['name' => 'author']);
    $author->save();

    $outsider = User::create(['name' => 'outsider']);
    $outsider->save();

    $node = Node::create([
      'type' => 'avc_document',
      'title' => 'Test Document',
      'uid' => $author->id(),
    ]);
    $node->save();

    // Add workflow task
    $this->createWorkflowTask($node, 'user', $author->id());

    // Outsider should not have access
    $this->assertFalse($node->access('view', $outsider));

    // Author should have access
    $this->assertTrue($node->access('view', $author));
  }

}
```

---

## Migration / Rollout Plan

### Phase 1: Deploy Code (No Impact)
1. Deploy new services and hook
2. Leave `workflow_access_control_types` empty in config
3. Test in staging environment

### Phase 2: Enable Per Content Type
1. Enable for `avc_document` first
2. Monitor for access issues
3. Enable for `avc_resource`
4. Enable for `avc_project`

### Phase 3: User Training
1. Document new access behavior
2. Train editors on workflow visibility
3. Update help text in UI

---

## Rollback

To disable workflow access control without code changes:

```php
// Disable via drush
drush cset workflow_assignment.settings workflow_access_control_types "[]" -y
drush cr
```

Or in UI: **Admin > Config > Workflow > Settings** → Uncheck all content types under "Workflow Access Control"

---

## Security Considerations

1. **Cache invalidation** - Access is cached; must invalidate when tasks change
2. **Admin bypass** - `administer workflow tasks` permission bypasses all checks
3. **Author access** - Authors always have access to their own content
4. **Group membership** - Depends on accurate group membership data
5. **Revision access** - Consider if users should see historical revisions

---

## Future Enhancements

1. **Stage-specific revisions** - Lock content to specific revision per stage
2. **Approval gates** - Require explicit approval before advancing
3. **Parallel assignments** - Multiple users working on same stage
4. **Deadline enforcement** - Auto-escalate or reassign overdue tasks
5. **Audit logging** - Track all access attempts (allowed and denied)
