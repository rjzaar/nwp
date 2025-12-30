<?php

namespace Drupal\divine_mercy\Form;

use Drupal\Core\Form\FormBase;
use Drupal\Core\Form\FormStateInterface;
use Drupal\Core\Entity\EntityTypeManagerInterface;
use Drupal\Core\Url;
use Drupal\divine_mercy\Service\SuggestionService;
use Symfony\Component\DependencyInjection\ContainerInterface;

/**
 * Form for reviewing prayer suggestions.
 */
class SuggestionReviewForm extends FormBase {

  /**
   * The suggestion service.
   *
   * @var \Drupal\divine_mercy\Service\SuggestionService
   */
  protected $suggestionService;

  /**
   * The entity type manager.
   *
   * @var \Drupal\Core\Entity\EntityTypeManagerInterface
   */
  protected $entityTypeManager;

  /**
   * Constructs a SuggestionReviewForm object.
   *
   * @param \Drupal\divine_mercy\Service\SuggestionService $suggestion_service
   *   The suggestion service.
   * @param \Drupal\Core\Entity\EntityTypeManagerInterface $entity_type_manager
   *   The entity type manager.
   */
  public function __construct(SuggestionService $suggestion_service, EntityTypeManagerInterface $entity_type_manager) {
    $this->suggestionService = $suggestion_service;
    $this->entityTypeManager = $entity_type_manager;
  }

  /**
   * {@inheritdoc}
   */
  public static function create(ContainerInterface $container) {
    return new static(
      $container->get('divine_mercy.suggestion_service'),
      $container->get('entity_type.manager')
    );
  }

  /**
   * {@inheritdoc}
   */
  public function getFormId() {
    return 'divine_mercy_suggestion_review_form';
  }

  /**
   * {@inheritdoc}
   */
  public function buildForm(array $form, FormStateInterface $form_state, $suggestion_id = NULL) {
    $suggestion = $this->suggestionService->load($suggestion_id);

    if (!$suggestion) {
      $this->messenger()->addError($this->t('Suggestion not found.'));
      return $form;
    }

    $form['suggestion_id'] = [
      '#type' => 'hidden',
      '#value' => $suggestion_id,
    ];

    // Display suggestion details.
    $form['details'] = [
      '#type' => 'fieldset',
      '#title' => $this->t('Suggestion Details'),
    ];

    // Load target entity.
    $target_info = $this->t('Unknown');
    $target_link = NULL;
    try {
      $entity = $this->entityTypeManager->getStorage($suggestion->target_entity_type)->load($suggestion->target_entity_id);
      if ($entity) {
        $target_info = $entity->label();
        $target_link = $entity->toUrl()->toString();
      }
    }
    catch (\Exception $e) {
      // Ignore.
    }

    // Load user.
    $user = $this->entityTypeManager->getStorage('user')->load($suggestion->uid);
    $user_name = $user ? $user->getDisplayName() : $this->t('Anonymous');

    $form['details']['target'] = [
      '#markup' => '<p><strong>' . $this->t('Target:') . '</strong> ' . ($target_link ? '<a href="' . $target_link . '">' . $target_info . '</a>' : $target_info) . '</p>',
    ];

    $form['details']['type'] = [
      '#markup' => '<p><strong>' . $this->t('Type:') . '</strong> ' . $suggestion->suggestion_type . '</p>',
    ];

    $form['details']['user'] = [
      '#markup' => '<p><strong>' . $this->t('Submitted by:') . '</strong> ' . $user_name . '</p>',
    ];

    $form['details']['created'] = [
      '#markup' => '<p><strong>' . $this->t('Date:') . '</strong> ' . \Drupal::service('date.formatter')->format($suggestion->created, 'medium') . '</p>',
    ];

    if ($suggestion->langcode && $suggestion->langcode !== 'en') {
      $form['details']['language'] = [
        '#markup' => '<p><strong>' . $this->t('Language:') . '</strong> ' . $suggestion->langcode . '</p>',
      ];
    }

    $form['details']['status'] = [
      '#markup' => '<p><strong>' . $this->t('Status:') . '</strong> ' . $suggestion->status . '</p>',
    ];

    $form['suggestion_content'] = [
      '#type' => 'fieldset',
      '#title' => $this->t('Suggestion Content'),
    ];

    $form['suggestion_content']['suggestion_text'] = [
      '#type' => 'item',
      '#title' => $this->t('Suggestion'),
      '#markup' => '<div class="suggestion-text">' . nl2br(htmlspecialchars($suggestion->suggestion_text)) . '</div>',
    ];

    if (!empty($suggestion->proposed_text)) {
      $form['suggestion_content']['proposed_text'] = [
        '#type' => 'item',
        '#title' => $this->t('Proposed Text'),
        '#markup' => '<div class="proposed-text">' . nl2br(htmlspecialchars($suggestion->proposed_text)) . '</div>',
      ];
    }

    $form['review'] = [
      '#type' => 'fieldset',
      '#title' => $this->t('Review'),
    ];

    $form['review']['new_status'] = [
      '#type' => 'select',
      '#title' => $this->t('Status'),
      '#options' => [
        'pending' => $this->t('Pending'),
        'reviewed' => $this->t('Reviewed'),
        'accepted' => $this->t('Accepted'),
        'rejected' => $this->t('Rejected'),
      ],
      '#default_value' => $suggestion->status,
    ];

    $form['review']['admin_notes'] = [
      '#type' => 'textarea',
      '#title' => $this->t('Admin Notes'),
      '#description' => $this->t('Internal notes about this suggestion.'),
      '#default_value' => $suggestion->admin_notes ?? '',
      '#rows' => 4,
    ];

    $form['actions'] = [
      '#type' => 'actions',
    ];

    $form['actions']['submit'] = [
      '#type' => 'submit',
      '#value' => $this->t('Update'),
    ];

    $form['actions']['delete'] = [
      '#type' => 'submit',
      '#value' => $this->t('Delete'),
      '#submit' => ['::deleteSubmit'],
      '#attributes' => [
        'class' => ['button--danger'],
      ],
    ];

    return $form;
  }

  /**
   * {@inheritdoc}
   */
  public function submitForm(array &$form, FormStateInterface $form_state) {
    $suggestion_id = $form_state->getValue('suggestion_id');
    $status = $form_state->getValue('new_status');
    $admin_notes = $form_state->getValue('admin_notes');

    $this->suggestionService->updateStatus($suggestion_id, $status, $admin_notes);

    $this->messenger()->addStatus($this->t('Suggestion updated.'));
    $form_state->setRedirect('divine_mercy.suggestion.list');
  }

  /**
   * Submit handler for delete button.
   */
  public function deleteSubmit(array &$form, FormStateInterface $form_state) {
    $suggestion_id = $form_state->getValue('suggestion_id');
    $this->suggestionService->delete($suggestion_id);

    $this->messenger()->addStatus($this->t('Suggestion deleted.'));
    $form_state->setRedirect('divine_mercy.suggestion.list');
  }

}
