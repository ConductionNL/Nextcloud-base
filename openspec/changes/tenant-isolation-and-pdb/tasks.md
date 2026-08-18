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

## 3. Observe real traffic (read-only)

- [ ] 3.1 Enable Calico flow logging for one tenant namespace with real traffic — an accept
      tenant is too quiet to be representative
- [ ] 3.2 Run an observation window long enough to include the background jobs (cron, sync,
      app updates), not just interactive use. Record the window length with the result
- [ ] 3.3 Produce the destination inventory: address, port, and which component initiates it
- [ ] 3.4 Settle whether `openconnector` targets are per tenant. If they are, egress policy
      becomes per-tenant data and phase 6 needs redesigning before it is built
- [ ] 3.5 Verify how kubelet probe traffic presents under Calico. The deleted chart assumed it
      needed `ipBlock: 0.0.0.0/0`, which negated its own ingress restriction — do not repeat
      that without evidence

## 4. Chart and delivery

- [ ] 4.1 `charts/tenant-networkpolicy`, renders nothing unless
      `tenant.networkPolicy.enabled` is set
- [ ] 4.2 ApplicationSet `nextcloud-tenant-netpol` with a post-selector on that flag. NOT a
      source on `nextcloud-tenants` — that changes the spec of all 84 Applications; and
      `templatePatch` cannot avoid it because a merge patch replaces lists. Precedent:
      `nextcloud-tenant-routes`
- [ ] 4.3 `scripts/verify.sh` renders and validates the new chart like the others

## 5. Ingress policy (the part that closes the gap)

- [ ] 5.1 Namespace default-deny for ingress, plus allows for: `ingress-nginx`,
      `envoy-gateway-system`, kubelet probes as established in 3.5, and Prometheus scraping
- [ ] 5.2 Canary tenant only. Verify from outside that the tenant still serves, and verify
      from a pod in another tenant namespace that it no longer reaches this one — that second
      check is the actual proof and is easy to forget
- [ ] 5.3 Confirm the ServiceMonitor still scrapes; a broken metrics path is the quiet failure
      mode here
- [ ] 5.4 Observation window on the canary before any wave. Record the length
- [ ] 5.5 HUMAN: waves, one at a time, with an observation window each

## 6. Egress policy (separate, after ingress is quiet)

- [ ] 6.1 Design from the 3.3 inventory. Every rule carries a comment naming what needs it.
      No `0.0.0.0/0` without a dated justification
- [ ] 6.2 Canary first, same two-sided verification and observation window as phase 5
- [ ] 6.3 HUMAN: waves

## 7. PodDisruptionBudget — record the decision, ship nothing

- [ ] 7.1 Write the decision into `docs/HAVEN-COMPLIANCE.md` §5: no PDB while `replicaCount`
      is 1, because `minAvailable: 1` on one replica blocks node drains and
      `maxUnavailable: 1` asserts nothing. Name the trigger that reopens it (RS>1 landing via
      `nextcloud-ha` / `stateless-nextcloud-ha`)
- [ ] 7.2 Cross-reference from those two changes, so whoever lands RS>1 sees the PDB is owed

## 8. Verify & archive

- [ ] 8.1 `./scripts/verify.sh` green; `docs/HAVEN-COMPLIANCE.md` §5 and §9 describe what runs
      instead of naming a gap; changelog fragment added
- [ ] 8.2 Re-run the two-sided isolation check on a sample of migrated tenants — the control is
      only real if cross-tenant traffic is actually refused
- [ ] 8.3 Archive this change
