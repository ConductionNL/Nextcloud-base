## ADDED Requirements

### Requirement: App versions are defined under a top-level `appVersions` key

The Helm values for tenant deployments SHALL accept a top-level `appVersions` map with the keys `opencatalogi`, `openconnector`, and `openregister`, each holding a string version (e.g. `"1.0.0"`). This key MAY appear in any layer of the layered values architecture: `common.yaml`, `env/{accept,prod}.yaml`, or `values/tenants/tenant-*.yaml`.

#### Scenario: appVersions defined in common.yaml is the platform default
- **WHEN** `nextcloud-platform/values/common.yaml` defines `appVersions: {opencatalogi: "1.0.0", openconnector: "1.0.0", openregister: "1.0.0"}`
- **AND** no other layer overrides it
- **THEN** every tenant's Nextcloud pod MUST receive `OPENCATALOGI_VERSION=1.0.0`, `OPENCONNECTOR_VERSION=1.0.0`, `OPENREGISTER_VERSION=1.0.0` as environment variables

#### Scenario: env-level override applies to all tenants in that environment
- **WHEN** `common.yaml` sets `appVersions.opencatalogi: "1.0.0"`
- **AND** `env/accept.yaml` sets `appVersions.opencatalogi: "1.1.0-rc"`
- **THEN** every tenant with `tenant.environment: accept` MUST receive `OPENCATALOGI_VERSION=1.1.0-rc`
- **AND** every tenant with `tenant.environment: prod` MUST receive `OPENCATALOGI_VERSION=1.0.0`

#### Scenario: tenant-level override beats env and common
- **WHEN** `common.yaml` sets `appVersions.opencatalogi: "1.0.0"`
- **AND** `env/accept.yaml` sets `appVersions.opencatalogi: "1.1.0-rc"`
- **AND** `values/tenants/tenant-X-accept.yaml` sets `appVersions.opencatalogi: "1.0.5-hotfix"`
- **THEN** tenant `X-accept` MUST receive `OPENCATALOGI_VERSION=1.0.5-hotfix`
- **AND** all other accept tenants MUST receive `OPENCATALOGI_VERSION=1.1.0-rc`

#### Scenario: Layered merge order is common → env → db → tenant, last-wins
- **WHEN** the same `appVersions.X` key is set in multiple layers
- **THEN** the value from the layer applied last in the Helm merge MUST win, following the documented order in `CLAUDE.md`: `common.yaml`, then `env/<env>.yaml`, then `db/<dbType>.yaml`, then `values/tenants/tenant-<name>.yaml`

### Requirement: Version env vars are emitted by Helm, not by the ApplicationSet goTemplate

The `OPENCATALOGI_VERSION`, `OPENCONNECTOR_VERSION`, and `OPENREGISTER_VERSION` environment variables on the Nextcloud pod MUST be defined via Helm-side `extraEnv` entries in `nextcloud-platform/values/common.yaml`. They MUST NOT be constructed inside the ApplicationSet `goTemplate` `values:` block.

#### Scenario: ApplicationSet goTemplate no longer references app versions
- **WHEN** `nextcloud-platform/argo/applicationsets/nextcloud-tenants.yaml` is inspected
- **THEN** its `goTemplate` values block MUST NOT contain `OPENCATALOGI_VERSION`, `OPENCONNECTOR_VERSION`, or `OPENREGISTER_VERSION`

#### Scenario: common.yaml contains the version env-var definitions
- **WHEN** `nextcloud-platform/values/common.yaml` is inspected
- **THEN** `nextcloud.extraEnv` MUST contain entries for `OPENCATALOGI_VERSION`, `OPENCONNECTOR_VERSION`, and `OPENREGISTER_VERSION`
- **AND** each entry's `value` MUST be a Helm template expression that resolves the version from `.Values.appVersions.<app>` with `.Values.tenant.apps.versions.<app>` as a fallback override

### Requirement: Legacy `tenant.apps.versions.*` field remains an override for one deprecation cycle

During the deprecation cycle, the Helm template for each version env var MUST honor `.Values.tenant.apps.versions.<app>` as a final override that wins over `.Values.appVersions.<app>`. This preserves any pre-existing per-tenant pin until the migration is complete.

#### Scenario: Legacy pin still wins during deprecation cycle
- **WHEN** `common.yaml` sets `appVersions.opencatalogi: "1.0.0"`
- **AND** `values/tenants/tenant-Y-prod.yaml` still uses the legacy form `tenant.apps.versions.opencatalogi: "0.9.5"`
- **THEN** tenant `Y-prod` MUST receive `OPENCATALOGI_VERSION=0.9.5`

#### Scenario: Documentation flags legacy field as deprecated
- **WHEN** `docs/ADDING-TENANT.md` or the tenant template (`nextcloud-platform/values/templates/tenant-template.yaml`) is inspected
- **THEN** any reference to `tenant.apps.versions.*` MUST be marked as deprecated
- **AND** the recommended location for setting versions MUST be documented as `appVersions.*` in `common.yaml` or `env/*.yaml`

### Requirement: Validation script enforces appVersions presence in common.yaml

`scripts/validate-values.sh` MUST fail when `nextcloud-platform/values/common.yaml` does not define all three of `appVersions.opencatalogi`, `appVersions.openconnector`, `appVersions.openregister` as non-empty strings.

#### Scenario: validate-values.sh blocks empty appVersions
- **WHEN** an operator removes one of the three `appVersions.*` keys from `common.yaml`
- **AND** runs `./scripts/validate-values.sh`
- **THEN** the script MUST exit non-zero with a message identifying the missing key

#### Scenario: vng tenant exception preserved
- **WHEN** `validate-values.sh` runs against the full `values/tenants/` directory
- **THEN** any failure originating in a file matching `*vng*` MUST be ignored, consistent with the existing project convention

### Requirement: Missing version means inherit, not "latest"

After this change is fully migrated (i.e., legacy fallback removed in the follow-on cleanup commit), an unset `appVersions.<app>` at every layer MUST cause the corresponding env var to be empty. The install hook in `common.yaml` MAY treat an empty value as "use the chart default" or "fail loudly" — operators MUST NOT rely on empty meaning "install latest from upstream".

#### Scenario: Empty version is no longer an implicit "latest"
- **WHEN** the deprecation cycle ends and the legacy fallback is removed
- **AND** `common.yaml` defines `appVersions.opencatalogi: "1.0.0"`
- **THEN** every tenant inherits `OPENCATALOGI_VERSION=1.0.0` unless an env or tenant layer explicitly overrides
- **AND** there is no path by which an unset version resolves to a moving "latest" tag without operator intent
