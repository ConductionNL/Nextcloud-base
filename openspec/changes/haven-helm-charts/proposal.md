## Why

Haven is the Dutch municipal Kubernetes standard (VNG Realisatie / Common Ground). Procurement
cooperatives increasingly require an explicit, citable statement of Haven alignment as part of
SLA and tender review — "we run on Kubernetes" is not sufficient; reviewers want to see the
specific controls (probes, PDBs, resource governance, secrets handling, horizontal scaling
posture, GitOps auditability) mapped to what Haven actually asks for.

An audit of this repo (`nextcloud-platform/`) shows the platform **already implements** nearly
every technical control Haven expects — it is a real, live, multi-tenant GitOps deployment of
the Conduction Nextcloud app fleet (opencatalogi, openconnector, openregister, …) running in
production for real municipalities. What is missing is not capability, it is a **single document
that states the alignment explicitly**, with pointers to the concrete implementation, so it can
be handed to a procurement reviewer or auditor without them having to read the whole repo.

Building a *second*, greenfield Helm chart elsewhere (e.g. under `openregister/deploy/helm`)
would fragment ownership of the deployment story: this repo is the canonical, actively-operated
GitOps source of truth for the fleet (confirmed via `docs/ARCHITECTURE.md` and the
`nextcloud-tenants` / `nextcloud-platform-components` ApplicationSets), and a parallel chart
would not be deployed by anything, would drift immediately, and would contradict the fleet-wide
lesson that duplicated implementations of the same contract cause real incidents.

## What Changes

- Add `docs/HAVEN-COMPLIANCE.md`: a pillar-by-pillar mapping of Haven requirements to the
  concrete implementation in this repo, with exact file references (`values/common.yaml`,
  `platform/tenant-resources/templates/pdb.yaml`, `platform/policies/`,
  `platform/externalsecrets/`, `argo/applicationsets/*.yaml`).
- Document the one known, already-tracked gap honestly: prod HPA is currently `enabled: false`
  fleet-wide because the Nextcloud code volume is a `ReadWriteOnce` Cinder PVC (single-writer,
  blocks RS>1). This is not a new finding — it is already the subject of two in-flight changes
  (`openspec/changes/nextcloud-ha`, `openspec/changes/stateless-nextcloud-ha`). This doc links to
  them rather than re-litigating the fix.
- No chart, template, or values files change. No ArgoCD-watched path
  (`nextcloud-platform/platform/`, `nextcloud-platform/values/`, `nextcloud-platform/argo/`) is
  touched — this change cannot trigger a cluster mutation on merge.

## Capabilities

### New Capabilities

- `haven-compliance-documentation`: an explicit, file-referenced statement of how this platform's
  existing Helm/ArgoCD deployment satisfies the Haven Kubernetes standard, for procurement/audit
  consumption.

## Impact

- New file: `docs/HAVEN-COMPLIANCE.md` (repo root docs/, per the existing docs index convention
  in `README.md`).
- New file: `README.md` gains one row in the documentation table pointing at the new doc.
- No infra, chart, values, or ArgoCD-application files are touched.

## Out of scope

- Closing the prod-HPA gap (tracked separately in `nextcloud-ha` / `stateless-nextcloud-ha`).
- Any new Helm chart. The upstream `nextcloud/nextcloud` chart plus this repo's
  `platform/tenant-resources` companion chart already form the deployed unit; duplicating that
  here would create a second, unmaintained deployment path for the same fleet.
