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
