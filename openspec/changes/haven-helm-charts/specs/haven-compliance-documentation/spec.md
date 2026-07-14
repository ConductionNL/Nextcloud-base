## ADDED Requirements

### Requirement: Haven alignment is documented with file-level evidence
The repository SHALL provide a single document (`docs/HAVEN-COMPLIANCE.md`) that states, for
each Haven pillar, the concrete file(s) in this repo implementing it, so the claim is falsifiable
by a reviewer without reading the whole codebase.

#### Scenario: Reviewer checks a claimed control
- **GIVEN** a procurement reviewer opens `docs/HAVEN-COMPLIANCE.md`
- **WHEN** they read the row for "health probes"
- **THEN** the row names the exact file and line range (`values/common.yaml:674-696`) where
  `livenessProbe`, `readinessProbe`, and `startupProbe` are configured
- **AND** opening that file confirms all three are `enabled: true`

#### Scenario: Known gaps are stated, not hidden
- **GIVEN** the platform currently ships with `hpa.enabled: false` in production
- **WHEN** the compliance document covers horizontal scaling
- **THEN** it states the gap explicitly (RWO Cinder PVC blocks RS>1)
- **AND** it links to the open change(s) tracking the fix (`nextcloud-ha`,
  `stateless-nextcloud-ha`) rather than omitting the limitation

### Requirement: Documentation changes must not touch ArgoCD-watched deploy paths
A change whose stated purpose is documentation-only MUST NOT modify any path read by an
`automated: { prune: true, selfHeal: true }` ArgoCD ApplicationSet, so that merging it cannot
trigger a cluster mutation.

#### Scenario: Diff review confirms no deploy-path changes
- **GIVEN** the `haven-helm-charts` change is complete
- **WHEN** its diff is reviewed against the paths referenced in
  `argo/applicationsets/nextcloud-platform-components.yaml` and
  `argo/applicationsets/nextcloud-tenants.yaml` (`nextcloud-platform/platform/`,
  `nextcloud-platform/values/`, `nextcloud-platform/argo/`)
- **THEN** the diff contains only `docs/HAVEN-COMPLIANCE.md` (new) and one added row in
  `README.md`
- **AND** no file under any ArgoCD-watched path is present in the diff

### Requirement: Production pushes on infra repos require human execution
An agent preparing a change on this repository SHALL commit locally and hand off for a human to
push, rather than pushing or merging itself, consistent with `CLAUDE.md` in this repo (and the
identical clause in `cluster-infra` and `cluster-config`).

#### Scenario: Agent completes a change without pushing
- **GIVEN** an agent has finished drafting and committing a change on a local branch
- **WHEN** the change is ready to ship
- **THEN** the agent stops short of `git push` and PR creation/merge
- **AND** the agent's report names the branch, the exact commit(s), and states that a human must
  push it
