---
last_reviewed: 2026-08-05
owner: info@conduction.nl
---

# Database Options

This platform supports three database configurations. Choose based on your needs.

> **PostgreSQL is de default sinds 2026-08-05.** MariaDB blijft ondersteund, maar
> is een legacy-keuze die je expliciet maakt. `tenant.dbType` is een verplicht
> veld (`scripts/validate-values.sh`), dus een tenant erft nooit stilzwijgend een
> engine; laat je het weg, dan faalt CI. De fallback in de ApplicationSet is
> `postgres`.

> DB config is layered: each profile lives in `values/db/<dbType>.yaml`
> (`mariadb`, `postgres`, `external`) and is selected by `tenant.dbType` in the
> tenant file. The blocks below are illustrative excerpts of those profiles — see
> `values/db/` for the authoritative values and `docs/ARCHITECTURE.md` for how the
> ApplicationSet wires them together.

## Option 1: MariaDB (Legacy — expliciet opt-in)

**Best for:** bestaande tenants die er al op staan. Kies voor nieuwe tenants
PostgreSQL (Option 2 of 3), tenzij er een concrete reden voor MariaDB is.

Each tenant gets their own MariaDB pod managed by the Nextcloud Helm chart.

### Configuration

Zet `tenant.dbType: mariadb` expliciet in het tenant-bestand; de matching
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
- ❌ De opstartcyclus van de bitnami-image kent een deadlock-risico (zie hieronder)

### Opstartgedrag en probes (belangrijk)

De bitnami-image start mysqld bij elke start eerst op de achtergrond voor
`mysql_upgrade`, stopt hem ~1 seconde na `ready for connections`, en start hem
daarna definitief. Valt die stop midden in het laden van de buffer pool uit
`ib_buffer_pool`, dan kan de afgebroken load de shutdown laten deadlocken: er
komt geen `Shutdown completed`, mysqld staat idle op enkele millicores, en de
kubelet schiet de container af.

`values/db/mariadb.yaml` dekt dit op twee manieren, en beide moeten blijven staan:

| Instelling | Waarom |
|---|---|
| `innodb_buffer_pool_load_at_startup=0` in `primary.configuration` | Geen load bij het opstarten, dus niets om af te breken. Prijs: koude cache na een herstart. |
| `primary.startupProbe` (budget 10 min) | Zonder startupProbe geldt alleen `livenessProbe.initialDelaySeconds` (chart-default 120s) als opstartbudget. InnoDB crash recovery van een grote database duurt legitiem langer; wordt hij daar middenin afgeschoten, dan begint recovery elke ronde opnieuw en komt hij nooit klaar. |

Let op: `primary.configuration` **vervangt** de my.cnf van de subchart volledig.
Bij een chart-upgrade moet de inhoud opnieuw vergeleken worden met de nieuwe
chart-default — het commando daarvoor staat in `values/db/mariadb.yaml`.

Voorval waar dit uit voortkomt: epe-prod en dinkelland-prod, 2026-08-04. Zie
`docs/DEBUGGING.md` voor het herkennen en verhelpen.

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

| Feature | MariaDB | PostgreSQL In-Cluster | External PostgreSQL |
|---------|---------|----------------------|---------------------|
| Default | Nee (legacy, expliciet) | **Ja** | Nee (expliciet) |
| Template | `tenant-template-postgres.yaml` (+ `dbType: mariadb`) | `tenant-template.yaml` | (custom) |
| Setup complexity | Easy | Easy | Medium |
| Resource efficiency | Medium | Low (includes Redis) | High |
| Connection pooling | No | No | Yes (PgBouncer) |
| Custom extensions | No | Yes | Depends |
| NetworkPolicy needed | Yes (platform Redis) | No (per-tenant Redis) | Yes |
| Node upgrade resilience | Medium | Medium | High |
| Multi-tenant efficiency | Medium | Low | High |
| Managed DB support | No | No | Yes |
| Recommended for | Bestaande MariaDB-tenants | Nieuwe tenants (default) | Production |

## Quick Reference

| I want... | Use this template |
|-----------|-------------------|
| Nieuwe tenant (default) | `tenant-template.yaml` (PostgreSQL) |
| PostgreSQL with extensions | `tenant-template-postgres.yaml` |
| MariaDB (legacy) | `tenant-template.yaml` + zet `dbType: mariadb` expliciet |
| Shared database cluster | External PostgreSQL (custom setup) |

