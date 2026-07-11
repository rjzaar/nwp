<?php
// auth_nwc event observers — F26 nwc<->ss OIDC UID-lock wiring (B1).
//
//   AUTH SURFACE — REQUIRES HUMAN REVIEW BEFORE MERGE/ENABLE.
//   UNTESTED ON MOODLE — draft for two-person review.
//
// GNU GPL v3 or later. Copyright 2026 Narrow Way Project.
//
// Core auth_oauth2 completes an OIDC login via complete_user_login(), which
// bypasses authenticate_user_login() and therefore never fires
// auth_plugin_base::user_authenticated_hook(). The only reliable post-auth seam
// is \core\event\user_loggedin (fired by complete_user_login() for every login).

defined('MOODLE_INTERNAL') || die();

$observers = [
    [
        'eventname' => '\core\event\user_loggedin',
        'callback'  => '\auth_nwc\observer::user_loggedin',
        // internal=true -> observer runs synchronously in the login request, so a
        // DENY/SUSPEND decision can kill the session before the response returns.
        // A queued/cron observer could not reject the login it is meant to block.
        'internal'  => true,
    ],
];
