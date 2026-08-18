## ADDED Requirements

### Requirement: The absence of a PodDisruptionBudget is a recorded decision
While the Nextcloud Deployment runs a single replica, the platform SHALL NOT ship a
`PodDisruptionBudget` for it, and the documentation SHALL state that as a decision with its
reasoning and its trigger. An unexplained absence SHALL NOT be left to be rediscovered as a
finding.

Reasoning to be recorded: with one replica, `minAvailable: 1` prevents node drains from ever
completing, and `maxUnavailable: 1` permits everything and therefore asserts nothing. Neither
protects availability.

#### Scenario: A reviewer looks for the control
- **GIVEN** an auditor or a new operator reads the compliance documentation
- **WHEN** they reach the availability section
- **THEN** they find that no PDB exists, why that is correct for a single-replica topology, and
  what would change it
- **AND** they do not have to infer it from the absence of a manifest

#### Scenario: A claim outruns the implementation
- **WHEN** documentation states that a tenant-level control is in place
- **THEN** that claim names the file that implements it and is verifiable against the cluster
- **AND** if it cannot be verified, the documentation is corrected rather than the claim left
  standing

### Requirement: The decision has a trigger
The recorded decision SHALL name the condition that reopens it — the Nextcloud Deployment being
able to run more than one replica — and SHALL be cross-referenced from the changes that pursue
that condition, so it is seen by whoever lands it.

#### Scenario: Multi-replica becomes possible
- **WHEN** a change makes RS>1 viable for the Nextcloud workload
- **THEN** the PDB decision is revisited as part of that change
- **AND** shipping RS>1 without revisiting it is visible as an omission, because the
  cross-reference points at it
