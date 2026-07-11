<?php

namespace Drupal\nwc_moodle_erase\Plugin\QueueWorker;

use Drupal\Core\Logger\LoggerChannelFactoryInterface;
use Drupal\Core\Plugin\ContainerFactoryPluginInterface;
use Drupal\Core\Queue\QueueWorkerBase;
use Drupal\nwc_moodle_erase\NwcMoodleErase;
use Symfony\Component\DependencyInjection\ContainerInterface;

/**
 * Delivers queued erase commands to the ssc Moodle receiver.
 *
 * @QueueWorker(
 *   id = "nwc_moodle_erase",
 *   title = @Translation("NWC Moodle Erase sender"),
 *   cron = {"time" = 30}
 * )
 */
class EraseWorker extends QueueWorkerBase implements ContainerFactoryPluginInterface {

  public function __construct(
    array $configuration,
    $plugin_id,
    $plugin_definition,
    protected NwcMoodleErase $sender,
    protected LoggerChannelFactoryInterface $loggerFactory,
  ) {
    parent::__construct($configuration, $plugin_id, $plugin_definition);
  }

  /**
   * {@inheritdoc}
   */
  public static function create(ContainerInterface $container, array $configuration, $plugin_id, $plugin_definition) {
    return new static(
      $configuration,
      $plugin_id,
      $plugin_definition,
      $container->get('nwc_moodle_erase.sender'),
      $container->get('logger.factory'),
    );
  }

  /**
   * {@inheritdoc}
   *
   * A transport error throws (NwcMoodleErase::send re-throws GuzzleException),
   * which the queue treats as "requeue"; the receiver is idempotent on
   * request_id, so a retry is safe. A malformed item is skipped (no throw) so
   * it does not loop forever.
   */
  public function processItem($data) {
    if (!is_array($data) || empty($data['sub']) || empty($data['request_id'])) {
      // Never fabricate a target — drop a malformed job (permanent failure).
      $this->loggerFactory->get('nwc_moodle_erase')
        ->error('Dropping malformed erase queue item (missing sub/request_id).');
      return;
    }
    $this->sender->send($data);
  }

}
