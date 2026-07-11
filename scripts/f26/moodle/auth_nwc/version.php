<?php
// auth_nwc — Moodle OIDC client for the F26 nwc<->ss single sign-on.
// AUTH SURFACE — REQUIRES HUMAN REVIEW BEFORE MERGE/ENABLE.
// GNU GPL v3 or later. Copyright 2026 Narrow Way Project.

defined('MOODLE_INTERNAL') || die();

$plugin->component = 'auth_nwc';
$plugin->version   = 2026071100;      // YYYYMMDDXX
$plugin->requires  = 2022041900;      // Moodle 4.0+
$plugin->maturity  = MATURITY_ALPHA;  // F26 build-out; human-gated.
$plugin->release   = '0.1.0-f26';
// Rides on Moodle core OAuth2 for the protocol dance (issuer/endpoints/keys).
$plugin->dependencies = [];
