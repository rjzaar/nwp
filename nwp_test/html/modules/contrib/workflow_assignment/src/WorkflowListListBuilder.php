<?php

namespace Drupal\workflow_assignment;

use Drupal\Core\Config\Entity\ConfigEntityListBuilder;
use Drupal\Core\Entity\EntityInterface;
use Drupal\Core\Url;
use Drupal\Component\Utility\Unicode;

/**
 * Provides a listing of Workflow Lists.
 */
class WorkflowListListBuilder extends ConfigEntityListBuilder {

  /**
   * {@inheritdoc}
   */
  public function render() {
    $build = parent::render();
    
    // Add the "Add Workflow List" button at the top of the page.
    $build['table']['#empty'] = $this->t('No workflow lists available. <a href=":add-url">Add a workflow list</a>.', [
      ':add-url' => Url::fromRoute('entity.workflow_list.add_form')->toString(),
    ]);
    
    // Add action links at the top of the page.
    $build['add_link'] = [
      '#type' => 'link',
      '#title' => $this->t('Add Workflow List'),
      '#url' => Url::fromRoute('entity.workflow_list.add_form'),
      '#attributes' => [
        'class' => ['button', 'button--action', 'button--primary'],
      ],
      '#weight' => -10,
    ];
    
    return $build;
  }

  /**
   * {@inheritdoc}
   */
  public function buildHeader() {
    $header['label'] = $this->t('Name');
    $header['description'] = $this->t('Description');
    $header['assigned'] = $this->t('Assigned');
    $header['comments'] = $this->t('Comments');
    return $header + parent::buildHeader();
  }

  /**
   * {@inheritdoc}
   */
  public function buildRow(EntityInterface $entity) {
    /** @var \Drupal\workflow_assignment\Entity\WorkflowList $entity */
    $row['label'] = $entity->label();

    // Description (truncated).
    $description = $entity->getDescription();
    $row['description'] = $description ? Unicode::truncate($description, 40, TRUE, TRUE) : '-';
    
    // Assigned entity with type indicator
    $assigned_label = $entity->getAssignedLabel();
    $assigned_type = $entity->getAssignedType();
    
    if ($assigned_label && $assigned_type) {
      $type_labels = [
        'user' => $this->t('User'),
        'group' => $this->t('Group'),
        'destination' => $this->t('Destination'),
      ];
      
      $type_label = isset($type_labels[$assigned_type]) ? $type_labels[$assigned_type] : $assigned_type;
      $row['assigned'] = $this->t('@type: @label', [
        '@type' => $type_label,
        '@label' => $assigned_label,
      ]);
    }
    else {
      $row['assigned'] = '-';
    }
    
    // Comments (truncated)
    $comments = $entity->getComments();
    $row['comments'] = $comments ? Unicode::truncate($comments, 30, TRUE, TRUE) : '-';
    
    return $row + parent::buildRow($entity);
  }

  /**
   * {@inheritdoc}
   */
  public function getDefaultOperations(EntityInterface $entity) {
    $operations = parent::getDefaultOperations($entity);
    
    // Add quick edit operation.
    $operations['quick_edit'] = [
      'title' => $this->t('Quick Edit'),
      'weight' => 15,
      'url' => Url::fromRoute('workflow_assignment.quick_edit', [
        'workflow_list' => $entity->id(),
      ]),
    ];
    
    return $operations;
  }

}