## 1. Phase 1 PoC — emptyDir + RS=2 on canary-prod

- [x] 1.1 Update `canary-overrides.yaml`: set `persistence.enabled: false` and configure `emptyDir` (sizeLimit: 2Gi) volumes for `/var/www/html` and subdirs
- [x] 1.2 Set `replicaCount: 2` in `tenant-canary-prod.yaml`
- [ ] 1.3 Sync canary-prod via Argo CD and confirm both pods reach `3/3 Ready`
- [ ] 1.4 Verify both pods serve `{"installed":true}` from `/status.php`
- [ ] 1.5 Verify Conduction apps installed on both pods (`php occ app:list` on each)
- [ ] 1.6 Trigger a rolling restart and confirm zero downtime (one pod always Ready)
- [ ] 1.7 Run canary-prod for 7 consecutive days — record start date in a comment in `tenant-canary-prod.yaml`
- [ ] 1.8 Sign off Phase 1 graduation: confirm all criteria in `specs/canary-gate/spec.md` are met, commit sign-off note

## 2. Image repo setup

- [ ] 2.1 Create `nextcloud-image` repository (GitHub, under Conduction org)
- [ ] 2.2 Write `Dockerfile` extending `nextcloud:{version}-fpm` with `docker-php-ext-install` for listed extensions
- [ ] 2.3 Create `manifest.yaml` (or equivalent) declaring: Nextcloud base version, Conduction app versions (opencatalogi, openconnector, openregister), and PHP extensions list
- [ ] 2.4 Write app install script that runs at build time via `occ app:install --keep-disabled` for each app in the manifest
- [ ] 2.5 Confirm `pdo_pgsql` and `soap` are in the default extensions list in the manifest
- [ ] 2.6 Add `.github/workflows/build.yaml`: triggers on manifest changes, builds image, runs `php -m` checks, pushes to GHCR with tag `{nc-version}-apps-{apps-semver}`
- [ ] 2.7 Configure GHCR repo with immutable tags (prevent overwriting published tags)
- [ ] 2.8 Add vulnerability scan step (Trivy or equivalent) — fail on Critical CVEs, report High CVEs

## 3. Phase 2 — Custom image on canary-prod

- [ ] 3.1 Build and publish first image: `conduction/nextcloud:32.0.5-apps-1.0.0`
- [ ] 3.2 Confirm image scan is clean (no Critical CVEs)
- [ ] 3.3 Update `canary-overrides.yaml` to reference custom image tag
- [ ] 3.4 Sync canary-prod, confirm both pods start from custom image and reach `3/3 Ready`
- [ ] 3.5 Verify all three Conduction apps are at expected pinned versions on both pods
- [ ] 3.6 Verify `pdo_pgsql` and `soap` extensions present: `php -m | grep -E 'pdo_pgsql|soap'`
- [ ] 3.7 Test rollback: revert `canary-overrides.yaml` to previous image tag, sync, confirm pods recover
- [ ] 3.8 Restore custom image tag and re-sync canary-prod
- [ ] 3.9 Run canary-prod on custom image for 14 consecutive days — record start date
- [ ] 3.10 Sign off Phase 2 graduation: confirm all criteria in `specs/canary-gate/spec.md` are met
- [ ] 3.11 Update `values/common.yaml` to reference custom image for all tenants
- [ ] 3.12 Roll out to prod tenants wave by wave (wave 1 → 2 → 3), validate each wave before proceeding

## 4. Phase 3 — Blue-green via Argo Rollouts (long-term)

- [ ] 4.1 Install Argo Rollouts controller and CRDs in cluster (via cluster-infra GitOps)
- [ ] 4.2 Confirm controller health: `kubectl get pods -n argo-rollouts`
- [ ] 4.3 Add `Rollout` resource to the platform Helm chart with BlueGreen strategy (previewService + activeService)
- [ ] 4.4 Enable Argo Rollouts on canary-prod only (feature flag in `canary-overrides.yaml`)
- [ ] 4.5 Perform first full upgrade cycle on canary-prod: deploy green → validate → promote → confirm blue scaled down
- [ ] 4.6 Test rollback after promotion: abort, confirm traffic returns to previous image, confirm no downtime in probe logs
- [ ] 4.7 Run a second full cycle (re-promote to green) to confirm repeatability
- [ ] 4.8 Sign off Phase 3 graduation: confirm all criteria in `specs/canary-gate/spec.md` (full cycle, zero downtime)
- [ ] 4.9 Enable Argo Rollouts for prod tenants, wave by wave, with manual promotion gate per wave
