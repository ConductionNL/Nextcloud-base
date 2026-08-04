---
last_reviewed: 2026-06-23
owner: info@conduction.nl
---

# Database Options

> ## MariaDB is legacy — use PostgreSQL for anything new
>
> **Do not pick MariaDB for a new tenant.** It is being phased out (decision of
> 2026-08-04). PostgreSQL in-cluster (Option 2) is the direction. Option 1 below is
> kept because 22 tenants still run on it, not as a recommendation.
>
> Caveat while the phase-out runs: the MariaDB pods keep the tight resource limits
> from `values/common.yaml` (500m/512Mi, or the Bitnami `micro` preset's 384Mi on
> older deployments). Measured MariaDB memory p90 is 291Mi, so those ceilings are
> close — `moerdijk`'s repeated exit-137 restarts sat on a MariaDB pod against a
> 384Mi limit. This is deliberately not being fixed, because those pods are going
> away. See [CNPG-MIGRATIE.md](CNPG-MIGRATIE.md) for the measurements, including
> the same limits-only pattern on the PostgreSQL side.

This platform supports three database configurations.

> DB config is layered: each profile lives in `values/db/<dbType>.yaml`
> (`mariadb`, `postgres`, `external`) and is selected by `tenant.dbType` in the
> tenant file. The blocks below are illustrative excerpts of those profiles — see
> `values/db/` for the authoritative values and `docs/ARCHITECTURE.md` for how the
> ApplicationSet wires them together.

## Option 1: MariaDB (LEGACY — being phased out)

**Best for:** nothing new. Existing tenants only, until they are migrated.

> The platform default is **PostgreSQL** as of 2026-08-04. The fallback lives in
> `argo/applicationsets/nextcloud-tenants.yaml`
> (`db/{{ default "postgres" .tenant.dbType }}.yaml`), not in `common.yaml` — the
> `db/` profile is layered after `common.yaml` and always wins. Still set
> `tenant.dbType` explicitly in every tenant file rather than relying on the
> fallback.

Each tenant gets their own MariaDB pod managed by the Nextcloud Helm chart.

### Configuration

Set `tenant.dbType: mariadb` (the default) in the tenant file; the matching
profile `values/db/mariadb.yaml` is then layered in automatically. Illustrative
excerpt of that profile:

```yaml
# values/db/mariadb.yaml (excerpt)
mariadb:
  enabled: true
  auth:
    existingSecret: nextcloud-secrets
    secretKeys:
      mariadb-root-password: mariadb-root-password
      mariadb-password: mariadb-password
```

### Pros
- ✅ Simplest to set up
- ✅ No external dependencies
- ✅ Each tenant fully isolated

### Cons
- ❌ One database pod per tenant (resource overhead)
- ❌ Database pod can be affected by node upgrades
- ❌ No connection pooling

---

## Option 2: PostgreSQL In-Cluster

**Best for:** When you need PostgreSQL features but don't have external PostgreSQL

Each tenant gets their own PostgreSQL pod with optional custom extensions.

### Template

Use `tenant-template-postgres.yaml` which includes:
- Custom PostgreSQL image with extensions
- Per-tenant Redis
- All necessary secret references

```bash
cp values/templates/tenant-template-postgres.yaml values/tenants/tenant-<name>.yaml
```

### Configuration

```yaml
# In tenant values file
mariadb:
  enabled: false

postgresql:
  enabled: true
  image:
    # Custom image with extensions (recommended).
    # Example tag — check values/db/postgres.yaml for the current tag/digest.
    registry: docker.io
    repository: conduction2022/nextcloud-images
    tag: postgres16-ext-sha-8abef67
    pullPolicy: IfNotPresent
  auth:
    database: nextcloud_<tenant>
    username: nextcloud
    existingSecret: nextcloud-secrets
    secretKeys:
      adminPasswordKey: postgres-password
      userPasswordKey: db-password
  primary:
    persistence:
      enabled: true
      size: 8Gi

# Per-tenant Redis (included in postgres template)
redis:
  enabled: true
  auth:
    enabled: true
    existingSecret: nextcloud-secrets
    existingSecretPasswordKey: redis-password
```

### Custom PostgreSQL Image

The custom image (`conduction2022/nextcloud-images:postgres16-ext-*`) includes:
- PostgreSQL 16
- Additional extensions for performance
- Optimized settings for Nextcloud

### Secret Creation

```bash
cd scripts
./create-tenant-secret.sh <tenant-name> --postgres
```

### Pros
- ✅ PostgreSQL features (better JSON support, etc.)
- ✅ Each tenant fully isolated
- ✅ Custom extensions available
- ✅ Per-tenant Redis (no NetworkPolicy needed)

### Cons
- ❌ More pods per tenant (PostgreSQL + Redis)
- ❌ Higher resource usage than shared database

---

## Option 3: External PostgreSQL (Production)

**Best for:** Production, multi-tenant efficiency, managed databases

Shared external PostgreSQL cluster with PgBouncer connection pooling.
Databases are automatically provisioned per tenant.

### Configuration

Set `tenant.dbType: external` in the tenant file; the matching profile
`values/db/external.yaml` is then layered in automatically. Illustrative excerpt
of that profile (host/port are typically set in `values/env/*.yaml`):

```yaml
# values/db/external.yaml (excerpt)
mariadb:
  enabled: false

postgresql:
  enabled: false

internalDatabase:
  enabled: false

externalDatabase:
  enabled: true
  type: postgresql
  existingSecret:
    enabled: true
    secretName: nextcloud-secrets
    usernameKey: db-username
    passwordKey: db-password
```

### Prerequisites

1. External PostgreSQL server accessible from cluster
2. PostgreSQL admin secret for auto-provisioning:

```bash
export POSTGRES_HOST='your-postgres-host'
export POSTGRES_PORT='5432'
export POSTGRES_ADMIN_USER='postgres'
export POSTGRES_ADMIN_PASSWORD='your-admin-password'
./scripts/create-postgres-admin-secret.sh
```

### What's Automated

When using external PostgreSQL, a Job automatically:
- Creates database `nextcloud_<tenant-name>`
- Creates user `nextcloud_<tenant-name>`
- Grants all necessary privileges

### Pros
- ✅ Most efficient for multi-tenant
- ✅ Connection pooling via PgBouncer
- ✅ Can use managed PostgreSQL (RDS, Cloud SQL, etc.)
- ✅ Better resilience (database survives cluster issues)

### Cons
- ❌ Requires external PostgreSQL setup
- ❌ More complex initial setup

---

## Migrating Between Options

### MariaDB → External PostgreSQL

1. **Export data** from MariaDB:
   ```bash
   kubectl exec -n "$TENANT" deploy/nextcloud -- php occ maintenance:mode --on
   # Use mysqldump or Nextcloud's backup app
   ```

2. **Update tenant values** to use external PostgreSQL

3. **Sync with Argo CD** (creates new database)

4. **Import data** to PostgreSQL

5. **Disable maintenance mode**

### Using CloudNativePG Operator (Future — NOT implemented)

> ⚠️ **Aspirational / not implemented.** This section describes a possible future
> direction only. None of the below is wired into the platform today — do not
> follow it as current guidance. The three options above are the supported set.
>
> **Before proposing this route, read [CNPG-MIGRATIE.md](CNPG-MIGRATIE.md).** It
> holds the measurements: the cost case does not hold (the whole consolidation
> gain is 4.4 GiB RAM and 2.2 cores across 58 tenants), and the prototype cluster
> `nextcloud-pg` sat unrecoverable in `nextcloud-platform` for 62 days without
> anyone being alerted. That document also lists the gates that must close before
> any tenant data moves.

For production, one option to consider is [CloudNativePG](https://cloudnative-pg.io/):

```yaml
# Future / NOT implemented: operator-managed PostgreSQL
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: nextcloud-postgres
spec:
  instances: 3
  storage:
    size: 100Gi
```

This provides:
- High availability (automatic failover)
- Backups to S3
- Point-in-time recovery
- Rolling updates

---

## Comparison Table

| Feature | MariaDB (legacy) | PostgreSQL In-Cluster | External PostgreSQL |
|---------|---------|----------------------|---------------------|
| Template | `tenant-template.yaml` | `tenant-template-postgres.yaml` | (custom) |
| Setup complexity | Easy | Easy | Medium |
| Resource efficiency | Medium | Low (includes Redis) | High |
| Connection pooling | No | No | Yes (PgBouncer) |
| Custom extensions | No | Yes | Depends |
| NetworkPolicy needed | Yes (platform Redis) | No (per-tenant Redis) | Yes |
| Node upgrade resilience | Medium | Medium | High |
| Multi-tenant efficiency | Medium | Low | High |
| Managed DB support | No | No | Yes |
| Recommended for | **nothing new — being phased out** | new tenants | Production, once the shared backend works |

> The "External PostgreSQL" column describes the shared CNPG/PgBouncer path. That
> backend is currently **not** in a usable state — see
> [CNPG-MIGRATIE.md](CNPG-MIGRATIE.md). Treat this column as a design target, not
> as an option you can pick today.

## Quick Reference

| I want... | Use this template |
|-----------|-------------------|
| **A new tenant** | `tenant-template-postgres.yaml` |
| PostgreSQL with extensions | `tenant-template-postgres.yaml` |
| MariaDB | don't — legacy, being phased out |
| Shared database cluster | not available yet, see [CNPG-MIGRATIE.md](CNPG-MIGRATIE.md) |

