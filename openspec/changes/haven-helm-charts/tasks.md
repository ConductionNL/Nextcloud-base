## 1. Audit existing implementation

- [x] 1.1 Confirm no dedicated infra/deploy repo was missing — found `Nextcloud-base` /
      `nextcloud-platform` as the canonical, live GitOps platform for the fleet (real
      municipality tenants: Delft, Meppel, Rijswijk, Midden-Delfland, xxllnc, Almere, …).
- [x] 1.2 Read `values/common.yaml` for probes, resources, HPA, cronjob, persistence config.
- [x] 1.3 Read `platform/tenant-resources/templates/` for PDB, NetworkPolicy, ExternalSecret,
      ServiceMonitor.
- [x] 1.4 Read `platform/policies/` for ResourceQuota, LimitRange, PriorityClass.
- [x] 1.5 Read `platform/externalsecrets/` for the ClusterSecretStore / ESO secret pattern.
- [x] 1.6 Read `argo/applicationsets/*.yaml` for the deployed topology: upstream
      `nextcloud/nextcloud` Helm chart + `tenant-resources` companion chart, sync policy
      (`automated: prune/selfHeal`), and the confirmed prod-HPA-disabled rationale (RWO Cinder
      PVC).
- [x] 1.7 Confirm the HPA/HA gap is already tracked (`openspec/changes/nextcloud-ha`,
      `openspec/changes/stateless-nextcloud-ha`) rather than undocumented.
- [x] 1.8 Run `helm lint` on `platform/tenant-resources` to confirm the existing chart is
      healthy (0 charts failed; 1 pre-existing cosmetic warning: namespace template name
      truncation in `templates/namespace.yaml`, not introduced by this change).

## 2. Write the compliance mapping

- [x] 2.1 Draft `docs/HAVEN-COMPLIANCE.md` covering: cloud-native/containerized, declarative
      GitOps deploys, 12-factor config (env/secrets, no baked secrets), health probes, resource
      governance, horizontal-scaling posture (+ documented gap), standard labels/PDB,
      multi-tenant isolation (NetworkPolicy, namespace-per-tenant, ResourceQuota), auditability
      (Git history = deploy history, no manual `kubectl apply` for tenants).
- [x] 2.2 Add a row to `README.md`'s documentation table linking to the new doc.
- [x] 2.3 Validate every file reference in the doc against the actual repo paths (no invented
      paths).

## 3. Ship

- [ ] 3.1 Commit locally on branch `wip/haven-helm-charts-docs` off `origin/main`.
- [ ] 3.2 **Do not push.** This repo's `CLAUDE.md` states explicitly: "Push en álle
      cluster-mutaties doet een mens" (a human does all pushes and cluster mutations) — the
      same rule appears verbatim in `cluster-infra` and `cluster-config`. `docs/ARCHITECTURE.md`
      further confirms `git push` to the `codeberg` remote on `main` is read directly by two
      `automated: {prune: true, selfHeal: true}` ArgoCD ApplicationSets against a live prod
      cluster (`con-prod`). A human with push access must review and push this branch.
- [ ] 3.3 Hand off: branch location, diff summary, and this task list to the repo owner.
