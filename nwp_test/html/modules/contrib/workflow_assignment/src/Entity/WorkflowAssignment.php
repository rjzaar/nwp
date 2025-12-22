<?php

namespace Drupal\workflow_assignment\Entity;

use Drupal\Core\Entity\ContentEntityBase;
use Drupal\Core\Entity\EntityChangedTrait;
use Drupal\Core\Entity\EntityTypeInterface;
use Drupal\Core\Entity\RevisionLogEntityTrait;
use Drupal\Core\Field\BaseFieldDefinition;
use Drupal\user\EntityOwnerTrait;

/**
 * Defines the Workflow Assignment entity.
 *
 * This is a content entity that represents individual workflow assignments.
 * Each assignment can be edited, has revisions, and is specific to a piece of content.
 *
 * @ContentEntityType(
 *   id = "workflow_assignment",
 *   label = @Translation("Workflow Assignment"),
 *   label_collection = @Translation("Workflow Assignments"),
 *   label_singular = @Translation("workflow assignment"),
 *   label_plural = @Translation("workflow assignments"),
 *   handlers = {
 *     "view_builder" = "Drupal\Core\Entity\EntityViewBuilder",
 *     "list_builder" = "Drupal\workflow_assignment\WorkflowAssignmentListBuilder",
 *     "views_data" = "Drupal\views\EntityViewsData",
 *     "form" = {
 *       "default" = "Drupal\workflow_assignment\Form\WorkflowAssignmentForm",
 *       "add" = "Drupal\workflow_assignment\Form\WorkflowAssignmentForm",
 *       "edit" = "Drupal\workflow_assignment\Form\WorkflowAssignmentForm",
 *       "delete" = "Drupal\Core\Entity\ContentEntityDeleteForm",
 *     },
 *     "access" = "Drupal\workflow_assignment\WorkflowAssignmentAccessControlHandler",
 *   },
 *   base_table = "workflow_assignment",
 *   revision_table = "workflow_assignment_revision",
 *   data_table = "workflow_assignment_field_data",
 *   revision_data_table = "workflow_assignment_field_revision",
 *   show_revision_ui = TRUE,
 *   translatable = FALSE,
 *   admin_permission = "administer workflow assignments",
 *   entity_keys = {
 *     "id" = "id",
 *     "revision" = "vid",
 *     "label" = "title",
 *     "uuid" = "uuid",
 *     "owner" = "uid",
 *   },
 *   revision_metadata_keys = {
 *     "revision_user" = "revision_uid",
 *     "revision_created" = "revision_timestamp",
 *     "revision_log_message" = "revision_log"
 *   },
 *   links = {
 *     "canonical" = "/workflow-assignment/{workflow_assignment}",
 *     "add-form" = "/workflow-assignment/add",
 *     "edit-form" = "/workflow-assignment/{workflow_assignment}/edit",
 *     "delete-form" = "/workflow-assignment/{workflow_assignment}/delete",
 *     "version-history" = "/workflow-assignment/{workflow_assignment}/revisions",
 *     "revision" = "/workflow-assignment/{workflow_assignment}/revisions/{workflow_assignment_revision}/view",
 *   },
 * )
 */
class WorkflowAssignment extends ContentEntityBase {

  use EntityChangedTrait;
  use EntityOwnerTrait;
  use RevisionLogEntityTrait;

  /**
   * {@inheritdoc}
   */
  public static function baseFieldDefinitions(EntityTypeInterface $entity_type) {
    $fields = parent::baseFieldDefinitions($entity_type);

    // Standard field, used as unique if primary index.
    $fields['id'] = BaseFieldDefinition::create('integer')
      ->setLabel(t('ID'))
      ->setDescription(t('The ID of the Workflow Assignment entity.'))
      ->setReadOnly(TRUE);

    // Standard field, unique outside of the scope of the current project.
    $fields['uuid'] = BaseFieldDefinition::create('uuid')
      ->setLabel(t('UUID'))
      ->setDescription(t('The UUID of the Workflow Assignment entity.'))
      ->setReadOnly(TRUE);

    // Revision ID.
    $fields['vid'] = BaseFieldDefinition::create('integer')
      ->setLabel(t('Revision ID'))
      ->setDescription(t('The revision ID of the workflow assignment.'))
      ->setReadOnly(TRUE)
      ->setSetting('unsigned', TRUE);

    // Owner field - who created this assignment.
    $fields['uid'] = BaseFieldDefinition::create('entity_reference')
      ->setLabel(t('Authored by'))
      ->setDescription(t('The user ID of author of the Workflow Assignment entity.'))
      ->setRevisionable(TRUE)
      ->setSetting('target_type', 'user')
      ->setSetting('handler', 'default')
      ->setDisplayOptions('view', [
        'label' => 'hidden',
        'type' => 'author',
        'weight' => 0,
      ])
      ->setDisplayOptions('form', [
        'type' => 'entity_reference_autocomplete',
        'weight' => 5,
        'settings' => [
          'match_operator' => 'CONTAINS',
          'size' => '60',
          'autocomplete_type' => 'tags',
          'placeholder' => '',
        ],
      ])
      ->setDisplayConfigurable('form', TRUE)
      ->setDisplayConfigurable('view', TRUE);

    // Job Number field.
    $fields['job_number'] = BaseFieldDefinition::create('string')
      ->setLabel(t('Job Number'))
      ->setDescription(t('The job number for this workflow assignment.'))
      ->setRevisionable(TRUE)
      ->setSettings([
        'max_length' => 50,
        'text_processing' => 0,
      ])
      ->setDefaultValue('')
      ->setDisplayOptions('view', [
        'label' => 'above',
        'type' => 'string',
        'weight' => -4,
      ])
      ->setDisplayOptions('form', [
        'type' => 'string_textfield',
        'weight' => -4,
      ])
      ->setDisplayConfigurable('form', TRUE)
      ->setDisplayConfigurable('view', TRUE)
      ->setRequired(FALSE);

    // Title field.
    $fields['title'] = BaseFieldDefinition::create('string')
      ->setLabel(t('Title'))
      ->setDescription(t('The title of the Workflow Assignment entity.'))
      ->setRevisionable(TRUE)
      ->setSettings([
        'max_length' => 255,
        'text_processing' => 0,
      ])
      ->setDefaultValue('')
      ->setDisplayOptions('view', [
        'label' => 'above',
        'type' => 'string',
        'weight' => -5,
      ])
      ->setDisplayOptions('form', [
        'type' => 'string_textfield',
        'weight' => -5,
      ])
      ->setDisplayConfigurable('form', TRUE)
      ->setDisplayConfigurable('view', TRUE)
      ->setRequired(TRUE);

    // Description field.
    $fields['description'] = BaseFieldDefinition::create('text_long')
      ->setLabel(t('Description'))
      ->setDescription(t('A description of the workflow assignment.'))
      ->setRevisionable(TRUE)
      ->setDisplayOptions('view', [
        'label' => 'above',
        'type' => 'text_default',
        'weight' => 0,
      ])
      ->setDisplayOptions('form', [
        'type' => 'text_textarea',
        'weight' => 0,
        'settings' => [
          'rows' => 4,
        ],
      ])
      ->setDisplayConfigurable('form', TRUE)
      ->setDisplayConfigurable('view', TRUE);

    // Assignment type (user, group, or destination).
    $fields['assigned_type'] = BaseFieldDefinition::create('list_string')
      ->setLabel(t('Assignment Type'))
      ->setDescription(t('The type of assignment: user, group, or destination.'))
      ->setRevisionable(TRUE)
      ->setSettings([
        'allowed_values' => [
          'user' => 'User',
          'group' => 'Group',
          'destination' => 'Destination',
        ],
      ])
      ->setDisplayOptions('view', [
        'label' => 'above',
        'type' => 'list_default',
        'weight' => 1,
      ])
      ->setDisplayOptions('form', [
        'type' => 'options_buttons',
        'weight' => 1,
      ])
      ->setDisplayConfigurable('form', TRUE)
      ->setDisplayConfigurable('view', TRUE)
      ->setRequired(TRUE);

    // Assigned User - shown when assignment type is 'user'.
    $fields['assigned_user'] = BaseFieldDefinition::create('entity_reference')
      ->setLabel(t('Assigned User'))
      ->setDescription(t('The user assigned to this workflow.'))
      ->setRevisionable(TRUE)
      ->setSetting('target_type', 'user')
      ->setSetting('handler', 'default')
      ->setDisplayOptions('view', [
        'label' => 'above',
        'type' => 'entity_reference_label',
        'weight' => 2,
      ])
      ->setDisplayOptions('form', [
        'type' => 'entity_reference_autocomplete',
        'weight' => 2,
        'settings' => [
          'match_operator' => 'CONTAINS',
          'size' => '60',
          'placeholder' => '',
        ],
      ])
      ->setDisplayConfigurable('form', TRUE)
      ->setDisplayConfigurable('view', TRUE);

    // Assigned Group - shown when assignment type is 'group'.
    $fields['assigned_group'] = BaseFieldDefinition::create('entity_reference')
      ->setLabel(t('Assigned Group'))
      ->setDescription(t('The group assigned to this workflow.'))
      ->setRevisionable(TRUE)
      ->setSetting('target_type', 'group')
      ->setSetting('handler', 'default')
      ->setDisplayOptions('view', [
        'label' => 'above',
        'type' => 'entity_reference_label',
        'weight' => 2,
      ])
      ->setDisplayOptions('form', [
        'type' => 'entity_reference_autocomplete',
        'weight' => 2,
        'settings' => [
          'match_operator' => 'CONTAINS',
          'size' => '60',
          'placeholder' => '',
        ],
      ])
      ->setDisplayConfigurable('form', TRUE)
      ->setDisplayConfigurable('view', TRUE);

    // Assigned Destination - shown when assignment type is 'destination'.
    $fields['assigned_destination'] = BaseFieldDefinition::create('entity_reference')
      ->setLabel(t('Assigned Destination'))
      ->setDescription(t('The destination assigned to this workflow.'))
      ->setRevisionable(TRUE)
      ->setSetting('target_type', 'taxonomy_term')
      ->setSetting('handler', 'default')
      ->setSetting('handler_settings', [
        'target_bundles' => [
          'destination_locations' => 'destination_locations',
        ],
      ])
      ->setDisplayOptions('view', [
        'label' => 'above',
        'type' => 'entity_reference_label',
        'weight' => 2,
      ])
      ->setDisplayOptions('form', [
        'type' => 'entity_reference_autocomplete',
        'weight' => 2,
        'settings' => [
          'match_operator' => 'CONTAINS',
          'size' => '60',
          'placeholder' => '',
        ],
      ])
      ->setDisplayConfigurable('form', TRUE)
      ->setDisplayConfigurable('view', TRUE);

    // Comments field.
    $fields['comments'] = BaseFieldDefinition::create('text_long')
      ->setLabel(t('Comments'))
      ->setDescription(t('Comments about this workflow assignment.'))
      ->setRevisionable(TRUE)
      ->setDisplayOptions('view', [
        'label' => 'above',
        'type' => 'text_default',
        'weight' => 3,
      ])
      ->setDisplayOptions('form', [
        'type' => 'text_textarea',
        'weight' => 3,
        'settings' => [
          'rows' => 3,
        ],
      ])
      ->setDisplayConfigurable('form', TRUE)
      ->setDisplayConfigurable('view', TRUE);

    // Completion status field.
    $fields['completion'] = BaseFieldDefinition::create('list_string')
      ->setLabel(t('Completion Status'))
      ->setDescription(t('The completion status of this workflow assignment.'))
      ->setRevisionable(TRUE)
      ->setSettings([
        'allowed_values' => [
          'proposed' => 'Proposed',
          'accepted' => 'Accepted',
          'completed' => 'Completed',
        ],
      ])
      ->setDefaultValue('proposed')
      ->setDisplayOptions('view', [
        'label' => 'above',
        'type' => 'list_default',
        'weight' => 4,
      ])
      ->setDisplayOptions('form', [
        'type' => 'options_buttons',
        'weight' => 4,
      ])
      ->setDisplayConfigurable('form', TRUE)
      ->setDisplayConfigurable('view', TRUE)
      ->setRequired(TRUE);

    // Created timestamp.
    $fields['created'] = BaseFieldDefinition::create('created')
      ->setLabel(t('Created'))
      ->setDescription(t('The time that the entity was created.'))
      ->setRevisionable(TRUE);

    // Changed timestamp.
    $fields['changed'] = BaseFieldDefinition::create('changed')
      ->setLabel(t('Changed'))
      ->setDescription(t('The time that the entity was last edited.'))
      ->setRevisionable(TRUE);

    return $fields;
  }

  /**
   * Gets the assigned entity label.
   *
   * @return string
   *   The label of the assigned entity.
   */
  public function getAssignedLabel() {
    $type = $this->get('assigned_type')->value;
    
    switch ($type) {
      case 'user':
        $user = $this->get('assigned_user')->entity;
        return $user ? $user->getDisplayName() : '';
      
      case 'group':
        $group = $this->get('assigned_group')->entity;
        return $group ? $group->label() : '';
      
      case 'destination':
        $term = $this->get('assigned_destination')->entity;
        return $term ? $term->getName() : '';
      
      default:
        return '';
    }
  }

}