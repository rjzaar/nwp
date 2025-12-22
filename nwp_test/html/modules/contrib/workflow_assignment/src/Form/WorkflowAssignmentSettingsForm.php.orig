<?php

namespace Drupal\workflow_assignment\Form;

use Drupal\Core\Form\ConfigFormBase;
use Drupal\Core\Form\FormStateInterface;
use Symfony\Component\DependencyInjection\ContainerInterface;
use Drupal\Core\Entity\EntityTypeManagerInterface;
use Drupal\Core\Config\ConfigFactoryInterface;

/**
 * Configuration form for workflow assignment settings.
 */
class WorkflowAssignmentSettingsForm extends ConfigFormBase {

  /**
   * The entity type manager.
   *
   * @var \Drupal\Core\Entity\EntityTypeManagerInterface
   */
  protected $entityTypeManager;

  /**
   * Constructs a WorkflowAssignmentSettingsForm object.
   *
   * @param \Drupal\Core\Config\ConfigFactoryInterface $config_factory
   *   The factory for configuration objects.
   * @param \Drupal\Core\Entity\EntityTypeManagerInterface $entity_type_manager
   *   The entity type manager.
   */
  public function __construct(ConfigFactoryInterface $config_factory, EntityTypeManagerInterface $entity_type_manager) {
    parent::__construct($config_factory);
    $this->entityTypeManager = $entity_type_manager;
  }

  /**
   * {@inheritdoc}
   */
  public static function create(ContainerInterface $container) {
    return new static(
      $container->get('config.factory'),
      $container->get('entity_type.manager')
    );
  }

  /**
   * {@inheritdoc}
   */
  protected function getEditableConfigNames() {
    return ['workflow_assignment.settings'];
  }

  /**
   * {@inheritdoc}
   */
  public function getFormId() {
    return 'workflow_assignment_settings';
  }

  /**
   * {@inheritdoc}
   */
  public function buildForm(array $form, FormStateInterface $form_state) {
    $config = $this->config('workflow_assignment.settings');

    // Get all content types.
    $node_types = $this->entityTypeManager->getStorage('node_type')->loadMultiple();
    $content_type_options = [];
    foreach ($node_types as $type) {
      $content_type_options[$type->id()] = $type->label();
    }

    $form['enabled_content_types'] = [
      '#type' => 'checkboxes',
      '#title' => $this->t('Enabled Content Types'),
      '#options' => $content_type_options,
      '#default_value' => $config->get('enabled_content_types') ?: [],
      '#description' => $this->t('Select which content types can have workflow lists assigned. The workflow field will be added to these content types.'),
    ];

    // Get all vocabularies.
    $vocabularies = $this->entityTypeManager->getStorage('taxonomy_vocabulary')->loadMultiple();
    $vocab_options = [];
    foreach ($vocabularies as $vid => $vocabulary) {
      $vocab_options[$vid] = $vocabulary->label();
    }

    $form['destination_vocabulary'] = [
      '#type' => 'select',
      '#title' => $this->t('Destination Location Vocabulary'),
      '#options' => $vocab_options,
      '#default_value' => $config->get('destination_vocabulary') ?: 'destination_locations',
      '#description' => $this->t('Select the taxonomy vocabulary to use for destination locations.'),
      '#required' => TRUE,
    ];

    $form['show_workflow_tab'] = [
      '#type' => 'checkbox',
      '#title' => $this->t('Show Workflow Tab'),
      '#default_value' => $config->get('show_workflow_tab') ?? TRUE,
      '#description' => $this->t('Display a separate "Workflow" tab on content pages.'),
    ];

    return parent::buildForm($form, $form_state);
  }

  /**
   * {@inheritdoc}
   */
  public function submitForm(array &$form, FormStateInterface $form_state) {
    $enabled_types = array_filter($form_state->getValue('enabled_content_types'));
    
    $this->config('workflow_assignment.settings')
      ->set('enabled_content_types', array_values($enabled_types))
      ->set('destination_vocabulary', $form_state->getValue('destination_vocabulary'))
      ->set('show_workflow_tab', $form_state->getValue('show_workflow_tab'))
      ->save();

    // Add/remove workflow field to content types.
    $this->updateContentTypeFields($enabled_types);

    parent::submitForm($form, $form_state);
  }

  /**
   * Updates workflow fields on content types.
   *
   * @param array $enabled_types
   *   Array of enabled content type IDs.
   */
  protected function updateContentTypeFields(array $enabled_types) {
    $field_storage_config = $this->entityTypeManager->getStorage('field_storage_config');
    $field_config = $this->entityTypeManager->getStorage('field_config');

    // Ensure field storage exists.
    $field_storage = $field_storage_config->load('node.field_workflow_list');
    if (!$field_storage) {
      $field_storage = $field_storage_config->create([
        'field_name' => 'field_workflow_list',
        'entity_type' => 'node',
        'type' => 'entity_reference',
        'cardinality' => -1, // Unlimited - allow multiple workflows
        'settings' => [
          'target_type' => 'workflow_list',
        ],
      ]);
      $field_storage->save();
    }

    // Get all node types.
    $all_types = array_keys($this->entityTypeManager->getStorage('node_type')->loadMultiple());

    foreach ($all_types as $type) {
      $field = $field_config->load("node.{$type}.field_workflow_list");
      
      if (in_array($type, $enabled_types)) {
        // Add field if it doesn't exist.
        if (!$field) {
          $field = $field_config->create([
            'field_name' => 'field_workflow_list',
            'entity_type' => 'node',
            'bundle' => $type,
            'label' => 'Workflow List',
            'required' => FALSE,
            'settings' => [
              'handler' => 'default:workflow_list',
              'handler_settings' => [],
            ],
          ]);
          $field->save();

          // Set form display.
          $form_display = $this->entityTypeManager
            ->getStorage('entity_form_display')
            ->load("node.{$type}.default");
          
          if (!$form_display) {
            $form_display = $this->entityTypeManager
              ->getStorage('entity_form_display')
              ->create([
                'targetEntityType' => 'node',
                'bundle' => $type,
                'mode' => 'default',
                'status' => TRUE,
              ]);
          }
          
          $form_display->setComponent('field_workflow_list', [
            'type' => 'workflow_list_widget',  // Use custom widget
            'weight' => 100,
            'settings' => [],
          ])->save();

          // Set view display - HIDE the field (only show on workflow tab)
          $view_display = $this->entityTypeManager
            ->getStorage('entity_view_display')
            ->load("node.{$type}.default");
          
          if (!$view_display) {
            $view_display = $this->entityTypeManager
              ->getStorage('entity_view_display')
              ->create([
                'targetEntityType' => 'node',
                'bundle' => $type,
                'mode' => 'default',
                'status' => TRUE,
              ]);
          }
          
          // Remove the field from display - we only show it on the workflow tab
          $view_display->removeComponent('field_workflow_list')->save();
        }
      }
      else {
        // Remove field if it exists.
        if ($field) {
          $field->delete();
        }
      }
    }
  }

}
