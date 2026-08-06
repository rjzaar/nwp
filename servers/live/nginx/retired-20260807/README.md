# Retired vhosts — 2026-08-07

`avc.conf` + `avctest.conf`: retired per the operator's go on nwp/ops#188
(reversible-mv on the box: confs in /etc/nginx/conf.d/retired-20260807/,
docroots at /var/www/{avc,avctest}.retired-20260807, certbot renewal conf
disabled). Moved OUT of the tracked conf.d baseline so `pl server conf-drift`
does not flag them UNDEPLOYED and invite an accidental un-retire — the exact
mechanism of the ops#303 nwd incident, inverted.

ADR-0015 AMENDMENT (recorded here; the ADR's "AVC stays live indefinitely as
comparison" clause is superseded): avc 1.x was FROZEN 2026-07-01, nwc is
canonical, the content was verified fully present in nwc (nwp/ops#188,
2026-08-06 research — 11 original nodes mapped, guild prose independently
authored), and the site retired 2026-08-07. The comparison-fallback role named
in REFACTOR-PLAN-AVC-TO-NWC.md and REFACTOR-DEFERRED-R4-R6-R7-R8.md no longer
exists; those docs are historical.
