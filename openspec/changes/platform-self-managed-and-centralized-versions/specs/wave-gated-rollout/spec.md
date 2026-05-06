## ADDED Requirements

### Requirement: Tenant Applications carry a selectable wave label

The ApplicationSet template at `nextcloud-platform/argo/applicationsets/nextcloud-tenants.yaml` MUST emit each generated `Application` with a `metadata.labels` entry `nextcloud.platform/wave: "<tenant.wave>"` whose value matches the `tenant.wave` field from the tenant yaml (defaulting to `"1"` when unset, consistent with the existing `argocd.argoproj.io/sync-wave` annotation default).

#### Scenario: Operator selects all wave-1 Applications via label
- **WHEN** an operator runs `kubectl get application -n argocd -l nextcloud.platform/wave=1`
- **THEN** the output MUST include every Application generated for tenants whose tenant yaml has `tenant.wave: "1"` (or no wave field set)
- **AND** the output MUST NOT include Applications for tenants in any other wave

#### Scenario: Wave label and sync-wave annotation share their source
- **WHEN** the ApplicationSet template is inspected
- **THEN** the `nextcloud.platform/wave` label MUST be derived from the same `{{ .tenant.wave }}` template expression used by the `argocd.argoproj.io/sync-wave` annotation
- **AND** the two values MUST always be equal for any given Application

### Requirement: Phased promotion protocol is documented in `docs/ROLLOUTS.md`

`docs/ROLLOUTS.md` MUST describe the phased-promotion protocol for fleet-wide changes (e.g. an `appVersions.*` bump in `common.yaml`):
1. First bump `nextcloud-platform/values/canary-overrides.yaml` (wave 0 only) and validate.
2. Then bump `env/accept.yaml` and validate accept tenants as a batch.
3. Then bump `env/prod.yaml` and sync prod waves serially via `argocd app sync -l nextcloud.platform/wave=N` with operator validation between waves.

#### Scenario: ROLLOUTS.md contains the four-step protocol
- **WHEN** an operator opens `docs/ROLLOUTS.md`
- **THEN** the document MUST contain a section that names each step (canary-overrides → env/accept → env/prod wave-by-wave)
- **AND** for each step, document the validation criteria the operator should check before proceeding

#### Scenario: Operator can serialize prod rollout with the wave selector
- **WHEN** an operator wants to roll a `common.yaml` version bump out one wave at a time on prod
- **THEN** the documented procedure MUST instruct: `argocd app sync -l nextcloud.platform/wave=0 -l nextcloud.platform/environment=prod` first, validate, then `wave=1`, validate, then `wave=2`, etc.

### Requirement: Wave promotion is operator-gated, not automated

There MUST NOT be any automated mechanism in this change that promotes a wave to the next based on health-check completion. All wave-to-wave transitions MUST be initiated by an operator action (CLI sync, UI sync, or pause/unpause of a deny window).

#### Scenario: No PostSync hook triggers next wave
- **WHEN** the ApplicationSet template, AppProject, or any new manifest under `nextcloud-platform/argo/` is inspected
- **THEN** there MUST NOT be any PostSync hook, lifecycle webhook, or controller that automatically triggers `argocd app sync` on a higher-numbered wave when a lower-numbered wave reports `Healthy`

### Requirement: Capacity verification is part of the rollout-readiness checklist

`docs/ROLLOUTS.md` MUST include a pre-fleet-bump checklist that requires the operator to confirm capacity headroom on shared services before initiating a fleet-wide rollout. The checklist MUST cover at minimum:
- Argo CD application-controller `processors` setting versus the current and projected fleet size.
- S3 backend connection limits versus the burst implied by simultaneous tenant upgrades.
- Redis (`nextcloud-platform` namespace) `maxclients` versus the burst.
- PgBouncer (`nextcloud-platform` namespace) `default_pool_size` versus the burst (relevant only for `external` dbType tenants).

#### Scenario: Checklist mentions all four capacity dimensions
- **WHEN** an operator opens `docs/ROLLOUTS.md` and finds the rollout-readiness checklist
- **THEN** the checklist MUST include items for Argo controller processors, S3 connection limits, Redis maxclients, and PgBouncer default_pool_size
- **AND** each item MUST name the file or `kubectl` command an operator can use to verify the current setting

### Requirement: Wave-0 (canary) is the gate for accept and prod fan-out

`docs/ROLLOUTS.md` MUST state explicitly that no version bump in `env/accept.yaml` or `env/prod.yaml` may be merged before the corresponding bump has been validated on wave 0 (canary). The validation criteria for wave 0 — pods Ready, no crashlooping, no error in `conduction-apps.log`, no spike in 5xx — MUST be enumerated.

#### Scenario: Operator who skips canary is flagged by docs
- **WHEN** an operator reads `docs/ROLLOUTS.md` for a fleet-wide version bump
- **THEN** the documented procedure MUST instruct that bumping `env/accept.yaml` or `env/prod.yaml` is forbidden until canary (wave 0) has been validated
- **AND** the validation criteria for wave 0 MUST be enumerated as named checks (pods Ready, log clean, no 5xx spike, etc.)
