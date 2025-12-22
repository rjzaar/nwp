<?php

namespace Drupal\workflow_assignment\Entity;

use Drupal\Core\Entity\ContentEntityBase;
use Drupal\Core\Entity\EntityChangedTrait;
use Drupal\Core\Entity\EntityTypeInterface;
use Drupal\Core\Entity\RevisionLogEntityTrait;
use Drupal\Core\Field\BaseFieldDefinition;
use Drupal\user\EntityOwnerTrait;

/**
 * Defines the Workflow Template entity.
 *
 * This is a content entity that represents reusable workflow templates.
 * Templates can be edited and improved over time, with revision tracking.
 * When applied to content, the template creates copies of workflow_assignment entities.
 *
 * @ContentEntityType(
 *   id = "workflow_template",
 *   label = @Translation("Workflow Template"),
 *   label_collection = @Translation("Workflow Templates"),
 *   label_singular = @Translation("workflow template"),
 *   label_plural = @Translation("workflow templates"),
 *   handlers = {
 *     "view_builder" = "Drupal\Core\Entity\EntityViewBuilder",
 *     "list_builder" = "Drupal\workflow_assignment\WorkflowTemplateListBuilder",
 *     "views_data" = "Drupal\views\EntityViewsData",
 *     "form" = {
 *       "default" = "Drupal\workflow_assignment\Form\WorkflowTemplateForm",
 *       "add" = "Drupal\workflow_assignment\Form\WorkflowTemplateForm",
 *       "edit" = "Drupal\workflow_assignment\Form\WorkflowTemplateForm",
 *       "delete" = "Drupal\Core\Entity\ContentEntityDeleteForm",
 *     },
 *     "access" = "Drupal\workflow_assignment\WorkflowTemplateAccessControlHandler",
 *   },
 *   base_table = "workflow_template",
 *   revision_table = "workflow_template_revision",
 *   data_table = "workflow_template_field_data",
 *   revision_data_table = "workflow_template_field_revision",
 *   show_revision_ui = TRUE,
 *   translatable = FALSE,
 *   admin_permission = "administer workflow templates",
 *   entity_keys = {
 *     "id" = "id",
 *     "revision" = "vid",
 *     "label" = "name",
 *     "uuid" = "uuid",
 *     "owner" = "uid",
 *   },
 *   revision_metadata_keys = {
 *     "revision_user" = "revision_uid",
 *     "revision_created" = "revision_timestamp",
 *     "revision_log_message" = "revision_log"
 *   },
 *   links = {
 *     "canonical" = "/workflow-template/{workflow_template}",
 *     "add-form" = "/workflow-template/add",
 *     "edit-form" = "/workflow-template/{workflow_template}/edit",
 *     "delete-form" = "/workflow-template/{workflow_template}/delete",
 *     "collection" = "/admin/structure/workflow-template",
 *     "version-history" = "/workflow-template/{workflow_template}/revisions",
 *     "revision" = "/workflow-template/{workflow_template}/revisions/{workflow_template_revision}/view",
 *   },
 * )
 */
class WorkflowTemplate extends ContentEntityBase {

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
      ->setDescription(t('The ID of the Workflow Template entity.'))
      ->setReadOnly(TRUE);

    // Standard field, unique outside of the scope of the current project.
    $fields['uuid'] = BaseFieldDefinition::create('uuid')
      ->setLabel(t('UUID'))
      ->setDescription(t('The UUID of the Workflow Template entity.'))
      ->setReadOnly(TRUE);

    // Revision ID.
    $fields['vid'] = BaseFieldDefinition::create('integer')
      ->setLabel(t('Revision ID'))
      ->setDescription(t('The revision ID of the workflow template.'))
      ->setReadOnly(TRUE)
      ->setSetting('unsigned', TRUE);

    // Owner field - who created this template.
    $fields['uid'] = BaseFieldDefinition::create('entity_reference')
      ->setLabel(t('Authored by'))
      ->setDescription(t('The user ID of author of the Workflow Template entity.'))
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

    // Name field (used as label).
    $fields['name'] = BaseFieldDefinition::create('string')
      ->setLabel(t('Name'))
      ->setDescription(t('The name of the Workflow Template.'))
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
      ->setDescription(t('A description of this workflow template.'))
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

    // Reference to workflow_assignment entities that make up this template.
    // These are the "prototype" assignments that will be copied when the template is applied.
    $fields['assignments'] = BaseFieldDefinition::create('entity_reference')
      ->setLabel(t('Template Assignments'))
      ->setDescription(t('The workflow assignments that make up this template. When applied to content, these will be copied.'))
      ->setRevisionable(TRUE)
      ->setSetting('target_type', 'workflow_assignment')
      ->setSetting('handler', 'default')
      ->setCardinality(BaseFieldDefinition::CARDINALITY_UNLIMITED)
      ->setDisplayOptions('view', [
        'label' => 'above',
        'type' => 'entity_reference_label',
        'weight' => 1,
      ])
      ->setDisplayOptions('form', [
        'type' => 'entity_reference_autocomplete',
        'weight' => 1,
        'settings' => [
          'match_operator' => 'CONTAINS',
          'size' => '60',
          'placeholder' => '',
        ],
      ])
      ->setDisplayConfigurable('form', TRUE)
      ->setDisplayConfigurable('view', TRUE);

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
   * Gets the template name.
   *
   * @return string
   *   The template name.
   */
  public function getName() {
    return $this->get('name')->value;
  }

  /**
   * Sets the template name.
   *
   * @param string $name
   *   The template name.
   *
   * @return $this
   */
  public function setName($name) {
    $this->set('name', $name);
    return $this;
  }

  /**
   * Gets the template description.
   *
   * @return string
   *   The description.
   */
  public function getDescription() {
    return $this->get('description')->value;
  }

  /**
   * Sets the template description.
   *
   * @param string $description
   *   The description.
   *
   * @return $this
   */
  public function setDescription($description) {
    $this->set('description', $description);
    return $this;
  }

  /**
   * Gets the assignment entities that make up this template.
   *
   * @return \Drupal\workflow_assignment\Entity\WorkflowAssignment[]
   *   Array of workflow assignment entities.
   */
  public function getAssignments() {
    $assignments = [];
    foreach ($this->get('assignments') as $item) {
      if ($assignment = $item->entity) {
        $assignments[] = $assignment;
      }
    }
    return $assignments;
  }

  /**
   * Adds an assignment to this template.
   *
   * @param \Drupal\workflow_assignment\Entity\WorkflowAssignment $assignment
   *   The assignment entity to add.
   *
   * @return $this
   */
  public function addAssignment(WorkflowAssignment $assignment) {
    $current = $this->get('assignments')->getValue();
    $current[] = ['target_id' => $assignment->id()];
    $this->set('assignments', $current);
    return $this;
  }

  /**
   * Creates copies of this template's assignments for a specific node.
   *
   * When a template is applied to content, this method creates new
   * workflow_assignment entities based on the template's assignments.
   * Each assignment is duplicated (not referenced) so it can be edited
   * independently for that specific content.
   *
   * @param \Drupal\node\NodeInterface $node
   *   The node to create assignments for.
   *
   * @return array
   *   Array of created workflow_assignment entity IDs.
   */
  public function createAssignmentsForNode($node) {
    $entity_type_manager = \Drupal::entityTypeManager();
    $storage = $entity_type_manager->getStorage('workflow_assignment');
    $created_ids = [];

    // Get the template assignments.
    $template_assignments = $this->getAssignments();

    foreach ($template_assignments as $template_assignment) {
      // Create a copy (not a reference) of the assignment.
      // This allows each content item to have its own editable version.
      $new_assignment = $template_assignment->createDuplicate();
      
      // Clear the ID and revision ID so it's created as a new entity.
      $new_assignment->set('id', NULL);
      $new_assignment->set('vid', NULL);
      
      // Reset completion status to 'proposed' for new assignments.
      $new_assignment->set('completion', 'proposed');
      
      // Save the new assignment.
      $new_assignment->save();
      
      $created_ids[] = $new_assignment->id();
    }

    return $created_ids;
  }

  /**
   * Gets the count of assignments in this template.
   *
   * @return int
   *   The number of assignments.
   */
  public function getAssignmentCount() {
    return count($this->get('assignments'));
  }

}