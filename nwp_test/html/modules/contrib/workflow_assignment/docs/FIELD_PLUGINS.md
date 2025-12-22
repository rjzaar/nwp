# Field Plugins - Technical Documentation

## Overview

The Workflow Assignment module includes custom field plugins for displaying and editing workflow information on content.

## Field Formatter: WorkflowInfoFormatter

### Purpose
Displays workflow information in a formatted, user-friendly way when viewing content.

### Location
`src/Plugin/Field/FieldFormatter/WorkflowInfoFormatter.php`

### Features
- Automatically loads workflow entity from field value
- Renders using Twig template
- Shows all workflow details (users, groups, locations, destinations)
- Color-coded destination display
- Professional styling

### Usage

#### Automatic (Default)
When you enable a content type for workflows, the formatter is automatically configured for the default view mode.

#### Manual Configuration
1. Go to: `/admin/structure/types/manage/[content-type]/display`
2. Find the "Workflow List" field
3. Change format to "Workflow Information"
4. Save

### Template
The formatter uses: `templates/workflow-info-block.html.twig`

### CSS
Styled by: `css/workflow-tab.css` (included via library)

## Field Widget: WorkflowListWidget

### Purpose
Enhanced dropdown for selecting workflows when editing content.

### Location
`src/Plugin/Field/FieldWidget/WorkflowListWidget.php`

### Features
- Dropdown list of all available workflows
- Shows destination information in parentheses
- Example: "Marketing Campaign (Public, Private)"
- Link to create new workflows
- Clear "None" option
- Helpful description text

### Usage

#### Automatic (Default)
Automatically configured when content type is enabled for workflows.

#### Manual Configuration
1. Go to: `/admin/structure/types/manage/[content-type]/form-display`
2. Find the "Workflow List" field
3. Change widget to "Workflow List Selector"
4. Save

### Display Format

```
Workflow List: [Select dropdown ▼]

Options:
- None -
Marketing Campaign (Public)
Product Launch (Public, Private)
Internal Docs (Private)
Newsletter Workflow (Public, Customer Portal)

Need a new workflow? Create one here.
```

## Template: workflow-info-block.html.twig

### Location
`templates/workflow-info-block.html.twig`

### Purpose
Renders workflow information when displayed via field formatter.

### Available Variables
- `workflow` - The WorkflowList entity
- `node` - The node entity (optional)

### Sections Displayed
1. **Workflow Name** (always shown)
2. **Description** (if provided)
3. **Assigned Users** (if any)
4. **Assigned Groups** (if any)
5. **Resource Locations** (if any)
6. **Destination Locations** (if any) - **Color-coded**

### Customization

You can override this template in your theme:

```
your_theme/
  templates/
    workflow-info-block.html.twig
```

## CSS Styling

### Field Formatter Classes

```css
/* Main container */
.workflow-info-block

/* Header */
.workflow-info-header h4

/* Description */
.workflow-info-description

/* Each section */
.workflow-info-section
.workflow-info-section--destinations

/* Lists */
.workflow-info-list
.workflow-info-list--destinations

/* Destination badges */
.destination-badge
.destination-badge--public
.destination-badge--private
```

### Styling Example

The field formatter displays like this:

```
╔═══════════════════════════════════╗
║ Workflow: Marketing Campaign      ║
╠═══════════════════════════════════╣
║                                   ║
║ Workflow description here...      ║
║                                   ║
║ ASSIGNED USERS:                   ║
║ • John Smith                      ║
║ • Jane Doe                        ║
║                                   ║
║ DESTINATION LOCATIONS:            ║
║ [📍 Public]  [📍 Private]         ║
║                                   ║
╚═══════════════════════════════════╝
```

## Usage in View Modes

### Default View Mode
Automatically configured to use WorkflowInfoFormatter.

### Other View Modes
Configure manually:
1. Go to display settings for the view mode
2. Add/configure the Workflow List field
3. Select "Workflow Information" formatter

### Teaser View Mode
You can add workflow info to teasers:
1. Go to: `/admin/structure/types/manage/[type]/display/teaser`
2. Enable "Workflow List" field
3. Format: "Workflow Information"
4. Save

## Programmatic Usage

### Load and Display Workflow

```php
use Drupal\node\Entity\Node;

$node = Node::load(123);

// Get workflow ID
$workflow_id = $node->get('field_workflow_list')->value;

if ($workflow_id) {
  // Load workflow
  $workflow = \Drupal::entityTypeManager()
    ->getStorage('workflow_list')
    ->load($workflow_id);
  
  // Render using template
  $build = [
    '#theme' => 'workflow_info_block',
    '#workflow' => $workflow,
    '#node' => $node,
  ];
  
  $output = \Drupal::service('renderer')->render($build);
}
```

### Custom Widget Usage

The widget is automatically used, but you can also instantiate it programmatically if needed for custom forms.

## Integration with Views

### Adding Workflow Field to Views

1. Add a View of Content
2. Add field: "Workflow List"
3. Format: "Workflow Information"
4. The workflow info will display in your view

### Example: Content List with Workflows

```
View: Content with Workflows
Display: Page

Fields:
- Content: Title
- Content: Workflow List (formatted as Workflow Information)

Filters:
- Content: Workflow List (is not empty)
```

## Theming Hooks

### Available Hooks

```php
/**
 * Implements hook_preprocess_workflow_info_block().
 */
function MYTHEME_preprocess_workflow_info_block(&$variables) {
  $workflow = $variables['workflow'];
  
  // Add custom variables
  $variables['workflow_age'] = time() - $workflow->getCreatedTime();
  
  // Add custom classes
  $variables['attributes']['class'][] = 'my-custom-class';
}
```

## Field Storage

### Field Definition

```yaml
field_name: field_workflow_list
entity_type: node
type: string
cardinality: 1
```

### Field Instance (per content type)

```yaml
field_name: field_workflow_list
entity_type: node
bundle: article
label: 'Workflow List'
required: false
```

## Performance

### Caching
- Workflow entities are configuration entities (cached)
- Field formatter output is cached per field
- Template rendered output is cached

### Optimization Tips
1. Use the workflow tab for frequently checking workflows (faster)
2. Field formatter is best for overview pages
3. Consider hiding field in some view modes for performance

## Troubleshooting

### Field Not Displaying

**Check:**
1. Content type enabled in settings
2. Field exists: `/admin/structure/types/manage/[type]/fields`
3. Field visible in display: `/admin/structure/types/manage/[type]/display`
4. Cache cleared: `drush cr`

### Formatter Not Working

**Check:**
1. Formatter selected: Should be "Workflow Information"
2. Library loaded: Check browser console for CSS
3. Template exists: `templates/workflow-info-block.html.twig`
4. Permissions: User can view workflows

### Widget Not Showing Options

**Check:**
1. Workflows exist: `/admin/structure/workflow-list`
2. Widget configured: Should be "Workflow List Selector"
3. Cache cleared: `drush cr`

## Best Practices

### When to Use Field Formatter
✅ Content listing pages
✅ Overview/dashboard pages
✅ When you need workflow info in Views
✅ For RSS feeds or exports

### When to Use Workflow Tab
✅ Detailed workflow management
✅ When editing workflows
✅ For comprehensive workflow view
✅ When you need to change workflows

### Display Configuration

**Recommended:**
- **Full content view**: Use workflow tab (cleaner)
- **Teaser view**: Use field formatter (shows key info)
- **Search results**: Use field formatter
- **Admin lists**: Use workflow tab link

## API Reference

### Field Formatter Methods

```php
// Get the formatter
$formatter = \Drupal::service('plugin.manager.field.formatter')
  ->createInstance('workflow_info_formatter', [
    'field_definition' => $field_definition,
    'settings' => [],
    'label' => 'hidden',
    'view_mode' => 'default',
  ]);

// Render
$elements = $formatter->viewElements($items, 'en');
```

### Field Widget Methods

```php
// Get the widget
$widget = \Drupal::service('plugin.manager.field.widget')
  ->createInstance('workflow_list_widget', [
    'field_definition' => $field_definition,
    'settings' => [],
  ]);

// Build form element
$element = $widget->formElement($items, 0, [], $form, $form_state);
```

## Conclusion

The field plugins provide:
- ✅ Automatic workflow display on content
- ✅ Enhanced editing experience
- ✅ Professional formatting
- ✅ Color-coded destinations
- ✅ Views integration
- ✅ Themeable output

All working together to make workflow management seamless and professional.

---

**File Count:** 3 plugin files + 1 template + CSS  
**Auto-configured:** Yes  
**Customizable:** Yes  
**Views Compatible:** Yes  
**Themeable:** Yes
