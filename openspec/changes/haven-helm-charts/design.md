## Context

Haven (haven.commonground.nl) is VNG Realisatie's reference standard for how Dutch government
Kubernetes workloads should be built, packaged, and operated: containerized, declaratively
deployed, config via env/secrets (not baked into images), observable, horizontally scalable, and
auditable. Procurement cooperatives use it as a checklist during tender review.

This design does **not** introduce new infrastructure. It documents the infrastructure that
already exists and is already live for real municipal tenants, and is explicit about the one
known deviation and how it is tracked.

## Deployed topology (as found, verified against this repo + `docs/ARCHITECTURE.md`)

```
Codeberg (conduction/Nextcloud-base, main)
        │  git push  (ONLY safe entry point — GitHub remote is a mirror Argo ignores)
        ▼
Argo CD (ns argocd, cluster con-prod)
  ├─ ApplicationSet nextcloud-platform-components   (waves -4..-1)
  │    → platform/redis, platform/pgbouncer, platform/externalsecrets,
  │      platform/policies, platform/postgres         [nextcloud-platform-core project]
  │
  └─ ApplicationSet nextcloud-tenants                 (one Application per tenant file,
       generator: glob values/tenants/tenant-*.yaml)   goTemplate, wave-gated canary-first)
       Each tenant Application is MULTI-SOURCE:
         source 1: repoURL https://nextcloud.github.io/helm/  chart: nextcloud   (upstream)
                    values = deep-merge(common.yaml, env/{accept,prod}.yaml,
                                         db/{mariadb,postgres,external}.yaml,
                                         tenants/tenant-<name>.yaml)
         source 2: repoURL Nextcloud-base.git  path: platform/tenant-resources   (this org's
                    companion chart: ExternalSecret, NetworkPolicy, PDB, ServiceMonitor,
                    namespace, database-job)
       syncPolicy: automated { prune: true, selfHeal: true }   ← any main push deploys
        ▼
  Namespace per tenant (== tenant.name), labelled app.kubernetes.io/part-of=nextcloud-platform
    ├─ Nextcloud Deployment (nginx + php-fpm), CronJob (background jobs), PVC (RWO, 50Gi, app code)
    ├─ User files → Ceph RGW S3 (NOT the PVC) — survives node/CSI outages during upgrades
    ├─ Redis (shared, platform ns) — cache + distributed locking
    ├─ PgBouncer (shared, platform ns) — connection pooling for external-DB tenants
    └─ Secrets: ExternalSecret → ClusterSecretStore (ESO) or fallback generator Job — never
       committed to Git
```

## Haven-pillar mapping

| Haven pillar | Implementation | Where |
|---|---|---|
| Containerized / declarative deploy | 100% GitOps — every deploy is a Git commit read by ArgoCD, no `kubectl apply` for tenant workloads | `docs/ARCHITECTURE.md` §2, `argo/applicationsets/*.yaml` |
| 12-factor config | Image tag, replicas, resources, storage class, hostname, enabled-apps all in layered `values/*.yaml`; no config baked into the image | `values/common.yaml`, `values/env/`, `values/tenants/` |
| No baked secrets | ExternalSecret → ESO ClusterSecretStore is the default path; documented fallback Job generates secrets in-cluster; `.gitignore` blocks `*.secret.yaml`, `secrets/` | `platform/externalsecrets/`, `platform/tenant-resources/templates/externalsecret.yaml`, `docs/SECRETS.md` |
| Health probes | `livenessProbe` / `readinessProbe` / `startupProbe` all enabled with tuned thresholds | `values/common.yaml:674-696` |
| Resource governance | Deliberate limits-only policy (schedule freely, throttle over reservation) for the main pod; `ResourceQuota` + `LimitRange` + `PriorityClass` templates at the platform level | `values/common.yaml:698-701`, `platform/policies/` |
| PodDisruptionBudget | `pdb.yaml` template shipped in the companion chart, applied per tenant | `platform/tenant-resources/templates/pdb.yaml` |
| Horizontal scaling | HPA is wired (`hpa.enabled`, min/max replicas, CPU+mem targets) but **deliberately `false` in prod today** — the code volume is a `ReadWriteOnce` Cinder PVC, so a 2nd replica cannot attach it (documented in `argo/applicationsets/nextcloud-tenants.yaml` inline comment). Fix is scoped and already in flight, not undocumented debt. | `values/common.yaml:727-732`; tracked in `openspec/changes/nextcloud-ha`, `openspec/changes/stateless-nextcloud-ha` |
| Standard labels/observability | `app.kubernetes.io/part-of=nextcloud-platform` on every namespace; Prometheus scrape annotations + `ServiceMonitor` template | `argo/applicationsets/*.yaml`, `values/common.yaml` (`podAnnotations`), `platform/tenant-resources/templates/servicemonitor.yaml` |
| Multi-tenant isolation | One namespace per tenant; `NetworkPolicy` template restricts cross-namespace traffic to labelled platform namespaces only | `platform/tenant-resources/templates/networkpolicy.yaml` |
| Resilience to infra churn | S3-primary storage for user files specifically to survive CSI/node-upgrade outages (README §"Waarom S3 Primary Storage?") | `README.md`, `values/common.yaml` (`persistence.nextcloudData.enabled: false`) |
| Auditability | Git history on `main` **is** the deploy history; ArgoCD `selfHeal` reverts manual drift; sync windows gate *when* platform changes may land | `CLAUDE.md` (Sync Windows), `docs/ARCHITECTURE.md` |

## Why not a new chart

The task that motivated this audit assumed no Helm charts existed for the fleet. That premise
does not hold here: `nextcloud-platform` is the live, GitOps-managed deployment of exactly this
fleet, using the well-maintained upstream `nextcloud/nextcloud` chart for the core workload and a
thin, purpose-built companion chart (`platform/tenant-resources`) for the platform-specific glue
(ExternalSecret, NetworkPolicy, PDB, ServiceMonitor). Writing a second, from-scratch chart
elsewhere would:

1. Not be deployed by anything (ArgoCD only reads the paths wired into its ApplicationSets).
2. Drift from the real values schema immediately (the real chart's values keys come from the
   upstream `nextcloud/nextcloud` chart, not from an invented schema).
3. Repeat a fleet-wide, previously-observed failure mode: shipping a parallel implementation of a
   contract that already has one canonical owner causes silent duplication bugs, not redundancy.

The correct contribution is documentation that makes the existing alignment legible, not a new
deployment path.

## Safety constraint on shipping

This repo's own `CLAUDE.md`, and the same clause in `cluster-infra` and `cluster-config`, states
explicitly that **a human performs all pushes and cluster mutations** — never an agent. Two
ArgoCD ApplicationSets in this repo run `automated: { prune: true, selfHeal: true }` against a
named production cluster. Even though this change is docs-only and touches no ArgoCD-watched
path, the push step itself is out of scope for this change per the repo's own governance; the
change is prepared as a local commit on a branch for a human to review and push.
