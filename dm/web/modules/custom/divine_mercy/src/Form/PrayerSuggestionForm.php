<?php

namespace Drupal\divine_mercy\Form;

use Drupal\Core\Form\FormBase;
use Drupal\Core\Form\FormStateInterface;
use Drupal\Core\Entity\EntityTypeManagerInterface;
use Drupal\Core\Language\LanguageManagerInterface;
use Drupal\divine_mercy\Service\SuggestionService;
use Symfony\Component\DependencyInjection\ContainerInterface;

/**
 * Form for submitting prayer suggestions.
 */
class PrayerSuggestionForm extends FormBase {

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
   * The language manager.
   *
   * @var \Drupal\Core\Language\LanguageManagerInterface
   */
  protected $languageManager;

  /**
   * Constructs a PrayerSuggestionForm object.
   *
   * @param \Drupal\divine_mercy\Service\SuggestionService $suggestion_service
   *   The suggestion service.
   * @param \Drupal\Core\Entity\EntityTypeManagerInterface $entity_type_manager
   *   The entity type manager.
   * @param \Drupal\Core\Language\LanguageManagerInterface $language_manager
   *   The language manager.
   */
  public function __construct(SuggestionService $suggestion_service, EntityTypeManagerInterface $entity_type_manager, LanguageManagerInterface $language_manager) {
    $this->suggestionService = $suggestion_service;
    $this->entityTypeManager = $entity_type_manager;
    $this->languageManager = $language_manager;
  }

  /**
   * {@inheritdoc}
   */
  public static function create(ContainerInterface $container) {
    return new static(
      $container->get('divine_mercy.suggestion_service'),
      $container->get('entity_type.manager'),
      $container->get('language_manager')
    );
  }

  /**
   * {@inheritdoc}
   */
  public function getFormId() {
    return 'divine_mercy_prayer_suggestion_form';
  }

  /**
   * {@inheritdoc}
   */
  public function buildForm(array $form, FormStateInterface $form_state, $entity_type = NULL, $entity_id = NULL) {
    // Store entity info.
    $form['target_entity_type'] = [
      '#type' => 'hidden',
      '#value' => $entity_type ?? 'node',
    ];
    $form['target_entity_id'] = [
      '#type' => 'hidden',
      '#value' => $entity_id ?? 0,
    ];

    // Show target entity info.
    if ($entity_type && $entity_id) {
      try {
        $entity = $this->entityTypeManager->getStorage($entity_type)->load($entity_id);
        if ($entity) {
          $form['target_info'] = [
            '#markup' => '<p>' . $this->t('Suggesting changes to: <strong>@title</strong>', ['@title' => $entity->label()]) . '</p>',
          ];
        }
      }
      catch (\Exception $e) {
        // Ignore.
      }
    }

    $form['suggestion_type'] = [
      '#type' => 'select',
      '#title' => $this->t('Suggestion Type'),
      '#options' => [
        'correction' => $this->t('Correction - Fix an error'),
        'addition' => $this->t('Addition - Add new content'),
        'translation' => $this->t('Translation - Provide a translation'),
        'variation' => $this->t('Variation - Alternative version'),
      ],
      '#required' => TRUE,
    ];

    // Language selection for translations.
    $languages = $this->languageManager->getLanguages();
    $language_options = [];
    foreach ($languages as $langcode => $language) {
      $language_options[$langcode] = $language->getName();
    }

    $form['langcode'] = [
      '#type' => 'select',
      '#title' => $this->t('Language'),
      '#options' => $language_options,
      '#default_value' => $this->languageManager->getCurrentLanguage()->getId(),
      '#states' => [
        'visible' => [
          ':input[name="suggestion_type"]' => ['value' => 'translation'],
        ],
      ],
    ];

    $form['suggestion_text'] = [
      '#type' => 'textarea',
      '#title' => $this->t('Your Suggestion'),
      '#description' => $this->t('Describe what you would like to change or add.'),
      '#required' => TRUE,
      '#rows' => 4,
    ];

    $form['proposed_text'] = [
      '#type' => 'textarea',
      '#title' => $this->t('Proposed Text'),
      '#description' => $this->t('If applicable, provide the exact text you are proposing.'),
      '#rows' => 6,
    ];

    $form['actions'] = [
      '#type' => 'actions',
    ];

    $form['actions']['submit'] = [
      '#type' => 'submit',
      '#value' => $this->t('Submit Suggestion'),
    ];

    return $form;
  }

  /**
   * {@inheritdoc}
   */
  public function submitForm(array &$form, FormStateInterface $form_state) {
    $data = [
      'target_entity_type' => $form_state->getValue('target_entity_type'),
      'target_entity_id' => $form_state->getValue('target_entity_id'),
      'suggestion_type' => $form_state->getValue('suggestion_type'),
      'suggestion_text' => $form_state->getValue('suggestion_text'),
      'proposed_text' => $form_state->getValue('proposed_text'),
      'langcode' => $form_state->getValue('langcode'),
    ];

    $id = $this->suggestionService->create($data);

    $this->messenger()->addStatus($this->t('Thank you! Your suggestion has been submitted for review.'));

    // Redirect back to the entity if possible.
    if ($data['target_entity_type'] === 'node' && $data['target_entity_id']) {
      $form_state->setRedirect('entity.node.canonical', ['node' => $data['target_entity_id']]);
    }
    else {
      $form_state->setRedirect('divine_mercy.chaplet');
    }
  }

}
