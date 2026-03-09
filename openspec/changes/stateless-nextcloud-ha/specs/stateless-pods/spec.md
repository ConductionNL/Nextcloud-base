## ADDED Requirements

### Requirement: Nextcloud pods have no shared persistent volume
Nextcloud application pods SHALL NOT share a block-device-backed PVC for `/var/www/html`. Each pod SHALL be self-contained with respect to the application code layer.

#### Scenario: No shared PVC on canary-prod (Phase 1)
- **WHEN** canary-prod is configured with `persistence.enabled: false`
- **THEN** no PVC of type `cinder-rwx` or `ReadWriteMany` SHALL be mounted by Nextcloud pods
- **THEN** `/var/www/html` SHALL be backed by an `emptyDir` volume

#### Scenario: Multiple pods start cleanly from emptyDir
- **WHEN** RS=2 is set and both pods start from an empty `/var/www/html`
- **THEN** each pod SHALL independently install Nextcloud and Conduction apps via the post-installation hook
- **THEN** both pods SHALL reach `Ready` state within 3 minutes of the hook completing
- **THEN** both pods SHALL serve `{"installed":true}` from `/status.php`

### Requirement: S3, Redis, and database are unaffected by pod restarts
User data, sessions, and database state SHALL survive pod restarts and pod replacements without data loss, because they are stored externally (S3, Redis, MariaDB/PostgreSQL).

#### Scenario: Pod replacement preserves user data
- **WHEN** a Nextcloud pod is deleted and replaced
- **THEN** user files stored in S3 SHALL remain accessible after the new pod reaches Ready
- **THEN** active user sessions backed by Redis SHALL remain valid
- **THEN** no database records SHALL be lost

### Requirement: emptyDir has a size limit
The `emptyDir` volume used for `/var/www/html` in Phase 1 SHALL have a `sizeLimit` of `2Gi` to prevent runaway disk usage on the node.

#### Scenario: Size limit enforced
- **WHEN** the emptyDir volume exceeds 2Gi
- **THEN** Kubernetes SHALL evict the pod (standard emptyDir sizeLimit behaviour)
- **THEN** the eviction SHALL be visible in pod events as an OOMKill or eviction event

### Requirement: RS=2 with RollingUpdate is safe for stateless pods
With no shared PVC, `replicaCount: 2` and `strategy: RollingUpdate` with `maxSurge: 1, maxUnavailable: 0` SHALL provide zero-downtime pod replacement.

#### Scenario: Rolling update with RS=2
- **WHEN** a rolling update is triggered (image tag change, config change)
- **THEN** one old pod SHALL remain Ready while the new pod starts
- **THEN** traffic SHALL only shift to the new pod after it passes the startup probe
- **THEN** at no point during the update SHALL all pods be unavailable
