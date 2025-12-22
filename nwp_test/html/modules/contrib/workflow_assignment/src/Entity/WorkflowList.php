<?php

namespace Drupal\workflow_assignment\Entity;

use Drupal\Core\Config\Entity\ConfigEntityBase;
use Drupal\Core\Entity\EntityStorageInterface;

/**
 * Defines the Workflow List entity.
 *
 * @ConfigEntityType(
 *   id = "workflow_list",
 *   label = @Translation("Workflow List"),
 *   label_collection = @Translation("Workflow Lists"),
 *   label_singular = @Translation("workflow list"),
 *   label_plural = @Translation("workflow lists"),
 *   label_count = @PluralTranslation(
 *     singular = "@count workflow list",
 *     plural = "@count workflow lists",
 *   ),
 *   handlers = {
 *     "list_builder" = "Drupal\workflow_assignment\WorkflowListListBuilder",
 *     "form" = {
 *       "add" = "Drupal\workflow_assignment\Form\WorkflowListForm",
 *       "edit" = "Drupal\workflow_assignment\Form\WorkflowListForm",
 *       "delete" = "Drupal\Core\Entity\EntityDeleteForm"
 *     }
 *   },
 *   config_prefix = "workflow_list",
 *   admin_permission = "administer workflow lists",
 *   entity_keys = {
 *     "id" = "id",
 *     "label" = "label",
 *     "uuid" = "uuid"
 *   },
 *   links = {
 *     "collection" = "/admin/structure/workflow-list",
 *     "add-form" = "/admin/structure/workflow-list/add",
 *     "edit-form" = "/admin/structure/workflow-list/{workflow_list}/edit",
 *     "delete-form" = "/admin/structure/workflow-list/{workflow_list}/delete"
 *   },
 *   config_export = {
 *     "id",
 *     "label",
 *     "description",
 *     "assigned_type",
 *     "assigned_id",
 *     "comments",
 *     "created",
 *     "changed"
 *   }
 * )
 */
class WorkflowList extends ConfigEntityBase {

  /**
   * The workflow list ID.
   *
   * @var string
   */
  protected $id;

  /**
   * The workflow list label.
   *
   * @var string
   */
  protected $label;

  /**
   * The workflow list description.
   *
   * @var string
   */
  protected $description;

  /**
   * The assigned entity type (user, group, or destination).
   *
   * @var string
   */
  protected $assigned_type;

  /**
   * The assigned entity ID.
   *
   * @var int|string
   */
  protected $assigned_id;

  /**
   * Comments for the workflow.
   *
   * @var string
   */
  protected $comments;

  /**
   * The creation timestamp.
   *
   * @var int
   */
  protected $created;

  /**
   * The last modified timestamp.
   *
   * @var int
   */
  protected $changed;

  /**
   * {@inheritdoc}
   */
  public function preSave(EntityStorageInterface $storage) {
    parent::preSave($storage);
    
    $this->changed = \Drupal::time()->getRequestTime();
    
    if ($this->isNew()) {
      $this->created = \Drupal::time()->getRequestTime();
    }
  }

  /**
   * Gets the description.
   *
   * @return string
   *   The description.
   */
  public function getDescription() {
    return $this->description;
  }

  /**
   * Sets the description.
   *
   * @param string $description
   *   The description.
   *
   * @return $this
   */
  public function setDescription($description) {
    $this->description = $description;
    return $this;
  }

  /**
   * Gets the assigned entity type.
   *
   * @return string
   *   The assigned entity type (user, group, or destination).
   */
  public function getAssignedType() {
    return $this->assigned_type;
  }

  /**
   * Sets the assigned entity type.
   *
   * @param string $type
   *   The assigned entity type.
   *
   * @return $this
   */
  public function setAssignedType($type) {
    $this->assigned_type = $type;
    return $this;
  }

  /**
   * Gets the assigned entity ID.
   *
   * @return int|string
   *   The assigned entity ID.
   */
  public function getAssignedId() {
    return $this->assigned_id;
  }

  /**
   * Sets the assigned entity ID.
   *
   * @param int|string $id
   *   The assigned entity ID.
   *
   * @return $this
   */
  public function setAssignedId($id) {
    $this->assigned_id = $id;
    return $this;
  }

  /**
   * Gets the assignment as an array with type and ID.
   *
   * @return array
   *   Array with 'type' and 'id' keys.
   */
  public function getAssignment() {
    return [
      'type' => $this->assigned_type,
      'id' => $this->assigned_id,
    ];
  }

  /**
   * Sets the assignment.
   *
   * @param string $type
   *   The entity type (user, group, or destination).
   * @param int|string $id
   *   The entity ID.
   *
   * @return $this
   */
  public function setAssignment($type, $id) {
    $this->assigned_type = $type;
    $this->assigned_id = $id;
    return $this;
  }

  /**
   * Gets the comments.
   *
   * @return string
   *   The comments.
   */
  public function getComments() {
    return $this->comments;
  }

  /**
   * Sets the comments.
   *
   * @param string $comments
   *   The comments.
   *
   * @return $this
   */
  public function setComments($comments) {
    $this->comments = $comments;
    return $this;
  }

  /**
   * Gets the creation timestamp.
   *
   * @return int
   *   The creation timestamp.
   */
  public function getCreatedTime() {
    return $this->created;
  }

  /**
   * Gets the last modified timestamp.
   *
   * @return int
   *   The last modified timestamp.
   */
  public function getChangedTime() {
    return $this->changed;
  }

  /**
   * Gets the label of the assigned entity.
   *
   * @return string
   *   The label of the assigned entity.
   */
  public function getAssignedLabel() {
    if (empty($this->assigned_type) || empty($this->assigned_id)) {
      return '';
    }

    $entity_type_manager = \Drupal::entityTypeManager();
    
    switch ($this->assigned_type) {
      case 'user':
        $user = $entity_type_manager->getStorage('user')->load($this->assigned_id);
        return $user ? $user->getDisplayName() : '';
      
      case 'group':
        if (\Drupal::moduleHandler()->moduleExists('group')) {
          $group = $entity_type_manager->getStorage('group')->load($this->assigned_id);
          return $group ? $group->label() : '';
        }
        return '';
      
      case 'destination':
        $term = $entity_type_manager->getStorage('taxonomy_term')->load($this->assigned_id);
        return $term ? $term->getName() : '';
      
      default:
        return '';
    }
  }

}
