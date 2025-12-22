# CHANGELOG - Workflow Assignment Module

## Version 3.0 - Streamlined Single Assignment Model

### 🎯 Major Breaking Changes

#### Single Assignment Per Workflow
- **REMOVED:** Multiple users, groups, and destination arrays
- **ADDED:** Single assignment model with `assigned_type` and `assigned_id`
- Each workflow can now be assigned to ONE entity only:
  - User (individual assignment)
  - Group (team assignment) 
  - Destination Location (taxonomy term)

#### Removed Resource Locations
- **REMOVED:** Resource location vocabulary and all related code
- **REMOVED:** `resource_tags` field from entity
- Simplified workflow model focusing on assignment only

### ✨ New Features

#### Comments Field
- **NEW:** Comments field added to workflows
- Expandable display in table view
- Support for detailed workflow notes

#### Color-Coded Assignments
- **Green:** User assignments (#d4edda)
- **Blue:** Group assignments (#d1ecf1)
- **Orange:** Destination assignments (#fff3cd)

#### Expandable Table Cells
- Description and Comments cells expand on click
- Shows truncated text (50 characters) by default
- Infrastructure ready for inline editing (double-click)

### 🎨 UI/UX Improvements

#### Simplified Table Display
- **4 columns:** Name, Description, Assigned, Comments
- Single "Assigned" column replaces 3 separate columns
- Cleaner, more focused interface
- Better mobile responsiveness

#### JavaScript Enhancements
- NEW: `workflow-tab.js` for interactive behaviors
- Click to expand/collapse long text
- Smooth transitions and visual feedback
- Ready for AJAX inline editing

### 📁 Technical Changes

#### Entity Structure
```php
// Old structure (removed)
protected $assigned_users = [];
protected $assigned_groups = [];
protected $resource_tags = [];
protected $destination_tags = [];

// New structure
protected $assigned_type;   // 'user', 'group', or 'destination'
protected $assigned_id;     // ID of the assigned entity
protected $comments;        // Text field for notes
```

#### New Methods
- `getAssignment()` - Returns array with type and ID
- `setAssignment($type, $id)` - Sets single assignment
- `getAssignedLabel()` - Gets human-readable label
- `getComments()` / `setComments()` - Manage comments

#### Templates
- **workflow-tab-content.html.twig** - Main table display
- **workflow-info-block.html.twig** - Block display format

### 🔄 Migration

#### Update Hook 9003
Automatically converts existing data:
1. Takes first user if multiple were assigned
2. Falls back to first group if no users
3. Falls back to first destination if no users/groups
4. Adds empty comments field
5. Removes old array fields

### 📦 Files Changed/Added

#### New Files
- `js/workflow-tab.js` - JavaScript behaviors
- `templates/workflow-tab-content.html.twig` - Tab template
- `templates/workflow-info-block.html.twig` - Block template

#### Modified Files
- `src/Entity/WorkflowList.php` - Complete restructure
- `src/Controller/NodeWorkflowController.php` - Template-based
- `src/Form/WorkflowListForm.php` - Radio button selection
- `src/Form/QuickEditWorkflowForm.php` - Single assignment
- `css/workflow-tab.css` - Color coding & expandable cells
- `workflow_assignment.libraries.yml` - Added JS
- `workflow_assignment.install` - Migration hooks
- All other form and list builder files updated

### 🚀 Installation

#### Fresh Install
```bash
drush en workflow_assignment -y
drush cr
```

#### Upgrade from v2.x
```bash
drush updatedb -y
drush cr
```

### ⚠️ Breaking Changes

1. **Data Model:** Complete change from arrays to single assignment
2. **Resource Locations:** Completely removed - no migration path
3. **API Changes:** All methods for multiple assignments removed
4. **Template Variables:** Different structure in templates

### 💡 Future Enhancements

Planned for v3.1:
- [ ] AJAX inline editing for description/comments
- [ ] Workflow status field
- [ ] Assignment history tracking
- [ ] Email notifications
- [ ] Bulk operations
- [ ] CSV export

---

**Version:** 3.0  
**Date:** November 2025  
**Drupal:** 10.x / 11.x  
**PHP:** 8.0+  
**Status:** Production Ready
