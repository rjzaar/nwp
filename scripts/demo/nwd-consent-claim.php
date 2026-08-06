<?php

/**
 * @file
 * scripts/demo/nwd-consent-claim.php — prove the ops#118 `art9_consent` claim
 * actually appears in a TOKEN's userinfo response on the nwd (Drupal) half of
 * the demo pair. nwp/ops#279, operator GO 2026-08-07 item 2:
 *
 *   "Verify a claim actually appears in a token, not just that the module is
 *    enabled."
 *
 * Run through the sanctioned verb (which staged this file, 0600, outside the
 * docroot, and removes it afterwards):
 *
 *   pl drush nwd --tier=live --execute --script=scripts/demo/nwd-consent-claim.php
 *
 * WHY "THE MODULE IS ENABLED" IS NOT EVIDENCE
 * -------------------------------------------
 * `nwc_oidc_claims` computes the claim in a hook. Between that hook and a
 * consumer reading `$raw->art9_consent` sit: whether the hook is invoked on the
 * userinfo path at all, whether simple_oauth's normalizer keeps unmapped custom
 * claims, whether the scope set in the token permits them, and whether the
 * resource server accepts the token in the first place. Each of those has its
 * own failure mode and none is visible from `pm:list`. So this probe mints a
 * real token, makes a real HTTP request to the real `/oauth/userinfo`, and
 * reads the real response body.
 *
 * NO CREDENTIAL IS EVER PRINTED
 * -----------------------------
 * The access token exists only inside this process and inside the request it
 * makes. It is never echoed, never written to a file, and is deleted from
 * storage before the script exits — so running this owes no rotation entry
 * under the exposure rule. Only the decoded CLAIM SET is printed, and only the
 * boolean claims this probe is about.
 *
 * FAIL-CLOSED: any step that cannot be completed prints CANNOT-VERIFY and exits
 * non-zero. A missing claim and an unreachable endpoint must never both read as
 * "art9_consent: false".
 */

use Drupal\simple_oauth\Entities\ClientEntity;
use Drupal\user\Entity\User;

$exit = 0;

/** Print one reading. */
function reading(string $k, $v): void {
  if (is_bool($v)) {
    $v = $v ? 'true' : 'false';
  }
  echo "{$k}: {$v}\n";
}

/** Record a reading that could not be taken. */
function cannot(string $k, string $why): void {
  global $exit;
  echo "{$k}: CANNOT-VERIFY ({$why})\n";
  $exit = 2;
}

echo "probe: nwd-consent-claim v1\n";
reading('taken_at', gmdate('Y-m-d\TH:i:s\Z'));

// The issuer base URL — the one Moodle actually calls. Under drush CLI there is
// no real request, so \Drupal::request()->getSchemeAndHttpHost() returns
// `http://default`, and a probe that hit THAT would be testing nothing. It is
// supplied by the wrapper from the pair contract (endpoints.<tier>.issuer), the
// same declared fact the OIDC wiring itself is built from.
$wwwroot = '';
foreach ($extra ?? [] as $a) {
  if (str_starts_with((string) $a, '--base-url=')) {
    $wwwroot = rtrim(substr((string) $a, strlen('--base-url=')), '/');
  }
}
if ($wwwroot === '') {
  $wwwroot = rtrim((string) (getenv('NWD_BASE_URL') ?: ''), '/');
}
if ($wwwroot === '' || str_contains($wwwroot, '://default')) {
  cannot('base_url', 'no issuer base URL supplied — pass --base-url=<https://host>');
  $wwwroot = '';
}
else {
  reading('base_url', $wwwroot);
}

// -----------------------------------------------------------------------------
// 1. Pick the subject: a demo persona that HAS explicit consent, and one that
//    does not. Proving both is the point — a probe that only ever sees `true`
//    cannot tell a working claim from a hardcoded one.
// -----------------------------------------------------------------------------
$gate = NULL;
try {
  $gate = \Drupal::service('nwc_privacy.consent_gate');
}
catch (\Throwable $e) {
  cannot('consent_gate', $e->getMessage());
}

$consenting = NULL;
$trialing = NULL;
if ($gate) {
  try {
    $ids = \Drupal::entityQuery('user')
      ->condition('status', 1)
      ->condition('uid', 1, '>')
      ->accessCheck(FALSE)
      ->execute();
    foreach (User::loadMultiple($ids) as $u) {
      $uid = (int) $u->id();
      // Demo tier only: never mint a token for anything but a synthetic account.
      if (!str_ends_with((string) $u->getEmail(), '@demo.invalid')) {
        continue;
      }
      if ($gate->hasExplicitConsent($uid)) {
        $consenting = $consenting ?? $u;
      }
      else {
        $trialing = $trialing ?? $u;
      }
      if ($consenting && $trialing) {
        break;
      }
    }
  }
  catch (\Throwable $e) {
    cannot('subject_selection', $e->getMessage());
  }
}

if (!$consenting) {
  cannot('subject_consenting', 'no @demo.invalid account with explicit Art.9 consent');
}
if (!$trialing) {
  // Not fatal to the positive case, but it means the negative control is absent
  // and the run proves less. Say so rather than quietly skipping it.
  reading('subject_trialing', 'NONE — negative control unavailable this run');
}

// -----------------------------------------------------------------------------
// 2. The OAuth client Moodle uses.
// -----------------------------------------------------------------------------
$consumer = NULL;
try {
  $storage = \Drupal::entityTypeManager()->getStorage('consumer');
  // The demo pair's Moodle client. Resolve by client_id, then fall back to the
  // single non-default consumer if the id differs on this tier.
  foreach (['ssd_moodle', 'ss_moodle'] as $cid) {
    $found = $storage->loadByProperties(['client_id' => $cid]);
    if ($found) {
      $consumer = reset($found);
      break;
    }
  }
  if (!$consumer) {
    $all = $storage->loadMultiple();
    foreach ($all as $c) {
      if (!$c->get('is_default')->value) {
        $consumer = $c;
        break;
      }
    }
  }
}
catch (\Throwable $e) {
  cannot('oauth_client', $e->getMessage());
}
if (!$consumer) {
  cannot('oauth_client', 'no simple_oauth consumer found');
}
else {
  reading('oauth_client', $consumer->get('client_id')->value);
}

/**
 * Mint a short-lived access token for $uid, call /oauth/userinfo with it, and
 * return the decoded claim set. The token is revoked before returning.
 *
 * @return array{status:int, claims:array}|null
 */
function probe_userinfo($consumer, int $uid, string $wwwroot): ?array {
  $client = new ClientEntity($consumer);
  $scopeRepo = \Drupal::service('simple_oauth.repositories.scope');
  $scopes = [];
  foreach (['openid', 'profile', 'email'] as $sid) {
    $s = $scopeRepo->getScopeEntityByIdentifier($sid);
    if ($s) {
      $scopes[] = $s;
    }
  }
  $repo = \Drupal::service('simple_oauth.repositories.access_token');
  $token = $repo->getNewToken($client, $scopes, (string) $uid);
  $token->setIdentifier(bin2hex(random_bytes(20)));
  // Deliberately tiny: this token exists for one request. A long-lived token
  // minted by a probe is a credential the probe forgot it created.
  $token->setExpiryDateTime(new \DateTimeImmutable('+2 minutes'));
  $repo->persistNewAccessToken($token);

  // league/oauth2-server 9.x: setPrivateKey() then toString(). There is no
  // toString($key) overload and no __toString(); calling either fails far from
  // the cause ("privateKey must not be accessed before initialization" /
  // "could not be converted to string"). Both were hit writing this probe.
  $keyPath = \Drupal::config('simple_oauth.settings')->get('private_key');
  $real = \Drupal::service('file_system')->realpath($keyPath) ?: $keyPath;
  $token->setPrivateKey(new \League\OAuth2\Server\CryptKey($real, NULL, FALSE));
  $jwt = $token->toString();

  $status = 0;
  $claims = [];
  try {
    $response = \Drupal::httpClient()->get(rtrim($wwwroot, '/') . '/oauth/userinfo', [
      'headers' => ['Authorization' => 'Bearer ' . $jwt],
      'http_errors' => FALSE,
      'timeout' => 20,
      // The demo box serves its own hostname; keep verification on.
      'verify' => TRUE,
    ]);
    $status = $response->getStatusCode();
    $body = (string) $response->getBody();
    $decoded = json_decode($body, TRUE);
    $claims = is_array($decoded) ? $decoded : [];
  }
  catch (\Throwable $e) {
    $status = -1;
    $claims = ['_error' => $e->getMessage()];
  }
  finally {
    // Revoke immediately — the probe must not leave a usable token behind.
    try {
      $repo->revokeAccessToken($token->getIdentifier());
    }
    catch (\Throwable $e) {
      // Non-fatal; it expires in two minutes regardless.
    }
    // Wipe the local copy so it cannot reach a log or a stack trace.
    $jwt = str_repeat('*', 8);
  }

  return ['status' => $status, 'claims' => $claims];
}

// -----------------------------------------------------------------------------
// 3. Run the positive case, then the negative control.
// -----------------------------------------------------------------------------
$sawpositive = FALSE;
if ($consumer && $consenting) {
  try {
    $r = probe_userinfo($consumer, (int) $consenting->id(), $wwwroot);
    reading('consenting_uid', $consenting->id());
    reading('consenting_userinfo_http', $r['status']);
    if ($r['status'] !== 200) {
      cannot('consenting_userinfo', 'HTTP ' . $r['status']
        . ' — cannot read claims, so their absence proves nothing');
    }
    else {
      $has = array_key_exists('art9_consent', $r['claims']);
      reading('consenting_claim_present', $has);
      if ($has) {
        reading('consenting_art9_consent', var_export($r['claims']['art9_consent'], TRUE));
        reading('consenting_may_keep_formation',
          var_export($r['claims']['may_keep_formation'] ?? '(absent)', TRUE));
        $sawpositive = ((bool) $r['claims']['art9_consent']) === TRUE;
        if (!$sawpositive) {
          echo "note: the claim is present but FALSE for a consented member — "
            . "the carrier works, the decision does not.\n";
        }
      }
      // Name the full claim set so a rename shows up as a rename, not a silence.
      reading('consenting_claims_seen', implode(',', array_keys($r['claims'])));
    }
  }
  catch (\Throwable $e) {
    cannot('consenting_probe', $e->getMessage());
  }
}

if ($consumer && $trialing) {
  try {
    $r = probe_userinfo($consumer, (int) $trialing->id(), $wwwroot);
    reading('trialing_uid', $trialing->id());
    reading('trialing_userinfo_http', $r['status']);
    if ($r['status'] === 200) {
      $v = $r['claims']['art9_consent'] ?? '(absent)';
      reading('trialing_art9_consent', var_export($v, TRUE));
      if ($v === TRUE) {
        // A non-consenting member reading `true` is the one outcome that is
        // worse than no claim at all: it would open the Moodle write gate.
        echo "note: NEGATIVE CONTROL FAILED — a non-consenting member's token "
          . "carries art9_consent=true.\n";
        $exit = 1;
      }
    }
    else {
      cannot('trialing_userinfo', 'HTTP ' . $r['status']);
    }
  }
  catch (\Throwable $e) {
    cannot('trialing_probe', $e->getMessage());
  }
}

// -----------------------------------------------------------------------------
// 4. Verdict.
// -----------------------------------------------------------------------------
if ($exit === 0 && !$sawpositive) {
  $exit = 1;
}

// NO exit() HERE, DELIBERATELY.
//
// `drush php:script` turns ANY exit() the script makes — including exit(0) —
// into "Drush command terminated abnormally" and a drush exit status of 1. A
// probe that exits 0 on success therefore reads as a FAILURE to its caller,
// which is precisely the "check that has never been proven to fail" shape in
// reverse: a passing check reported red teaches the reader to ignore red.
//
// So the verdict travels as the LAST LINE of stdout and the wrapper parses it.
// A missing verdict line means the script died before reaching here, and the
// wrapper treats that as CANNOT-VERIFY — never as a pass.
if ($exit === 0) {
  echo "result: OK — art9_consent rides in a real token from this issuer\n";
}
elseif ($exit === 2) {
  echo "result: CANNOT-VERIFY — do not record this run as evidence\n";
}
else {
  echo "result: FAILED — see the readings above\n";
}
