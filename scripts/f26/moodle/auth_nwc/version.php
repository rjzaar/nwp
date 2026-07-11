<?php
// auth_nwc — Moodle OIDC client for the F26 nwc<->ss single sign-on.
// AUTH SURFACE — REQUIRES HUMAN REVIEW BEFORE MERGE/ENABLE.
// GNU GPL v3 or later. Copyright 2026 Narrow Way Project.

defined('MOODLE_INTERNAL') || die();

$plugin->component = 'auth_nwc';
$plugin->version   = 2026071101;      // YYYYMMDDXX (bumped for the v1.0.0 release cut)
$plugin->requires  = 2022041900;      // Moodle 4.0+
$plugin->maturity  = MATURITY_STABLE; // merged to nwp/nwp main + live-proven end-to-end on ssc (F26).
$plugin->release   = '1.0.0';         // ADR-0031 D3: tag = v + $plugin->release (=> v1.0.0).
// Rides on Moodle core OAuth2 for the protocol dance (issuer/endpoints/keys).
$plugin->dependencies = [];
