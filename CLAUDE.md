# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Request Router (read first)

Before doing anything, classify the request — almost all work here is one of two kinds:

| Kind | What it is | Route |
|------|-----------|-------|
| **A — Tenant** | Add or change a tenant (files under `values/tenants/` only) | `/add-tenant` (one) or `/batch-add-tenant` (many). **Always** create secrets via `/generate-secrets`. Deploy with `/sync-tenant` (use `--refresh-appset` for brand-new tenants). Allowed any time. |
| **B — Platform** | Anything outside `values/tenants/` (`platform/`, `argo/`, `values/common.yaml`, `values/env/`, `values/db/`, `scripts/`, `policy/`, `.github/`, docs) | Run `/change-guard` **first** to check the sync window, then edit. Deploy windows are restricted (see Sync Windows below). |
| **C — Neither** | Unclear or out of scope | Ask the user which it is before proceeding. |

**Skill-first rule:** drive the work through the skills above and the sanctioned scripts they call (`create-tenant-secret.sh`, `argocd-sync.sh`, `validate-values.sh`). Ad-hoc `bash` is acceptable only as the script a skill invokes — never as a substitute for the skill itself, and never to hand-roll a loop that a batch skill already covers.

## Project Overview

This is a **GitOps platform** for deploying multiple isolated Nextcloud instances on Kubernetes using Argo CD. The platform uses a layered Helm values architecture to manage multi-tenant deployments with shared platform services.

Key architectural innovation: **S3-primary storage** eliminates NFS dependencies that cause failures during Kubernetes node upgrades.

## Common Commands

### Local Validation (run before pushing)
```bash
./scripts/validate-values.sh        # Validate all tenant YAML files (required fields, structure)
./scripts/smoke-checks.sh           # Helm template rendering + kubeconform schema validation
```

### Secret Management
```bash
# Create tenant secrets (use --generate-passwords to auto-generate)
# Geef de db-vlag ALTIJD expliciet mee; die moet matchen met tenant.dbType.
# Let op: de script-default staat nog op --mariadb terwijl het platform sinds
# 2026-08-05 postgres als default heeft. Nooit op de default vertrouwen.
./scripts/create-tenant-secret.sh <tenant-name> --postgres --namespace <ns>
./scripts/create-tenant-secret.sh <tenant-name> --postgres --namespace <ns> --generate-passwords

# Platform secrets
./scripts/create-platform-secrets.sh
./scripts/create-postgres-admin-secret.sh
```

### Argo CD Operations
```bash
./scripts/argocd-sync.sh <pattern>  # Force sync apps matching pattern
```

### Required Local Tools
`helm`, `kubeconform`, `kube-score`, `yq`, `yamllint`, `conftest`, `gitleaks`

## Architecture

### Layered Helm Values (4-file merge per tenant)
Argo CD ApplicationSet composes values in this order:
1. `values/common.yaml` — base config for all tenants (Nextcloud image, PHP-FPM, Nginx, Redis, probes, resource limits)
2. `values/env/{accept,prod}.yaml` — environment-specific overrides (replicas, HPA, resources)
3. `values/db/{mariadb,postgres,external}.yaml` — database configuration
4. `values/tenants/tenant-{name}.yaml` — per-tenant settings (minimal, 10-15 lines typically)

### Tenant Definition Pattern
Tenant files are thin configs; all else is derived from them:
```yaml
tenant:
  name: orgname-prod         # Drives namespace (nc-orgname-prod) and hostname
  environment: prod           # Selects env values file
  wave: "1"                  # Rollout wave (0=canary, 1-3=progressive)
  dbType: postgres            # Selects db values file. Verplicht veld; postgres is
                              # de default sinds 2026-08-05, mariadb is legacy.
  apps:
    enabled:
      - opencatalogi
      - openconnector
      - openregister
```

### Key Directories
- `argo/` — Argo CD ApplicationSet, AppProject (RBAC, sync windows), platform Application
- `platform/` — Shared services: Redis, PgBouncer, ExternalSecrets, NetworkPolicies, per-tenant Helm chart
- `values/` — All Helm values files (common, env, db, tenants, templates)
- `scripts/` — Operational utilities for secrets and validation
- `docs/` — Operational runbooks (ADDING-TENANT.md, SECRETS.md, ROLLOUTS.md, etc.)
- `policy/` — OPA/Conftest policies for CI enforcement

### Namespace Convention
The Kubernetes namespace equals `tenant.name` directly (e.g., `zuiddrecht-prod`). The ApplicationSet auto-creates it and labels it with `app.kubernetes.io/part-of: nextcloud-platform`. An explicit `tenant.namespace` override can be set in the tenant values file if needed.

### Platform Shared Services
- **Redis** (`nextcloud-platform` namespace): Shared distributed caching and locking across all tenants
- **PgBouncer** (`nextcloud-platform` namespace): PostgreSQL connection pooler for `external` dbType tenants
- **NetworkPolicies**: No manual updates needed when adding tenants — the ApplicationSet labels every namespace with `app.kubernetes.io/part-of: nextcloud-platform` and both NetworkPolicies allow all namespaces with that label automatically.

### Sync Windows (Governance)
The AppProject enforces automatic sync blocks during office hours, but the operational rule is stricter:

- **Platform changes**: Only allowed Monday–Thursday 17:00–07:00 **Amsterdam time** (Europe/Amsterdam — handles CET/CEST automatically). Never on Friday evenings, Saturdays, or Sundays — unless mwest2020 explicitly approves.
- **Tenant config additions** (`values/tenants/` only): Allowed at any time, including office hours and weekends.
- **Canary (wave 0)**: Syncs first in every rollout; validate before allowing other waves to proceed.

## CI/CD Pipeline

GitHub Actions runs on every push/PR (`.github/workflows/validate.yaml`):

| Job | Blocking? | What it checks |
|-----|-----------|----------------|
| YAML Lint | Yes | yamllint, 200-char line limit |
| Kubeconform | Yes | Kubernetes schema validation |
| Helm Checks | Yes | Template rendering, resource existence |
| Values Validation | Yes | Required fields via `validate-values.sh` |
| Kustomize Build | Yes | Platform component kustomization builds |
| Policy Checks | No (warn only) | kube-score + OPA/Conftest policies |
| Secret Scanning | Yes | gitleaks + custom patterns |

## Known Validation Exceptions

`tenant-vng-backend-accept.yaml` fails `validate-values.sh` with "Missing required field: .tenant.apps.enabled". This is intentional — the vng tenant uses a non-standard app setup. **Ignore all validation errors for any tenant file matching `*vng*`.**

## Adding a New Tenant

1. Copy `nextcloud-platform/values/templates/tenant-template.yaml` to `nextcloud-platform/values/tenants/tenant-{name}.yaml`
2. Edit: name, environment, wave, dbType (postgres tenzij bewust mariadb), apps
3. Create secrets: `./nextcloud-platform/scripts/create-tenant-secret.sh {name} --{dbType} --namespace {name} --generate-passwords`
4. Commit and push — ApplicationSet auto-detects the new file and creates the Application

No NetworkPolicy changes needed (see Platform Shared Services above).

## Resource Policy

**No requests, only limits** for background/non-critical containers (cron jobs, sidecars). Kubernetes schedules freely and throttles CPU when under pressure — preferred over reserving capacity that sits idle. Only set requests on containers where guaranteed scheduling matters (main Nextcloud pod, nginx).

This is set globally in `values/common.yaml` and should not be overridden with requests in env or tenant files.

## Conduction Apps

Three apps (opencatalogi, openconnector, openregister) are auto-installed in Nextcloud via hooks in `values/common.yaml`. They run idempotently using a state file at `/var/www/html/data/.conduction-apps-state`. Installation logs are at `/var/www/html/data/conduction-apps.log`.

Pin app versions via tenant values: `OPENCATALOGI_VERSION: "1.0.0"`

## Secret Management

Two supported approaches (see `docs/SECRETS.md`):
- **External Secrets Operator (recommended)**: `platform/externalsecrets/` ClusterSecretStore + per-tenant ExternalSecret
- **Fallback Job**: Kubernetes Job generates cryptographically secure passwords in-cluster

Required secret keys per tenant: `admin-password`, `s3-access-key`, `s3-secret-key`, `db-password`

**Never commit secrets** — `.gitignore` excludes `*.secret.yaml`, `secrets/`, and `env.local`.

## Agent-guardrails

- Operatie-cataloog: `docs/agents.md` — **niet gecatalogiseerd = eerst
  vragen** (uitbreiden kan alleen via PR op het cataloog).
- Grondwaarheid: MCP `conduction-docs` (het handboek) boven modelkennis;
  bij tegenspraak wint de handboekpagina, flag de discrepantie.
- Vóór afronden: `./scripts/verify.sh` groen; docs wijzigen mee in
  dezelfde wijziging (docs-as-code).
- Push en álle cluster-mutaties doet een mens. Nooit `--no-verify`.
