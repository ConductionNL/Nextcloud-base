---
last_reviewed: 2026-08-18
owner: info@conduction.nl
---

# Haven Compliance

> Haven (haven.commonground.nl) is VNG Realisatie's reference standard for how Dutch government
> Kubernetes workloads should be built, packaged, and operated. This document maps Haven's
> pillars to what this platform **already does**, with file-level pointers, so a procurement
> reviewer or tender assessor can verify each claim directly against the source instead of
> taking our word for it.
>
> Nothing in this document changes behaviour — it is a statement of what is already deployed and
> live for real municipal tenants (see `values/tenants/`).

## 1. Containerized, declaratively deployed

Every tenant is a set of Kubernetes resources generated from Git state and reconciled by Argo CD
— there is no manual `kubectl apply` step in the tenant lifecycle.

- Two Argo CD ApplicationSets drive everything: `nextcloud-platform-components` (shared platform
  services) and `nextcloud-tenants` (one Application per `values/tenants/tenant-*.yaml` file).
  See `argo/applicationsets/nextcloud-platform-components.yaml` and
  `argo/applicationsets/nextcloud-tenants.yaml`.
- Each tenant Application is **multi-source**: the core Nextcloud workload comes from the
  upstream, community-maintained `nextcloud/nextcloud` Helm chart
  (`https://nextcloud.github.io/helm/`); this repo supplies layered values plus two small
  companion charts, `charts/tenant-hpa` and `charts/tenant-secret`. Tenants that have
  migrated to Gateway API get a third, `charts/tenant-httproute`, from the separate
  `nextcloud-tenant-routes` ApplicationSet.
- `syncPolicy.automated: { prune: true, selfHeal: true }` — cluster drift is corrected
  automatically back to Git state, and Git state is the only path to changing the cluster (see
  `docs/ARCHITECTURE.md` §2, "Golden rule: Argo reads GitHub").

## 2. Twelve-factor configuration

- Image tag, replica count, resource requests/limits, storage class, hostname, and which
  Conduction apps are enabled are all parameterized via a layered `values/*.yaml` merge —
  `values/common.yaml` → `values/env/{accept,prod}.yaml` → `values/db/{mariadb,postgres,external}.yaml`
  → `values/tenants/tenant-<name>.yaml` — never baked into an image.
- No secret is ever committed: `.gitignore` excludes `*.secret.yaml`, `secrets/`, `env.local`.
  Secrets reach pods via `ExternalSecret` → an ESO `ClusterSecretStore`
  (`platform/externalsecrets/clustersecretstore.yaml`), or a documented fallback in-cluster
  generator Job for environments without ESO. See `docs/SECRETS.md`.

## 3. Health probes

Probes worden per workload gezet, niet platform-breed in één blok. De dekking is
daarom per component gespecificeerd — een claim over "de Nextcloud-container"
zegt niets over de database-subchart, en omgekeerd.

**Nextcloud-container** — `livenessProbe`, `readinessProbe` en `startupProbe`
alle drie aan, met een opstartbudget van 10 minuten:

```yaml
# values/common.yaml (sectie "Probes")
livenessProbe:  { enabled: true, initialDelaySeconds: 60, periodSeconds: 30, failureThreshold: 6 }
readinessProbe: { enabled: true, initialDelaySeconds: 30, periodSeconds: 15, failureThreshold: 3 }
startupProbe:   { enabled: true, initialDelaySeconds: 60, periodSeconds: 10, failureThreshold: 60 }
```

**Database-subchart** — de bitnami-charts leveren standaard *geen* startupProbe.
Het opstartbudget is dan wat liveness toestaat, en dat is kort: MariaDB kreeg
`initialDelaySeconds: 120` + 3×10s ≈ 150s, PostgreSQL `initialDelaySeconds: 30`
+ 6×10s = 90s (gemeten via `helm template` op chart 8.9.0). Daarna schiet de
kubelet de container af; bij een trage of hangende start levert dat een
CrashLoopBackOff op in plaats van één zichtbare fout. Voor **beide** in-cluster
engines is dat expliciet rechtgezet:

```yaml
# values/db/mariadb.yaml én values/db/postgres.yaml
primary.startupProbe: { enabled: true, initialDelaySeconds: 30, periodSeconds: 10, failureThreshold: 60 }
primary.livenessProbe: { enabled: true, initialDelaySeconds: 30, periodSeconds: 10, failureThreshold: 3 }
```

Gemeten met `helm template` per profiel: beide geven een opstartbudget van 630s en
liveness op 30s. Het `external`-profiel levert geen in-cluster database en heeft dus
geen database-probes.

PostgreSQL liep tot 2026-08-05 op 30s + 6×10s = 90 seconden, krapper dan MariaDB's
150s. Bij een onreine stop doet PostgreSQL WAL-recovery voordat hij connecties
opent; wordt hij daar middenin afgeschoten, dan begint recovery elke ronde opnieuw.
Crash-safe, maar permanent down.

## 4. Resource governance

- The main Nextcloud pod runs under a deliberate **limits-only** policy — no CPU/memory
  *requests* on background/non-critical containers, so Kubernetes schedules freely and throttles
  under pressure rather than reserving idle capacity (`values/common.yaml:698-702`, and the
  rationale is spelled out in `CLAUDE.md` → "Resource Policy"). The main pod and nginx do carry
  requests, since guaranteed scheduling matters there.
- Platform-level governance templates exist for tenant namespaces: `ResourceQuota`,
  `LimitRange`, `PriorityClass` — `platform/policies/{resource-quotas,limit-ranges,priority-classes}.yaml`.

## 5. Availability: PodDisruptionBudget — deliberately absent

**Corrected 2026-08-17.** This section claimed every tenant gets a
`PodDisruptionBudget` from a companion chart `platform/tenant-resources`. That chart was
never referenced by any ApplicationSet and has been deleted; the claim was false.

What actually runs: the only `PodDisruptionBudget` in a tenant namespace comes from the
`postgresql` subchart and protects the database, not the Nextcloud workload. Measured
2026-08-17: **zero** PDBs across the fleet select `app.kubernetes.io/name: nextcloud`.

The practical impact is limited today because `replicaCount` is 1 and HPA is disabled for
the reason in §6. A PDB over a single replica does not protect availability: `minAvailable: 1`
stops node drains from ever completing, and `maxUnavailable: 1` permits everything and asserts
nothing. The current position is therefore that no PDB is correct for this topology, and the
trigger that reopens it is RS>1 becoming possible (`nextcloud-ha`, `stateless-nextcloud-ha`).

Tracked in `openspec/changes/tenant-isolation-and-pdb`, which records the decision and its
trigger rather than shipping a manifest.

## 6. Horizontal scaling — status and honest gap

HPA is fully wired (`hpa.enabled`, min/max replicas, CPU + memory targets,
`values/common.yaml:727-732`) but is **`enabled: false` in production today**. The reason is a
specific, documented storage constraint, not an oversight: the Nextcloud code volume
(`/var/www/html`) is provisioned as a `ReadWriteOnce` Cinder PVC, so a second replica cannot
attach it — pod anti-affinity across nodes would leave the tenant permanently unable to run
`replicaCount > 1`. This is called out inline in
`argo/applicationsets/nextcloud-tenants.yaml` and is the explicit subject of two in-flight
OpenSpec changes in this repo: `openspec/changes/nextcloud-ha` and
`openspec/changes/stateless-nextcloud-ha`, which scope a Cinder multi-attach (RWX) StorageClass
migration to unblock RS>1 and activate the existing HPA wiring. We are documenting this
limitation rather than hiding it, per Haven's expectation of auditable, truthful platform
posture.

User-facing files are **not** subject to this constraint — see §8.

## 7. Standard labels and observability

- Every tenant namespace is labelled `app.kubernetes.io/part-of: nextcloud-platform`
  (`argo/applicationsets/nextcloud-tenants.yaml`). That label is what the platform `redis` and
  `pgbouncer` NetworkPolicies key on to admit tenants; it is also what a tenant-side policy would
  use, once there is one (§9).
- Prometheus scrape annotations are set by default (`podAnnotations` in `values/common.yaml`),
  and each tenant has a `ServiceMonitor` — verified present in every tenant namespace on
  2026-08-17. It comes from the **upstream** `nextcloud` chart, not from a companion chart of
  ours; the earlier citation to `platform/tenant-resources` was wrong.

## 8. Resilience to infrastructure churn (S3-primary storage)

User files are stored in Ceph RGW S3, not on a Kubernetes-attached volume
(`persistence.nextcloudData.enabled: false` in `values/common.yaml`). During Kubernetes node
upgrades, CSI attach/mount operations can fail or the OpenStack API can be temporarily
unavailable; because user data lives in S3 rather than on an in-cluster/NFS volume, it stays
reachable independent of cluster node state. See README.md → "Waarom S3 Primary Storage?".

## 9. Multi-tenant isolation

- One Kubernetes namespace per tenant, named after `tenant.name`.
- **Corrected 2026-08-17 — the Nextcloud workload has no NetworkPolicy.** This section cited
  `platform/tenant-resources/templates/networkpolicy.yaml` as the source of default isolation.
  That chart was never deployed by any ApplicationSet and has been deleted.

  What actually runs in a tenant namespace, measured 2026-08-17: one `NetworkPolicy` from the
  `postgresql` subchart, and three (`default-deny`, `allow-ingress`, `allow-egress`) from the
  **React frontend** chart. None of them selects the Nextcloud pod. The claim that "new tenants
  are isolated by default" did not hold for the Nextcloud workload itself.

  The namespace label the policies key on (`app.kubernetes.io/part-of: nextcloud-platform`) *is*
  applied, via `managedNamespaceMetadata` in the tenant ApplicationSet — so the mechanism is in
  place, only the policy that would use it is missing.

  Closing this is a deliberate decision, not a documentation fix: a default-deny over a live
  fleet of ~50 tenants needs its own change with a staged rollout. Tracked in
  `openspec/changes/tenant-isolation-and-pdb` — ingress before egress, opt-in per tenant, and
  the allowlist derived from observed traffic rather than from a design-time guess.

## 10. Auditability and rollback

- Git history on `main` **is** the deploy history: every change to a running tenant traces to a
  commit, author, and PR. `selfHeal: true` means any out-of-band cluster edit is reverted back to
  Git state automatically, so the cluster cannot silently diverge from what's reviewable in Git.
- Canary-first, wave-gated rollout strategy with explicit rollback procedure — see
  `docs/ROLLOUTS.md` and `docs/UPGRADE.md`.
- Platform-affecting changes are further gated by an explicit sync window (Mon–Thu 17:00–07:00
  Amsterdam time) documented in `CLAUDE.md`; tenant-only additions are unrestricted.

## What this document is not

This is not a new Helm chart and does not change any deployed resource. It is a citation index
for reviewers. If a claim above stops matching the code, fix the code or fix this document — do
not let them drift apart.
