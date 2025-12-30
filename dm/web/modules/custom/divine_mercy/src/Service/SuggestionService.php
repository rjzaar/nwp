<?php

namespace Drupal\divine_mercy\Service;

use Drupal\Component\Uuid\UuidInterface;
use Drupal\Core\Database\Connection;
use Drupal\Core\Datetime\DateFormatterInterface;
use Drupal\Core\Session\AccountProxyInterface;
use Drupal\Component\Datetime\TimeInterface;

/**
 * Service for managing prayer suggestions.
 */
class SuggestionService {

  /**
   * The database connection.
   *
   * @var \Drupal\Core\Database\Connection
   */
  protected $database;

  /**
   * The current user.
   *
   * @var \Drupal\Core\Session\AccountProxyInterface
   */
  protected $currentUser;

  /**
   * The time service.
   *
   * @var \Drupal\Component\Datetime\TimeInterface
   */
  protected $time;

  /**
   * Constructs a SuggestionService object.
   *
   * @param \Drupal\Core\Database\Connection $database
   *   The database connection.
   * @param \Drupal\Core\Session\AccountProxyInterface $current_user
   *   The current user.
   * @param \Drupal\Component\Datetime\TimeInterface $time
   *   The time service.
   */
  public function __construct(Connection $database, AccountProxyInterface $current_user, TimeInterface $time) {
    $this->database = $database;
    $this->currentUser = $current_user;
    $this->time = $time;
  }

  /**
   * Create a new suggestion.
   *
   * @param array $data
   *   The suggestion data.
   *
   * @return int
   *   The new suggestion ID.
   */
  public function create(array $data) {
    $uuid = \Drupal::service('uuid')->generate();
    $now = $this->time->getRequestTime();

    $fields = [
      'uuid' => $uuid,
      'target_entity_type' => $data['target_entity_type'] ?? 'node',
      'target_entity_id' => $data['target_entity_id'] ?? 0,
      'suggestion_type' => $data['suggestion_type'] ?? 'correction',
      'suggestion_text' => $data['suggestion_text'] ?? '',
      'proposed_text' => $data['proposed_text'] ?? '',
      'langcode' => $data['langcode'] ?? 'en',
      'uid' => $this->currentUser->id(),
      'status' => 'pending',
      'admin_notes' => '',
      'created' => $now,
      'changed' => $now,
    ];

    return $this->database->insert('prayer_suggestion')
      ->fields($fields)
      ->execute();
  }

  /**
   * Get a suggestion by ID.
   *
   * @param int $id
   *   The suggestion ID.
   *
   * @return object|null
   *   The suggestion record or null.
   */
  public function load($id) {
    return $this->database->select('prayer_suggestion', 's')
      ->fields('s')
      ->condition('id', $id)
      ->execute()
      ->fetchObject();
  }

  /**
   * Get suggestions by status.
   *
   * @param string $status
   *   The status to filter by.
   * @param int $limit
   *   Maximum number to return.
   *
   * @return array
   *   Array of suggestion records.
   */
  public function getByStatus($status, $limit = 50) {
    return $this->database->select('prayer_suggestion', 's')
      ->fields('s')
      ->condition('status', $status)
      ->orderBy('created', 'DESC')
      ->range(0, $limit)
      ->execute()
      ->fetchAll();
  }

  /**
   * Get all pending suggestions.
   *
   * @param int $limit
   *   Maximum number to return.
   *
   * @return array
   *   Array of suggestion records.
   */
  public function getPending($limit = 50) {
    return $this->getByStatus('pending', $limit);
  }

  /**
   * Get suggestions for a specific entity.
   *
   * @param string $entity_type
   *   The entity type.
   * @param int $entity_id
   *   The entity ID.
   *
   * @return array
   *   Array of suggestion records.
   */
  public function getForEntity($entity_type, $entity_id) {
    return $this->database->select('prayer_suggestion', 's')
      ->fields('s')
      ->condition('target_entity_type', $entity_type)
      ->condition('target_entity_id', $entity_id)
      ->orderBy('created', 'DESC')
      ->execute()
      ->fetchAll();
  }

  /**
   * Update a suggestion's status.
   *
   * @param int $id
   *   The suggestion ID.
   * @param string $status
   *   The new status.
   * @param string $admin_notes
   *   Optional admin notes.
   *
   * @return int
   *   Number of rows updated.
   */
  public function updateStatus($id, $status, $admin_notes = NULL) {
    $fields = [
      'status' => $status,
      'changed' => $this->time->getRequestTime(),
    ];

    if ($admin_notes !== NULL) {
      $fields['admin_notes'] = $admin_notes;
    }

    return $this->database->update('prayer_suggestion')
      ->fields($fields)
      ->condition('id', $id)
      ->execute();
  }

  /**
   * Delete a suggestion.
   *
   * @param int $id
   *   The suggestion ID.
   *
   * @return int
   *   Number of rows deleted.
   */
  public function delete($id) {
    return $this->database->delete('prayer_suggestion')
      ->condition('id', $id)
      ->execute();
  }

  /**
   * Get count of pending suggestions.
   *
   * @return int
   *   The count.
   */
  public function getPendingCount() {
    return $this->database->select('prayer_suggestion', 's')
      ->condition('status', 'pending')
      ->countQuery()
      ->execute()
      ->fetchField();
  }

}
