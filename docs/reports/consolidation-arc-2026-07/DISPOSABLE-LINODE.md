# ⚠️ DISPOSABLE Linode — MUST BE TORN DOWN

- **Purpose:** ops#120 ADR-0032 live-host validation (throwaway).
- **id:** 101301964  ·  **ip:** 172.239.153.133  ·  label: nwp-arc-test-120  ·  region us-iad-2  ·  g6-standard-2 (~$0.036/hr)
- **Created:** 2026-07-25  ·  tags: arc-disposable, ops120
- **root pass:** scratchpad/linode-rootpass.txt (0600) — SSH key ~/.ssh/nwp is the real access.

## TEARDOWN (run when validation done — do NOT leave it billing):
```
lk=$(cd ~/nwp && bash -c 'source lib/common.sh; get_infra_secret linode.provision_token ""')
curl -s -X DELETE -H "Authorization: Bearer $lk" https://api.linode.com/v4/linode/instances/101301964
```

## [ver-harness] nwp-vertest-ver-20260725-082615 — ACTIVE until torn down
- **id:** 101309316  ·  **ip:** 172.239.153.133  ·  role: test-ver  ·  region us-iad-2  ·  g6-standard-2  ·  tags arc-disposable,ver-harness
- **Created:** 2026-07-24T22:26Z by `pl ver-test` (task #11 / ops#25+#127)
- Teardown: `pl ver-test teardown`  (or: `curl -X DELETE .../linode/instances/101309316` with the provision token)

## [ver-harness] nwp-vertest-prod-20260725-083946 — ACTIVE until torn down
- **id:** 101310154  ·  **ip:** 172.239.154.43  ·  role: test-prod  ·  region us-iad-2  ·  g6-standard-2  ·  tags arc-disposable,ver-harness
- **Created:** 2026-07-24T22:39Z by `pl ver-test` (task #11 / ops#25+#127)
- Teardown: `pl ver-test teardown`  (or: `curl -X DELETE .../linode/instances/101310154` with the provision token)
- **TORN DOWN** 2026-07-24T22:46Z: test-prod id 101310154 — DELETE HTTP 200, verify GET now HTTP 404 ✓
- **TORN DOWN** 2026-07-24T22:46Z: test-ver id 101309316 — DELETE HTTP 200, verify GET now HTTP 404 ✓
