## ADDED Requirements

### Requirement: Blue-green deployment via Argo Rollouts replaces Deployment for Nextcloud pods
In Phase 3, Nextcloud tenant deployments SHALL use an Argo Rollouts `Rollout` resource with `BlueGreen` strategy instead of a standard Kubernetes `Deployment`. This applies canary-prod first, then prod tenants after graduation.

#### Scenario: Rollout resource created for canary-prod
- **WHEN** Phase 3 begins on canary-prod
- **THEN** the existing `Deployment` for canary-prod SHALL be replaced by a `Rollout` resource managed by Argo Rollouts
- **THEN** the `Rollout` SHALL use `BlueGreen` strategy with a `previewService` (green) and `activeService` (blue/current)

### Requirement: Green slot is validated before traffic is switched
Traffic SHALL NOT be switched from the active (blue) slot to the new (green) slot until the green slot has passed validation.

#### Scenario: Manual promotion gate
- **WHEN** Argo Rollouts starts a new green ReplicaSet
- **THEN** green pods SHALL start and be validated (startup probe passes, `/status.php` returns 200)
- **THEN** traffic SHALL remain on the blue slot until a human (or automated AnalysisRun) explicitly promotes
- **THEN** promotion SHALL switch the `activeService` selector to point to green pods atomically

#### Scenario: Automated analysis as an optional gate
- **WHEN** an `AnalysisRun` is configured for the Rollout
- **THEN** the analysis SHALL query `/status.php` on green pods at regular intervals
- **THEN** if the success rate falls below threshold during the analysis window, the Rollout SHALL abort and traffic remain on blue

### Requirement: Rollback is a single operation
Rolling back from green to blue SHALL be achievable with a single `kubectl argo rollouts abort` or equivalent Argo CD sync operation, with no data loss.

#### Scenario: Rollback during promotion window
- **WHEN** an operator aborts a Rollout before promotion completes
- **THEN** the `activeService` SHALL continue pointing to blue pods
- **THEN** green pods SHALL be scaled down
- **THEN** user traffic SHALL be unaffected (never left blue)

#### Scenario: Rollback after promotion
- **WHEN** an operator rolls back after green has become active
- **THEN** Argo Rollouts SHALL re-promote the previous (blue) ReplicaSet
- **THEN** traffic SHALL switch back to the previous image version
- **THEN** the operation SHALL complete within 60 seconds of the rollback command

### Requirement: Blue-green doubles resource usage only during the upgrade window
The old (blue) ReplicaSet SHALL be scaled down after successful promotion. Both ReplicaSets SHALL NOT run simultaneously outside of the active upgrade window.

#### Scenario: Blue scaled down after promotion
- **WHEN** green is successfully promoted to active
- **THEN** the blue ReplicaSet SHALL be scaled to zero within `scaleDownDelaySeconds` (default: 30s)
- **THEN** resource usage SHALL return to the baseline RS=2 level

### Requirement: Argo Rollouts controller is installed in the cluster before Phase 3 begins
The Argo Rollouts controller and CRDs SHALL be installed and operational in the cluster as a prerequisite for Phase 3.

#### Scenario: Controller health check
- **WHEN** Phase 3 is initiated
- **THEN** `kubectl get pods -n argo-rollouts` SHALL show the controller as Running
- **THEN** `kubectl get crd rollouts.argoproj.io` SHALL confirm the CRD exists
