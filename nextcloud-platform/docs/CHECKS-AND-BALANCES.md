# Checks And Balances (Safe Rollouts)

This document defines the operational safety flow for tenant additions and platform changes.

It is designed to avoid a single change affecting all environments at once.

## 1) Add or change environment

Every PR is classified as:

- **Platform change**: shared behavior/templating/rollout logic.
- **Tenant additive change**: isolated tenant file updates.

Classification is automated by `scripts/classify-change.sh` and enforced in CI by:

- `.github/workflows/governance-check.yaml`

Required labels:

- `change/platform` for platform/mixed changes
- `change/tenant-additive` for tenant-only changes

## 2) Check installation viability

Before merge, CI runs:

- `scripts/validate-values.sh` for changed tenant files
- `scripts/smoke-checks.sh --tenant <name>` for changed tenants

This catches invalid values and Helm/rendering failures early.

## 3) Configuration checks

Post-merge verification can be run via:

- `.github/workflows/rollout-verify.yaml` (manual dispatch)

What it checks:

- values/schema validation
- optional tenant smoke-checks
- optional Argo live status checks (when `KUBECONFIG_B64` is configured)

## 4) Test configuration

Use the manual `Rollout Verify` workflow for test stages:

- run with `tenants_csv` set to canary tenants first
- then run for the next batch
- optionally enable `run_cluster_checks=true`

This keeps promotion explicit and traceable.

## 5) Success => promote, failure => rollback

- **Success**: promote next ring/batch by PR.
- **Failure**: rollback by reverting the batch PR.

Always keep batch PRs small so rollback is one revert.

## Recommended operating model

- Platform changes: canary first, then batches.
- Tenant additive changes: direct allowed, but keep small batches.
- If uncertain: treat as platform change.

## Notes for AI assistants

AI assistants must follow the same model:

- classify change scope first
- default to safer path when uncertain
- avoid broad multi-tenant blast-radius changes in one step

This is enforced by `.cursor/rules/rollout-governance.mdc`.
