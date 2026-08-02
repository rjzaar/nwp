<?php
/**
 * scripts/demo/ssd-completion-ws-provision.php
 *
 * Provision the NARROWEST possible Moodle web-service surface that lets the
 * demo-tier Drupal provider (nwd) READ a member's course completions back out
 * of the demo-tier Moodle consumer (ssd).
 *
 * DIRECTION: ssd -> nwd, and ONE DIRECTION ONLY. Nothing here lets Drupal
 * write to Moodle. The three functions exposed are all `read`:
 *
 *     core_webservice_get_site_info    health probe (no member data)
 *     core_user_get_users_by_field     nwd account uuid -> mdl user id
 *     core_enrol_get_users_courses     that user's courses + `completed` flag
 *
 * WHY A TOKEN AT ALL, when auth_nwc already federates identity: OIDC carries
 * claims *into* Moodle at login. It carries nothing back out, and Moodle emits
 * no completion event to anywhere (verified: zero non-core observers of
 * \core\event\course_completed on ssd/ssc). A pull is therefore the only
 * mechanism that exists without inventing a fourth cross-site channel.
 *
 * WHAT THIS DELIBERATELY DOES NOT DO
 *   - does not enable a `write` function, ever;
 *   - does not touch `noemailever`, the demo posture, or enforce_gate;
 *   - does not grant the service account any archetype, any course role, or
 *     any capability beyond the four below;
 *   - does not print the token (see --token-to-nwd).
 *
 * USAGE (always via scripts/demo/ssd-completion-ws-provision.sh)
 *   --check           report state, change nothing, exit 1 if incomplete
 *   --apply           create/repair role, user, service, authorisation, token
 *   --token-to-nwd    additionally write the token into nwd's
 *                     settings.local.overrides.php on the SAME box, so the
 *                     value never crosses the network and never reaches the
 *                     AI-readable tier. Co-located precedent: registry entry
 *                     `nwc_ss_copyright_sync`.
 *   --nwd-root=DIR    nwd Drupal root (default /var/www/nwd)
 */

define('CLI_SCRIPT', true);
require(getcwd() . '/config.php');
global $DB, $CFG;
require_once($CFG->libdir . '/clilib.php');
require_once($CFG->libdir . '/accesslib.php');
require_once($CFG->dirroot . '/webservice/lib.php');
require_once($CFG->dirroot . '/user/lib.php');

list($opts, $unrecognised) = cli_get_params([
    'check' => false, 'apply' => false, 'token-to-nwd' => false,
    'emit-token' => false, 'nwd-root' => '/var/www/nwd', 'help' => false,
], []);

if ($opts['help'] || (!$opts['check'] && !$opts['apply'])) {
    cli_writeln("usage: --check | --apply [--token-to-nwd] [--nwd-root=DIR]");
    exit($opts['help'] ? 0 : 2);
}

const SVC_SHORTNAME = 'nwd_completion_pull';
const SVC_NAME      = 'NWD completion pull (read-only)';
const WS_USERNAME   = 'nwd_completion_reader';
const ROLE_SHORT    = 'nwdcompletionreader';

/** The whole surface. Adding a `write` function here is a boundary change. */
const WS_FUNCTIONS = [
    'core_webservice_get_site_info',
    'core_user_get_users_by_field',
    'core_enrol_get_users_courses',
];

/**
 * The whole capability set, and why each one is here. Every entry was derived
 * by READING enrol/externallib.php on the target, not by guessing:
 *
 *   get_users_courses() line 66:
 *     if (!$sameuser && (!course_can_view_participants($context)
 *                        || !user_can_view_profile($user, $course))) continue;
 *   get_users_courses() line 88:
 *     if ($sameuser || completion_can_view_data($userid, $course))   <- the
 *     branch that populates `completed` / `progress`. Without it the courses
 *     come back but the completion flag never does.
 *
 * Drop any one of these and the pull silently returns an empty array rather
 * than an error, which is the worst possible failure mode — hence the --check
 * mode and the drift assertion below.
 */
const WS_CAPS = [
    // Use the REST endpoint at all.
    'webservice/rest:use'             => CAP_ALLOW,
    // user_can_view_profile() — resolve a member and read their profile.
    'moodle/user:viewdetails'         => CAP_ALLOW,
    // core_user_get_users_by_field(field=idnumber) — idnumber is the UID-lock
    // join key (auth_nwc writes mdl_user.idnumber = the nwd account uuid).
    'moodle/site:viewuseridentity'    => CAP_ALLOW,
    // course_can_view_participants($coursecontext) — MEASURED, not guessed:
    // that helper swaps to the *site* capability only when handed a SYSTEM
    // context. get_users_courses() hands it a COURSE context, so the site
    // variant is inert here and the course variant is the one that counts.
    // Granting it at system inherits it into every course context.
    'moodle/course:viewparticipants'  => CAP_ALLOW,
    // get_users_courses() line 59 calls external_api::validate_context(), which
    // calls require_login($course) — and the reader is enrolled in nothing.
    // Without this the call returns an EMPTY ARRAY, not an error: every course
    // is silently skipped by the catch/continue on line 62. This is the single
    // most confusing failure in the chain, hence the note.
    'moodle/course:view'              => CAP_ALLOW,
    // Withdrawn: proven inert for this call path (see above). Declared so the
    // provisioner actively removes it rather than leaving it lying around.
    'moodle/site:viewparticipants'    => CAP_INHERIT,
    // completion_can_view_data() — the completion flag itself.
    'report/completion:view'          => CAP_ALLOW,
    // Explicitly DENIED: a reader must not see what a member cannot.
    'moodle/course:viewhiddencourses' => CAP_PREVENT,
    'moodle/course:viewhiddenuserfields' => CAP_PREVENT,
];

/**
 * Site settings this bridge REQUIRES, with the value they must hold.
 *
 * showuseridentity gates which fields core_user_get_users_by_field will even
 * search: with the stock 'email' the idnumber lookup returns [] — no error,
 * just nothing. We join on idnumber and not on email deliberately. idnumber is
 * the contractual UID-lock (pairs/ssd.pair-contract.yml oidc.user_field_mappings
 * sub->idnumber); email is mutable and the same contract sets
 * link_legacy_by_email: 0 precisely to stop identities being joined by email.
 * Falling back to an email join would quietly reintroduce that.
 */
const REQUIRED_SETTINGS = [
    'showuseridentity' => ['must_contain' => 'idnumber'],
];

$apply   = (bool) $opts['apply'];
$syscx   = context_system::instance();
$problems = [];
$did      = [];

function note(string $m): void { cli_writeln('  ' . $m); }

// ---------------------------------------------------------------- prereqs --
cli_writeln('== prerequisites');
foreach (['enablewebservices' => 1] as $k => $want) {
    $have = (int) get_config('moodle', $k);
    if ($have !== $want) {
        $problems[] = "$k is $have, want $want";
        note("MISSING $k=$want (have $have)");
    } else {
        note("ok $k=$have");
    }
}
$protocols = (string) get_config('moodle', 'webserviceprotocols');
if (strpos($protocols, 'rest') === false) {
    $problems[] = "rest protocol not enabled (have '$protocols')";
    note("MISSING rest in webserviceprotocols ('$protocols')");
} else {
    note("ok webserviceprotocols=$protocols");
}

// ------------------------------------------------------- required settings --
cli_writeln('== required site settings');
foreach (REQUIRED_SETTINGS as $name => $rule) {
    $cur = (string) get_config('moodle', $name);
    $need = $rule['must_contain'];
    $parts = array_filter(array_map('trim', explode(',', $cur)), 'strlen');
    if (in_array($need, $parts, true)) {
        note("ok $name='$cur' (contains $need)");
        continue;
    }
    if (!$apply) {
        $problems[] = "$name must contain '$need' (is '$cur')";
        note("MISSING $name must contain '$need' (is '$cur')");
        continue;
    }
    $parts[] = $need;
    $new = implode(',', $parts);
    set_config($name, $new);
    // The prior value is the rollback row; print it, it is not a secret.
    $did[] = "$name '$cur' -> '$new'";
    note("set $name='$new'  (PREVIOUS VALUE WAS '$cur' — rollback with that)");
}

// ------------------------------------------------------------------- role --
cli_writeln('== role ' . ROLE_SHORT);
$role = $DB->get_record('role', ['shortname' => ROLE_SHORT]);
if (!$role) {
    if (!$apply) { $problems[] = 'role missing'; note('MISSING (would create)'); }
    else {
        $rid = create_role('NWD completion reader (read-only WS)', ROLE_SHORT,
            'Read-only web-service reader used by nwd to pull course completions back to the Drupal provider. Created by scripts/demo/ssd-completion-ws-provision.php. No archetype: it inherits nothing.');
        set_role_contextlevels($rid, [CONTEXT_SYSTEM]);
        $role = $DB->get_record('role', ['id' => $rid]);
        $did[] = 'created role ' . ROLE_SHORT;
        note('created id=' . $rid);
    }
} else {
    note('exists id=' . $role->id);
}
if ($role) {
    foreach (WS_CAPS as $cap => $perm) {
        $cur = $DB->get_record('role_capabilities',
            ['roleid' => $role->id, 'capability' => $cap, 'contextid' => $syscx->id]);
        $have = $cur ? (int) $cur->permission : CAP_INHERIT;
        if ($have !== $perm) {
            if (!$apply) { $problems[] = "cap $cap"; note("MISSING cap $cap (have $have want $perm)"); }
            else if ($perm === CAP_INHERIT) {
                unassign_capability($cap, $role->id, $syscx->id);
                $did[] = "cap $cap withdrawn";
                note("withdrew cap $cap");
            } else {
                assign_capability($cap, $perm, $role->id, $syscx->id, true);
                $did[] = "cap $cap=$perm";
                note("set cap $cap=$perm");
            }
        } else {
            note("ok cap $cap=$perm");
        }
    }
    // Nothing else may be granted. Report drift loudly rather than silently.
    $extra = $DB->get_records_select('role_capabilities',
        'roleid = ? AND ' . $DB->sql_like('capability', '?', true, true, true),
        [$role->id, '%'], '', 'capability');
    foreach ($extra as $c) {
        if (!array_key_exists($c->capability, WS_CAPS)) {
            $problems[] = 'UNEXPECTED capability on the reader role: ' . $c->capability;
            note('DRIFT unexpected cap ' . $c->capability);
        }
    }
}

// ------------------------------------------------------------------- user --
cli_writeln('== service account ' . WS_USERNAME);
$wsuser = $DB->get_record('user', ['username' => WS_USERNAME, 'mnethostid' => $CFG->mnet_localhost_id]);
if (!$wsuser) {
    if (!$apply) { $problems[] = 'ws user missing'; note('MISSING (would create)'); }
    else {
        $u = new stdClass();
        $u->username    = WS_USERNAME;
        $u->auth        = 'webservice';   // cannot log in interactively
        $u->firstname   = 'NWD';
        $u->lastname    = 'Completion Reader';
        // demo.invalid: never deliverable, matches the demo tier's own convention.
        $u->email       = 'nwd-completion-reader@demo.invalid';
        $u->password    = AUTH_PASSWORD_NOT_CACHED;
        $u->confirmed   = 1;
        $u->policyagreed = 1;
        $u->mnethostid  = $CFG->mnet_localhost_id;
        $u->id = user_create_user($u, false, false);
        $wsuser = $DB->get_record('user', ['id' => $u->id]);
        $did[] = 'created ws user';
        note('created id=' . $wsuser->id);
    }
} else {
    note('exists id=' . $wsuser->id . ' auth=' . $wsuser->auth);
}

if ($role && $wsuser) {
    $assigned = user_has_role_assignment($wsuser->id, $role->id, $syscx->id);
    if (!$assigned) {
        if (!$apply) { $problems[] = 'role not assigned'; note('MISSING role assignment'); }
        else { role_assign($role->id, $wsuser->id, $syscx->id); $did[] = 'role assigned'; note('assigned role at system context'); }
    } else {
        note('ok role assigned at system context');
    }
}

// ---------------------------------------------------------------- service --
cli_writeln('== external service ' . SVC_SHORTNAME);
$svc = $DB->get_record('external_services', ['shortname' => SVC_SHORTNAME]);
if (!$svc) {
    if (!$apply) { $problems[] = 'service missing'; note('MISSING (would create)'); }
    else {
        $s = new stdClass();
        $s->name             = SVC_NAME;
        $s->shortname        = SVC_SHORTNAME;
        $s->enabled          = 1;
        $s->restrictedusers  = 1;   // only the authorised account may use it
        $s->downloadfiles    = 0;
        $s->uploadfiles      = 0;
        $s->component        = null;
        $s->timecreated      = time();
        $s->id = $DB->insert_record('external_services', $s);
        $svc = $DB->get_record('external_services', ['id' => $s->id]);
        $did[] = 'created service';
        note('created id=' . $svc->id);
    }
} else {
    note('exists id=' . $svc->id . " enabled={$svc->enabled} restrictedusers={$svc->restrictedusers}");
    if ((int) $svc->restrictedusers !== 1) {
        $problems[] = 'service is NOT restrictedusers';
        note('DRIFT restrictedusers != 1');
    }
}

if ($svc) {
    $have = $DB->get_fieldset_select('external_services_functions', 'functionname', 'externalserviceid = ?', [$svc->id]);
    foreach (WS_FUNCTIONS as $fn) {
        if (!$DB->record_exists('external_functions', ['name' => $fn])) {
            $problems[] = "function $fn is not defined on this Moodle";
            note("MISSING core function $fn");
            continue;
        }
        if (!in_array($fn, $have, true)) {
            if (!$apply) { $problems[] = "fn $fn"; note("MISSING fn $fn"); }
            else {
                $DB->insert_record('external_services_functions',
                    (object) ['externalserviceid' => $svc->id, 'functionname' => $fn]);
                $did[] = "fn $fn";
                note("added fn $fn");
            }
        } else {
            note("ok fn $fn");
        }
    }
    foreach ($have as $fn) {
        if (!in_array($fn, WS_FUNCTIONS, true)) {
            $problems[] = 'UNEXPECTED function on the service: ' . $fn;
            note('DRIFT unexpected fn ' . $fn);
        }
    }

    if ($wsuser) {
        if (!$DB->record_exists('external_services_users', ['externalserviceid' => $svc->id, 'userid' => $wsuser->id])) {
            if (!$apply) { $problems[] = 'user not authorised on service'; note('MISSING authorisation'); }
            else {
                $DB->insert_record('external_services_users', (object) [
                    'externalserviceid' => $svc->id, 'userid' => $wsuser->id,
                    'timecreated' => time(),
                ]);
                $did[] = 'authorised ws user on service';
                note('authorised user on service');
            }
        } else {
            note('ok user authorised on service');
        }
    }
}

// ------------------------------------------------------------------ token --
cli_writeln('== token');
// Moodle 4.2 moved the token API into \core_external and deprecated the
// global. Resolve both so this script works on 4.1 LTS and 4.4 alike.
// The CONSTANT stayed global through 4.4 (EXTERNAL_TOKEN_PERMANENT === 0);
// only the FUNCTION moved. Measured on ssd live, Moodle 4.4.12+:
//   class_exists('\core_external\token')  => false
//   class_exists('\core_external\util')   => true
//   function_exists('external_generate_token') => false
// so resolve the callable, never the class constant.
$tokentype = defined('EXTERNAL_TOKEN_PERMANENT') ? EXTERNAL_TOKEN_PERMANENT : 0;
$mint = static function (object $svc, int $userid, $cx) use ($tokentype) {
    if (method_exists('\core_external\util', 'generate_token')) {
        return \core_external\util::generate_token($tokentype, $svc, $userid, $cx);
    }
    if (function_exists('external_generate_token')) {
        return external_generate_token($tokentype, $svc, $userid, $cx);
    }
    throw new \moodle_exception('no token-generation API found on this Moodle');
};

$token = null;
if ($svc && $wsuser) {
    $existing = $DB->get_record('external_tokens', [
        'externalserviceid' => $svc->id, 'userid' => $wsuser->id, 'tokentype' => $tokentype,
    ]);
    if ($existing) {
        note('exists (id=' . $existing->id . ', created ' . userdate($existing->timecreated) . ')');
        $token = $existing->token;
    } else if (!$apply) {
        $problems[] = 'token missing';
        note('MISSING (would mint)');
    } else {
        $token = $mint($svc, (int) $wsuser->id, $syscx);
        $did[] = 'minted token';
        note('minted (value NOT printed)');
    }
}

// --------------------------------------------- co-located hand-off to nwd --
// The token is minted on this box and consumed by a Drupal site on the SAME
// box. Writing it straight across means the value never traverses the network
// and never lands in the AI-readable secret tier.
if ($opts['token-to-nwd']) {
    cli_writeln('== hand-off to nwd settings.local.overrides.php');
    if (!$token) {
        $problems[] = 'no token to hand off';
        note('SKIP no token');
    } else {
        $file = rtrim($opts['nwd-root'], '/') . '/html/sites/default/settings.local.overrides.php';
        if (!is_file($file)) {
            $problems[] = "nwd overrides file not found: $file";
            note('MISSING ' . $file);
        } else if (!$apply) {
            note('would rewrite the nwc_moodle_data webservice_token line in ' . $file);
        } else {
            $src  = file_get_contents($file);
            $line = "\$config['nwc_moodle_data.settings']['webservice_token'] = '" . addslashes($token) . "';";
            $re   = "~^\\\$config\\['nwc_moodle_data\\.settings'\\]\\['webservice_token'\\].*$~m";
            $new  = preg_match($re, $src)
                ? preg_replace($re, $line, $src)
                : rtrim($src, "\n") . "\n\n// ssd->nwd completion pull (read-only Moodle WS token).\n"
                  . "// Minted by scripts/demo/ssd-completion-ws-provision.php; see secrets-registry\n"
                  . "// id: ssd_nwd_completion_ws.\n" . $line . "\n";
            if ($new !== $src) {
                $bak = $file . '.pre-completion-ws.' . date('Ymd\THis\Z', time());
                file_put_contents($bak, $src);
                @chmod($bak, 0640);
                file_put_contents($file, $new);
                $did[] = 'wrote token into nwd overrides (backup ' . basename($bak) . ')';
                note('wrote (value NOT printed); backup ' . basename($bak));
            } else {
                note('ok already current');
            }
        }
    }
}

// ------------------------------------------------------- capture (no echo) --
// --emit-token writes the value on ONE marked line so the shell wrapper can
// redirect it straight into a 0600 file. It is never rendered to a terminal by
// the wrapper, which greps the marker out and drops the rest. Use this only to
// seed `.secrets.yml` so `pl secrets` can own rotation/audit thereafter; on a
// tier where the value must NOT reach the AI-readable store, use
// --token-to-nwd instead and the value never leaves the box.
if ($opts['emit-token']) {
    if ($token) {
        cli_writeln('NWP-WS-TOKEN:' . $token);
    } else {
        $problems[] = 'no token to emit';
    }
}

// ----------------------------------------------------------------- report --
cli_writeln('');
if ($did)      { cli_writeln('CHANGED: ' . implode('; ', $did)); }
if ($problems) { cli_writeln('INCOMPLETE: ' . implode('; ', $problems)); exit(1); }
cli_writeln($apply ? 'APPLY-OK' : 'CHECK-OK');
exit(0);
