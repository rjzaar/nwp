# Updated Architecture - Both Content Entities

## You're Absolutely Right!

Both `workflow_template` and `workflow_assignment` should be **content entities** because:

1. ✅ **Templates can be improved** - Users need to edit and refine templates
2. ✅ **Need revision tracking on templates** - See how templates evolved
3. ✅ **User-managed content** - Not just admin config
4. ✅ **Same interface for both** - Consistent UX

## Final Architecture

```
┌──────────────────────────────────────────┐
│   workflow_template                      │  ← Content Entity
│   (Content Entity - Can be improved)     │     (Database)
├──────────────────────────────────────────┤
│ - id: 123                                │
│ - vid: 1 (revision)                      │
│ - name: "Editorial Process"              │
│ - description: "..."                     │
│ - assignments: [                         │  ← References prototype assignments
│     workflow_assignment #456,            │
│     workflow_assignment #457,            │
│     workflow_assignment #458             │
│   ]                                      │
│ - created: timestamp                     │
│ - changed: timestamp                     │
└──────────────────────────────────────────┘
            │
            │ When applied to content
            │ creates copies ↓
            │
┌──────────────────────────────────────────┐
│   workflow_assignment (copies)           │  ← Content Entity
│   (Content Entity - Individual work)     │     (Database)
├──────────────────────────────────────────┤
│ Copy from template assignment #456:      │
│ - id: 789                                │
│ - job_number: "ED-001"                   │
│ - title: "Initial Review"                │
│ - assigned_type: "user"                  │
│ - assigned_user: 5                       │
│ - completion: "proposed"                 │
├──────────────────────────────────────────┤
│ Copy from template assignment #457:      │
│ - id: 790                                │
│ - ...                                    │
└──────────────────────────────────────────┘
            │
            │ Referenced by node
            │ via entity_reference ↓
            │
┌──────────────────────────────────────────┐
│   Node (Content)                         │
├──────────────────────────────────────────┤
│ - nid: 999                               │
│ - title: "My Article"                    │
│ - field_workflow_list: [                 │
│     789,  ← workflow_assignment copy     │
│     790,  ← workflow_assignment copy     │
│   ]                                      │
└──────────────────────────────────────────┘
```

## How Templates Work

### 1. Creating a Template

```
User creates "Editorial Process" template:
├─ Creates workflow_template entity (id: 123)
├─ Creates prototype workflow_assignment entities:
│  ├─ Assignment #456: "Initial Review"
│  ├─ Assignment #457: "Copy Edit"
│  └─ Assignment #458: "Final Approval"
└─ Template references [456, 457, 458]
```

### 2. Applying Template to Content

```
User applies template #123 to Article #999:
├─ Template loads its assignments [456, 457, 458]
├─ Creates COPIES (not references):
│  ├─ Copy #456 → New assignment #789
│  ├─ Copy #457 → New assignment #790
│  └─ Copy #458 → New assignment #791
├─ Article references [789, 790, 791]
└─ Each copy can be edited independently
```

### 3. Improving the Template

```
User realizes "Legal Review" is missing:
├─ Edit template #123 (creates revision v2)
├─ Add new prototype assignment #459: "Legal Review"
├─ Template now references [456, 457, 458, 459]
└─ Revision history shows:
   ├─ v2: Added Legal Review
   └─ v1: Original 3 assignments

Next time template is applied:
└─ Creates 4 copies (including Legal Review)
```

## Benefits of Both Being Content Entities

### For workflow_template

✅ **Revisions** - Track improvements over time
```
Editorial Process Template
├─ v1: Initial version (3 assignments)
├─ v2: Added Legal Review (4 assignments)
└─ v3: Updated descriptions
```

✅ **Editable** - Users can refine templates
```
User: "This template needs a QA step"
→ Edit template → Add QA assignment → Save
```

✅ **User-owned** - Created by content editors
```
Editor creates "Quick Blog Post" template
└─ Lightweight workflow for simple posts
```

✅ **Views integration** - List/filter templates
```
View: Popular Templates
├─ Most used
├─ Recently updated
└─ By author
```

### For workflow_assignment

✅ **Revisions** - Track all status changes
✅ **Editable** - Modify per content item
✅ **Independent** - Each copy stands alone
✅ **Trackable** - Who changed what when

## Database Schema

### workflow_template Tables

```sql
-- Base table
CREATE TABLE workflow_template (
  id INT PRIMARY KEY AUTO_INCREMENT,
  vid INT,  -- Current revision ID
  uuid VARCHAR(128),
  uid INT,  -- Author
  name VARCHAR(255),
  created INT,
  changed INT
);

-- Revision table
CREATE TABLE workflow_template_revision (
  id INT,
  vid INT PRIMARY KEY AUTO_INCREMENT,
  revision_uid INT,
  revision_timestamp INT,
  revision_log TEXT
);

-- Field data
CREATE TABLE workflow_template_field_data (
  id INT,
  vid INT,
  description TEXT
);

-- Reference to prototype assignments
CREATE TABLE workflow_template__assignments (
  entity_id INT,  -- Template ID
  assignments_target_id INT,  -- workflow_assignment ID
  delta INT
);
```

### workflow_assignment Tables

```sql
-- (Same as before)
CREATE TABLE workflow_assignment (
  id INT PRIMARY KEY AUTO_INCREMENT,
  vid INT,
  job_number VARCHAR(50),
  title VARCHAR(255),
  -- ... all other fields
);
```

## Shared Interface Pattern

Both entities can use similar form interfaces:

### Template Builder Interface

```php
/**
 * Form for building/editing workflow templates.
 */
class WorkflowTemplateForm extends ContentEntityForm {
  
  public function form(array $form, FormStateInterface $form_state) {
    $form = parent::form($form, $form_state);
    
    /** @var \Drupal\workflow_assignment\Entity\WorkflowTemplate $template */
    $template = $this->entity;
    
    // Basic info
    $form['name'] = [...];
    $form['description'] = [...];
    
    // Assignment builder
    $form['assignments'] = [
      '#type' => 'container',
      '#title' => $this->t('Assignments'),
    ];
    
    // Load current assignments
    $assignments = $template->getAssignments();
    
    foreach ($assignments as $delta => $assignment) {
      $form['assignments'][$delta] = [
        '#type' => 'details',
        '#title' => $assignment->label(),
        '#open' => FALSE,
      ];
      
      // Embedded assignment form (reusable!)
      $form['assignments'][$delta] += $this->buildAssignmentFields($assignment);
    }
    
    // Add more button
    $form['assignments']['add_more'] = [
      '#type' => 'submit',
      '#value' => $this->t('Add assignment'),
      '#submit' => ['::addMoreAssignment'],
    ];
    
    return $form;
  }
  
  /**
   * Reusable assignment fields builder.
   */
  protected function buildAssignmentFields($assignment) {
    return [
      'job_number' => [...],
      'title' => [...],
      'description' => [...],
      'assigned_type' => [...],
      'assigned_user' => [...],
      'assigned_group' => [...],
      'assigned_destination' => [...],
    ];
  }
}
```

### Same Interface for Direct Assignment Creation

```php
/**
 * Form for creating workflow assignments directly.
 */
class WorkflowAssignmentForm extends ContentEntityForm {
  
  public function form(array $form, FormStateInterface $form_state) {
    $form = parent::form($form, $form_state);
    
    // Uses the SAME field structure as template builder!
    $form += $this->buildAssignmentFields($this->entity);
    
    return $form;
  }
  
  // Can reuse the same helper method
  protected function buildAssignmentFields($assignment) {
    // Same implementation as WorkflowTemplateForm
  }
}
```

## Use Cases

### Use Case 1: Create Reusable Template

```
Editor creates "Standard Article Review" template:
1. Go to /workflow-template/add
2. Name: "Standard Article Review"
3. Add 4 assignments:
   - Initial Draft Review
   - Copy Edit
   - Fact Check
   - Final Approval
4. Save template (id: 100)
5. Template has 4 prototype assignments (ids: 201-204)
```

### Use Case 2: Apply Template to Content

```
Writer works on article:
1. Create article "Climate Change Report"
2. Click "Apply Template" on Workflow tab
3. Select "Standard Article Review"
4. System creates 4 copies:
   - 301: Initial Draft Review
   - 302: Copy Edit
   - 303: Fact Check
   - 304: Final Approval
5. Article references [301, 302, 303, 304]
6. Writer can now work through each assignment
```

### Use Case 3: Improve Template

```
Editor realizes templates need SEO review:
1. Edit template #100 (creates revision v2)
2. Add 5th assignment: "SEO Review"
3. Save template
4. Next time template is applied:
   → Creates 5 copies (including SEO Review)
5. Existing content keeps their 4 assignments
6. New content gets all 5 assignments
```

### Use Case 4: Custom Workflow for Special Content

```
Writer has unique article needs:
1. Create article
2. Don't use template
3. Add assignments manually:
   - Click "Add Assignment"
   - Create custom "Expert Review"
   - Create custom "Legal Clearance"
4. Completely custom workflow for this one article
```

## Revision Tracking

### Template Revisions

```
Editorial Process Template (id: 123)

v1 (2025-01-01): Created
├─ 3 assignments
└─ "Initial template"

v2 (2025-02-15): Added Legal Review
├─ 4 assignments
└─ "Added legal review step"

v3 (2025-03-20): Improved descriptions
├─ 4 assignments
└─ "Clarified assignment descriptions"
```

### Assignment Revisions

```
Assignment "Initial Review" (id: 789)

v1 (2025-01-05): Created from template
├─ completion: proposed
└─ Created by: editor

v2 (2025-01-07): Accepted
├─ completion: accepted
├─ comments: "Looks good"
└─ Changed by: reviewer

v3 (2025-01-09): Completed
├─ completion: completed
├─ comments: "Published"
└─ Changed by: publisher
```

## URLs

```
Templates:
├─ /admin/structure/workflow-template (list)
├─ /workflow-template/add (create)
├─ /workflow-template/123 (view)
├─ /workflow-template/123/edit (edit)
└─ /workflow-template/123/revisions (history)

Assignments:
├─ /workflow-assignment/789 (view)
├─ /workflow-assignment/789/edit (edit)
└─ /workflow-assignment/789/revisions (history)

On Content:
├─ /node/999/workflow (tab)
├─ /node/999/workflow/apply-template (apply)
└─ /node/999/workflow/add (add single)
```

## Permissions

```yaml
# Template permissions
create workflow templates:
  title: 'Create workflow templates'

edit own workflow templates:
  title: 'Edit own workflow templates'

edit any workflow templates:
  title: 'Edit any workflow templates'

delete own workflow templates:
  title: 'Delete own workflow templates'

delete any workflow templates:
  title: 'Delete any workflow templates'

view workflow templates:
  title: 'View workflow templates'

# Assignment permissions (as before)
create workflow assignments:
  title: 'Create workflow assignments'
# ... etc
```

## Summary

### Both Are Content Entities ✅

**workflow_template:**
- ✅ User-editable
- ✅ Revisionable
- ✅ Can be improved over time
- ✅ References prototype assignments
- ✅ Creates copies when applied

**workflow_assignment:**
- ✅ Individual work items
- ✅ Revisionable
- ✅ Per-content copies
- ✅ Fully independent
- ✅ Track completion status

### Benefits

1. **Consistency** - Both use content entity patterns
2. **Revisions** - Full history on both
3. **Flexibility** - Templates can evolve
4. **Shared Interface** - Same form builder
5. **User-friendly** - Editors manage both

### Key Difference from Config Entities

**Config entities are for:**
- Site structure (content types, views)
- Rarely changed
- Admin-only
- Exported to git

**Content entities are for:**
- User-managed data
- Frequently edited
- Can evolve
- Database storage

**Your templates are user-managed and can be improved** → Content entities! ✅

---

This is the correct architecture for your requirements!
