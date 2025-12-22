<?php

namespace Drupal\workflow_assignment\Form;

use Drupal\Core\Form\FormBase;
use Drupal\Core\Form\FormStateInterface;
use Symfony\Component\DependencyInjection\ContainerInterface;
use Drupal\Core\Entity\EntityTypeManagerInterface;
use Drupal\node\NodeInterface;
use Drupal\Core\Url;

/**
 * Form for assigning workflows to nodes.
 */
class NodeAssignWorkflowForm extends FormBase {

  /**
   * The entity type manager.
   *
   * @var \Drupal\Core\Entity\EntityTypeManagerInterface
   */
  protected $entityTypeManager;

  /**
   * Constructs a NodeAssignWorkflowForm object.
   *
   * @param \Drupal\Core\Entity\EntityTypeManagerInterface $entity_type_manager
   *   The entity type manager.
   */
  public function __construct(EntityTypeManagerInterface $entity_type_manager) {
    $this->entityTypeManager = $entity_type_manager;
  }

  /**
   * {@inheritdoc}
   */
  public static function create(ContainerInterface $container) {
    return new static(
      $container->get('entity_type.manager')
    );
  }

  /**
   * {@inheritdoc}
   */
  public function getFormId() {
    return 'workflow_assignment_node_assign';
  }

  /**
   * {@inheritdoc}
   */
  public function buildForm(array $form, FormStateInterface $form_state, NodeInterface $node = NULL) {
    if (!$node) {
      return $form;
    }

    $form_state->set('node', $node);

    $form['info'] = [
      '#markup' => '<p>' . $this->t('Manage workflows for: <strong>@title</strong>', [
        '@title' => $node->getTitle(),
      ]) . '</p>',
    ];

    // Get all workflow lists.
    $workflow_storage = $this->entityTypeManager->getStorage('workflow_list');
    $workflows = $workflow_storage->loadMultiple();
    
    $workflow_options = [];
    foreach ($workflows as $workflow) {
      $assigned = $workflow->getAssignedLabel();
      $type = $workflow->getAssignedType();
      
      $type_labels = [
        'user' => $this->t('User'),
        'group' => $this->t('Group'),
        'destination' => $this->t('Dest'),
      ];
      
      $type_label = isset($type_labels[$type]) ? $type_labels[$type] : $type;
      
      $workflow_options[$workflow->id()] = $workflow->label() . ' (' . $type_label . ': ' . $assigned . ')';
    }

    // Get currently assigned workflows.
    $current_workflows = [];
    if ($node->hasField('field_workflow_list')) {
      foreach ($node->get('field_workflow_list') as $item) {
        // For entity reference field, get the target_id
        if (!empty($item->target_id)) {
          $current_workflows[$item->target_id] = $item->target_id;
        }
      }
    }

    $form['workflow_list'] = [
      '#type' => 'checkboxes',
      '#title' => $this->t('Assigned Workflows'),
      '#options' => $workflow_options,
      '#default_value' => $current_workflows,
      '#description' => $this->t('Select one or more workflows to assign to this content. Uncheck to remove workflows.'),
    ];

    $form['actions'] = [
      '#type' => 'actions',
    ];

    $form['actions']['submit'] = [
      '#type' => 'submit',
      '#value' => $this->t('Save'),
      '#button_type' => 'primary',
    ];

    $form['actions']['cancel'] = [
      '#type' => 'link',
      '#title' => $this->t('Cancel'),
      '#url' => Url::fromRoute('workflow_assignment.node_workflow_tab', ['node' => $node->id()]),
      '#attributes' => ['class' => ['button']],
    ];

    return $form;
  }

  /**
   * {@inheritdoc}
   */
  public function submitForm(array &$form, FormStateInterface $form_state) {
    /** @var \Drupal\node\NodeInterface $node */
    $node = $form_state->get('node');
    $selected_workflows = array_filter($form_state->getValue('workflow_list'));

    if ($node->hasField('field_workflow_list')) {
      // Clear existing workflows and set new ones
      $node->set('field_workflow_list', array_values($selected_workflows));
      $node->save();

      $count = count($selected_workflows);
      if ($count > 0) {
        $this->messenger()->addStatus($this->formatPlural(
          $count,
          'Successfully assigned 1 workflow to this content.',
          'Successfully assigned @count workflows to this content.'
        ));
      }
      else {
        $this->messenger()->addStatus($this->t('All workflows have been removed from this content.'));
      }
    }

    // Redirect to the workflow tab.
    $form_state->setRedirect('workflow_assignment.node_workflow_tab', [
      'node' => $node->id(),
    ]);
  }

}
