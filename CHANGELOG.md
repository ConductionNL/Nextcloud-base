# Changelog

All notable changes to the Nextcloud multi-tenant GitOps platform are recorded here.

The format is loosely based on [Keep a Changelog](https://keepachangelog.com/).
Dates are in `YYYY-MM-DD` (Europe/Amsterdam). This file is the audit trail for
platform-level changes — update it in the same commit as the change.

## [Unreleased]

### Added
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

### Changed
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

## History

Earlier changes predate this changelog. See `git log` for full detail. Recent
notable entries:

- 2026-06-01 — Added tenant `pipelinq-server-prod`.
- 2026-06-01 — Argo: dropped the `nc-*` office-hours sync window.
- 2026-06-01 — Argo: pointed sources to Codeberg (GitHub org shadowbanned).
- 2026-05-26 — Added tenants `softwarecatalogus-tilburg-test`,
  `conduction-test`, `conduction-demo`; validator gained `hostnameOverride`
  flag and `-demo` suffix support.
