<?php

namespace Drupal\divine_mercy\Controller;

use Drupal\Core\Controller\ControllerBase;
use Drupal\Core\Entity\EntityTypeManagerInterface;
use Drupal\Core\Url;
use Drupal\divine_mercy\Service\SuggestionService;
use Symfony\Component\DependencyInjection\ContainerInterface;

/**
 * Controller for managing prayer suggestions.
 */
class SuggestionController extends ControllerBase {

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
   * Constructs a SuggestionController object.
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
   * Lists all pending suggestions.
   *
   * @return array
   *   A render array.
   */
  public function list() {
    $suggestions = $this->suggestionService->getPending(100);

    $header = [
      $this->t('ID'),
      $this->t('Type'),
      $this->t('Target'),
      $this->t('User'),
      $this->t('Status'),
      $this->t('Created'),
      $this->t('Operations'),
    ];

    $rows = [];
    foreach ($suggestions as $suggestion) {
      // Load target entity.
      $target_label = $this->t('Unknown');
      try {
        $storage = $this->entityTypeManager->getStorage($suggestion->target_entity_type);
        $entity = $storage->load($suggestion->target_entity_id);
        if ($entity) {
          $target_label = $entity->label();
        }
      }
      catch (\Exception $e) {
        // Entity type doesn't exist or entity not found.
      }

      // Load user.
      $user = $this->entityTypeManager->getStorage('user')->load($suggestion->uid);
      $user_label = $user ? $user->getDisplayName() : $this->t('Anonymous');

      $rows[] = [
        $suggestion->id,
        $suggestion->suggestion_type,
        $target_label,
        $user_label,
        $suggestion->status,
        \Drupal::service('date.formatter')->format($suggestion->created, 'short'),
        [
          'data' => [
            '#type' => 'link',
            '#title' => $this->t('Review'),
            '#url' => Url::fromRoute('divine_mercy.suggestion.review', ['suggestion_id' => $suggestion->id]),
          ],
        ],
      ];
    }

    $build = [
      'table' => [
        '#type' => 'table',
        '#header' => $header,
        '#rows' => $rows,
        '#empty' => $this->t('No pending suggestions.'),
      ],
    ];

    return $build;
  }

}
