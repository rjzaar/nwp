<?php

namespace Drupal\workflow_assignment\Plugin\Field\FieldWidget;

use Drupal\Core\Field\FieldItemListInterface;
use Drupal\Core\Field\Plugin\Field\FieldWidget\OptionsButtonsWidget;
use Drupal\Core\Form\FormStateInterface;
use Drupal\Core\Entity\FieldableEntityInterface;

/**
 * Plugin implementation of the 'workflow_list_widget' widget.
 *
 * @FieldWidget(
 *   id = "workflow_list_widget",
 *   label = @Translation("Workflow List Selector"),
 *   field_types = {
 *     "entity_reference"
 *   }
 * )
 */
class WorkflowListWidget extends OptionsButtonsWidget {

  /**
   * {@inheritdoc}
   */
  protected function getOptions(FieldableEntityInterface $entity) {
    $options = parent::getOptions($entity);
    
    // Enhance the options with assignment information
    $enhanced_options = [];
    foreach ($options as $key => $label) {
      if ($key == '_none') {
        $enhanced_options[$key] = $label;
        continue;
      }
      
      // Load the workflow entity to get assignment details
      $workflow = \Drupal::entityTypeManager()
        ->getStorage('workflow_list')
        ->load($key);
        
      if ($workflow) {
        $assigned_label = $workflow->getAssignedLabel();
        $assigned_type = $workflow->getAssignedType();
        
        if ($assigned_label && $assigned_type) {
          $type_labels = [
            'user' => $this->t('User'),
            'group' => $this->t('Group'),
            'destination' => $this->t('Dest'),
          ];
          
          $type_label = isset($type_labels[$assigned_type]) ? $type_labels[$assigned_type] : $assigned_type;
          $enhanced_options[$key] = $workflow->label() . ' (' . $type_label . ': ' . $assigned_label . ')';
        }
        else {
          $enhanced_options[$key] = $workflow->label();
        }
      }
      else {
        $enhanced_options[$key] = $label;
      }
    }
    
    return $enhanced_options;
  }

  /**
   * {@inheritdoc}
   */
  public function formElement(FieldItemListInterface $items, $delta, array $element, array &$form, FormStateInterface $form_state) {
    $element = parent::formElement($items, $delta, $element, $form, $form_state);
    
    // Add help text and links
    $element['#description'] = $this->t('Select one or more workflows to assign to this content. View full workflow details on the Workflow tab.');
    
    // Add suffix with helpful links
    $element['#suffix'] = '<div class="workflow-widget-help">' . 
      '<div class="description">' . 
      $this->t('Need a new workflow? <a href="@url" target="_blank">Create one here</a>.', [
        '@url' => '/admin/structure/workflow-list/add',
      ]) . 
      '</div>' .
      '<div class="description"><em>' . 
      $this->t('Tip: Use the Workflow tab for a detailed table view of all assigned workflows.') . 
      '</em></div>' .
      '</div>';
    
    // Add element validation to filter out zeros before field validation
    $element['#element_validate'][] = [get_class($this), 'validateElement'];
    
    return $element;
  }

  /**
   * Element validation callback to filter out zero values.
   *
   * @param array $element
   *   The form element.
   * @param \Drupal\Core\Form\FormStateInterface $form_state
   *   The form state.
   * @param array $form
   *   The complete form.
   */
  public static function validateElement(array &$element, FormStateInterface $form_state, array &$form) {
    $values = $form_state->getValue($element['#parents']);
    
    if (is_array($values)) {
      $filtered = [];
      
      foreach ($values as $delta => $value) {
        // Skip non-numeric deltas
        if (!is_numeric($delta)) {
          continue;
        }
        
        // Extract the actual value
        $target_id = NULL;
        if (is_array($value) && isset($value['target_id'])) {
          $target_id = $value['target_id'];
        }
        elseif (is_scalar($value)) {
          $target_id = $value;
        }
        
        // Only keep non-zero values
        if (!empty($target_id) && $target_id !== 0 && $target_id !== '0') {
          $filtered[] = ['target_id' => $target_id];
        }
      }
      
      // Update the form state with filtered values
      $form_state->setValueForElement($element, $filtered);
    }
  }

  /**
   * {@inheritdoc}
   */
  public function massageFormValues(array $values, array $form, FormStateInterface $form_state) {
    // Additional filtering as a safety net
    $filtered = [];
    
    foreach ($values as $value) {
      // Extract target_id from various possible structures
      $target_id = NULL;
      
      if (is_array($value) && isset($value['target_id'])) {
        $target_id = $value['target_id'];
      }
      elseif (is_scalar($value)) {
        $target_id = $value;
      }
      
      // Only keep valid entity IDs (not 0, '0', empty, etc.)
      if (!empty($target_id) && $target_id !== 0 && $target_id !== '0') {
        $filtered[] = ['target_id' => $target_id];
      }
    }
    
    return $filtered;
  }

}