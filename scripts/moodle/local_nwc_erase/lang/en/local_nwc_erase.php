<?php
defined('MOODLE_INTERNAL') || die();

$string['pluginname'] = 'NWC Erasure Receiver';
$string['nwc_erase:manage'] = 'Manage the NWC erasure receiver (token / kill switch)';
$string['setting_enabled'] = 'Enable NWC → SS erasure';
$string['setting_enabled_desc'] = 'DESTRUCTIVE. When enabled, accept POSTs from NWC on /local/nwc_erase/erase.php and perform a Privacy-API erasure of the matching user (resolved by idnumber == sub). Leave OFF unless the operator has explicitly wired this channel.';
$string['setting_admin_token'] = 'Shared bearer token';
$string['setting_admin_token_desc'] = 'Bearer token required in the Authorization header. Must match the value configured at NWC (nwc_moodle_erase.settings:admin_token). On a real prod tier this is a ver-held secret.';
$string['setting_allowed_ips'] = 'Allowed source IPs (optional)';
$string['setting_allowed_ips_desc'] = 'Comma-separated list. If set, requests from any other IP are rejected.';
$string['setting_allowed_issuer'] = 'Allowed issuer (optional)';
$string['setting_allowed_issuer_desc'] = 'If set, the command\'s issuer field must match this exactly (binds the channel to a single nwc issuer identity).';
$string['privacy:metadata'] = 'The NWC Erasure Receiver stores an audit log of erase commands (the durable account UUID, never an email) so that erasures are auditable on both sides.';
