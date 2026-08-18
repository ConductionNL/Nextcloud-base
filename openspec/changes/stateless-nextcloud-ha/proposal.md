## Why

Nextcloud pods share a Cinder block volume (`cinder-rwx`) for `/var/www/html`. ext4 is not a cluster filesystem — concurrent writes from RS=2 pods cause inode corruption (confirmed 2026-03-09). Until this is solved, canary-prod is locked at RS=1 with no real HA. Eliminating the shared PVC entirely is the correct fix: S3 already handles data, Redis handles locking, and the application code can be baked into a versioned image. This unblocks RS=2+ HA for all tenants.

> **Openstaand bij deze change: de PodDisruptionBudget.** Zolang `replicaCount`
> 1 is, is er bewust geen PDB voor de Nextcloud-workload — `minAvailable: 1`
> blokkeert dan node drains en `maxUnavailable: 1` beweert niets. Dat besluit en
> de trigger staan in `openspec/changes/tenant-isolation-and-pdb`. Zodra déze
> change RS>1 mogelijk maakt, vervalt de reden en hoort de PDB alsnog te komen.
> Landt RS>1 zonder dat, dan is dat een omissie.

## What Changes

- **New**: Dedicated image build repo (`nextcloud-image`) that produces `conduction/nextcloud:{nc-version}-{apps-version}` images with opencatalogi, openconnector, and openregister pre-installed, plus a declarative manifest for additional PHP extensions (e.g. `pdo_pgsql`, `soap`) — operators add an extension by editing the manifest, not the Dockerfile
- **New**: Image build CI pipeline — triggers on Nextcloud base image bump or Conduction app version bump; NOT on every platform repo push
- **New**: Canary graduation process — explicit criteria and checklist that must pass on `canary-prod` before any change reaches prod tenants
- **Modified**: `canary-prod` tenant migrated to stateless model (`persistence.enabled: false`, `emptyDir` for code layer) as PoC — unlocks RS=2 immediately
- **Modified**: Platform Helm values updated to reference custom image tag instead of upstream `nextcloud:x.y.z-fpm`
- **Long-term**: Blue-green rollout strategy via Argo Rollouts, validated on canary before prod

## Capabilities

### New Capabilities

- `image-pipeline`: Versioned custom Nextcloud image build and publish pipeline; rebuilds on Nextcloud or app version change; produces immutable, scannable tags
- `stateless-pods`: Nextcloud pods with no shared PVC — code layer via `emptyDir` (PoC) evolving to baked image; RS=2+ safe
- `canary-gate`: Formal canary graduation process — defined criteria, validation period, and promotion checklist that gates every phase before prod rollout
- `blue-green-rollout`: Blue-green deployment strategy via Argo Rollouts, applied canary-first; zero-downtime image upgrades across all tenants

### Modified Capabilities

<!-- No existing specs to delta against -->

## Impact

- **New repo**: `nextcloud-image` (or equivalent) — Dockerfile, app version pins, GitHub Actions build pipeline, GHCR/Docker Hub publish
- **Platform repo** (`nextcloud-platform`): image reference changes from upstream tag to custom tag; canary tenant values updated for stateless model
- **Argo CD**: Argo Rollouts controller added to cluster for blue-green support (long-term phase)
- **Unchanged**: S3 (Fuga/Ceph RGW) for data, Redis for sessions/locking, PostgreSQL/MariaDB for DB (pgvector and all DB-backed features survive as-is)
- **Blast radius**: Canary-prod is the only tenant affected in phases 1–2; prod tenants are not touched until canary has validated each phase
