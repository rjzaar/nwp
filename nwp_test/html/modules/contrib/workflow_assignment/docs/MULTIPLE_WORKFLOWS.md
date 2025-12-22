# Multiple Workflow Assignments - User Guide

## Overview

The Workflow Assignment module now supports **multiple workflow assignments** per content item, with all workflows displayed in a **table format** on the dedicated Workflow tab.

## Key Features

### ✅ Multiple Workflows
- Assign unlimited workflows to any content item
- Each workflow appears as a separate row in the table
- Mix different workflow types (public, private, etc.)

### ✅ Table Display
- Clean, organized table view
- One row per workflow assignment
- All workflow details visible at a glance
- Color-coded destination badges

### ✅ Workflow Tab Only
- Workflow information **only** appears on the Workflow tab
- Not displayed in content view or edit form
- Dedicated space for workflow management
- Clean separation of concerns

## Workflow Tab Table View

### Table Columns

When you view the Workflow tab, you'll see a table with these columns:

1. **Workflow Name** - The name of the workflow
2. **Description** - Brief description (if provided)
3. **Assigned Users** - Comma-separated list of users
4. **Assigned Groups** - Comma-separated list of groups
5. **Resource Locations** - Where resources are stored
6. **Destination Locations** - Color-coded badges (Public, Private, etc.)

### Example Table View

```
╔════════════════╦═══════════════╦═══════════════╦════════════╦═══════════════╦═══════════════╗
║ Workflow Name  ║ Description   ║ Assigned Users║ Groups     ║ Resources     ║ Destinations  ║
╠════════════════╬═══════════════╬═══════════════╬════════════╬═══════════════╬═══════════════╣
║ Blog Publishing║ Public blog   ║ John, Jane    ║ Editors    ║ Google Drive  ║ 📍 Public     ║
║                ║ workflow      ║               ║            ║               ║               ║
╠════════════════╬═══════════════╬═══════════════╬════════════╬═══════════════╬═══════════════╣
║ Internal Review║ Private docs  ║ Manager, Team ║ Admin Team ║ SharePoint    ║ 📍 Private    ║
║                ║               ║ Lead          ║            ║               ║               ║
╠════════════════╬═══════════════╬═══════════════╬════════════╬═══════════════╬═══════════════╣
║ Customer Portal║ External      ║ Sales Team    ║ -          ║ CRM System    ║ 📍 Public     ║
║                ║ content       ║               ║            ║               ║ 📍 Customer   ║
╚════════════════╩═══════════════╩═══════════════╩════════════╩═══════════════╩═══════════════╝
```

## Assigning Multiple Workflows

### Method 1: From Workflow Tab (Recommended)

1. Navigate to your content
2. Click the **Workflow** tab
3. Click **"Manage Workflows"** button
4. You'll see a **checkbox list** of all available workflows
5. Check multiple workflows to assign
6. Uncheck to remove workflows
7. Click **Save**

### Method 2: From Edit Form

1. Edit your content
2. Find the **Workflow List** field
3. Check multiple workflows in the checkbox list
4. Save the content
5. View the **Workflow tab** to see the table

## Use Cases

### Use Case 1: Blog Post with Multiple Audiences

**Scenario:** A blog post needs both internal review and public publication

**Workflows Assigned:**
- Internal Review Workflow (Private)
- Blog Publishing Workflow (Public)

**Table Display:**
```
Row 1: Internal Review | Private review | Editors | Admin Team | Confluence | 📍 Private
Row 2: Blog Publishing | Public blog | Writers | Marketing  | CMS       | 📍 Public
```

### Use Case 2: Product Launch Content

**Scenario:** Product documentation needs multiple distribution channels

**Workflows Assigned:**
- Internal Documentation (Private)
- Customer Help Center (Public)
- Partner Portal (Partner Access)

**Table Display:**
```
Row 1: Internal Documentation | Internal use | Tech Writers | Product Team | Wiki      | 📍 Private
Row 2: Customer Help Center  | Public help   | Support Team | -            | Help Desk | 📍 Public
Row 3: Partner Portal        | Partner docs  | Partner Mgmt | Partners     | Portal    | 📍 Partner
```

### Use Case 3: Marketing Campaign

**Scenario:** Campaign content has different workflows for different stages

**Workflows Assigned:**
- Draft Review (Private)
- Approval Process (Private)
- Publication (Public)

**Table Display:**
```
Row 1: Draft Review      | Initial review | Writers    | Creative | Drive | 📍 Private
Row 2: Approval Process  | Final approval | Managers   | Legal    | DAM   | 📍 Private
Row 3: Publication       | Go live        | Publishers | -        | CMS   | 📍 Public
```

## Benefits of Multiple Workflows

### 1. Flexible Content Management
- Assign different workflows for different purposes
- Track multiple processes simultaneously
- Separate internal and external workflows

### 2. Better Organization
- Clear table view shows all assignments
- Easy to scan and understand
- One place to see everything

### 3. Team Collaboration
- Different teams can have different workflows
- No confusion about responsibilities
- Clear visibility of all assignments

### 4. Process Tracking
- Track content through multiple stages
- See all active workflows at once
- Manage complex processes easily

## Managing Multiple Workflows

### Adding Workflows

1. Go to Workflow tab
2. Click "Manage Workflows"
3. Check additional workflows
4. Save

### Removing Workflows

1. Go to Workflow tab
2. Click "Manage Workflows"
3. Uncheck workflows to remove
4. Save

### Viewing All Assignments

1. Go to Workflow tab
2. See complete table of all workflows
3. Each row shows one workflow
4. Scroll to see all columns

## Table Features

### Responsive Design
- Table adapts to screen size
- Horizontal scroll on small screens
- Readable on all devices

### Visual Indicators
- **Color-coded destinations**
  - Blue = Public
  - Red = Private
  - Custom colors for custom destinations
- **Icons** - 📍 for destinations
- **Hover effects** - Rows highlight on hover

### Data Display
- **Names in bold** - Easy to identify workflows
- **Comma-separated lists** - Clean user/group lists
- **Badges** - Destination locations stand out
- **Dash (-)** - Empty fields clearly marked

## Tips and Best Practices

### Naming Workflows
✅ Use descriptive names that indicate purpose
✅ Include target audience (Internal, Public, Partners)
✅ Keep names short but meaningful

### Assigning Workflows
✅ Assign only relevant workflows
✅ Don't over-assign - keep it manageable
✅ Review assignments periodically

### Using the Table
✅ Check the Workflow tab regularly
✅ Use table to track progress
✅ Review all workflows before publishing

## Technical Details

### Field Configuration
- **Field Name:** `field_workflow_list`
- **Type:** String (unlimited)
- **Cardinality:** -1 (unlimited values)
- **Storage:** Multi-value field

### Display Settings
- **View Display:** Hidden (not shown in content view)
- **Edit Display:** Checkboxes widget
- **Workflow Tab:** Table format

### Data Structure
```php
// Multiple workflow IDs stored as array
$node->get('field_workflow_list') = [
  ['value' => 'blog_publishing'],
  ['value' => 'internal_review'],
  ['value' => 'partner_portal'],
];
```

## Upgrading from Single Workflow

If you're upgrading from the previous version:

1. **Run update hooks:**
   ```bash
   drush updatedb -y
   drush cr
   ```

2. **Existing assignments preserved:**
   - Your single workflow remains assigned
   - Field now allows multiple workflows
   - Add more workflows as needed

3. **New interface:**
   - Checkboxes instead of dropdown
   - Table view on Workflow tab
   - Same data, better display

## API Usage

### Getting All Workflows

```php
$node = \Drupal\node\Entity\Node::load(123);

// Get all workflow IDs
$workflow_ids = [];
foreach ($node->get('field_workflow_list') as $item) {
  $workflow_ids[] = $item->value;
}

// Load workflows
$workflows = \Drupal::entityTypeManager()
  ->getStorage('workflow_list')
  ->loadMultiple($workflow_ids);
```

### Adding a Workflow

```php
$node = \Drupal\node\Entity\Node::load(123);

// Get current workflows
$current = [];
foreach ($node->get('field_workflow_list') as $item) {
  $current[] = $item->value;
}

// Add new workflow
$current[] = 'new_workflow_id';

// Set and save
$node->set('field_workflow_list', $current);
$node->save();
```

### Removing a Workflow

```php
$node = \Drupal\node\Entity\Node::load(123);

// Get current workflows
$current = [];
foreach ($node->get('field_workflow_list') as $item) {
  $current[] = $item->value;
}

// Remove specific workflow
$current = array_diff($current, ['workflow_to_remove']);

// Set and save
$node->set('field_workflow_list', array_values($current));
$node->save();
```

## Troubleshooting

### Table Not Showing
**Problem:** Workflow tab is empty
**Solution:**
- Check if workflows are assigned
- Clear cache: `drush cr`
- Check permissions

### Can't Assign Multiple
**Problem:** Only one workflow can be selected
**Solution:**
- Run update: `drush updatedb`
- Check field cardinality
- Clear cache

### Workflows Not in Table
**Problem:** Assigned workflows don't appear
**Solution:**
- Verify workflow exists
- Check workflow hasn't been deleted
- Clear entity cache

## Summary

The multiple workflow system provides:

✅ **Unlimited assignments** - No limit on workflows per content  
✅ **Table display** - Clear, organized view  
✅ **Tab-only display** - Clean separation  
✅ **Easy management** - Simple checkbox interface  
✅ **Better tracking** - See all workflows at once  

**Use the Workflow tab to see your complete workflow table!**

---

**Version:** 2.1  
**Feature:** Multiple Workflows  
**Display:** Table Format  
**Location:** Workflow Tab Only
