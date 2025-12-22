<?php

namespace Drupal\workflow_assignment\Form;

use Drupal\Core\Entity\EntityForm;
use Drupal\Core\Form\FormStateInterface;
use Symfony\Component\DependencyInjection\ContainerInterface;
use Drupal\Core\Entity\EntityTypeManagerInterface;
use Drupal\Core\Extension\ModuleHandlerInterface;

/**
 * Form handler for the workflow list add and edit forms.
 */
class WorkflowListForm extends EntityForm {

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
   * Constructs a WorkflowListForm object.
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
  public function form(array $form, FormStateInterface $form_state) {
    $form = parent::form($form, $form_state);

    /** @var \Drupal\workflow_assignment\Entity\WorkflowList $workflow */
    $workflow = $this->entity;

    $form['label'] = [
      '#type' => 'textfield',
      '#title' => $this->t('Name'),
      '#maxlength' => 255,
      '#default_value' => $workflow->label(),
      '#description' => $this->t('Name for this workflow list.'),
      '#required' => TRUE,
    ];

    $form['id'] = [
      '#type' => 'machine_name',
      '#default_value' => $workflow->id(),
      '#machine_name' => [
        'exists' => '\Drupal\workflow_assignment\Entity\WorkflowList::load',
      ],
      '#disabled' => !$workflow->isNew(),
    ];

    $form['description'] = [
      '#type' => 'textarea',
      '#title' => $this->t('Description'),
      '#default_value' => $workflow->getDescription(),
      '#description' => $this->t('Optional description of this workflow.'),
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
      '#default_value' => $workflow->getAssignedType() ?: 'user',
      '#required' => TRUE,
      '#description' => $this->t('Select what type of entity this workflow should be assigned to.'),
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
      '#default_value' => $workflow->getAssignedType() == 'user' ? $workflow->getAssignedId() : '',
      '#states' => [
        'visible' => [
          ':input[name="assignment_type"]' => ['value' => 'user'],
        ],
        'required' => [
          ':input[name="assignment_type"]' => ['value' => 'user'],
        ],
      ],
      '#description' => $this->t('Select the user to assign to this workflow.'),
    ];

    // Group selection (if Group module is available)
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
        '#default_value' => $workflow->getAssignedType() == 'group' ? $workflow->getAssignedId() : '',
        '#states' => [
          'visible' => [
            ':input[name="assignment_type"]' => ['value' => 'group'],
          ],
          'required' => [
            ':input[name="assignment_type"]' => ['value' => 'group'],
          ],
        ],
        '#description' => $this->t('Select the group to assign to this workflow.'),
      ];
    }
    else {
      // Hide group option if module not available
      unset($form['assignment_type']['#options']['group']);
    }

    // Destination location selection
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
      '#title' => $this->t('Assigned Destination Location'),
      '#options' => $destination_options,
      '#default_value' => $workflow->getAssignedType() == 'destination' ? $workflow->getAssignedId() : '',
      '#states' => [
        'visible' => [
          ':input[name="assignment_type"]' => ['value' => 'destination'],
        ],
        'required' => [
          ':input[name="assignment_type"]' => ['value' => 'destination'],
        ],
      ],
      '#description' => $this->t('Select the destination location to assign to this workflow.'),
    ];

    // Comments field
    $form['comments'] = [
      '#type' => 'textarea',
      '#title' => $this->t('Comments'),
      '#default_value' => $workflow->getComments(),
      '#description' => $this->t('Optional comments or notes about this workflow.'),
      '#rows' => 3,
    ];

    return $form;
  }

  /**
   * {@inheritdoc}
   */
  public function validateForm(array &$form, FormStateInterface $form_state) {
    parent::validateForm($form, $form_state);

    $assignment_type = $form_state->getValue('assignment_type');
    
    // Validate that an assignment is selected based on type
    switch ($assignment_type) {
      case 'user':
        if (empty($form_state->getValue('assigned_user'))) {
          $form_state->setErrorByName('assigned_user', $this->t('Please select a user.'));
        }
        break;
      
      case 'group':
        if ($this->moduleHandler->moduleExists('group') && empty($form_state->getValue('assigned_group'))) {
          $form_state->setErrorByName('assigned_group', $this->t('Please select a group.'));
        }
        break;
      
      case 'destination':
        if (empty($form_state->getValue('assigned_destination'))) {
          $form_state->setErrorByName('assigned_destination', $this->t('Please select a destination location.'));
        }
        break;
    }
  }

  /**
   * {@inheritdoc}
   */
  public function save(array $form, FormStateInterface $form_state) {
    $workflow = $this->entity;
    
    // Set assignment based on type
    $assignment_type = $form_state->getValue('assignment_type');
    $workflow->setAssignedType($assignment_type);
    
    switch ($assignment_type) {
      case 'user':
        $workflow->setAssignedId($form_state->getValue('assigned_user'));
        break;
      
      case 'group':
        $workflow->setAssignedId($form_state->getValue('assigned_group'));
        break;
      
      case 'destination':
        $workflow->setAssignedId($form_state->getValue('assigned_destination'));
        break;
    }
    
    // Set comments
    $workflow->setComments($form_state->getValue('comments'));
    
    $status = $workflow->save();

    if ($status === SAVED_NEW) {
      $this->messenger()->addStatus($this->t('Created workflow list %label.', [
        '%label' => $workflow->label(),
      ]));
    }
    else {
      $this->messenger()->addStatus($this->t('Updated workflow list %label.', [
        '%label' => $workflow->label(),
      ]));
    }

    $form_state->setRedirectUrl($workflow->toUrl('collection'));
  }

}
