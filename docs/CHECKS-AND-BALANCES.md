---
last_reviewed: 2026-08-10
owner: info@conduction.nl
---

# Checks And Balances (Safe Rollouts)

This document defines the operational safety flow for tenant additions and platform changes.

It is designed to avoid a single change affecting all environments at once.

## 1) Add or change environment

Every PR is classified as:

- **Platform change**: shared behavior/templating/rollout logic.
- **Tenant additive change**: isolated tenant file updates.

Classification is automated by `nextcloud-platform/scripts/classify-change.sh`
and enforced in CI by:

- `.github/workflows/governance-check.yaml`

Required labels (both exist in this repository; the gate fails without the
matching one):

- `change/platform` for platform/mixed changes
- `change/tenant-additive` for tenant-only changes

## 2) Check installation viability

Before merge, CI runs `scripts/verify.sh`, which wraps:

- `nextcloud-platform/scripts/validate-values.sh` — required/forbidden fields
  and patterns across all tenant files
- `nextcloud-platform/scripts/smoke-checks.sh` — Helm chart renders

This catches invalid values and Helm/rendering failures early. Both are dry-run:
CI needs no cluster access and no secrets. The same gate runs locally via
`./scripts/verify.sh` before pushing.

### Docs change with the code (`docs-touched`)

A third pre-push gate, `docs-touched`, reads the diff of the push: when it
touches platform paths that `docs/` describes, documentation has to change in
the same push. The path rules live in `.docs-touched.yaml` in the repo root and
deliberately mirror the platform/tenant split of `classify-change.sh` — tenant
files under `nextcloud-platform/values/tenants/` are exempt, so ordinary tenant
PRs are never held up.

The gate runs in **`mode: warn`**: it reports in full and blocks nothing, so we
can see what it would catch before it starts refusing pushes. Switching it to
`enforce` is a separate, deliberate change.

Config format, the per-commit `Docs-not-needed:` exemption and the verification
recipe are documented once, in techbook `docs/docs-touched.md`.

## 3) Configuration checks

> ⚠️ **Not implemented.** `.github/workflows/rollout-verify.yaml` does not exist.
> The section below describes intent, not a workflow you can dispatch. Run
> `nextcloud-platform/scripts/smoke-checks.sh --tenant <name>` by hand for the
> per-tenant checks, and see `docs/ROLLOUTS.md` for the canary ring.

Post-merge verification is intended to run via:

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
