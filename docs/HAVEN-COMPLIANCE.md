---
last_reviewed: 2026-08-03
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
  (`https://nextcloud.github.io/helm/`); this repo supplies layered values plus a thin companion
  chart, `platform/tenant-resources`, for the platform-specific glue (ExternalSecret,
  NetworkPolicy, PDB, ServiceMonitor, namespace, database provisioning job).
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

`livenessProbe`, `readinessProbe`, and `startupProbe` are all enabled with tuned thresholds
(startup allows up to 10 minutes for first boot before failing):

```yaml
# values/common.yaml:674-696
livenessProbe:  { enabled: true, initialDelaySeconds: 60, periodSeconds: 30, failureThreshold: 6 }
readinessProbe: { enabled: true, initialDelaySeconds: 30, periodSeconds: 15, failureThreshold: 3 }
startupProbe:   { enabled: true, initialDelaySeconds: 60, periodSeconds: 10, failureThreshold: 60 }
```

## 4. Resource governance

- The main Nextcloud pod runs under a deliberate **limits-only** policy — no CPU/memory
  *requests* on background/non-critical containers, so Kubernetes schedules freely and throttles
  under pressure rather than reserving idle capacity (`values/common.yaml:698-702`, and the
  rationale is spelled out in `CLAUDE.md` → "Resource Policy"). The main pod and nginx do carry
  requests, since guaranteed scheduling matters there.
- Platform-level governance templates exist for tenant namespaces: `ResourceQuota`,
  `LimitRange`, `PriorityClass` — `platform/policies/{resource-quotas,limit-ranges,priority-classes}.yaml`.

## 5. Availability: PodDisruptionBudget

Every tenant gets a `PodDisruptionBudget` from the companion chart:
`platform/tenant-resources/templates/pdb.yaml`.

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
  (`argo/applicationsets/nextcloud-tenants.yaml`), which is also how NetworkPolicies scope
  allowed traffic (§9) without per-tenant manual updates.
- Prometheus scrape annotations are set by default (`podAnnotations` in `values/common.yaml`),
  and a `ServiceMonitor` template ships in the companion chart
  (`platform/tenant-resources/templates/servicemonitor.yaml`).

## 8. Resilience to infrastructure churn (S3-primary storage)

User files are stored in Ceph RGW S3, not on a Kubernetes-attached volume
(`persistence.nextcloudData.enabled: false` in `values/common.yaml`). During Kubernetes node
upgrades, CSI attach/mount operations can fail or the OpenStack API can be temporarily
unavailable; because user data lives in S3 rather than on an in-cluster/NFS volume, it stays
reachable independent of cluster node state. See README.md → "Waarom S3 Primary Storage?".

## 9. Multi-tenant isolation

- One Kubernetes namespace per tenant, named after `tenant.name`.
- `NetworkPolicy` (`platform/tenant-resources/templates/networkpolicy.yaml`) restricts traffic to
  namespaces carrying the shared `app.kubernetes.io/part-of: nextcloud-platform` label — new
  tenants are isolated by default without any manual policy update.

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
