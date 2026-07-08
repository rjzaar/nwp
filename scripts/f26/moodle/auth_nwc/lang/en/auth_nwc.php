<?php
// auth_nwc language strings — F26 nwc<->ss OIDC client.
// GNU GPL v3 or later. Copyright 2026 Narrow Way Project.

defined('MOODLE_INTERNAL') || die();

$string['pluginname'] = 'NWC OIDC (F26)';
$string['auth_nwcdescription'] = 'Single sign-on with Narrow Way Commons (nwc / Drupal) over OpenID Connect. Binds each Moodle account to the nwc user id (idnumber lock, F26 §3.2). AUTH SURFACE — human review gated.';

$string['nwc_url'] = 'nwc base URL';
$string['nwc_url_desc'] = 'Base URL of the nwc (Drupal) issuer, e.g. https://nwc-dev.ddev.site. Used for password/profile links.';

$string['issuerid'] = 'OAuth2 issuer id';
$string['issuerid_desc'] = 'The numeric id of the custom OAuth2 service you created under Site admin > Server > OAuth2 services pointing at nwc. See moodle/INSTALL.md.';

$string['autoredirect'] = 'Auto-redirect to nwc';
$string['autoredirect_desc'] = 'Send users straight to nwc login instead of showing the Moodle login form.';

$string['link_legacy_by_email'] = 'Migration: link legacy accounts by verified email';
$string['link_legacy_by_email_desc'] = 'MIGRATION WINDOW ONLY. When enabled, a first OIDC login whose verified email matches an existing pre-OIDC Moodle account binds that account to the nwc uid once (sets idnumber). Afterwards, matching is always by idnumber. Leave OFF outside a migration window.';

$string['enable_logging'] = 'Developer logging';
$string['enable_logging_desc'] = 'Emit UID-lock decisions to the developer log (DEBUG_DEVELOPER only).';

$string['privacy:metadata'] = 'The NWC OIDC plugin does not store personal data itself; identity is asserted by the nwc issuer and stored in the standard Moodle user record.';
