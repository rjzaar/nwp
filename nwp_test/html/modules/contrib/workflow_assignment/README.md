# Workflow Assignment Module - Improved Version

A streamlined Drupal 10+ module that provides a flexible workflow system with single assignment per workflow and color-coded display.

## 🆕 Key Features

### Single Assignment Model
- Each workflow can be assigned to **ONE** entity:
  - **User** (Green) - Individual user assignment
  - **Group** (Blue) - Group assignment (requires Group module)
  - **Destination Location** (Orange) - Destination taxonomy term

### Enhanced Table Display
- **Streamlined columns**: Workflow Name, Description, Assigned, Comments
- **Color-coded assignments**: Visual distinction by type
- **Expandable cells**: Click to expand description and comments
- **Inline editing**: Double-click description/comments to edit (future enhancement)

### No Resource Locations
- Simplified model - resource locations removed
- Focus on assignment and destination

## Installation

```bash
# Copy module to Drupal
cp -r workflow_assignment /path/to/drupal/modules/custom/

# Enable module
drush en workflow_assignment -y

# Clear cache
drush cr

# Run database updates (if upgrading)
drush updatedb -y
```

## Configuration

### Step 1: Enable Content Types

1. Navigate to: `/admin/config/workflow/workflow-assignment`
2. Select content types for workflow support
3. Save configuration

### Step 2: Create Destination Locations

1. Navigate to: `/admin/structure/taxonomy/manage/destination_locations`
2. Default terms created:
   - Public
   - Private
3. Add custom destinations as needed

### Step 3: Create Workflows

1. Navigate to: `/admin/structure/workflow-list`
2. Click "Add Workflow List"
3. Fill in:
   - **Name**: Workflow name
   - **Description**: Detailed description (expandable in table)
   - **Assignment Type**: Choose User, Group, or Destination
   - **Assignment**: Select the specific entity
   - **Comments**: Additional notes (expandable in table)
4. Save

## Usage

### Viewing Workflows

Navigate to any content with workflows enabled and click the "Workflow" tab.

**Table columns:**
- **Workflow Name**: Bold display of workflow name
- **Description**: Truncated with expand on click
- **Assigned**: Color-coded entity (Green=User, Blue=Group, Orange=Destination)
- **Comments**: Truncated with expand on click

### Color Coding

```css
/* Green for Users */
.assigned-user {
  background: #d4edda;
  color: #155724;
}

/* Blue for Groups */
.assigned-group {
  background: #d1ecf1;
  color: #0c5460;
}

/* Orange for Destinations */
.assigned-destination {
  background: #fff3cd;
  color: #856404;
}
```

### Expandable Cells

- **Single Click**: Expand/collapse to see full text
- **Double Click**: Enter edit mode (when implemented with AJAX)
- **Visual Indicator**: Arrow shows expandable content

## API Usage

### Create Workflow with Single Assignment

```php
use Drupal\workflow_assignment\Entity\WorkflowList;

// Create workflow assigned to user
$workflow = WorkflowList::create([
  'id' => 'user_workflow',
  'label' => 'User Review Workflow',
  'description' => 'Workflow for user review process',
  'comments' => 'Requires manager approval',
]);
$workflow->setAssignment('user', 5); // User ID 5
$workflow->save();

// Create workflow assigned to group
$workflow = WorkflowList::create([
  'id' => 'group_workflow',
  'label' => 'Team Workflow',
]);
$workflow->setAssignment('group', 2); // Group ID 2
$workflow->save();

// Create workflow assigned to destination
$workflow = WorkflowList::create([
  'id' => 'public_workflow',
  'label' => 'Public Publishing',
]);
$workflow->setAssignment('destination', 1); // Term ID 1 (Public)
$workflow->save();
```

### Get Assignment Information

```php
$workflow = WorkflowList::load('user_workflow');

// Get assignment type and ID
$type = $workflow->getAssignedType(); // 'user'
$id = $workflow->getAssignedId();     // 5

// Get human-readable label
$label = $workflow->getAssignedLabel(); // 'John Smith'

// Get comments
$comments = $workflow->getComments();
```

## JavaScript Behaviors

The module includes JavaScript for expandable cells:

```javascript
// Expandable cells behavior
Drupal.behaviors.workflowExpandableCells = {
  attach: function (context, settings) {
    $('.expandable-cell', context).once('expandable-cell').each(function () {
      // Click to expand/collapse
      // Double-click to edit (future)
    });
  }
};
```

## Module Structure

```
workflow_assignment/
├── src/
│   ├── Entity/
│   │   └── WorkflowList.php              # Single assignment entity
│   ├── Controller/
│   │   └── NodeWorkflowController.php    # Table display controller
│   ├── Form/
│   │   ├── WorkflowListForm.php          # Create/edit with single assignment
│   │   ├── QuickEditWorkflowForm.php     # Quick edit form
│   │   ├── NodeAssignWorkflowForm.php    # Assign to content
│   │   └── WorkflowAssignmentSettingsForm.php
│   ├── Plugin/
│   │   └── Field/
│   │       └── FieldWidget/
│   │           └── WorkflowListWidget.php
│   └── WorkflowListListBuilder.php       # Admin list display
├── css/
│   └── workflow-tab.css                  # Color coding & expandable cells
├── js/
│   └── workflow-tab.js                   # Expandable behavior
├── config/
│   └── schema/
│       └── workflow_assignment.schema.yml
├── workflow_assignment.info.yml
├── workflow_assignment.module
├── workflow_assignment.install
├── workflow_assignment.routing.yml
├── workflow_assignment.permissions.yml
├── workflow_assignment.links.task.yml
└── workflow_assignment.libraries.yml
```

## Theming

### CSS Classes

```css
/* Assignment color coding */
.assigned-user { }      /* Green */
.assigned-group { }     /* Blue */
.assigned-destination { } /* Orange */

/* Expandable cells */
.expandable-cell { }
.expandable-cell.expanded { }
.expandable-cell.editing { }

/* Table styling */
.workflow-assignments-table { }
```

## Permissions

- **administer workflow lists**: Full admin access
- **assign workflow lists to content**: Assign workflows
- **view workflow list assignments**: View workflow tab

## Troubleshooting

### Workflows not appearing
- Check permissions
- Clear cache: `drush cr`
- Verify content type enabled

### Colors not showing
- Check CSS is loaded
- Verify assignment type is set correctly

### Expandable cells not working
- Check JavaScript is loaded
- Verify jQuery dependencies

## Future Enhancements

- [ ] AJAX inline editing for description and comments
- [ ] Workflow status tracking
- [ ] Assignment history
- [ ] Email notifications
- [ ] Bulk operations

## Requirements

- Drupal 10.x or 11.x
- PHP 8.0+
- jQuery (core)
- Taxonomy module (core)
- Optional: Group module

## License

GPL-2.0-or-later
