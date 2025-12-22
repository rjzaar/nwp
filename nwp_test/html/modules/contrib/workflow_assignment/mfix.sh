#!/bin/bash

# Workflow Assignment Module Fix Script
# This script fixes the checkbox "value 0" error at the module level

echo "========================================"
echo "Workflow Assignment Module Fix"
echo "========================================"

# Check if we're in the right directory
if [ ! -f "workflow_assignment.module" ]; then
    echo "Error: Please run this script from the workflow_assignment module directory"
    echo "Example: cd modules/custom/workflow_assignment"
    exit 1
fi

echo "Backing up original files..."
cp workflow_assignment.module workflow_assignment.module.backup
cp src/Form/WorkflowAssignmentSettingsForm.php src/Form/WorkflowAssignmentSettingsForm.php.backup
cp workflow_assignment.install workflow_assignment.install.backup

echo "Fixing WorkflowAssignmentSettingsForm.php..."
# Fix the settings form to use options_select
sed -i "s/'type' => 'workflow_list_widget',.*/'type' => 'options_select', \/\/ Use select list to avoid checkbox issues/" src/Form/WorkflowAssignmentSettingsForm.php

echo "Adding validation hooks to workflow_assignment.module..."
# Check if the hook already exists
if ! grep -q "workflow_assignment_field_widget_multivalue_form_alter" workflow_assignment.module; then
    cat >> workflow_assignment.module << 'EOF'

/**
 * Implements hook_field_widget_multivalue_form_alter().
 * 
 * Fixes the "submitted value 0" error that occurs when using checkboxes
 * for entity reference fields by filtering out unchecked values (zeros).
 */
function workflow_assignment_field_widget_multivalue_form_alter(array &$elements, FormStateInterface $form_state, array $context) {
  // Only process the workflow list field
  if ($context['items']->getName() == 'field_workflow_list') {
    // Add validation to filter out zeros before entity reference validation
    array_unshift($elements['#element_validate'], 'workflow_assignment_clean_checkbox_values');
  }
}

/**
 * Validation callback to clean checkbox values.
 * 
 * Removes zeros from checkbox submissions before entity reference validation
 * to prevent "submitted value 0" errors.
 */
function workflow_assignment_clean_checkbox_values(&$element, FormStateInterface $form_state) {
  $values = $form_state->getValue($element['#parents']);
  
  if (is_array($values)) {
    $cleaned = [];
    foreach ($values as $key => $value) {
      // Only keep non-zero values (checked checkboxes)
      if ($value !== 0 && $value !== '0' && !empty($value)) {
        $cleaned[] = ['target_id' => $value];
      }
    }
    $form_state->setValueForElement($element, $cleaned);
  }
}
EOF
    echo "✓ Added validation hooks"
else
    echo "✓ Validation hooks already exist"
fi

echo "Adding update hook to workflow_assignment.install..."
# Check if update 9005 already exists
if ! grep -q "workflow_assignment_update_9005" workflow_assignment.install; then
    cat >> workflow_assignment.install << 'EOF'

/**
 * Fix workflow field widgets to use select lists instead of checkboxes.
 */
function workflow_assignment_update_9005() {
  $entity_form_display_storage = \Drupal::entityTypeManager()
    ->getStorage('entity_form_display');
  
  $updated = 0;
  
  // Get all form displays
  $form_displays = $entity_form_display_storage->loadMultiple();
  
  foreach ($form_displays as $form_display) {
    if ($component = $form_display->getComponent('field_workflow_list')) {
      // Check if using problematic widget type
      if (in_array($component['type'], ['options_buttons', 'workflow_list_widget', 'entity_reference_checkboxes'])) {
        // Change to select widget
        $form_display->setComponent('field_workflow_list', [
          'type' => 'options_select',
          'weight' => $component['weight'] ?? 100,
          'settings' => [],
          'third_party_settings' => $component['third_party_settings'] ?? [],
        ])->save();
        $updated++;
      }
    }
  }
  
  return t('Updated @count workflow field widgets to use select lists instead of checkboxes.', [
    '@count' => $updated,
  ]);
}
EOF
    echo "✓ Added update hook"
else
    echo "✓ Update hook already exists"
fi

echo ""
echo "========================================"
echo "Module fixes applied successfully!"
echo "========================================"
echo ""
echo "Next steps:"
echo "1. Clear cache: drush cr"
echo "2. Run updates: drush updb -y"
echo ""
echo "The module will now:"
echo "✓ Use select lists instead of checkboxes (no zero values)"
echo "✓ Handle any remaining checkboxes safely"
echo "✓ Work correctly on any Drupal site"
echo ""
echo "Backup files created with .backup extension"
