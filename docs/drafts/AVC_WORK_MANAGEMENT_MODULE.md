# AVC Work Management Module

**Status:** DRAFT
**Created:** January 11, 2026
**Module:** avc_work_management
**Purpose:** Unified "My Work" dashboard for workflow task visibility

---

## Overview

This module provides a user-facing dashboard showing:
- Summary cards by content type (Documents, Resources, Projects)
- Action Needed tasks (assigned to me, in progress)
- Available to Claim tasks (assigned to my groups)
- Recently Completed tasks

---

## File Structure

```
avc_work_management/
├── avc_work_management.info.yml
├── avc_work_management.module
├── avc_work_management.routing.yml
├── avc_work_management.services.yml
├── avc_work_management.permissions.yml
├── avc_work_management.links.menu.yml
├── avc_work_management.libraries.yml
│
├── config/
│   ├── install/
│   │   └── avc_work_management.settings.yml
│   └── schema/
│       └── avc_work_management.schema.yml
│
├── src/
│   ├── Controller/
│   │   └── MyWorkController.php
│   ├── Service/
│   │   ├── WorkTaskQueryService.php
│   │   └── WorkTaskActionService.php
│   └── Form/
│       └── ClaimTaskForm.php
│
├── templates/
│   ├── my-work-dashboard.html.twig
│   ├── my-work-summary-cards.html.twig
│   ├── my-work-task-list.html.twig
│   └── my-work-task-row.html.twig
│
└── css/
    └── my-work-dashboard.css
```

---

## Module Files

### avc_work_management.info.yml

```yaml
name: 'AVC Work Management'
type: module
description: 'Provides My Work dashboard for workflow task management'
package: AVC
core_version_requirement: ^9 || ^10
dependencies:
  - drupal:node
  - drupal:user
  - workflow_assignment:workflow_assignment
  - avc_asset:avc_asset
  - group:group
```

---

### avc_work_management.routing.yml

```yaml
avc_work_management.my_work:
  path: '/my-work'
  defaults:
    _controller: '\Drupal\avc_work_management\Controller\MyWorkController::dashboard'
    _title: 'My Work'
  requirements:
    _permission: 'access my work dashboard'

avc_work_management.my_work_section:
  path: '/my-work/{section}'
  defaults:
    _controller: '\Drupal\avc_work_management\Controller\MyWorkController::section'
    _title_callback: '\Drupal\avc_work_management\Controller\MyWorkController::sectionTitle'
  requirements:
    _permission: 'access my work dashboard'
    section: 'active|available|upcoming|completed'

avc_work_management.claim_task:
  path: '/my-work/claim/{workflow_task}'
  defaults:
    _form: '\Drupal\avc_work_management\Form\ClaimTaskForm'
    _title: 'Claim Task'
  requirements:
    _permission: 'claim workflow tasks'
  options:
    parameters:
      workflow_task:
        type: entity:workflow_task
```

---

### avc_work_management.services.yml

```yaml
services:
  avc_work_management.task_query:
    class: Drupal\avc_work_management\Service\WorkTaskQueryService
    arguments:
      - '@entity_type.manager'
      - '@current_user'
      - '@group.membership_loader'
      - '@config.factory'

  avc_work_management.task_action:
    class: Drupal\avc_work_management\Service\WorkTaskActionService
    arguments:
      - '@entity_type.manager'
      - '@current_user'
      - '@datetime.time'
      - '@logger.factory'
```

---

### avc_work_management.permissions.yml

```yaml
access my work dashboard:
  title: 'Access My Work dashboard'
  description: 'View personal workflow task dashboard'

claim workflow tasks:
  title: 'Claim workflow tasks'
  description: 'Claim group-assigned tasks for personal work'

view all work dashboards:
  title: 'View all user work dashboards'
  description: 'Administrators can view any user work dashboard'
  restrict access: true
```

---

### avc_work_management.links.menu.yml

```yaml
avc_work_management.my_work:
  title: 'My Work'
  route_name: avc_work_management.my_work
  menu_name: main
  weight: -10
```

---

### avc_work_management.libraries.yml

```yaml
dashboard:
  version: 1.x
  css:
    theme:
      css/my-work-dashboard.css: {}
  dependencies:
    - core/drupal
```

---

### config/install/avc_work_management.settings.yml

```yaml
# Content types to track in dashboard
tracked_content_types:
  avc_document:
    label: 'Documents'
    icon: 'file-text'
    color: '#4a90d9'
  avc_resource:
    label: 'Resources'
    icon: 'link'
    color: '#7b68ee'
  avc_project:
    label: 'Projects'
    icon: 'folder'
    color: '#50c878'

# Dashboard sections
sections:
  active:
    label: 'Action Needed'
    status: 'in_progress'
    assigned_to: 'user'
    limit: 10
    show_view_all: true
  available:
    label: 'Available to Claim'
    status: 'pending'
    assigned_to: 'group'
    limit: 5
    show_view_all: true
    show_claim: true
  upcoming:
    label: 'Upcoming'
    status: 'pending'
    assigned_to: 'user'
    limit: 5
    show_view_all: true
  completed:
    label: 'Recently Completed'
    status: 'completed'
    assigned_to: 'user'
    limit: 5
    show_view_all: true

# Display options
display:
  show_due_dates: true
  show_content_type_icon: true
  date_format: 'M j'
```

---

### config/schema/avc_work_management.schema.yml

```yaml
avc_work_management.settings:
  type: config_object
  label: 'AVC Work Management settings'
  mapping:
    tracked_content_types:
      type: mapping
      label: 'Tracked content types'
      mapping:
        '*':
          type: mapping
          mapping:
            label:
              type: string
            icon:
              type: string
            color:
              type: string
    sections:
      type: mapping
      label: 'Dashboard sections'
    display:
      type: mapping
      label: 'Display options'
```

---

## PHP Classes

### src/Service/WorkTaskQueryService.php

```php
<?php

namespace Drupal\avc_work_management\Service;

use Drupal\Core\Config\ConfigFactoryInterface;
use Drupal\Core\Entity\EntityTypeManagerInterface;
use Drupal\Core\Session\AccountInterface;
use Drupal\group\GroupMembershipLoaderInterface;
use Drupal\node\NodeInterface;

/**
 * Service for querying workflow tasks.
 */
class WorkTaskQueryService {

  /**
   * The entity type manager.
   */
  protected EntityTypeManagerInterface $entityTypeManager;

  /**
   * The current user.
   */
  protected AccountInterface $currentUser;

  /**
   * The group membership loader.
   */
  protected ?GroupMembershipLoaderInterface $groupMembershipLoader;

  /**
   * The config factory.
   */
  protected ConfigFactoryInterface $configFactory;

  /**
   * Constructs a WorkTaskQueryService.
   */
  public function __construct(
    EntityTypeManagerInterface $entity_type_manager,
    AccountInterface $current_user,
    ?GroupMembershipLoaderInterface $group_membership_loader,
    ConfigFactoryInterface $config_factory
  ) {
    $this->entityTypeManager = $entity_type_manager;
    $this->currentUser = $current_user;
    $this->groupMembershipLoader = $group_membership_loader;
    $this->configFactory = $config_factory;
  }

  /**
   * Get tracked content types from config.
   */
  public function getTrackedContentTypes(): array {
    $config = $this->configFactory->get('avc_work_management.settings');
    return $config->get('tracked_content_types') ?? [];
  }

  /**
   * Get summary counts by content type.
   */
  public function getSummaryCounts(?AccountInterface $user = NULL): array {
    $user = $user ?? $this->currentUser;
    $types = $this->getTrackedContentTypes();
    $summary = [];

    foreach ($types as $type_id => $type_config) {
      $summary[$type_id] = [
        'label' => $type_config['label'],
        'icon' => $type_config['icon'],
        'color' => $type_config['color'],
        'active' => $this->countTasks($user, $type_id, 'in_progress', 'user'),
        'upcoming' => $this->countTasks($user, $type_id, 'pending', 'user'),
        'completed' => $this->countTasks($user, $type_id, 'completed', 'user'),
      ];
    }

    return $summary;
  }

  /**
   * Count tasks matching criteria.
   */
  public function countTasks(
    AccountInterface $user,
    ?string $content_type = NULL,
    ?string $status = NULL,
    string $assigned_to = 'user'
  ): int {
    $query = $this->buildBaseQuery($user, $assigned_to);

    if ($status) {
      $query->condition('status', $status);
    }

    if ($content_type) {
      $node_ids = $this->getNodeIdsByType($content_type);
      if (empty($node_ids)) {
        return 0;
      }
      $query->condition('node_id', $node_ids, 'IN');
    }

    return (int) $query->count()->execute();
  }

  /**
   * Get tasks for a section.
   */
  public function getTasksForSection(
    string $section,
    ?AccountInterface $user = NULL,
    ?int $limit = NULL
  ): array {
    $user = $user ?? $this->currentUser;
    $config = $this->configFactory->get('avc_work_management.settings');
    $section_config = $config->get('sections.' . $section);

    if (!$section_config) {
      return [];
    }

    $status = $section_config['status'] ?? NULL;
    $assigned_to = $section_config['assigned_to'] ?? 'user';
    $limit = $limit ?? ($section_config['limit'] ?? 10);

    return $this->getTasks($user, NULL, $status, $assigned_to, $limit);
  }

  /**
   * Get tasks matching criteria.
   */
  public function getTasks(
    AccountInterface $user,
    ?string $content_type = NULL,
    ?string $status = NULL,
    string $assigned_to = 'user',
    ?int $limit = NULL
  ): array {
    $query = $this->buildBaseQuery($user, $assigned_to);

    if ($status) {
      $query->condition('status', $status);
    }

    if ($content_type) {
      $node_ids = $this->getNodeIdsByType($content_type);
      if (empty($node_ids)) {
        return [];
      }
      $query->condition('node_id', $node_ids, 'IN');
    }

    // Sort by weight (priority), then due date.
    $query->sort('weight', 'ASC');

    if ($limit) {
      $query->range(0, $limit);
    }

    $ids = $query->execute();

    if (empty($ids)) {
      return [];
    }

    $tasks = $this->entityTypeManager->getStorage('workflow_task')->loadMultiple($ids);

    // Enrich with node data.
    return $this->enrichTasksWithNodeData($tasks);
  }

  /**
   * Build base query for tasks.
   */
  protected function buildBaseQuery(AccountInterface $user, string $assigned_to): object {
    $storage = $this->entityTypeManager->getStorage('workflow_task');
    $query = $storage->getQuery()->accessCheck(TRUE);

    if ($assigned_to === 'user') {
      $query->condition('assigned_type', 'user');
      $query->condition('assigned_user', $user->id());
    }
    elseif ($assigned_to === 'group') {
      $group_ids = $this->getUserGroupIds($user);
      if (empty($group_ids)) {
        // Return impossible condition if user has no groups.
        $query->condition('id', 0);
      }
      else {
        $query->condition('assigned_type', 'group');
        $query->condition('assigned_group', $group_ids, 'IN');
      }
    }

    return $query;
  }

  /**
   * Get IDs of groups user belongs to.
   */
  protected function getUserGroupIds(AccountInterface $user): array {
    if (!$this->groupMembershipLoader) {
      return [];
    }

    $memberships = $this->groupMembershipLoader->loadByUser($user);
    $group_ids = [];

    foreach ($memberships as $membership) {
      $group_ids[] = $membership->getGroup()->id();
    }

    return $group_ids;
  }

  /**
   * Get node IDs by content type.
   */
  protected function getNodeIdsByType(string $content_type): array {
    $query = $this->entityTypeManager->getStorage('node')->getQuery()
      ->accessCheck(FALSE)
      ->condition('type', $content_type);

    return $query->execute();
  }

  /**
   * Enrich tasks with related node data.
   */
  protected function enrichTasksWithNodeData(array $tasks): array {
    $enriched = [];
    $node_storage = $this->entityTypeManager->getStorage('node');
    $types = $this->getTrackedContentTypes();

    foreach ($tasks as $task) {
      $node_id = $task->get('node_id')->target_id;
      $node = $node_id ? $node_storage->load($node_id) : NULL;

      $content_type = $node ? $node->bundle() : 'unknown';
      $type_config = $types[$content_type] ?? [
        'label' => 'Content',
        'icon' => 'file',
        'color' => '#999',
      ];

      $enriched[] = [
        'task' => $task,
        'node' => $node,
        'title' => $node ? $node->label() : $task->label(),
        'node_url' => $node ? $node->toUrl()->toString() : NULL,
        'content_type' => $content_type,
        'content_type_label' => $type_config['label'],
        'content_type_icon' => $type_config['icon'],
        'content_type_color' => $type_config['color'],
        'status' => $task->get('status')->value,
        'due_date' => $task->hasField('due_date') ? $task->get('due_date')->value : NULL,
        'assigned_type' => $task->get('assigned_type')->value,
        'assigned_label' => $this->getAssignedLabel($task),
        'completed_date' => $task->get('status')->value === 'completed'
          ? $task->getChangedTime()
          : NULL,
      ];
    }

    return $enriched;
  }

  /**
   * Get human-readable assigned label.
   */
  protected function getAssignedLabel($task): string {
    $type = $task->get('assigned_type')->value;

    switch ($type) {
      case 'user':
        $user_id = $task->get('assigned_user')->target_id;
        $user = $user_id
          ? $this->entityTypeManager->getStorage('user')->load($user_id)
          : NULL;
        return $user ? $user->getDisplayName() : 'Unknown user';

      case 'group':
        $group_id = $task->get('assigned_group')->target_id;
        $group = $group_id
          ? $this->entityTypeManager->getStorage('group')->load($group_id)
          : NULL;
        return $group ? $group->label() : 'Unknown group';

      case 'destination':
        $term_id = $task->get('assigned_destination')->target_id;
        $term = $term_id
          ? $this->entityTypeManager->getStorage('taxonomy_term')->load($term_id)
          : NULL;
        return $term ? $term->label() : 'Unknown destination';
    }

    return 'Unassigned';
  }

  /**
   * Get cache tags for the dashboard.
   */
  public function getDashboardCacheTags(AccountInterface $user): array {
    $tags = [
      'user:' . $user->id(),
      'workflow_task_list',
    ];

    // Add group tags.
    foreach ($this->getUserGroupIds($user) as $group_id) {
      $tags[] = 'group:' . $group_id;
    }

    return $tags;
  }

}
```

---

### src/Service/WorkTaskActionService.php

```php
<?php

namespace Drupal\avc_work_management\Service;

use Drupal\Component\Datetime\TimeInterface;
use Drupal\Core\Entity\EntityTypeManagerInterface;
use Drupal\Core\Logger\LoggerChannelFactoryInterface;
use Drupal\Core\Session\AccountInterface;
use Drupal\workflow_assignment\Entity\WorkflowTaskInterface;

/**
 * Service for workflow task actions (claim, complete, release).
 */
class WorkTaskActionService {

  protected EntityTypeManagerInterface $entityTypeManager;
  protected AccountInterface $currentUser;
  protected TimeInterface $time;
  protected $logger;

  /**
   * Constructs a WorkTaskActionService.
   */
  public function __construct(
    EntityTypeManagerInterface $entity_type_manager,
    AccountInterface $current_user,
    TimeInterface $time,
    LoggerChannelFactoryInterface $logger_factory
  ) {
    $this->entityTypeManager = $entity_type_manager;
    $this->currentUser = $current_user;
    $this->time = $time;
    $this->logger = $logger_factory->get('avc_work_management');
  }

  /**
   * Check if user can claim a task.
   */
  public function canClaim(WorkflowTaskInterface $task, ?AccountInterface $user = NULL): bool {
    $user = $user ?? $this->currentUser;

    // Must be group-assigned.
    if ($task->get('assigned_type')->value !== 'group') {
      return FALSE;
    }

    // Must be pending.
    if ($task->get('status')->value !== 'pending') {
      return FALSE;
    }

    // User must be in the assigned group.
    $group_id = $task->get('assigned_group')->target_id;
    return $this->userInGroup($user, $group_id);
  }

  /**
   * Claim a task for the current user.
   */
  public function claimTask(WorkflowTaskInterface $task, ?AccountInterface $user = NULL): bool {
    $user = $user ?? $this->currentUser;

    if (!$this->canClaim($task, $user)) {
      return FALSE;
    }

    try {
      // Store original group for potential release.
      $original_group = $task->get('assigned_group')->target_id;

      // Update assignment.
      $task->set('assigned_type', 'user');
      $task->set('assigned_user', $user->id());
      $task->set('assigned_group', NULL);
      $task->set('status', 'in_progress');

      // Add revision log.
      if ($task->hasField('revision_log')) {
        $task->setRevisionLogMessage(sprintf(
          'Task claimed by %s (was assigned to group %d)',
          $user->getDisplayName(),
          $original_group
        ));
      }
      $task->setNewRevision(TRUE);
      $task->save();

      $this->logger->info('Task @id claimed by user @user', [
        '@id' => $task->id(),
        '@user' => $user->id(),
      ]);

      return TRUE;
    }
    catch (\Exception $e) {
      $this->logger->error('Failed to claim task @id: @message', [
        '@id' => $task->id(),
        '@message' => $e->getMessage(),
      ]);
      return FALSE;
    }
  }

  /**
   * Mark a task as complete.
   */
  public function completeTask(WorkflowTaskInterface $task, ?AccountInterface $user = NULL): bool {
    $user = $user ?? $this->currentUser;

    // Must be assigned to user.
    if ($task->get('assigned_type')->value !== 'user') {
      return FALSE;
    }

    // Must be current assignee or admin.
    $assigned_user = $task->get('assigned_user')->target_id;
    if ((int) $assigned_user !== (int) $user->id() && !$user->hasPermission('administer workflow tasks')) {
      return FALSE;
    }

    try {
      $task->set('status', 'completed');

      if ($task->hasField('revision_log')) {
        $task->setRevisionLogMessage(sprintf(
          'Task completed by %s',
          $user->getDisplayName()
        ));
      }
      $task->setNewRevision(TRUE);
      $task->save();

      $this->logger->info('Task @id completed by user @user', [
        '@id' => $task->id(),
        '@user' => $user->id(),
      ]);

      // Activate next task in sequence if exists.
      $this->activateNextTask($task);

      return TRUE;
    }
    catch (\Exception $e) {
      $this->logger->error('Failed to complete task @id: @message', [
        '@id' => $task->id(),
        '@message' => $e->getMessage(),
      ]);
      return FALSE;
    }
  }

  /**
   * Release a claimed task back to the group.
   *
   * Note: This requires storing original group somewhere.
   * For now, this is a placeholder.
   */
  public function releaseTask(WorkflowTaskInterface $task, int $group_id): bool {
    try {
      $task->set('assigned_type', 'group');
      $task->set('assigned_group', $group_id);
      $task->set('assigned_user', NULL);
      $task->set('status', 'pending');

      $task->setNewRevision(TRUE);
      $task->save();

      return TRUE;
    }
    catch (\Exception $e) {
      $this->logger->error('Failed to release task @id: @message', [
        '@id' => $task->id(),
        '@message' => $e->getMessage(),
      ]);
      return FALSE;
    }
  }

  /**
   * Activate the next task in the workflow sequence.
   */
  protected function activateNextTask(WorkflowTaskInterface $completed_task): void {
    $node_id = $completed_task->get('node_id')->target_id;
    $current_weight = $completed_task->get('weight')->value;

    // Find next pending task.
    $storage = $this->entityTypeManager->getStorage('workflow_task');
    $query = $storage->getQuery()
      ->accessCheck(FALSE)
      ->condition('node_id', $node_id)
      ->condition('status', 'pending')
      ->condition('weight', $current_weight, '>')
      ->sort('weight', 'ASC')
      ->range(0, 1);

    $ids = $query->execute();

    if (!empty($ids)) {
      $next_task = $storage->load(reset($ids));
      if ($next_task && $next_task->get('assigned_type')->value === 'user') {
        $next_task->set('status', 'in_progress');
        $next_task->save();

        // TODO: Send notification to next assignee.
      }
    }
  }

  /**
   * Check if user is in a group.
   */
  protected function userInGroup(AccountInterface $user, int $group_id): bool {
    try {
      $group = $this->entityTypeManager->getStorage('group')->load($group_id);
      if (!$group) {
        return FALSE;
      }

      $membership_loader = \Drupal::service('group.membership_loader');
      $membership = $membership_loader->load($group, $user);

      return $membership !== NULL;
    }
    catch (\Exception $e) {
      return FALSE;
    }
  }

}
```

---

### src/Controller/MyWorkController.php

```php
<?php

namespace Drupal\avc_work_management\Controller;

use Drupal\avc_work_management\Service\WorkTaskQueryService;
use Drupal\Core\Controller\ControllerBase;
use Drupal\Core\Session\AccountInterface;
use Symfony\Component\DependencyInjection\ContainerInterface;

/**
 * Controller for My Work dashboard.
 */
class MyWorkController extends ControllerBase {

  protected WorkTaskQueryService $taskQuery;

  /**
   * Constructs a MyWorkController.
   */
  public function __construct(WorkTaskQueryService $task_query) {
    $this->taskQuery = $task_query;
  }

  /**
   * {@inheritdoc}
   */
  public static function create(ContainerInterface $container) {
    return new static(
      $container->get('avc_work_management.task_query')
    );
  }

  /**
   * Render the My Work dashboard.
   */
  public function dashboard(): array {
    $user = $this->currentUser();
    $config = $this->config('avc_work_management.settings');

    // Get summary counts by content type.
    $summary = $this->taskQuery->getSummaryCounts($user);

    // Get tasks for each section.
    $sections = [];
    $section_config = $config->get('sections') ?? [];

    foreach ($section_config as $section_id => $section_settings) {
      $tasks = $this->taskQuery->getTasksForSection($section_id, $user);
      $total = $this->taskQuery->countTasks(
        $user,
        NULL,
        $section_settings['status'] ?? NULL,
        $section_settings['assigned_to'] ?? 'user'
      );

      $sections[$section_id] = [
        'id' => $section_id,
        'label' => $section_settings['label'],
        'tasks' => $tasks,
        'total' => $total,
        'limit' => $section_settings['limit'] ?? 10,
        'show_view_all' => ($section_settings['show_view_all'] ?? FALSE) && $total > count($tasks),
        'show_claim' => $section_settings['show_claim'] ?? FALSE,
        'view_all_url' => '/my-work/' . $section_id,
      ];
    }

    // Calculate totals for available section.
    $available_count = $this->taskQuery->countTasks($user, NULL, 'pending', 'group');

    return [
      '#theme' => 'my_work_dashboard',
      '#summary' => $summary,
      '#sections' => $sections,
      '#available_count' => $available_count,
      '#user' => $user,
      '#attached' => [
        'library' => ['avc_work_management/dashboard'],
      ],
      '#cache' => [
        'tags' => $this->taskQuery->getDashboardCacheTags($user),
        'contexts' => ['user'],
        'max-age' => 300, // 5 minutes.
      ],
    ];
  }

  /**
   * Render a specific section (View All page).
   */
  public function section(string $section): array {
    $user = $this->currentUser();
    $config = $this->config('avc_work_management.settings');
    $section_config = $config->get('sections.' . $section);

    if (!$section_config) {
      throw new \Symfony\Component\HttpKernel\Exception\NotFoundHttpException();
    }

    // Get all tasks for this section (no limit).
    $tasks = $this->taskQuery->getTasks(
      $user,
      NULL,
      $section_config['status'] ?? NULL,
      $section_config['assigned_to'] ?? 'user',
      NULL // No limit
    );

    return [
      '#theme' => 'my_work_section',
      '#section' => [
        'id' => $section,
        'label' => $section_config['label'],
        'tasks' => $tasks,
        'show_claim' => $section_config['show_claim'] ?? FALSE,
      ],
      '#attached' => [
        'library' => ['avc_work_management/dashboard'],
      ],
      '#cache' => [
        'tags' => $this->taskQuery->getDashboardCacheTags($user),
        'contexts' => ['user'],
      ],
    ];
  }

  /**
   * Title callback for section pages.
   */
  public function sectionTitle(string $section): string {
    $config = $this->config('avc_work_management.settings');
    $label = $config->get('sections.' . $section . '.label') ?? 'Tasks';
    return 'My Work: ' . $label;
  }

}
```

---

### src/Form/ClaimTaskForm.php

```php
<?php

namespace Drupal\avc_work_management\Form;

use Drupal\avc_work_management\Service\WorkTaskActionService;
use Drupal\Core\Form\ConfirmFormBase;
use Drupal\Core\Form\FormStateInterface;
use Drupal\Core\Url;
use Drupal\workflow_assignment\Entity\WorkflowTaskInterface;
use Symfony\Component\DependencyInjection\ContainerInterface;

/**
 * Form to confirm claiming a task.
 */
class ClaimTaskForm extends ConfirmFormBase {

  protected WorkTaskActionService $taskAction;
  protected ?WorkflowTaskInterface $task = NULL;

  /**
   * Constructs a ClaimTaskForm.
   */
  public function __construct(WorkTaskActionService $task_action) {
    $this->taskAction = $task_action;
  }

  /**
   * {@inheritdoc}
   */
  public static function create(ContainerInterface $container) {
    return new static(
      $container->get('avc_work_management.task_action')
    );
  }

  /**
   * {@inheritdoc}
   */
  public function getFormId() {
    return 'avc_work_management_claim_task_form';
  }

  /**
   * {@inheritdoc}
   */
  public function getQuestion() {
    return $this->t('Claim this task?');
  }

  /**
   * {@inheritdoc}
   */
  public function getDescription() {
    return $this->t('You will become the assignee for this task and it will appear in your Action Needed list.');
  }

  /**
   * {@inheritdoc}
   */
  public function getCancelUrl() {
    return new Url('avc_work_management.my_work');
  }

  /**
   * {@inheritdoc}
   */
  public function getConfirmText() {
    return $this->t('Claim Task');
  }

  /**
   * {@inheritdoc}
   */
  public function buildForm(array $form, FormStateInterface $form_state, WorkflowTaskInterface $workflow_task = NULL) {
    $this->task = $workflow_task;

    if (!$this->taskAction->canClaim($workflow_task)) {
      $this->messenger()->addError($this->t('You cannot claim this task.'));
      return $this->redirect('avc_work_management.my_work');
    }

    // Show task details.
    $form['task_info'] = [
      '#type' => 'container',
      '#attributes' => ['class' => ['claim-task-info']],
    ];

    $form['task_info']['title'] = [
      '#markup' => '<h3>' . $workflow_task->label() . '</h3>',
    ];

    if ($workflow_task->hasField('description') && !$workflow_task->get('description')->isEmpty()) {
      $form['task_info']['description'] = [
        '#markup' => '<p>' . $workflow_task->get('description')->value . '</p>',
      ];
    }

    return parent::buildForm($form, $form_state);
  }

  /**
   * {@inheritdoc}
   */
  public function submitForm(array &$form, FormStateInterface $form_state) {
    if ($this->taskAction->claimTask($this->task)) {
      $this->messenger()->addStatus($this->t('Task claimed successfully. It now appears in your Action Needed list.'));
    }
    else {
      $this->messenger()->addError($this->t('Failed to claim task. Please try again.'));
    }

    $form_state->setRedirectUrl($this->getCancelUrl());
  }

}
```

---

### avc_work_management.module

```php
<?php

/**
 * @file
 * AVC Work Management module.
 */

use Drupal\Core\Routing\RouteMatchInterface;

/**
 * Implements hook_help().
 */
function avc_work_management_help($route_name, RouteMatchInterface $route_match) {
  switch ($route_name) {
    case 'help.page.avc_work_management':
      return '<p>' . t('Provides a My Work dashboard for viewing and managing workflow tasks.') . '</p>';
  }
}

/**
 * Implements hook_theme().
 */
function avc_work_management_theme() {
  return [
    'my_work_dashboard' => [
      'variables' => [
        'summary' => [],
        'sections' => [],
        'available_count' => 0,
        'user' => NULL,
      ],
      'template' => 'my-work-dashboard',
    ],
    'my_work_summary_cards' => [
      'variables' => [
        'summary' => [],
      ],
      'template' => 'my-work-summary-cards',
    ],
    'my_work_task_list' => [
      'variables' => [
        'section' => [],
      ],
      'template' => 'my-work-task-list',
    ],
    'my_work_task_row' => [
      'variables' => [
        'task' => [],
        'show_claim' => FALSE,
      ],
      'template' => 'my-work-task-row',
    ],
    'my_work_section' => [
      'variables' => [
        'section' => [],
      ],
      'template' => 'my-work-section',
    ],
  ];
}
```

---

## Templates

### templates/my-work-dashboard.html.twig

```twig
{#
/**
 * @file
 * My Work Dashboard template.
 *
 * Variables:
 * - summary: Array of content type summaries with counts.
 * - sections: Array of task sections (active, available, upcoming, completed).
 * - available_count: Total available tasks to claim.
 * - user: Current user account.
 */
#}
<div class="my-work-dashboard">

  {# Header #}
  <div class="my-work-header">
    <h1 class="my-work-title">{{ 'My Work'|t }}</h1>
  </div>

  {# Summary Cards by Content Type #}
  <div class="my-work-summary">
    {% for type_id, type_data in summary %}
      <div class="summary-card" style="--card-color: {{ type_data.color }}">
        <div class="summary-card-header">
          <span class="summary-icon">
            {% if type_data.icon == 'file-text' %}
              <span class="icon-doc" aria-hidden="true"></span>
            {% elseif type_data.icon == 'link' %}
              <span class="icon-link" aria-hidden="true"></span>
            {% elseif type_data.icon == 'folder' %}
              <span class="icon-folder" aria-hidden="true"></span>
            {% endif %}
          </span>
          <span class="summary-label">{{ type_data.label }}</span>
        </div>
        <div class="summary-card-body">
          <div class="summary-stat summary-active">
            <span class="stat-icon active-icon" aria-hidden="true"></span>
            <span class="stat-count">{{ type_data.active }}</span>
            <span class="stat-label">{{ 'Active'|t }}</span>
          </div>
          <div class="summary-stat summary-upcoming">
            <span class="stat-icon upcoming-icon" aria-hidden="true"></span>
            <span class="stat-count">{{ type_data.upcoming }}</span>
            <span class="stat-label">{{ 'Upcoming'|t }}</span>
          </div>
          <div class="summary-stat summary-completed">
            <span class="stat-icon completed-icon" aria-hidden="true"></span>
            <span class="stat-count">{{ type_data.completed }}</span>
            <span class="stat-label">{{ 'Completed'|t }}</span>
          </div>
        </div>
      </div>
    {% endfor %}
  </div>

  {# Task Sections #}
  <div class="my-work-sections">
    {% for section_id, section in sections %}
      {% if section.tasks is not empty or section_id == 'available' %}
        <div class="task-section section-{{ section_id }}">
          <div class="section-header">
            <h2 class="section-title">
              {{ section.label }}
              <span class="section-count">({{ section.total }})</span>
            </h2>
            {% if section.show_view_all %}
              <a href="{{ section.view_all_url }}" class="view-all-link">
                {{ 'View All'|t }}
              </a>
            {% endif %}
          </div>

          <div class="section-content">
            {% if section.tasks is empty %}
              <p class="no-tasks">{{ 'No tasks in this section.'|t }}</p>
            {% else %}
              <div class="task-list">
                {% for task_data in section.tasks %}
                  {% include '@avc_work_management/my-work-task-row.html.twig' with {
                    'task': task_data,
                    'show_claim': section.show_claim
                  } %}
                {% endfor %}
              </div>
            {% endif %}
          </div>
        </div>
      {% endif %}
    {% endfor %}
  </div>

</div>
```

---

### templates/my-work-task-row.html.twig

```twig
{#
/**
 * @file
 * Single task row template.
 *
 * Variables:
 * - task: Task data array with:
 *   - title: Task/node title
 *   - node_url: URL to the node
 *   - content_type_label: Human label (Document, Resource, Project)
 *   - content_type_icon: Icon identifier
 *   - status: Task status
 *   - due_date: Due date timestamp
 *   - assigned_label: Who it's assigned to
 *   - completed_date: Completion timestamp
 * - show_claim: Whether to show claim button
 */
#}
<div class="task-row status-{{ task.status }}">

  {# Content type icon #}
  <div class="task-icon" style="color: {{ task.content_type_color }}">
    {% if task.content_type_icon == 'file-text' %}
      <span aria-label="{{ 'Document'|t }}"></span>
    {% elseif task.content_type_icon == 'link' %}
      <span aria-label="{{ 'Resource'|t }}"></span>
    {% elseif task.content_type_icon == 'folder' %}
      <span aria-label="{{ 'Project'|t }}"></span>
    {% endif %}
  </div>

  {# Task title #}
  <div class="task-title">
    {% if task.node_url %}
      <a href="{{ task.node_url }}">{{ task.title }}</a>
    {% else %}
      {{ task.title }}
    {% endif %}
  </div>

  {# Content type label #}
  <div class="task-type">
    {{ task.content_type_label }}
  </div>

  {# Due date or completion date or assigned to #}
  <div class="task-meta">
    {% if task.status == 'completed' and task.completed_date %}
      <span class="completed-date">
        {{ 'Completed'|t }} {{ task.completed_date|date('M j') }}
      </span>
    {% elseif task.due_date %}
      <span class="due-date {% if task.due_date < 'now'|date('U') %}overdue{% endif %}">
        {{ 'Due:'|t }} {{ task.due_date|date('M j') }}
      </span>
    {% elseif task.assigned_type == 'group' %}
      <span class="assigned-group">
        {{ task.assigned_label }}
      </span>
    {% endif %}
  </div>

  {# Action button #}
  <div class="task-action">
    {% if show_claim and task.assigned_type == 'group' %}
      <a href="/my-work/claim/{{ task.task.id }}" class="btn btn-claim">
        {{ 'Claim'|t }}
      </a>
    {% elseif task.node_url %}
      <a href="{{ task.node_url }}" class="btn btn-open">
        {{ 'Open'|t }}
      </a>
    {% endif %}
  </div>

</div>
```

---

### templates/my-work-section.html.twig

```twig
{#
/**
 * @file
 * Full section page (View All).
 */
#}
<div class="my-work-section-page">

  <div class="section-header">
    <h1>{{ section.label }}</h1>
    <a href="/my-work" class="back-link">{{ '← Back to My Work'|t }}</a>
  </div>

  {% if section.tasks is empty %}
    <p class="no-tasks">{{ 'No tasks in this section.'|t }}</p>
  {% else %}
    <div class="task-list task-list-full">
      {% for task_data in section.tasks %}
        {% include '@avc_work_management/my-work-task-row.html.twig' with {
          'task': task_data,
          'show_claim': section.show_claim
        } %}
      {% endfor %}
    </div>
  {% endif %}

</div>
```

---

## CSS

### css/my-work-dashboard.css

```css
/**
 * My Work Dashboard Styles
 */

/* Dashboard Container */
.my-work-dashboard {
  max-width: 1200px;
  margin: 0 auto;
  padding: 20px;
}

.my-work-header {
  margin-bottom: 24px;
}

.my-work-title {
  font-size: 28px;
  font-weight: 600;
  margin: 0;
  color: #333;
}

/* Summary Cards */
.my-work-summary {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
  gap: 16px;
  margin-bottom: 32px;
}

.summary-card {
  background: #fff;
  border-radius: 8px;
  border-left: 4px solid var(--card-color, #4a90d9);
  box-shadow: 0 1px 3px rgba(0, 0, 0, 0.1);
  padding: 16px;
}

.summary-card-header {
  display: flex;
  align-items: center;
  gap: 8px;
  margin-bottom: 12px;
  font-weight: 600;
  color: #333;
}

.summary-card-body {
  display: flex;
  flex-direction: column;
  gap: 8px;
}

.summary-stat {
  display: flex;
  align-items: center;
  gap: 8px;
  font-size: 14px;
}

.stat-icon {
  width: 12px;
  height: 12px;
  border-radius: 50%;
}

.summary-active .stat-icon {
  background: #e74c3c;
}

.summary-upcoming .stat-icon {
  background: #f39c12;
  border: 2px solid #f39c12;
  background: transparent;
}

.summary-completed .stat-icon {
  background: #27ae60;
}

.stat-count {
  font-weight: 600;
  min-width: 24px;
}

.stat-label {
  color: #666;
}

/* Task Sections */
.my-work-sections {
  display: flex;
  flex-direction: column;
  gap: 24px;
}

.task-section {
  background: #fff;
  border-radius: 8px;
  box-shadow: 0 1px 3px rgba(0, 0, 0, 0.1);
  overflow: hidden;
}

.section-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 16px 20px;
  background: #f8f9fa;
  border-bottom: 1px solid #e9ecef;
}

.section-title {
  font-size: 16px;
  font-weight: 600;
  margin: 0;
  color: #333;
}

.section-count {
  font-weight: 400;
  color: #666;
}

.view-all-link {
  font-size: 14px;
  color: #4a90d9;
  text-decoration: none;
}

.view-all-link:hover {
  text-decoration: underline;
}

.section-content {
  padding: 0;
}

.no-tasks {
  padding: 20px;
  text-align: center;
  color: #666;
  font-style: italic;
}

/* Task List */
.task-list {
  display: flex;
  flex-direction: column;
}

.task-row {
  display: grid;
  grid-template-columns: 40px 1fr 100px 140px 80px;
  align-items: center;
  padding: 12px 20px;
  border-bottom: 1px solid #f0f0f0;
  gap: 12px;
}

.task-row:last-child {
  border-bottom: none;
}

.task-row:hover {
  background: #f8f9fa;
}

.task-icon {
  font-size: 20px;
  text-align: center;
}

.task-title {
  font-weight: 500;
}

.task-title a {
  color: #333;
  text-decoration: none;
}

.task-title a:hover {
  color: #4a90d9;
  text-decoration: underline;
}

.task-type {
  font-size: 13px;
  color: #666;
}

.task-meta {
  font-size: 13px;
  color: #666;
}

.due-date.overdue {
  color: #e74c3c;
  font-weight: 500;
}

.task-action {
  text-align: right;
}

.btn {
  display: inline-block;
  padding: 6px 12px;
  font-size: 13px;
  border-radius: 4px;
  text-decoration: none;
  cursor: pointer;
  border: none;
}

.btn-open {
  background: #4a90d9;
  color: #fff;
}

.btn-open:hover {
  background: #357abd;
}

.btn-claim {
  background: #27ae60;
  color: #fff;
}

.btn-claim:hover {
  background: #1e8449;
}

/* Status-specific styling */
.task-row.status-completed {
  opacity: 0.7;
}

.task-row.status-completed .task-title a {
  color: #666;
}

/* Section-specific styling */
.section-active .section-header {
  border-left: 4px solid #e74c3c;
}

.section-available .section-header {
  border-left: 4px solid #27ae60;
}

.section-upcoming .section-header {
  border-left: 4px solid #f39c12;
}

.section-completed .section-header {
  border-left: 4px solid #95a5a6;
}

/* Responsive */
@media (max-width: 768px) {
  .task-row {
    grid-template-columns: 32px 1fr;
    grid-template-rows: auto auto;
  }

  .task-type,
  .task-meta {
    grid-column: 2;
    font-size: 12px;
  }

  .task-action {
    grid-column: 1 / -1;
    text-align: left;
    margin-top: 8px;
  }

  .my-work-summary {
    grid-template-columns: 1fr;
  }
}

/* View All Page */
.my-work-section-page {
  max-width: 1200px;
  margin: 0 auto;
  padding: 20px;
}

.my-work-section-page .section-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin-bottom: 20px;
  padding: 0;
  background: transparent;
  border: none;
}

.back-link {
  color: #4a90d9;
  text-decoration: none;
}

.back-link:hover {
  text-decoration: underline;
}

.task-list-full .task-row {
  background: #fff;
  margin-bottom: 8px;
  border-radius: 4px;
  box-shadow: 0 1px 2px rgba(0, 0, 0, 0.05);
}
```

---

## Installation

```bash
# Enable the module
drush en avc_work_management -y

# Clear cache
drush cr

# Grant permissions
drush role:perm:add authenticated 'access my work dashboard'
drush role:perm:add authenticated 'claim workflow tasks'
```

---

## Testing Checklist

```
[ ] Dashboard loads at /my-work
[ ] Summary cards show correct counts per content type
[ ] Action Needed shows in_progress tasks assigned to me
[ ] Available to Claim shows group tasks I can claim
[ ] Upcoming shows pending tasks assigned to me
[ ] Recently Completed shows my finished tasks
[ ] Claim button works and moves task to my Action Needed
[ ] Open button navigates to the node
[ ] View All pages show full task lists
[ ] Cache invalidates when tasks change
[ ] Mobile responsive layout works
[ ] Permissions restrict access appropriately
```

---

## Future Enhancements

1. **Filters** - Filter by content type within sections
2. **Sorting** - Sort by due date, title, etc.
3. **Bulk actions** - Claim multiple tasks at once
4. **Notifications** - Email/in-app when new tasks assigned
5. **Due date warnings** - Highlight approaching deadlines
6. **Progress bar** - Visual workflow completion indicator
7. **Quick complete** - Complete task without opening node
8. **Export** - Download task list as CSV
