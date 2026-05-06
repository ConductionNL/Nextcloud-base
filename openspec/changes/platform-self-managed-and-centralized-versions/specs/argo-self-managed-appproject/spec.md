## ADDED Requirements

### Requirement: AppProject is GitOps-managed via a bootstrap Application

The platform SHALL include an Argo CD `Application` resource, named `appproject-bootstrap`, that watches the directory `nextcloud-platform/argo/projects/` in this repository and applies its contents to the `argocd` namespace. After eenmalige `kubectl apply` of the bootstrap Application itself, all subsequent changes to `nextcloud-platform/argo/projects/nextcloud-platform.yaml` (or any other file under that path) MUST take effect via Git push without further manual `kubectl apply`.

#### Scenario: AppProject change in Git is auto-applied to cluster
- **WHEN** an operator edits `nextcloud-platform/argo/projects/nextcloud-platform.yaml` and pushes to `upstream/main`
- **THEN** within Argo CD's normal refresh interval (≤3 minutes by default), the live `AppProject` named `nextcloud-platform` in the `argocd` namespace MUST reflect the committed YAML
- **AND** no manual `kubectl apply` step is required for the change to take effect

#### Scenario: Bootstrap Application is itself bootstrap-only
- **WHEN** the bootstrap Application manifest is changed in Git
- **THEN** the change MUST require a manual `kubectl apply` to take effect, because the bootstrap Application is the recursion-base and cannot manage itself

### Requirement: Bootstrap Application uses the built-in `default` project

The bootstrap Application's `spec.project` field MUST be set to `default` (the built-in Argo CD project). It MUST NOT use the `nextcloud-platform` AppProject.

#### Scenario: Bootstrap Application targets argocd namespace under default project
- **WHEN** the bootstrap Application is inspected
- **THEN** `spec.project` equals `default`
- **AND** `spec.destination.namespace` equals `argocd`
- **AND** the `nextcloud-platform` AppProject's `spec.destinations` list does NOT include the `argocd` namespace

### Requirement: Bootstrap Application disables auto-prune and preserves resources on deletion

The bootstrap Application's `spec.syncPolicy` MUST enable `automated` sync but MUST disable `prune` (set to `false` or omitted). The Application MUST set `spec.syncPolicy.preserveResourcesOnDeletion: true` (or use a finalizer pattern equivalent) so that accidental deletion of the Application does not cascade-delete the live AppProject.

#### Scenario: Stale AppProject manifest in Git does not delete live AppProject
- **WHEN** the file `nextcloud-platform/argo/projects/nextcloud-platform.yaml` is removed from Git
- **AND** Argo CD refreshes
- **THEN** the live `AppProject` named `nextcloud-platform` in the `argocd` namespace MUST remain present (no auto-prune)

#### Scenario: Deleting bootstrap Application preserves AppProject
- **WHEN** an operator runs `kubectl delete application appproject-bootstrap -n argocd`
- **THEN** the live `AppProject` named `nextcloud-platform` MUST remain present
- **AND** all tenant Applications referencing project `nextcloud-platform` MUST continue to operate

### Requirement: Bootstrap Application is auditable in the same repo as the AppProject

The bootstrap Application manifest MUST be checked in under `nextcloud-platform/argo/bootstrap/` (or a clearly named sibling directory under `nextcloud-platform/argo/`) so that operators can locate it without out-of-band knowledge.

#### Scenario: Operator finds bootstrap Application via repo layout
- **WHEN** an operator searches the repository for the manifest that bootstraps the `nextcloud-platform` AppProject
- **THEN** they find a single YAML file under `nextcloud-platform/argo/bootstrap/` (or equivalent named directory) containing an Argo CD `Application` resource with `metadata.name: appproject-bootstrap`

### Requirement: Manual `kubectl apply` remains a documented fallback during one deprecation cycle

For the first rollout cycle after this change lands, the documentation (`docs/SECRETS.md`, `docs/ROLLOUTS.md`, or a dedicated runbook) MUST retain instructions for manually applying the AppProject as a fallback in case the bootstrap Application is unavailable.

#### Scenario: Operator can recover when bootstrap Application is broken
- **WHEN** the bootstrap Application is in `Unknown` or `Degraded` state and the AppProject must be updated urgently
- **THEN** the documentation MUST instruct the operator to run `kubectl apply -f nextcloud-platform/argo/projects/nextcloud-platform.yaml` directly, with no other prerequisites
