# Changelog

All notable changes to this repository are documented in this file.

## 2026-06-24

### Added
- `delft-accept`: added a `tenant.frontend.branding.organisationName: "Gemeente Delft"`
  block so the co-tenant WOO PWA frontend (onboarded in React-base's `react-tenants`
  appset on 2026-06-24) renders the org name. `edam-volendam-accept` already carried
  its branding block; no change needed there.

## 2026-03-06 – 2026-03-12

### Added
- New tenants:
  - `lansingerland-prod` (MariaDB)
  - `meppel-prod` (MariaDB)
  - `noordwijk-prod` (MariaDB, initially via migrate domain `noordwijk.migrate.commonground.nu`)
  - `terneuzen-accept` and `terneuzen-prod` (MariaDB)
  - `debilt-prod` (MariaDB)
  - `epe-accept` (MariaDB)
  - `rijswijk-accept` (custom image with SOAP extension — first tenant using a non-upstream Nextcloud image)
- `cutover-tenant` script (`scripts/cutover-tenant.sh`), skill, and runbook for migrate-domain → canonical hostname promotions
- `values/canary-overrides.yaml` — staging layer for canary-only experiments; loaded by ApplicationSet only when `tenant.canary: true`
- OPA/Conftest policy (`policy/values-guardrails.rego`, `package values`) blocking `ReadWriteMany`, `cinder-rwx`, and `replicaCount > 1` in shared values files; enforced in CI and `validate-values.sh`
- `docs/CONFIG-CHANGES.md` — documents the GitOps-only pattern for Nextcloud config changes (no more `occ config:system:set` for persistent changes)
- OpenSpec change `stateless-nextcloud-ha` — full proposal, design, specs, and tasks for the stateless pod / custom image / blue-green HA roadmap

### Changed
- **canary-prod HA pivot**: Cinder ext4 multi-attach confirmed incompatible with RS=2 (inode corruption). Pivoted to stateless emptyDir model: `persistence.enabled: false` in `canary-overrides.yaml`, `replicaCount: 2` in tenant file. Phase 1 PoC in validation since 2026-03-09.
- **Nextcloud identity persistence**: `instanceid`, `passwordsalt`, and `secret` are now stored in `nextcloud-secrets` and injected via `identity.config.php` ConfigMap so they survive pod restarts on emptyDir tenants. `create-tenant-secret.sh` generates these automatically for all new tenants.
- `canary-prod` rolling update strategy (`RollingUpdate`, `maxSurge: 1`, `maxUnavailable: 0`) to enable zero-downtime pod replacement.
- `epe-accept` and `debilt-prod` refactored to modern thin-tenant style (removed redundant boilerplate).
- `noordwijk-prod` cut over from migrate domain to `noordwijk.commonground.nu`.

### Fixed
- **AppProject sync windows**: `manualSync: false` on deny windows was blocking ALL syncs including manual triggers. Corrected to `manualSync: true` (deny windows block only automated syncs).
- **ApplicationSet goTemplate boolean**: `{{- if .tenant.canary }}` evaluates false for YAML boolean `true` in Argo CD's Go template engine. Fixed to `{{- if eq (toString .tenant.canary) "true" }}`. This caused `canary-overrides.yaml` to be silently skipped on every sync.
- Volume permissions initContainer for Cinder RWX mounts (`fsGroupPolicy: ReadWriteOnceWithFSType` skips fsGroup chown for RWX volumes).
- Weak placeholder credentials replaced with `openssl rand` generation hints in `env.example` and all scripts.
- S3 credentials sourced from `scripts/.env` in `add-tenant` skill (was failing silently).
- Script paths corrected in all skill commands.
- Manual tenant syncs now allowed during weekend deny window.

### Removed
- `oc-test-prod` tenant removed (decommissioned).

---

## 2026-02-02

### Added
- New tenants:
  - `tenant-stichtsevecht-accept.yaml` (MariaDB, default Conduction apps)
  - `tenant-helmond-prod.yaml` (MariaDB, default Conduction apps)
- Documentation index in `docs/README.md` with 4 chapters:
  1. What is this platform
  2. Add/change tenants
  3. Canary ring
  4. Technical documentation

### Governance / Process
- Clarified that PR labels are required for governance checks:
  - `change/tenant-additive`
  - `change/platform`
- Added guidance to use label-based flow before rollout promotion.

