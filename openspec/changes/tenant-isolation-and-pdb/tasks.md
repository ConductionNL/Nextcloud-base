# Tasks: tenant-isolation-and-pdb

## 1. Approval

- [ ] 1.1 HUMAN: APPROVED (Mark, <date>) — in particular the recommendation **not** to add a
      PodDisruptionBudget while `replicaCount` is 1, and the staged ingress-before-egress
      rollout over a live fleet

## 2. Re-measure (read-only)

The numbers in `proposal.md` are from 2026-08-17. A default-deny built on a stale inventory is
how this goes wrong.

- [ ] 2.1 Confirm still zero PDBs selecting `app.kubernetes.io/name: nextcloud`
- [ ] 2.2 Confirm still zero NetworkPolicies selecting the Nextcloud pod
- [ ] 2.3 Confirm every tenant namespace carries
      `app.kubernetes.io/part-of: nextcloud-platform`, and that the platform `redis` and
      `pgbouncer` policies still key on it
- [ ] 2.4 List which tenants are already served by Envoy Gateway, so the ingress rule covers
      both front doors

## 3. Chart and delivery

- [ ] 3.1 `charts/tenant-networkpolicy`, renders nothing unless
      `tenant.networkPolicy.enabled` is set
- [ ] 3.2 ApplicationSet `nextcloud-tenant-netpol` with a post-selector on that flag. NOT a
      source on `nextcloud-tenants` — that changes the spec of all 84 Applications; and
      `templatePatch` cannot avoid it because a merge patch replaces lists. Precedent:
      `nextcloud-tenant-routes`
- [ ] 3.3 `scripts/verify.sh` renders and validates the new chart like the others
- [ ] 3.4 Verify how kubelet probe traffic presents under Calico. The deleted chart assumed it
      needed `ipBlock: 0.0.0.0/0`, which negated its own ingress restriction — do not repeat
      that without evidence

## 4. Ingress policy (the part that closes the gap)

No observation window needed: the set is small and knowable — the ingress
controller, the Envoy Gateway namespace, kubelet probes and Prometheus.

- [ ] 4.1 Namespace default-deny for ingress, plus allows for: `ingress-nginx`,
      `envoy-gateway-system`, kubelet probes as established in 3.4, and Prometheus scraping
- [ ] 4.2 Canary tenant only. Verify from outside that the tenant still serves, and verify
      from a pod in another tenant namespace that it no longer reaches this one — that second
      check is the actual proof and is easy to forget
- [ ] 4.3 Confirm the ServiceMonitor still scrapes; a broken metrics path is the quiet failure
      mode here
- [ ] 4.4 Observation window on the canary before any wave. Record the length
- [ ] 4.5 HUMAN: waves, one at a time, with an observation window each

## 5. Observe real traffic — only for egress (read-only)

Deliberately AFTER the ingress policy, not before it. Ingress is a closed, knowable
set; egress is not, and it is the side where `openconnector` reaches arbitrary
third parties. Putting the observation window first would have delayed the part
that actually closes the gap.

- [ ] 5.1 Enable Calico flow logging for one tenant namespace with real traffic — an accept
      tenant is too quiet to be representative
- [ ] 5.2 Run an observation window long enough to include the background jobs (cron, sync,
      app updates), not just interactive use. Record the window length with the result
- [ ] 5.3 Produce the destination inventory: address, port, and which component initiates it
- [ ] 5.4 Settle whether `openconnector` targets are per tenant. If they are, egress policy
      becomes per-tenant data and phase 6 needs redesigning before it is built

## 6. Egress policy (separate, after ingress is quiet)

- [ ] 6.1 Design from the 5.3 inventory. Every rule carries a comment naming what needs it.
      No `0.0.0.0/0` without a dated justification
- [ ] 6.2 Canary first, same two-sided verification and observation window as phase 4
- [ ] 6.3 HUMAN: waves

## 7. PodDisruptionBudget — record the decision, ship nothing (afgerond)

- [x] 7.1 Decision recorded in `docs/HAVEN-COMPLIANCE.md` §5 — 2026-08-18: section retitled
      "deliberately absent", with the reasoning (`minAvailable: 1` blocks node drains on a
      single replica, `maxUnavailable: 1` asserts nothing) and the trigger (RS>1 via
      `nextcloud-ha` / `stateless-nextcloud-ha`)
- [x] 7.2 Cross-reference added to both HA proposals — 2026-08-18: a blockquote stating the
      PDB is owed once that change lands, so shipping RS>1 without it is visible as an
      omission

## 8. Verify & archive

- [ ] 8.1 `./scripts/verify.sh` green; `docs/HAVEN-COMPLIANCE.md` §5 and §9 describe what runs
      instead of naming a gap; changelog fragment added
- [ ] 8.2 Re-run the two-sided isolation check on a sample of migrated tenants — the control is
      only real if cross-tenant traffic is actually refused
- [ ] 8.3 Archive this change
