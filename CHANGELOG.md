# Changelog

All notable changes to the Nextcloud multi-tenant GitOps platform are recorded here.

The format is loosely based on [Keep a Changelog](https://keepachangelog.com/).
Dates are in `YYYY-MM-DD` (Europe/Amsterdam). This file is the audit trail for
platform-level changes — update it in the same commit as the change.

## [Unreleased]

### Fixed
- **`nextcloud-tenants` ApplicationSet is `kubectl apply`-able again.** The canary override
  was selected with a `{{- if }}` control line wrapping a `valueFiles` list item — valid as
  an Argo goTemplate but invalid YAML, so `kubectl apply -f` failed (`line 62: could not
  find expected ':'`) and the AppSet had gone stale since commit `4afa549`. Replaced it with
  a templated filename (`canary-overrides{{ if ne … "true" }}-DISABLED{{ end }}.yaml`) plus
  `helm.ignoreMissingValueFiles: true`: canary tenants load `canary-overrides.yaml`,
  non-canary resolve to a missing file that is skipped. Re-applying the manifest now
  propagates the `charts/tenant-secret` source to tenant apps, so managed tenants get their
  ESO `nextcloud-secrets` natively (the manual `helm template … | kubectl apply` stopgap is
  no longer required).
- **Tenant AppSet is now GitOps-managed.** Removed its deliberate exclusion from the
  `nextcloud-platform-bootstrap` root app (it was excluded only because of the invalid
  YAML, now fixed). Committing `nextcloud-tenants.yaml` to Codeberg main now reconciles via
  the bootstrap directory source — no more hand-applying the AppSet.

### Documentation
- **`nextcloud-platform/docs/` refreshed to match current reality (2026-06-23).** Added
  `docs/ARCHITECTURE.md` (cross-repo map: GitOps/secret/auth flows, conventions, known
  issues). Rewrote `SECRETS.md` for the real ESO model (kubernetes-provider store +
  generator, no Vault/AWS; key is `nextcloud-password`). Corrected pervasive errors across
  `ADDING-/REMOVING-TENANT.md`, `OPERATIONS.md`, `UPGRADE.md`, `DATABASE.md`: tenant
  **namespace = bare name** (not `nc-<tenant>`, which is the Argo *app* name); push to the
  **Codeberg** remote (GitHub is an ignored mirror); chart version lives in the
  ApplicationSet `targetRevision`/`tenant.chartVersion` (not `values/common.yaml`); tenant
  deletion does **not** auto-remove the namespace (`preserveResourcesOnDeletion: true`); and
  and how to refresh/apply the `nextcloud-tenants` AppSet (now fixed — see Fixed above).
  Top-level `README.md` slimmed to an entry point that links into `docs/`.

### Changed
- **ESO consumers moved `external-secrets.io/v1beta1` → `external-secrets.io/v1`.**
  cluster-infra pins ESO to chart `2.6.0` (appVersion v2.6.0); the 2.x major no longer
  serves `v1beta1`. Updated `platform/externalsecrets/clustersecretstore.yaml`
  (`ClusterSecretStore`) and `charts/tenant-secret/templates/externalsecret.yaml`
  (`ExternalSecret`). `ClusterGenerator` stays `generators.external-secrets.io/v1alpha1`;
  passwordSpec fields verified present in 2.6.0. No spec/field changes beyond the apiVersion.
- **AppProject `nextcloud-platform-core` widened** (`nextcloud-platform/argo/projects/nextcloud-platform-core.yaml`)
  so `platform-externalsecrets` can sync the ESO consumers: cluster-scoped
  `external-secrets.io/ClusterSecretStore` + `generators.external-secrets.io/ClusterGenerator`
  added to `clusterResourceWhitelist`, and `rbac.authorization.k8s.io/*` (the
  `external-secrets-reader` Role/RoleBinding) added to `namespaceResourceWhitelist`.
  Without this the app fails `SyncFailed: resource ... not permitted in project`.

### Added
- **External Secrets Operator — per-tenant secret generation (NEW tenants only).**
  The ESO *operator* is installed by cluster-infra; this repo adds the *consumers*:
  `platform/externalsecrets/clustersecretstore.yaml` now defines a real
  `ClusterSecretStore` (kubernetes provider, reads the shared Fuga S3 creds from a
  central `nextcloud-s3-seed` Secret) **+** a `ClusterGenerator` (Password) for the
  random per-tenant secrets; `rbac.yaml` gains a least-privilege
  `external-secrets-reader` SA/Role; `s3-seed-secret.example.yaml` documents the
  seed (out-of-band, never Git). A new Helm chart **`charts/tenant-secret`** renders
  a per-tenant `ExternalSecret` that assembles `nextcloud-secrets` (generated
  admin/db/redis/salt + seeded S3), with `refreshInterval: "0"` so it generates
  **once and never rotates**. Wired as a 4th source on the `nextcloud-tenants`
  ApplicationSet, **gated on `tenant.secrets.managed: true`** — existing tenants
  omit the flag, so their script-applied secrets are untouched (no rotation). The
  flag is set by the web-UI for new (web-created) tenants. `clustersecretstore.yaml`
  re-added to the externalsecrets kustomization (needs ESO CRDs → deploy cluster-infra
  first). Deploy in the platform sync window.
- **argo/applicationsets/openwoo-provision.yaml**: per-tenant WOO base-config
  provisioning (the "target track"). One Application per **accept** tenant
  (`tenant-*-accept.yaml` glob — never prod) renders the `openwoo-app-config`
  repo (a kustomize app: provisioner ConfigMap + Argo PostSync Job on a stock
  python image) into the tenant namespace and runs
  `provision.py all --skip-credentials` to converge the WOO base config
  (idempotent). The per-tenant source connection (URL/API-Interface-ID/key) is
  set out-of-band by an operator, not here. **Sync is manual to start** (validate
  canary-accept first, then expand, then enable `automated`); pin
  `targetRevision` to a release tag of openwoo-app-config.
- **bootstrap**: App-of-apps root Application
  (`nextcloud-platform/bootstrap/nextcloud-platform-bootstrap.yaml`) that makes
  `nextcloud-platform/argo/` (AppProjects, the `nextcloud-platform-components`
  ApplicationSet, and the bundled platform app) GitOps-managed instead of
  hand-applied — eliminating the live-patch drift this repo accumulated. Applied
  once by hand; manual sync to start (mirrors `react-platform`). Deliberately
  excludes `applicationsets/nextcloud-tenants.yaml` (raw Go-template `valueFiles`
  is not directory-source-safe + gated canary drift). See
  `nextcloud-platform/bootstrap/README.md`.
- **tooling**: `/generate-secrets` operator skill
  (`.claude/commands/generate-secrets.md`) — the uniform way to create or repair
  a tenant's in-cluster `nextcloud-secrets` via `create-tenant-secret.sh`,
  outside the full `/add-tenant` flow (e.g. a tenant whose secret was never
  provisioned). Confirms before overwriting an existing secret and never prints
  secret values.
- **argo/projects**: New `nextcloud-platform-core` AppProject
  (`nextcloud-platform/argo/projects/nextcloud-platform-core.yaml`) for the
  privileged platform-infrastructure apps. Unlike the tenant project
  `nextcloud-platform`, it whitelists `scheduling.k8s.io/PriorityClass` and does
  **not** blacklist `ResourceQuota`/`LimitRange` — which the platform `policies`
  app must manage. Adds an after-hours sync window (deny 07:00–17:00 Mon–Fri,
  `manualSync: false`) covering `nextcloud-platform` + `platform-*`; previously
  the `platform-*` component apps had no window.
- **argo/applicationsets**: Captured the previously untracked, live-only
  `nextcloud-platform-components` ApplicationSet into Git
  (`nextcloud-platform/argo/applicationsets/nextcloud-platform-components.yaml`)
  so the per-component platform apps are GitOps-managed.

### Removed
- **argo (bundled platform app)**: Retired the redundant bundled
  `nextcloud-platform` Application (`argo/applications/platform.yaml`) and its
  now-orphan root kustomization (`platform/kustomization.yaml`). Its only content
  was `externalsecrets/rbac.yaml` (the `nextcloud-secret-generator` SA/RBAC),
  which the dedicated `platform-externalsecrets` app already owns — the overlap
  caused a persistent `SharedResourceWarning` on that ClusterRole. Now
  `platform-externalsecrets` is the sole owner. The live retire is a one-time
  `kubectl delete application nextcloud-platform -n argocd --cascade=orphan`
  (orphan keeps the RBAC in place; no secret-generator downtime).

### Changed
- **values/common.yaml (session security)**: Added
  `remember_login_cookie_lifetime => 28800` (8h) to the `proxy.config.php` block,
  matching `session_lifetime`. The "stay logged in" cookie can no longer outlive
  the 8h session, so users re-authenticate at least daily — a deliberate
  fleet-wide security-posture decision (gov tenants). MUST NOT be set lower than
  `session_lifetime` or Nextcloud terminates the session early. Affects all
  tenants; rolls out wave-by-wave (canary first).
- **platform/pgbouncer**: Parked the pgbouncer Deployment at `replicas: 0`. The
  shared CNPG postgres backend (`nextcloud-pg`) is currently unrecoverable and
  there are 0 `dbType: external` tenants, so pgbouncer has no backend and no
  consumers — at `replicas: 2` it just CrashLoopBackOffs on "waiting for
  PostgreSQL backend". Restore to 2 once CNPG is recovered and an external tenant
  needs the pooler. File: `nextcloud-platform/platform/pgbouncer/deployment.yaml`.
- **values/templates (postgres)**: `tenant-template-postgres.yaml` postgres image
  moved from `ghcr.io/conductionnl/nextcloud-images:...sha-6b56bfeda` (pullPolicy
  `Always`) to `docker.io/conduction2022/nextcloud-images:postgres16-ext-sha-8abef67`
  pinned to digest `sha256:7478…b4f8c4` (pullPolicy `IfNotPresent`), matching
  `values/db/postgres.yaml`. New postgres tenants no longer template a dead
  ghcr.io pull (GitHub org shadowbanned).
- **argo (platform-components)**: Repointed the `nextcloud-platform-components`
  ApplicationSet `source.repoURL` from `github.com/conductionnl/Nextcloud-base`
  to `codeberg.org/conduction/Nextcloud-base` (GitHub org shadowbanned; Codeberg
  is canonical since 2026-06-01). The 2026-06-01 cutover patched the tenant
  ApplicationSet and bundled app but missed these component apps, leaving
  `platform-externalsecrets`/`platform-policies` stuck (Sync failed) on a dead
  source.
- **argo (platform apps → core project)**: Moved the bundled `nextcloud-platform`
  app and the `platform-*` component apps from project `nextcloud-platform` to
  `nextcloud-platform-core`. Fixes `platform-policies` SyncFailed
  (`PriorityClass`/`ResourceQuota`/`LimitRange` not permitted in the tenant
  project). Tenant apps stay on `nextcloud-platform` with the guardrail intact.
  - Verified: after the move + a fresh sync, `platform-policies` is
    Synced/Healthy; `platform-redis`/`-pgbouncer`/`-postgres` and the bundled
    `nextcloud-platform` app are Synced/Healthy.
- **platform/externalsecrets**: Excluded `clustersecretstore.yaml` from the
  kustomization. The `ClusterSecretStore` requires the external-secrets.io CRD,
  but the External Secrets Operator is not installed on this cluster (the
  fallback secret Job is used). Including it made `platform-externalsecrets`
  SyncFailed. Re-add only after ESO + CRDs are installed cluster-wide.
  - File: `nextcloud-platform/platform/externalsecrets/kustomization.yaml`
  - Note: takes effect once merged to Codeberg `main` (the app syncs `HEAD`).
- **db/postgres**: Moved the in-cluster PostgreSQL image from
  `ghcr.io/conductionnl/nextcloud-images` to
  `docker.io/conduction2022/nextcloud-images:postgres16-ext-sha-8abef67`.
  Pinned to digest `sha256:7478927e1ad48c28d491a2589683fe6cb7a4f8468cece491915990e988b4f8c4`
  for immutability/auditability, and switched `pullPolicy` from `Always` to
  `IfNotPresent` (redundant given the digest pin).
  - File: `nextcloud-platform/values/db/postgres.yaml`
  - Scope: platform-wide — affects all tenants with `dbType: postgres`. The
    StatefulSet rolls a new DB image, causing brief per-tenant DB downtime on
    pod restart. Sync after 17:00 Amsterdam per the sync-window rules.
  - Verified: tag + digest confirmed present on Docker Hub; `helm template`
    renders `repository@digest` on the `postgresql` DB-server container;
    `smoke-checks.sh --tenant conduction-test` passes (21 checks, 0 errors).
  - Note: the chart's `postgresql-isready` init-container still references the
    image by tag (chart helper does not propagate the digest). Low relevance —
    transient `pg_isready` readiness check, no data or running workload impact.

### Fixed
- **platform/externalsecrets**: Removed the stray `nextcloud-secrets` Namespace
  from `externalsecrets/rbac.yaml` (the kustomization's `namespace:` directive
  renamed it to `nextcloud-platform`, so `platform-externalsecrets` co-claimed
  the platform namespace alongside the bootstrap-managed project file → a
  `SharedResourceWarning` that kept the bootstrap app `OutOfSync`). The namespace
  is now owned solely by the project file (full pod-security labels);
  `platform-externalsecrets` keeps `CreateNamespace=true`.

## History

Earlier changes predate this changelog. See `git log` for full detail. Recent
notable entries:

- 2026-06-01 — Added tenant `pipelinq-server-prod`.
- 2026-06-01 — Argo: dropped the `nc-*` office-hours sync window.
- 2026-06-01 — Argo: pointed sources to Codeberg (GitHub org shadowbanned).
- 2026-05-26 — Added tenants `softwarecatalogus-tilburg-test`,
  `conduction-test`, `conduction-demo`; validator gained `hostnameOverride`
  flag and `-demo` suffix support.
