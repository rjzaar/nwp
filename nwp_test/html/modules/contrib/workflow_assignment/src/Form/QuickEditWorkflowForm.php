<?php

namespace Drupal\workflow_assignment\Form;

use Drupal\Core\Form\FormBase;
use Drupal\Core\Form\FormStateInterface;
use Symfony\Component\DependencyInjection\ContainerInterface;
use Drupal\Core\Entity\EntityTypeManagerInterface;
use Drupal\Core\Extension\ModuleHandlerInterface;
use Drupal\workflow_assignment\Entity\WorkflowList;

/**
 * Quick edit form for workflow lists.
 */
class QuickEditWorkflowForm extends FormBase {

  /**
   * The entity type manager.
   *
   * @var \Drupal\Core\Entity\EntityTypeManagerInterface
   */
  protected $entityTypeManager;

  /**
   * The module handler.
   *
   * @var \Drupal\Core\Extension\ModuleHandlerInterface
   */
  protected $moduleHandler;

  /**
   * Constructs a QuickEditWorkflowForm object.
   *
   * @param \Drupal\Core\Entity\EntityTypeManagerInterface $entity_type_manager
   *   The entity type manager.
   * @param \Drupal\Core\Extension\ModuleHandlerInterface $module_handler
   *   The module handler.
   */
  public function __construct(EntityTypeManagerInterface $entity_type_manager, ModuleHandlerInterface $module_handler) {
    $this->entityTypeManager = $entity_type_manager;
    $this->moduleHandler = $module_handler;
  }

  /**
   * {@inheritdoc}
   */
  public static function create(ContainerInterface $container) {
    return new static(
      $container->get('entity_type.manager'),
      $container->get('module_handler')
    );
  }

  /**
   * {@inheritdoc}
   */
  public function getFormId() {
    return 'workflow_assignment_quick_edit';
  }

  /**
   * {@inheritdoc}
   */
  public function buildForm(array $form, FormStateInterface $form_state, WorkflowList $workflow_list = NULL) {
    if (!$workflow_list) {
      return $form;
    }

    $form_state->set('workflow', $workflow_list);

    $form['info'] = [
      '#markup' => '<h2>' . $this->t('Quick Edit: @name', ['@name' => $workflow_list->label()]) . '</h2>',
    ];

    // Quick edit for description
    $form['description'] = [
      '#type' => 'textarea',
      '#title' => $this->t('Description'),
      '#default_value' => $workflow_list->getDescription(),
      '#rows' => 3,
    ];

    // Assignment type selection
    $form['assignment_type'] = [
      '#type' => 'radios',
      '#title' => $this->t('Assignment Type'),
      '#options' => [
        'user' => $this->t('User'),
        'group' => $this->t('Group'),
        'destination' => $this->t('Destination Location'),
      ],
      '#default_value' => $workflow_list->getAssignedType() ?: 'user',
      '#required' => TRUE,
    ];

    // User selection
    $user_storage = $this->entityTypeManager->getStorage('user');
    $user_options = [];
    $users = $user_storage->loadMultiple();
    foreach ($users as $uid => $user) {
      if ($uid > 0) {
        $user_options[$uid] = $user->getDisplayName();
      }
    }

    $form['assigned_user'] = [
      '#type' => 'select',
      '#title' => $this->t('Assigned User'),
      '#options' => $user_options,
      '#default_value' => $workflow_list->getAssignedType() == 'user' ? $workflow_list->getAssignedId() : '',
      '#states' => [
        'visible' => [
          ':input[name="assignment_type"]' => ['value' => 'user'],
        ],
        'required' => [
          ':input[name="assignment_type"]' => ['value' => 'user'],
        ],
      ],
    ];

    // Groups (if available)
    if ($this->moduleHandler->moduleExists('group')) {
      $group_storage = $this->entityTypeManager->getStorage('group');
      $group_options = [];
      $groups = $group_storage->loadMultiple();
      foreach ($groups as $gid => $group) {
        $group_options[$gid] = $group->label();
      }

      $form['assigned_group'] = [
        '#type' => 'select',
        '#title' => $this->t('Assigned Group'),
        '#options' => $group_options,
        '#default_value' => $workflow_list->getAssignedType() == 'group' ? $workflow_list->getAssignedId() : '',
        '#states' => [
          'visible' => [
            ':input[name="assignment_type"]' => ['value' => 'group'],
          ],
          'required' => [
            ':input[name="assignment_type"]' => ['value' => 'group'],
          ],
        ],
      ];
    }
    else {
      unset($form['assignment_type']['#options']['group']);
    }

    // Destination locations
    $config = $this->config('workflow_assignment.settings');
    $destination_vocab = $config->get('destination_vocabulary') ?: 'destination_locations';
    
    $destination_terms = $this->entityTypeManager
      ->getStorage('taxonomy_term')
      ->loadTree($destination_vocab);
    
    $destination_options = [];
    foreach ($destination_terms as $term) {
      $destination_options[$term->tid] = $term->name;
    }

    $form['assigned_destination'] = [
      '#type' => 'select',
      '#title' => $this->t('Assigned Destination'),
      '#options' => $destination_options,
      '#default_value' => $workflow_list->getAssignedType() == 'destination' ? $workflow_list->getAssignedId() : '',
      '#states' => [
        'visible' => [
          ':input[name="assignment_type"]' => ['value' => 'destination'],
        ],
        'required' => [
          ':input[name="assignment_type"]' => ['value' => 'destination'],
        ],
      ],
    ];

    // Comments
    $form['comments'] = [
      '#type' => 'textarea',
      '#title' => $this->t('Comments'),
      '#default_value' => $workflow_list->getComments(),
      '#rows' => 3,
    ];

    $form['actions'] = [
      '#type' => 'actions',
    ];

    $form['actions']['submit'] = [
      '#type' => 'submit',
      '#value' => $this->t('Update Workflow'),
      '#button_type' => 'primary',
    ];

    $form['actions']['cancel'] = [
      '#type' => 'link',
      '#title' => $this->t('Cancel'),
      '#url' => $workflow_list->toUrl('collection'),
      '#attributes' => ['class' => ['button']],
    ];

    return $form;
  }

  /**
   * {@inheritdoc}
   */
  public function submitForm(array &$form, FormStateInterface $form_state) {
    /** @var \Drupal\workflow_assignment\Entity\WorkflowList $workflow */
    $workflow = $form_state->get('workflow');

    // Update description and comments
    $workflow->setDescription($form_state->getValue('description'));
    $workflow->setComments($form_state->getValue('comments'));
    
    // Set assignment based on type
    $assignment_type = $form_state->getValue('assignment_type');
    $workflow->setAssignedType($assignment_type);
    
    switch ($assignment_type) {
      case 'user':
        $workflow->setAssignedId($form_state->getValue('assigned_user'));
        break;
      
      case 'group':
        if ($this->moduleHandler->moduleExists('group')) {
          $workflow->setAssignedId($form_state->getValue('assigned_group'));
        }
        break;
      
      case 'destination':
        $workflow->setAssignedId($form_state->getValue('assigned_destination'));
        break;
    }
    
    $workflow->save();

    $this->messenger()->addStatus($this->t('Workflow %label has been updated.', [
      '%label' => $workflow->label(),
    ]));

    $form_state->setRedirectUrl($workflow->toUrl('collection'));
  }

}
