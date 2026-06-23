# Nextcloud Multi-Tenant GitOps Platform

Production GitOps for running many Nextcloud instances on Kubernetes with Argo CD, designed
to survive node upgrades with **no in-cluster NFS dependency** (S3-primary storage, stateless
config, Redis sessions/locking).

## 📖 Start here

| If you want to… | Read |
|---|---|
| **Understand how it all fits together** | **[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)** — repos, GitOps/secret/auth flows, conventions, known issues |
| Browse all documentation | [`docs/README.md`](docs/README.md) — the index |
| Add / remove a tenant | [`docs/ADDING-TENANT.md`](docs/ADDING-TENANT.md) · [`docs/REMOVING-TENANT.md`](docs/REMOVING-TENANT.md) |
| Understand secrets | [`docs/SECRETS.md`](docs/SECRETS.md) |
| Roll out / upgrade safely | [`docs/ROLLOUTS.md`](docs/ROLLOUTS.md) · [`docs/UPGRADE.md`](docs/UPGRADE.md) |
| Change Nextcloud config | [`docs/CONFIG-CHANGES.md`](docs/CONFIG-CHANGES.md) |
| Operate / troubleshoot | [`docs/OPERATIONS.md`](docs/OPERATIONS.md) |

## Conventions you must know (or you will get burned)

- **Argo reads Codeberg, not GitHub.** GitHub remotes are mirrors Argo ignores — `git push
  origin …` does **not** deploy. Push to the `codeberg` remote.
- **A tenant's namespace is its bare name** (e.g. `straatje-accept`). The Argo *application*
  is named `nc-<tenant>`, but the namespace is the bare name — never `nc-<tenant>`.
- **Chart version** lives in the `nextcloud-tenants` ApplicationSet (`targetRevision`,
  default `8.9.0`) and per-tenant via `tenant.chartVersion` — **not** in `values/common.yaml`.
- **Tenant deletion does not auto-remove the namespace** (`preserveResourcesOnDeletion: true`).
- **Secrets:** existing tenants use `scripts/create-tenant-secret.sh`; managed tenants
  (`tenant.secrets.managed: true`) get an ESO-assembled `nextcloud-secrets`. See `docs/SECRETS.md`.

## Repository layout

This `nextcloud-platform/` directory holds the platform; reusable charts live at the **repo
root** (`../charts/`), which the ApplicationSet consumes.

```
nextcloud-platform/
├── argo/
│   ├── applicationsets/nextcloud-tenants.yaml   # generates the nc-<tenant> apps (glob over tenant files)
│   └── projects/                                # Argo AppProjects (the guardrails)
├── platform/
│   ├── redis/  pgbouncer/  postgres/  policies/ # shared platform components
│   └── externalsecrets/                         # ESO CONSUMERS (store + generator); operator is in cluster-infra
├── values/
│   ├── common.yaml   env/{accept,prod}.yaml   db/{mariadb,postgres,external}.yaml
│   ├── canary-overrides.yaml
│   └── tenants/tenant-<org>-<env>.yaml          # one thin file per tenant
├── scripts/                                     # validate-values.sh, smoke-checks.sh, create-tenant-secret.sh, cutover-tenant.sh
└── docs/                                        # ← all documentation (start at ARCHITECTURE.md)

../charts/                                       # repo-root: tenant-secret, tenant-hpa (consumed by the ApplicationSet)
```

## CI quality gates

On every PR/push: `yamllint`, `kubeconform` schema validation, `helm lint` + `helm template`
for all tenants, policy checks, `gitleaks` secret scan, and `scripts/validate-values.sh`.
Locally: `./scripts/validate-values.sh && ./scripts/smoke-checks.sh`.

## License

EUPL-1.2 — see `LICENSE`.
