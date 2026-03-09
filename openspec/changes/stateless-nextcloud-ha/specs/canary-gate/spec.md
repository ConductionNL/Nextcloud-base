## ADDED Requirements

### Requirement: Canary-prod is the mandatory graduation gate for every phase
Every phase of the stateless-nextcloud-ha change SHALL be validated on canary-prod before any configuration, image, or rollout strategy is applied to prod tenants. Graduation requires explicit sign-off, not just absence of errors.

#### Scenario: Phase graduation blocked without sign-off
- **WHEN** a phase has completed its minimum validation period on canary-prod
- **THEN** no changes from that phase SHALL be applied to prod tenants until a human reviewer has explicitly confirmed graduation (via commit, PR approval, or documented sign-off)

#### Scenario: Canary failure blocks all prod promotion
- **WHEN** canary-prod experiences a CrashLoopBackOff, filesystem error, or `/status.php` returning non-200 during a validation period
- **THEN** the validation period resets and graduation to prod is blocked until canary runs clean for the full required duration

### Requirement: Phase 1 graduation criteria (emptyDir + RS=2)
canary-prod SHALL run the emptyDir stateless model with `replicaCount: 2` for a minimum of **7 consecutive days** before graduating to Phase 2.

#### Scenario: Minimum validation period
- **WHEN** canary-prod has run RS=2 with emptyDir for 7 days
- **THEN** the following criteria MUST all be met before graduation:
  - Zero CrashLoopBackOff events in the past 7 days
  - Pod startup time ≤ 3 minutes (from `Pending` to all containers `Ready`)
  - `/status.php` returns `{"installed":true,"maintenance":false}` on both pods
  - Conduction apps (opencatalogi, openconnector, openregister) confirmed installed on both pods

#### Scenario: Rolling restart validation
- **WHEN** a rolling restart is triggered on canary-prod during Phase 1
- **THEN** at least one pod SHALL remain Ready throughout the restart (RS=2 + maxUnavailable=0 guarantees this)
- **THEN** the restarting pod SHALL reach Ready within 3 minutes

### Requirement: Phase 2 graduation criteria (custom image)
canary-prod SHALL run the custom image for a minimum of **14 consecutive days** before the image is rolled out to prod tenants.

#### Scenario: Image validation
- **WHEN** the custom image has run on canary-prod for 14 days
- **THEN** the following criteria MUST all be met before graduating:
  - Image vulnerability scan shows no Critical CVEs (High CVEs reviewed and accepted)
  - All three Conduction apps confirmed at expected pinned versions
  - Rollback to previous image tag tested and confirmed successful on canary-prod
  - Image tag recorded in a graduation log (commit message or release note)

### Requirement: Phase 3 graduation criteria (blue-green rollout)
canary-prod SHALL complete a full blue-green upgrade cycle before the strategy is applied to any prod tenant.

#### Scenario: Full upgrade cycle on canary
- **WHEN** Argo Rollouts blue-green strategy is enabled on canary-prod
- **THEN** a complete cycle MUST be demonstrated:
  1. New image deployed to green slot
  2. Green slot validated (manual or automated AnalysisRun)
  3. Traffic switched from blue to green
  4. Rollback to blue confirmed working
  5. Re-promote to green confirmed working
- **THEN** zero downtime SHALL be confirmed (no gap in `/status.php` 200 responses during switch)
