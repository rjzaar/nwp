<?php
// This file is part of the auth_nwc plugin for Moodle.
//
// Pure guild→cohort reconciliation decision. NO Moodle dependency, so the
// mapping logic can be unit-tested without a database — the same pattern as
// uid_lock. All I/O (userinfo fetch, cohort create, membership add/remove)
// lives in auth_plugin_nwc::sync_guilds(); this class only decides.

namespace auth_nwc;

defined('MOODLE_INTERNAL') || die();

/**
 * Decides how a member's Moodle cohorts should change to match their nwc guilds.
 *
 * The nwc provider emits a `guilds` claim per ADR-0031 / the oauth_sso.claims
 * contract: an array of {id, uuid, label, type, roles[]}. `uuid` is the STABLE
 * key — id is a serial that renumbers on a DB rebuild, exactly the failure that
 * ADR-0031 D9 fixed for `sub`. So cohorts are bound to the guild UUID, never to
 * id and never to label.
 *
 * A Moodle cohort is "managed by nwc" iff its idnumber is MANAGED_PREFIX . uuid.
 * That prefix is load-bearing: it is how we guarantee we NEVER add to or remove
 * from a cohort an operator created by hand. Removal only ever targets managed
 * cohorts the member is no longer in.
 */
final class guild_cohort_map {

    /**
     * idnumber prefix that marks a cohort as nwc-guild-managed.
     *
     * Membership is only ever added to / removed from cohorts whose idnumber
     * starts with this. Anything else is the operator's and is never touched.
     */
    const MANAGED_PREFIX = 'nwcguild:';

    /**
     * The cohort idnumber for a given guild uuid.
     */
    public static function idnumber_for(string $uuid): string {
        return self::MANAGED_PREFIX . $uuid;
    }

    /**
     * Whether a cohort idnumber is one we manage.
     */
    public static function is_managed(string $idnumber): bool {
        return strncmp($idnumber, self::MANAGED_PREFIX, strlen(self::MANAGED_PREFIX)) === 0;
    }

    /**
     * The guild uuid encoded in a managed cohort idnumber (or '' if not ours).
     */
    public static function uuid_from(string $idnumber): string {
        if (!self::is_managed($idnumber)) {
            return '';
        }
        return substr($idnumber, strlen(self::MANAGED_PREFIX));
    }

    /**
     * Decide the cohort changes for a member.
     *
     * @param array $guilds
     *   The `guilds` claim: a list of ['uuid' => string, 'label' => string, ...].
     *   Entries without a non-empty uuid are ignored (a guild with no stable key
     *   cannot be safely bound — better to skip than to bind on a renumbering id).
     * @param string[] $current_managed_uuids
     *   The guild uuids the member is CURRENTLY in via managed cohorts.
     * @return array{
     *     ensure: array<int, array{uuid: string, label: string}>,
     *     leave: string[],
     *     reasons: string[]
     *   }
     *   `ensure` = guilds the member must be a member of (create cohort if
     *   missing, then add). `leave` = guild uuids of managed cohorts the member
     *   must be removed from. Membership already correct appears in neither.
     */
    public static function decide(array $guilds, array $current_managed_uuids): array {
        $want = [];
        $reasons = [];
        foreach ($guilds as $g) {
            $uuid = isset($g['uuid']) ? trim((string) $g['uuid']) : '';
            if ($uuid === '') {
                $reasons[] = 'skipped a guild with no uuid (cannot bind on renumber-fragile id)';
                continue;
            }
            $label = isset($g['label']) ? trim((string) $g['label']) : '';
            if ($label === '') {
                $label = $uuid;
            }
            $want[$uuid] = $label;
        }

        $current = [];
        foreach ($current_managed_uuids as $u) {
            $u = trim((string) $u);
            if ($u !== '') {
                $current[$u] = true;
            }
        }

        $ensure = [];
        foreach ($want as $uuid => $label) {
            // Always emit ensure entries: the executor is idempotent (skips if
            // already a member) and this is also what CREATES a missing cohort.
            $ensure[] = ['uuid' => $uuid, 'label' => $label];
        }

        $leave = [];
        foreach ($current as $uuid => $_) {
            if (!isset($want[$uuid])) {
                $leave[] = $uuid;
            }
        }

        return ['ensure' => $ensure, 'leave' => $leave, 'reasons' => $reasons];
    }

}
