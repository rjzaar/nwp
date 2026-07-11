<?php

namespace Drupal\nwc_moodle_erase;

use Drupal\Core\Config\ConfigFactoryInterface;
use Drupal\Core\Logger\LoggerChannelFactoryInterface;
use GuzzleHttp\ClientInterface;
use GuzzleHttp\Exception\GuzzleException;

/**
 * Sends a signed erase command to the ssc Moodle receiver (local_nwc_erase).
 *
 * The provider half of the ops#81 erasure channel. Mirrors the Bearer-POST
 * shape of nwc_copyright's MoodleToolPolicySync: a plain HTTPS POST of a JSON
 * body matching contracts/erasure.command.schema.json, with
 * `Authorization: Bearer <admin_token>`.
 *
 * DESTRUCTIVE. On a real prod tier the endpoint token is a `ver`-held secret
 * and the delivery fires only behind the ver Solo-touch gate (CLAUDE.md
 * AI-never-prod). dev/stg/live-test tiers are agent-operable (A14).
 */
class NwcMoodleErase {

  public function __construct(
    protected ConfigFactoryInterface $configFactory,
    protected ClientInterface $httpClient,
    protected LoggerChannelFactoryInterface $loggerFactory,
  ) {}

  /**
   * Build the closed erase command payload from a queue item.
   *
   * Fail-closed: returns NULL if the durable `sub` is missing or the action is
   * not one the contract allows. NEVER derives `sub` from an email.
   *
   * @param array $item
   *   Queue data: sub, request_id, action, issuer, timestamp.
   *
   * @return array|null
   *   The command matching erasure.command.schema.json, or NULL if invalid.
   */
  public function buildCommand(array $item): ?array {
    $sub = isset($item['sub']) ? trim((string) $item['sub']) : '';
    $requestId = isset($item['request_id']) ? trim((string) $item['request_id']) : '';
    $action = $item['action'] ?? 'delete';
    if ($sub === '' || $requestId === '' || !in_array($action, ['delete', 'anonymise'], TRUE)) {
      return NULL;
    }
    return [
      'sub' => $sub,
      'request_id' => $requestId,
      'action' => $action,
      'issuer' => (string) ($item['issuer'] ?? ($this->config()->get('issuer') ?: '')),
      'timestamp' => (int) ($item['timestamp'] ?? time()),
    ];
  }

  /**
   * POST the erase command to the Moodle receiver.
   *
   * @param array $item
   *   Queue data.
   *
   * @return array
   *   ['action' => 'sent'|'skipped'|'error', ...].
   *
   * @throws \RuntimeException
   *   On a transport error, so the queue worker requeues (idempotent replay).
   */
  public function send(array $item): array {
    $config = $this->config();
    $baseUrl = (string) $config->get('moodle_url');
    $token = (string) $config->get('admin_token');
    if ($baseUrl === '' || $token === '') {
      $this->log()->warning('Erase send skipped — moodle_url or admin_token not configured.');
      return ['action' => 'skipped', 'reason' => 'unconfigured'];
    }

    $command = $this->buildCommand($item);
    if ($command === NULL) {
      // Malformed job — a permanent failure, do NOT throw (would loop forever).
      $this->log()->error('Erase send skipped — malformed queue item (missing sub/request_id or bad action).');
      return ['action' => 'skipped', 'reason' => 'malformed'];
    }

    $endpoint = rtrim($baseUrl, '/') . '/local/nwc_erase/erase.php';
    // Dev-tier self-signed certs (*.ddev.site) skip verification; prod verifies.
    $verify = !preg_match('~\.ddev\.site($|/)~', $baseUrl);

    $options = [
      'headers' => [
        'Authorization' => 'Bearer ' . $token,
        'Content-Type' => 'application/json',
      ],
      'json' => $command,
      'timeout' => 10,
      'verify' => $verify,
    ];
    // Cross-project DDEV Host header override (parity with MoodleApiClient).
    $host = (string) $config->get('moodle_host');
    if ($host !== '') {
      $options['headers']['Host'] = $host;
      $options['headers']['X-Forwarded-Proto'] = 'https';
    }

    try {
      $response = $this->httpClient->request('POST', $endpoint, $options);
      $body = json_decode((string) $response->getBody(), TRUE);
      $this->log()->info('Erase command @rid delivered (@status): @action', [
        '@rid' => $command['request_id'],
        '@status' => $response->getStatusCode(),
        '@action' => is_array($body) ? ($body['action'] ?? '?') : '?',
      ]);
      return ['action' => 'sent', 'status' => $response->getStatusCode(), 'response' => $body];
    }
    catch (GuzzleException $e) {
      $msg = sprintf('Erase command %s POST failed: %s', $command['request_id'], $e->getMessage());
      $this->log()->error($msg);
      // Throw so the queue worker requeues; the receiver is idempotent on request_id.
      throw new \RuntimeException($msg, 0, $e);
    }
  }

  protected function config() {
    return $this->configFactory->get('nwc_moodle_erase.settings');
  }

  protected function log() {
    return $this->loggerFactory->get('nwc_moodle_erase');
  }

}
