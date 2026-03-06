## ADDED Requirements

### Requirement: Tenant YAML supports a canary boolean flag
The tenant values YAML template SHALL support an optional `tenant.canary` boolean field (default: `false`). When set to `true`, the ApplicationSet SHALL apply canary-specific overrides for that tenant.

#### Scenario: Canary flag enables replicaCount override
- **WHEN** a tenant YAML has `tenant.canary: true`
- **THEN** the ApplicationSet inline values set `replicaCount: 2` for that tenant, overriding the environment default

#### Scenario: Non-canary tenants are unaffected
- **WHEN** a tenant YAML has no `tenant.canary` field or `tenant.canary: false`
- **THEN** the tenant receives the default `replicaCount` from the environment values file without modification

### Requirement: canary-prod tenant is the primary canary for HA validation
The `canary-prod` tenant (wave 0, always-allow sync window) SHALL have `tenant.canary: true` and SHALL run with `replicaCount: 2` before HA storage is proven on all prod tenants.

#### Scenario: canary-prod runs two healthy pods
- **WHEN** the `canary-prod` tenant is synced after the RWX PVC migration
- **THEN** two pods are Running and Ready on different nodes, and the Deployment shows `2/2` available replicas

#### Scenario: canary-prod syncs without office-hours restriction
- **WHEN** an ArgoCD sync is triggered for the `nc-canary-prod` Application at any time of day
- **THEN** the sync is not blocked by any deny sync window

### Requirement: ApplicationSet canary templating uses conditional inline values
The ApplicationSet `values:` block SHALL use `{{ .tenant.canary }}` (or a Go template conditional equivalent) to conditionally inject canary overrides, rather than hardcoding per-tenant overrides in the ApplicationSet itself.

#### Scenario: Canary override is applied via template
- **WHEN** the ApplicationSet processes a tenant entry with `tenant.canary: true`
- **THEN** the rendered Helm values for that tenant include the canary overrides (e.g., `replicaCount: 2`) without requiring a separate ApplicationSet entry
