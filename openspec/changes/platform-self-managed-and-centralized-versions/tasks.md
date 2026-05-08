## 1. Bootstrap Application + Namespace split + incident doc (Commit 1)

- [ ] 1.1 Document the 6 May 2026 fan-out incident at `docs/incidents/2026-05-06-common-yaml-fanout.md`: timestamp (as precise as Argo audit log allows), affected tenant Applications (from `kubectl get application -n argocd -o json` sync history), root cause (deny window committed in 939db3d on 4 May, not `kubectl apply`'d until incident response on 6 May), corrective action (link to this OpenSpec change directory)
- [ ] 1.2 Split `nextcloud-platform/argo/projects/nextcloud-platform.yaml` into two single-document files in the same directory: keep AppProject content in `nextcloud-platform.yaml`, move the Namespace document to `namespace.yaml`. Verify each file holds exactly one YAML document: `test "$(yq eval-all 'document_index' nextcloud-platform.yaml | tail -1)" = "0"` and the same for `namespace.yaml` (both must exit zero)
- [ ] 1.3 Verify that `nextcloud-platform/argo/projects/nextcloud-platform.yaml` does NOT include the `argocd` namespace under `spec.destinations` — `grep -E '^[[:space:]]*-[[:space:]]+namespace:[[:space:]]*argocd[[:space:]]*$' nextcloud-platform/argo/projects/nextcloud-platform.yaml` MUST exit non-zero (per design D1). POSIX character classes are used instead of `\s` so the check is portable across Linux and macOS dev machines
- [ ] 1.4 Create directory `nextcloud-platform/argo/bootstrap/` and add `appproject-bootstrap.yaml`: Argo CD `Application` named `appproject-bootstrap` in namespace `argocd`, project `default`, source pointing at `nextcloud-platform/argo/projects/`, destination namespace `argocd`, syncPolicy automated with `prune: false` and `preserveResourcesOnDeletion: true`
- [ ] 1.5 Add `nextcloud-platform/argo/bootstrap/README.md` documenting the eenmalige `kubectl apply` step, who is authorised to run it, what to verify after, and the manual-apply fallback procedure if the bootstrap is removed. Include an explicit note that the bootstrap Application lives in the built-in `default` project (per D1) and is therefore NOT subject to the `nextcloud-platform` AppProject's office-hours deny window — AppProject changes via Git push apply at any time of day
- [ ] 1.6 Run `./scripts/validate-values.sh` and `./scripts/smoke-checks.sh` to confirm no validation regressions from the file split
- [ ] 1.7 Commit with message starting `feat(argo): self-manage AppProject via bootstrap Application` and push during the Mon–Thu 17:00–07:00 Amsterdam window
- [ ] 1.8 Apply the bootstrap Application once: `kubectl apply -f nextcloud-platform/argo/bootstrap/appproject-bootstrap.yaml`. Record operator name, kubeconfig context, and timestamp in the change ticket
- [ ] 1.9 Verify the bootstrap Application reaches `Synced/Healthy`: `kubectl get application appproject-bootstrap -n argocd -o jsonpath='{.status.sync.status} {.status.health.status}'` returns `Synced Healthy`
- [ ] 1.10 Smoke test self-management: edit a comment in `nextcloud-platform/argo/projects/nextcloud-platform.yaml`, commit, push, observe Argo refresh and apply within ~3 minutes without manual `kubectl apply`
- [ ] 1.11 Confirm both deny windows still exist after the self-managed apply: `kubectl get appproject nextcloud-platform -n argocd -o jsonpath='{.spec.syncWindows[*].applications[*]}'` lists both `nextcloud-platform` and `nc-*`

## 2. Centralised version pinning + wave label (Commit 2, evening window)

- [ ] 2.1 Add `nextcloud-platform/scripts/audit-app-versions.sh` that for each app in `{opencatalogi, openconnector, openregister}` lists every tenant file's current pin (or `<unset>` if absent), excluding `*vng*`. Output sorted by version with counts
- [ ] 2.2 Run the audit script and commit output to `docs/incidents/2026-05-pinning-baseline.md` BEFORE choosing platform defaults — this is the baseline against which behaviour changes for the 26 unpinned tenants
- [ ] 2.3 Decide platform-default versions for `common.yaml` based on the baseline. Document the rationale in the commit message of step 2.13 (which versions chosen, which tenants implicitly move to those versions, which keep their existing tenant-level overrides)
- [ ] 2.4 Add top-level `appVersions:` block to `nextcloud-platform/values/common.yaml` with explicit `opencatalogi`, `openconnector`, and `openregister` keys set to the chosen stable productie-versions
- [ ] 2.5 If staging-beta versions diverge from prod, add `appVersions:` block to `nextcloud-platform/values/env/accept.yaml` with the staging-specific pins. If accept matches prod, omit the block (inherit from common). Do NOT add `appVersions:` to `env/prod.yaml` unless prod must explicitly diverge from common
- [ ] 2.6 Add three Helm-side `extraEnv` entries to `nextcloud-platform/values/common.yaml` under `nextcloud.extraEnv` for `OPENCATALOGI_VERSION`, `OPENCONNECTOR_VERSION`, `OPENREGISTER_VERSION`. Each `value` MUST use the `dig`-based template from design D5 so tenant-level `tenant.apps.versions.*` overrides the platform/env-level `appVersions.*`
- [ ] 2.7 Remove the corresponding `OPENCATALOGI_VERSION`, `OPENCONNECTOR_VERSION`, `OPENREGISTER_VERSION` entries from the `goTemplate` `values:` block in `nextcloud-platform/argo/applicationsets/nextcloud-tenants.yaml`
- [ ] 2.8 Add `nextcloud.platform/wave: "{{ default \"1\" .tenant.wave }}"` to `metadata.labels` in the ApplicationSet template (per design D6). Use the same default-and-template expression as the existing `argocd.argoproj.io/sync-wave` annotation so the two cannot diverge
- [ ] 2.9 Update `scripts/validate-values.sh` per design D9: (a) require `appVersions.opencatalogi/openconnector/openregister` in `common.yaml` as non-empty semver without leading `v`; (b) permit optional `appVersions.*` in `env/accept.yaml` and `env/prod.yaml` with semver validation when present; (c) ERROR if any file under `values/tenants/` contains a top-level `appVersions:` block. Preserve the existing `*vng*` exception
- [ ] 2.10 Run `./scripts/validate-values.sh` and `./scripts/smoke-checks.sh` locally; expect them to pass
- [ ] 2.11 Run `helm template` on three representative tenants and grep the rendered Deployment for the three env-var values. Verify the resolution path:
  - A tenant with NO `tenant.apps.versions` → env vars resolve to platform/env defaults from the merged `appVersions`
  - A canary-accept tenant with `tenant.apps.versions.openregister: "0.2.14-beta..."` → the `openregister` env var is the tenant pin, others fall back to merged `appVersions`
  - A prod tenant with full `tenant.apps.versions: {opencatalogi, openconnector, openregister}` → all three env vars are the tenant pins
- [ ] 2.12 Pre-flight rollback drill on canary-accept against a feature branch (do NOT merge to main yet):
  - Create branch with steps 2.4–2.9 changes; push to origin
  - `argocd app sync nc-canary-accept --revision <branch>` and verify pods Healthy
  - Exec into the nextcloud container: `kubectl exec -n canary-accept deploy/nextcloud -c nextcloud -- sh -c 'env | grep -E "OPENCATALOGI_VERSION|OPENCONNECTOR_VERSION|OPENREGISTER_VERSION"'` — confirm values match expected resolution
  - Roll back: `argocd app sync nc-canary-accept --revision main` and verify pods Healthy with pre-change env values
  - Document drill outcome in the merge commit message
- [ ] 2.13 Commit with message starting `feat(values): centralise app version pinning and add wave label` (include the rollback-drill outcome and the list of tenants affected per step 2.3) and push during the Mon–Thu 17:00–07:00 Amsterdam window
- [ ] 2.14 Verify canary tenants (wave 0) auto-sync after push and pods come up Healthy with the expected version env vars
- [ ] 2.15 Verify the new label is queryable: `kubectl get application -n argocd -l nextcloud.platform/wave=0` returns at least `nc-canary-accept` and `nc-canary-prod`
- [ ] 2.16 Manually sync accept tenants: `argocd app sync -l nextcloud.platform/wave=1 -l nextcloud.platform/environment=accept` (adjust wave numbers to match your tenant.wave values). Spot-check 2–3 tenant pods for correct env values
- [ ] 2.17 Manually sync prod tenants wave-by-wave (wave 1 → 2 → 3). After each wave: pods Ready, no 5xx spike, no error in `conduction-apps.log`, version env vars match expected resolution. Sign off each wave in the commit ticket before proceeding to the next

## 3. Documentation + tenant-file cleanup script (Commit 3)

- [ ] 3.1 Update `docs/ROLLOUTS.md`: add a phased-promotion section describing the canary-overrides → env/accept → env/prod-per-wave protocol, the validation criteria for wave 0 (pods Ready, log clean, no 5xx spike, no error in `conduction-apps.log`), and the `argocd app sync -l nextcloud.platform/wave=N -l nextcloud.platform/environment=prod` selector pattern
- [ ] 3.2 Add a "Rollout-Readiness Capacity Checklist" section to `docs/ROLLOUTS.md` covering Argo CD application-controller `processors`, S3 connection limits, Redis `maxclients`, and PgBouncer `default_pool_size`. For each item include the file path or `kubectl` / `argocd` command to verify the current setting. State explicitly that thresholds are not set in this change; baselining is a follow-on
- [ ] 3.3 Update `docs/ADDING-TENANT.md`: explain the two-key model from design D5. Platform defaults in `common.yaml`. Environment beta-pins in `env/accept.yaml`. Tenant overrides via `tenant.apps.versions.*` in tenant files. State explicitly that top-level `appVersions:` in a tenant file is invalid and will fail validation
- [ ] 3.4 Update `nextcloud-platform/values/templates/tenant-template.yaml`: replace any existing `tenant.apps.versions` example with a comment block: "Only set tenant.apps.versions.<app> when this tenant must be pinned to a different version than the platform default. Otherwise omit and inherit from common.yaml / env files. NEVER add a top-level appVersions: block to a tenant file"
- [ ] 3.5 Add `nextcloud-platform/scripts/audit-tenant-pins.sh` (audit-only, no mode flags — cleanup is a manual per-tenant decision) that:
  - For each tenant file matching `values/tenants/tenant-*.yaml` excluding `*vng*`
  - Reads existing `tenant.apps.versions.{opencatalogi,openconnector,openregister}` values
  - Reads platform defaults from `common.yaml` and (where applicable) environment defaults from `env/accept.yaml` / `env/prod.yaml`
  - Logs per tenant per app: "matches platform default — candidate for removal" or "diverges (tenant=X, default=Y) — intentional override, keep"
  - Output to stdout only; never modifies any file. Operators decide whether and how to act on the audit per tenant
- [ ] 3.6 Run `./scripts/audit-tenant-pins.sh` and commit its output to `docs/incidents/2026-05-pinning-cleanup-candidates.md` for operator follow-up
- [ ] 3.7 Run `./scripts/validate-values.sh` and `./scripts/smoke-checks.sh`; verify zero regressions
- [ ] 3.8 Commit with message starting `docs(rollouts): document phased promotion, capacity checklist, and pinning model` and push (this commit is doc-and-script only, can land in any window per CLAUDE.md tenant-yaml-only rule)
- [ ] 3.9 Update auto-memory `feedback_version_pinning.md` to reflect the two-key model from design D5: platform/env defaults via top-level `appVersions.*` in `common.yaml` and `env/*.yaml`; tenant-level overrides via nested `tenant.apps.versions.*` in tenant files; top-level `appVersions:` in a tenant file is invalid (enforced by validation per D9). The previous "never extraEnv" rule remains true at tenant-file level only — at platform level extraEnv is now the canonical mechanism, synthesised by Helm from `appVersions.*`

## 4. Final verification across all three commits

- [ ] 4.1 Confirm AppProject self-management still works after all three commits: edit a comment in `nextcloud-platform/argo/projects/nextcloud-platform.yaml`, push, observe Argo apply within ~3 min
- [ ] 4.2 Confirm `kubectl get appproject nextcloud-platform -n argocd -o jsonpath='{.spec.syncWindows[*].applications[*]}'` lists both `nextcloud-platform` and `nc-*`
- [ ] 4.3 Confirm env-var resolution for three tenants spanning canary, accept, and prod:
  ```
  kubectl exec -n <ns> deploy/nextcloud -c nextcloud -- sh -c 'env | grep -E "OPENCATALOGI_VERSION|OPENCONNECTOR_VERSION|OPENREGISTER_VERSION"'
  ```
  Values must match the expected resolution per the layered merge (platform default for unpinned tenants, tenant pin for tenants with `tenant.apps.versions.*`)
- [ ] 4.4 Confirm `kubectl get application -n argocd -l nextcloud.platform/wave=0` returns at least the canary tenants
- [ ] 4.5 Confirm a tenant file with a deliberately-malformed top-level `appVersions:` block fails validation: copy `tenant-template.yaml` to a scratch file, add a top-level `appVersions: {opencatalogi: "1.0.0"}` block, run `./scripts/validate-values.sh` against it, expect non-zero exit with the expected error message. Discard the scratch file
- [ ] 4.6 Run `./scripts/validate-values.sh` from the merged main branch as a final check; verify exit 0 (with the documented `*vng*` exception silently honoured)
- [ ] 4.7 Document the rollout outcome in `nextcloud-platform/CHANGELOG.md` per the project's auditability rule: dates of each commit landing, files touched, version pins set in `common.yaml` and `env/accept.yaml`, list of tenants whose effective versions changed and to what (pulled from steps 2.2 and 2.3)
- [ ] 4.8 Close the link from the incident doc: append a "Resolved" section to `docs/incidents/2026-05-06-common-yaml-fanout.md` with the merge commits of all three commits and the date Commit 1 landed