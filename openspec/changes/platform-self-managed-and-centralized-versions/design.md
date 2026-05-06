## Context

This GitOps platform deploys 34 Nextcloud tenants via an Argo CD ApplicationSet, with a layered Helm values architecture (`common.yaml` → `env/*.yaml` → `db/*.yaml` → `tenants/tenant-*.yaml`, last-wins). Three coupled architectural facts shape this change:

1. **AppProject is bootstrap-only.** The `nextcloud-platform` AppProject (which defines source-repo allowlists, destination namespaces, sync windows, RBAC) lives in `nextcloud-platform/argo/projects/nextcloud-platform.yaml` but is not managed by any Argo CD Application. Convention: edit YAML, push, then `kubectl apply` manually. In practice this drifts — the recent `nc-*` deny-window fix sat unapplied for 2 days while shared-values changes still fanned out unchecked during office hours.

2. **App versions live in the wrong layer.** The OPENCATALOGI/OPENCONNECTOR/OPENREGISTER env vars are constructed inside the ApplicationSet `goTemplate`, which only sees the per-tenant yaml emitted by the git generator. `common.yaml` and `env/*.yaml` are invisible to the goTemplate; they're consumed later by Helm itself. So version pinning is per-tenant only. Currently 8 of 34 tenants have explicit pins via `tenant.apps.versions.*`; the remaining 26 implicitly track whatever the install hook installs at start time (effectively "latest").

3. **Fan-out is unguarded.** Once versions are centrally pinnable, a single `common.yaml` bump triggers OutOfSync on every tenant Application simultaneously. The existing `argocd.argoproj.io/sync-wave` annotation orders the *start* of syncs but does not gate wave N on healthy completion of wave N-1. With ~80 tenants on the horizon and v1.0.0 of the Conduction apps approaching, simultaneous `occ upgrade` runs would burst-load shared S3, Redis, and (for external-db tenants) PgBouncer.

Stakeholders: platform operators (mwest2020, conduction team), tenant admins (passive — no UX change), Argo CD controller (concurrency limits matter at fleet scale).

Constraints from `CLAUDE.md`:
- Platform changes only Mon–Thu 17:00–07:00 Amsterdam time. Tenant-yaml-only changes are allowed any time.
- "No requests, only limits" rule for non-critical containers stays untouched.
- `tenant-vng-backend-accept.yaml` fails standard validation by design — exclude from batch tenant edits and validation passes.

## Goals / Non-Goals

**Goals:**
- Eliminate manual `kubectl apply` for AppProject changes — make the AppProject GitOps-managed via a self-applying bootstrap Application.
- Allow Conduction app versions to be pinned at platform level (`common.yaml`), with environment-level (`env/{accept,prod}.yaml`) and tenant-level (`tenants/tenant-*.yaml`) override granularity using Helm's existing layered merge.
- Provide an operator-controlled mechanism to roll a version bump out wave-by-wave instead of fleet-wide-simultaneously.
- Preserve all existing rollback paths (each piece must be revertable independently).
- Link the change to the 6-May-2026 fan-out incident as a documented corrective action.

**Non-Goals:**
- Replacing the install hook in `common.yaml` (separate concern; the hook keeps its current install logic, only the env-var source changes).
- Changing the canary-prod stateless-HA workstream (separate proposal `stateless-nextcloud-ha`, untouched here).
- Postgres → MariaDB migrations (separate operational task).
- Auto-promotion between waves (no automated "wave 0 healthy → trigger wave 1"; promotion stays operator-initiated to keep an audit gate).
- Changing tenant naming conventions, namespace conventions, or the per-tenant secret pattern.
- Deprecating `tenant.apps.versions.*` — it remains the canonical place for tenant-level overrides.

## Decisions

### D1: Bootstrap Application lives in built-in `default` project, not in `nextcloud-platform`

**Choice:** The Application that watches `nextcloud-platform/argo/projects/` runs under Argo CD's built-in `default` project, not under `nextcloud-platform`.

**Why:** The `nextcloud-platform` AppProject restricts destinations to `nextcloud-platform`, `nc-*`, and `*-{accept,test,prod,green}` namespaces. The bootstrap Application needs to write a resource into the `argocd` namespace itself, which `nextcloud-platform` explicitly does not allow. Adding `argocd` as a destination on `nextcloud-platform` would broaden the platform project's blast radius — the platform project should not be able to manage Argo CD's own resources. Keeping the bootstrap in `default` enforces principle-of-least-privilege at the project boundary.

**Alternatives considered:**
- Add `argocd` namespace to `nextcloud-platform.spec.destinations` and self-manage. Rejected: the platform project becomes able to create arbitrary resources in `argocd`, weakening the security boundary.
- Create a dedicated `argocd-platform` AppProject just for managing other AppProjects. Rejected: adds a layer with no benefit over using the built-in `default` project.

### D2: Bootstrap Application uses `preserveResourcesOnDeletion: true` and no auto-prune

**Choice:** The bootstrap Application's `syncPolicy` enables auto-sync but explicitly disables `prune` and sets `preserveResourcesOnDeletion: true`.

**Why:** The failure mode "bootstrap Application accidentally deleted → AppProject pruned → all tenant Apps lose their project → cluster-wide sync stops" is catastrophic. Disabling prune means a stale AppProject manifest in Git won't tear down the live AppProject; preserveResourcesOnDeletion means deleting the bootstrap Application itself does not cascade-delete the AppProject. Tradeoff: removed AppProject yaml in Git won't auto-clean. Acceptable because AppProject deletion should always be a deliberate manual operation.

### D3: Split the AppProject and Namespace documents into separate files

**Choice:** Before introducing the bootstrap Application, split the current `nextcloud-platform/argo/projects/nextcloud-platform.yaml` (which today contains both the AppProject and a Namespace document separated by `---`) into two single-document files in the same directory: `nextcloud-platform.yaml` (AppProject only) and `namespace.yaml` (Namespace only).

**Why:** The bootstrap Application's source path is the directory `nextcloud-platform/argo/projects/`. Without a split, the bootstrap would manage both the AppProject and the Namespace, which conflates two different ownership concerns and risks Argo OutOfSync warnings if other tooling labels the namespace. Splitting keeps each manifest focused, makes the diff for any future edit clearer, and matches the convention of one resource per file used elsewhere in the repo.

**Alternative considered:** Move the Namespace to `platform/namespaces/` and keep only the AppProject under `argo/projects/`. Rejected for this change: broader directory restructuring expands scope; the in-place split achieves the same goal with a smaller diff. Can be done later as cleanup.

### D4: Move env-var construction from ApplicationSet goTemplate to Helm-side `extraEnv`

**Choice:** Remove the OPENCATALOGI_VERSION / OPENCONNECTOR_VERSION / OPENREGISTER_VERSION entries from the ApplicationSet `goTemplate` `values:` block. Add equivalent entries to `nextcloud-platform/values/common.yaml` under `nextcloud.extraEnv` using Helm template expressions that read `.Values.appVersions.*` with `.Values.tenant.apps.versions.*` as a tenant-level override.

**Why:** The goTemplate runs at ApplicationSet generator time and sees only the tenant yaml. Helm templates run later and see the full merged values. By relocating the env-var construction to Helm-side, the layered merge (`common` → `env` → `tenant`) automatically resolves the chain. Operators get top-down inheritance (set once in common, override per env, override per tenant) without any custom logic in the generator.

**Alternatives considered:**
- Keep goTemplate, parse `common.yaml` from the values repo at generator time. Rejected: ApplicationSet git generators don't support reading sibling values files; would require a custom plugin or generator-side preprocessing. Operationally fragile.
- Single canonical key (`appVersions.*`) in all layers including tenant files, deprecating `tenant.apps.versions.*`. Rejected — see D5.

### D5: Two-key model that mirrors the existing convention; each key has a clear scope

**Choice:**
- `appVersions.*` (top-level) is the **platform-and-environment-level** key. Set in `common.yaml` for the platform default, optionally in `env/accept.yaml` to pin staging beta versions, optionally in `env/prod.yaml` for an explicit prod-pin that diverges from common.
- `tenant.apps.versions.*` (nested) is the **tenant-level override** key. Used only in `tenants/tenant-*.yaml` for organisations that explicitly want a different version than the platform default.

**Why:** The existing tenant-file convention already places tenant-specific pins under `tenant.apps.versions.*`. Asymmetry between platform layers and tenant layers is intentional: a reader who opens a tenant file and sees `tenant.apps.versions: ...` immediately knows "this tenant deviates from platform default". A reader who opens `common.yaml` and sees `appVersions: ...` knows "this is the fleet-wide default". Reusing the same key in both locations would lose this signal. The asymmetry is also less migration work — the 8 existing tenants with `tenant.apps.versions.*` blocks stay syntactically unchanged.

**Helm template (using sprig `dig` to safely traverse possibly-missing nested keys):**
```yaml
- name: OPENCATALOGI_VERSION
  value: "{{ dig "tenant" "apps" "versions" "opencatalogi" (dig "appVersions" "opencatalogi" "" .Values) .Values }}"
- name: OPENCONNECTOR_VERSION
  value: "{{ dig "tenant" "apps" "versions" "openconnector" (dig "appVersions" "openconnector" "" .Values) .Values }}"
- name: OPENREGISTER_VERSION
  value: "{{ dig "tenant" "apps" "versions" "openregister" (dig "appVersions" "openregister" "" .Values) .Values }}"
```

Read: tenant pin wins if explicitly set; otherwise fall back to the merged `appVersions` (which Helm has already resolved through common → env layering). No deprecation cycle: both keys are first-class, in their respective scopes, indefinitely.

**Alternative considered:** Single `appVersions.*` key everywhere with deprecation of `tenant.apps.versions.*`. Rejected: forces a rename migration on 8 existing tenant files for no scope-clarity benefit; loses the signal that a tenant-file-level pin is a deliberate exception.

### D6: Wave label is `nextcloud.platform/wave` and lands in the same commit as the centralised pinning

**Choice:** Add `nextcloud.platform/wave: "{{ default \"1\" .tenant.wave }}"` to the Application template's `metadata.labels`. This change ships in Commit 2 (the centralised-pinning commit), not a separate commit.

**Why:** The label namespace `nextcloud.platform/*` already exists for `nextcloud.platform/tenant` and `nextcloud.platform/environment`. Argo CD's `argocd app sync -l <selector>` works on Application labels but not on annotations, so the existing `argocd.argoproj.io/sync-wave` annotation alone does not enable wave-by-wave manual sync. The label and the annotation share the same `{{ .tenant.wave }}` template source so they cannot diverge.

The label ships with Commit 2 because Commit 2 is the first commit that performs a wave-by-wave sync (the centralised pinning rollout). Without the label in Commit 2, Commit 2 cannot use the documented `argocd app sync -l nextcloud.platform/wave=N` selector — operators would have to fall back to per-app sync or environment-based grouping, which is not the same as wave-based grouping.

### D7: Wave promotion is operator-gated, not automated

**Choice:** Document a manual phased-promotion protocol in `docs/ROLLOUTS.md`. No code change to auto-trigger wave N+1 when wave N reports healthy.

**Why:** Auto-promotion adds significant complexity (health-check hooks, rollback automation, race conditions) for marginal benefit. Operators already gate platform changes via the existing AppProject deny window. Manual `argocd app sync -l nextcloud.platform/wave=N` after each wave validates is auditable, simple, and matches the project's preference for explicit operator action over implicit automation.

### D8: Capacity verification is a runbook check, not a config change

**Choice:** Add a runbook checklist to verify Argo controller `processors`, S3 connection limits, Redis `maxclients`, and PgBouncer `default_pool_size`. No code change in this proposal.

**Why:** The current fleet (34 tenants) does not stress these limits. Pre-emptively raising them risks setting wrong values without data. The check-task surfaces the question in the rollout-readiness checklist for v1.0.0; tuning is a follow-on change with measurements.

### D9: Validation enforces the asymmetry — `appVersions:` belongs only in platform layers

**Choice:** Update `scripts/validate-values.sh` with three changes:
1. Require `appVersions.opencatalogi/openconnector/openregister` in `common.yaml` as non-empty semver strings (without leading `v`).
2. Permit optional `appVersions.*` in `env/accept.yaml` and `env/prod.yaml`; if present, validate semver format.
3. **Error** if any file under `values/tenants/` contains a top-level `appVersions:` block. The canonical tenant-override path is `tenant.apps.versions.*`; a top-level `appVersions:` in a tenant file is a misuse and should fail validation, not silently work.

**Why:** Without rule 3, the asymmetry of D5 is convention-only and easily violated by accident. Enforcing it in CI keeps the scope-signal of each key intact. The existing per-tenant `validate_app_versions_format` check stays unchanged.

## Risks / Trade-offs

| Risk | Mitigation |
|---|---|
| Bootstrap Application misconfiguration prunes AppProject → all tenant Apps lose their project → cluster-wide sync stops | D2 (no prune, `preserveResourcesOnDeletion: true`); land in isolation as Commit 1; verify via `kubectl get appproject` before proceeding; manual `kubectl apply` retained as documented fallback |
| Empty version after migration → install hook installs unintended content | Ship Helm template change and `appVersions` defaults in `common.yaml` in the same commit; validation script enforces all three keys present and non-empty |
| Platform default in `common.yaml` silently changes behaviour for the 26 tenants without explicit pins | Pre-task 2.0: distribution audit committed as `docs/incidents/2026-05-pinning-baseline.md` before Commit 2; commit message of Commit 2 explicitly lists which tenants were on which version pre-change |
| vng tenant breakage during migration / validation | Migration script and validation pass both honour the existing `*vng*` exclusion; smoke-checks already document this exception |
| Wave label out of sync with annotation | Both come from the same `{{ .tenant.wave }}` template expression in the ApplicationSet — they cannot diverge unless the ApplicationSet itself is edited |
| Argo controller saturation under fleet bumps | D8 capacity-check; current default is fine for 34 tenants but should be re-checked before fleet grows toward 80 |
| Operator places `appVersions:` block in a tenant file by accident → silent works but misleading | D9: validation script errors on top-level `appVersions:` in any `values/tenants/*.yaml` file |
| Rollback claim ("revert Commit 2 → tenants keep working") is untested | Pre-flight rollback drill on canary-accept using `argocd app sync --revision <branch>` before Commit 2 merges to main; outcome documented in commit message |

## Migration Plan

The change lands in three commits, in this order, each verifiable independently. There is no follow-on cleanup commit because no field is being deprecated.

### Commit 1 — Bootstrap Application + Namespace file split + incident doc

1. Split `nextcloud-platform/argo/projects/nextcloud-platform.yaml` into two single-document files (`nextcloud-platform.yaml` for the AppProject, `namespace.yaml` for the Namespace) per D3.
2. Add `nextcloud-platform/argo/bootstrap/appproject-bootstrap.yaml` (Argo CD Application in `default` project, source path `nextcloud-platform/argo/projects/`, syncPolicy automated, `prune: false`, `preserveResourcesOnDeletion: true`).
3. Add `nextcloud-platform/argo/bootstrap/README.md` documenting the eenmalige `kubectl apply` step and the manual-apply fallback procedure.
4. Add `docs/incidents/2026-05-06-common-yaml-fanout.md` documenting the incident this change corrects: timestamp, affected tenants (from Argo Application sync history), root cause (deny window committed 4 May not applied until 6 May), and link back to this OpenSpec change directory.
5. Eenmalige `kubectl apply -f nextcloud-platform/argo/bootstrap/appproject-bootstrap.yaml` during the Mon–Thu 17:00–07:00 Amsterdam window. Record who applied it, when, and from which kubeconfig context in the change ticket.
6. Verify the bootstrap Application reaches `Synced/Healthy` and that both deny windows on the AppProject are still present.
7. Smoke test: edit a comment in `nextcloud-platform.yaml`, push, observe Argo apply within ~3 min without manual `kubectl apply`.

**Rollback:** `kubectl delete application appproject-bootstrap -n argocd` (D2 keeps the AppProject intact). Resume manual-apply workflow.

### Commit 2 — Centralised version pinning + wave label

1. Pre-task: run `scripts/audit-app-versions.sh` (added in this commit), commit output to `docs/incidents/2026-05-pinning-baseline.md` so the platform default in `common.yaml` is chosen with full visibility of the pre-change state.
2. Add `appVersions: {opencatalogi, openconnector, openregister}` block to `nextcloud-platform/values/common.yaml` with the chosen platform-default versions (stable productie versies).
3. If staging-beta versions diverge from prod, add `appVersions:` block to `nextcloud-platform/values/env/accept.yaml` with the staging-specific pins.
4. Add three Helm-side `extraEnv` entries to `common.yaml` under `nextcloud.extraEnv` using the `dig`-based template per D5.
5. Remove the corresponding three entries from the `goTemplate` `values:` block in `nextcloud-platform/argo/applicationsets/nextcloud-tenants.yaml`.
6. Add `nextcloud.platform/wave: "{{ default \"1\" .tenant.wave }}"` to the ApplicationSet template's `metadata.labels` per D6.
7. Update `scripts/validate-values.sh` per D9 (require platform-level `appVersions`, optional in env files, error on tenant-level top-level `appVersions:`).
8. Run `./scripts/validate-values.sh` and `./scripts/smoke-checks.sh` locally.
9. Pre-flight rollback drill: create a feature branch with these changes, sync canary-accept against the branch via `argocd app sync nc-canary-accept --revision <branch>`, verify env vars resolve correctly, then revert by syncing `--revision main`, verify env vars return to pre-change values. Document outcome in the commit message before merging to main.
10. Land in the Mon–Thu 17:00–07:00 Amsterdam window per CLAUDE.md.
11. After merge: canary tenants (wave 0) auto-sync first; verify pods Healthy and env vars match expected resolution.
12. Manual `argocd app sync -l nextcloud.platform/wave=1` for accept tenants, validate, then wave 2/3 for prod tenants.

**Rollback:** Revert Commit 2. The 8 tenants with explicit `tenant.apps.versions.*` continue to work unchanged because their pins still resolve through the goTemplate values block (which is restored by the revert). Drill in step 9 confirms this works in practice.

### Commit 3 — Documentation + tenant-file cleanup script

1. Update `docs/ROLLOUTS.md`: phased-promotion section (canary-overrides → env/accept → env/prod wave-by-wave), validation criteria per wave (pods Ready, log clean, no 5xx spike, no error in `conduction-apps.log`), and the `argocd app sync -l nextcloud.platform/wave=N -l nextcloud.platform/environment=prod` selector pattern.
2. Add a "Rollout-Readiness Capacity Checklist" section to `docs/ROLLOUTS.md` covering the four items in D8 with concrete verification commands.
3. Update `docs/ADDING-TENANT.md`: explain the two-key model. Platform defaults in `common.yaml`, environment beta-pins in `env/accept.yaml`, tenant overrides via `tenant.apps.versions.*` in tenant files. State explicitly that top-level `appVersions:` in a tenant file is invalid.
4. Update `nextcloud-platform/values/templates/tenant-template.yaml` with a comment explaining when to use `tenant.apps.versions.*`: "use this only when this tenant must be pinned to a different version than the platform default; otherwise omit the block and inherit from common.yaml/env files".
5. Add `scripts/migrate-app-versions.sh` (with `--dry-run` flag) that **audits but does not modify** tenant files: for each tenant with `tenant.apps.versions.*`, log whether the pin is identical to the platform default (= candidate for removal, manual decision) or diverges (= intentional override, keep). The script is an artefact of the migration, not an automated edit. Operators decide per tenant.
6. Run the audit script in `--dry-run` mode and commit its output to `docs/incidents/2026-05-pinning-cleanup-candidates.md` for follow-up.

**Rollback:** Wave label already shipped in Commit 2; this commit is doc-and-script only. Single `git revert` reverses everything.

## Open Questions

- **Default placement of `appVersions:` in `common.yaml`:** top-level or under a `platform:` namespace? Going with top-level for symmetry with how `nextcloud:`, `mariadb:`, `postgresql:` already live at top-level in this chart.
- **Should the bootstrap Application also manage the ApplicationSet itself?** Scope creep risk — ApplicationSet is currently bootstrap too. Leaving as a follow-on consideration; not in this proposal.
- **Audit log evidence for the 6-May incident:** the incident doc in Commit 1 needs the precise Argo audit-log timestamps for the auto-sync events. If those logs are no longer retained, document what is recoverable and note the gap. Either way the corrective-action link is valid.
- **Capacity-check thresholds:** D8 surfaces the question but does not set numbers. A follow-on change should baseline `processors` / `maxclients` / `default_pool_size` against an actual fleet-wide upgrade burst (probably during the v1.0.0 rollout itself, observed and recorded).