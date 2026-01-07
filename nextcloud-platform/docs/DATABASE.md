# Database Options

This platform supports three database configurations. Choose based on your needs:

## Option 1: MariaDB (Default - Simplest)

**Best for:** Getting started, development, small deployments

Each tenant gets their own MariaDB pod managed by the Nextcloud Helm chart.

### Configuration

```yaml
# In tenant values file
database:
  type: mariadb

mariadb:
  enabled: true
  auth:
    database: nextcloud
    username: nextcloud
    existingSecret: nextcloud-secrets
    secretKeys:
      password: db-password
  primary:
    persistence:
      enabled: true
      size: 8Gi
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

Each tenant gets their own PostgreSQL pod.

### Configuration

```yaml
# In tenant values file
database:
  type: postgres

mariadb:
  enabled: false

postgresql:
  enabled: true
  auth:
    database: nextcloud
    username: nextcloud
    existingSecret: nextcloud-secrets
    secretKeys:
      password: db-password
  primary:
    persistence:
      enabled: true
      size: 8Gi
```

### Pros
- ✅ PostgreSQL features (better JSON support, etc.)
- ✅ Each tenant fully isolated

### Cons
- ❌ Same resilience concerns as MariaDB
- ❌ One database pod per tenant

---

## Option 3: External PostgreSQL (Production)

**Best for:** Production, multi-tenant efficiency, managed databases

Shared external PostgreSQL cluster with PgBouncer connection pooling.
Databases are automatically provisioned per tenant.

### Configuration

```yaml
# In tenant values file
database:
  type: external

mariadb:
  enabled: false

postgresql:
  enabled: false

internalDatabase:
  enabled: false

externalDatabase:
  enabled: true
  type: postgresql
  host: pgbouncer.nextcloud-platform.svc.cluster.local
  port: 5432
  database: nextcloud_<tenant-name>
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
   kubectl exec -n nc-$TENANT deploy/nextcloud -- php occ maintenance:mode --on
   # Use mysqldump or Nextcloud's backup app
   ```

2. **Update tenant values** to use external PostgreSQL

3. **Sync with Argo CD** (creates new database)

4. **Import data** to PostgreSQL

5. **Disable maintenance mode**

### Using CloudNativePG Operator (Future)

For production, consider [CloudNativePG](https://cloudnative-pg.io/):

```yaml
# Future: operator-managed PostgreSQL
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
| Setup complexity | Easy | Easy | Medium |
| Resource efficiency | Low | Low | High |
| Connection pooling | No | No | Yes (PgBouncer) |
| Node upgrade resilience | Medium | Medium | High |
| Multi-tenant efficiency | Low | Low | High |
| Managed DB support | No | No | Yes |
| Recommended for | Dev/Test | Dev/Test | Production |

