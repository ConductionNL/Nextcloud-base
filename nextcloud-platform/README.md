# Nextcloud Multi-Tenant GitOps Platform

A production-ready GitOps repository for running multiple Nextcloud instances on Kubernetes using Argo CD. Designed for resilience during node upgrades and zero NFS dependency.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              Kubernetes Cluster                              │
├─────────────────────────────────────────────────────────────────────────────┤
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │                         Platform Components                              ││
│  │  ┌─────────────┐  ┌─────────────┐  ┌──────────────────────────────────┐ ││
│  │  │   Redis     │  │  PgBouncer  │  │  External Secrets Operator       │ ││
│  │  │  (shared)   │  │  (shared)   │  │  (secrets from Vault/cloud)      │ ││
│  │  └─────────────┘  └─────────────┘  └──────────────────────────────────┘ ││
│  └─────────────────────────────────────────────────────────────────────────┘│
│                                                                              │
│  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐          │
│  │ ns: nc-canary    │  │ ns: nc-example   │  │ ns: nc-tenant-n  │   ...    │
│  │  ┌────────────┐  │  │  ┌────────────┐  │  │  ┌────────────┐  │          │
│  │  │ Nextcloud  │  │  │  │ Nextcloud  │  │  │  │ Nextcloud  │  │          │
│  │  │   Pod(s)   │  │  │  │   Pod(s)   │  │  │  │   Pod(s)   │  │          │
│  │  └─────┬──────┘  │  │  └─────┬──────┘  │  │  └─────┬──────┘  │          │
│  │        │         │  │        │         │  │        │         │          │
│  │        ▼         │  │        ▼         │  │        ▼         │          │
│  │   ┌─────────┐    │  │   ┌─────────┐    │  │   ┌─────────┐    │          │
│  │   │ Secrets │    │  │   │ Secrets │    │  │   │ Secrets │    │          │
│  │   │(ESO/Job)│    │  │   │(ESO/Job)│    │  │   │(ESO/Job)│    │          │
│  │   └─────────┘    │  │   └─────────┘    │  │   └─────────┘    │          │
│  └──────────────────┘  └──────────────────┘  └──────────────────┘          │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                           External Services                                  │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────────────────┐  │
│  │   Ceph RGW S3   │  │   PostgreSQL    │  │   CephFS (minimal RWX)      │  │
│  │  (user files)   │  │   (external)    │  │   (config/appdata only)     │  │
│  └─────────────────┘  └─────────────────┘  └─────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Why This Architecture? (Node Upgrade Resilience)

### The Problem

During Kubernetes node upgrades, our provider blocks access to the OpenStack API. This causes:
- CSI attach/mount operations to fail
- In-cluster NFS provisioner to become unavailable
- Widespread `CreateContainerConfigError` and volume mount errors
- Service outages lasting the duration of the upgrade

### The Solution

This architecture **eliminates critical dependencies on in-cluster NFS and fragile CSI flows**:

| Component | Traditional (Fragile) | This Architecture (Resilient) |
|-----------|----------------------|-------------------------------|
| User files | NFS/block storage | **S3 Primary Object Storage** (Ceph RGW) |
| Config | RWX NFS volume | **ConfigMaps + Secrets** (stateless) |
| custom_apps | RWX NFS volume | **Baked into image** (immutable) |
| appdata | RWX NFS volume | **Minimal CephFS** (provider-managed, not in-cluster) |
| Sessions | Local/NFS | **Redis** (in-memory, shared) |
| Locking | File-based | **Redis** (distributed) |

**Result**: During node upgrades, pods can be rescheduled without waiting for CSI operations. User data in S3 is always accessible.

## Repository Structure

```
nextcloud-platform/
├── README.md                          # This file
├── argo/
│   ├── applicationsets/
│   │   └── nextcloud-tenants.yaml     # ApplicationSet for all tenants
│   └── projects/
│       └── nextcloud-platform.yaml    # Argo CD project definition
├── platform/
│   ├── redis/                         # Shared Redis deployment
│   ├── pgbouncer/                     # Shared PgBouncer deployment
│   ├── externalsecrets/               # ESO ClusterSecretStore + templates
│   └── policies/                      # NetworkPolicies, PDBs
├── values/
│   ├── common.yaml                    # Shared values for all tenants
│   ├── env/
│   │   ├── accept.yaml                # Acceptance environment overrides
│   │   └── prod.yaml                  # Production environment overrides
│   └── tenants/
│       ├── tenant-canary.yaml         # Canary tenant (first to upgrade)
│       └── tenant-example.yaml        # Example production tenant
├── scripts/
│   ├── validate-values.sh             # YAML schema validation
│   └── smoke-checks.sh                # Local template + existence checks
└── .github/
    └── workflows/
        └── validate.yaml              # CI pipeline
```

## Quick Start

### Prerequisites

- Kubernetes 1.28+
- Argo CD installed
- cert-manager installed
- External Secrets Operator installed (or use fallback Job)
- Ceph RGW S3 endpoint available
- PostgreSQL endpoint available
- CephFS StorageClass available (for minimal appdata)

### Bootstrap

1. **Fork/clone this repository**

2. **Configure your secret backend** (choose one):

   **Option A: External Secrets Operator (recommended)**
   ```bash
   # Configure ClusterSecretStore in platform/externalsecrets/
   # Point to your Vault/AWS Secrets Manager/etc.
   ```

   **Option B: Fallback Job (generates secrets in-cluster)**
   ```bash
   # Secrets are generated by a Kubernetes Job
   # See "Secrets Management" section below
   ```

3. **Apply the Argo CD project and ApplicationSet**:
   ```bash
   kubectl apply -f argo/projects/nextcloud-platform.yaml
   kubectl apply -f argo/applicationsets/nextcloud-tenants.yaml
   ```

4. **Add your first tenant** (see "Adding a Tenant" below)

### Adding a Tenant

Create a single file in `values/tenants/`:

```yaml
# values/tenants/tenant-acme.yaml
tenant:
  name: acme
  environment: prod
  
  # Required: unique hostname
  hostname: acme.nextcloud.example.com
  
  # Required: S3 bucket name (must be pre-created)
  s3:
    bucket: nextcloud-acme-prod
  
  # Optional: custom domain (in addition to hostname)
  customDomain: cloud.acme.com
  
  # Optional: resource overrides
  resources:
    requests:
      memory: "1Gi"
      cpu: "500m"
    limits:
      memory: "4Gi"
      cpu: "2"
```

Commit and push. Argo CD will automatically create the Application.

## Secrets Management

### Option A: External Secrets Operator (Recommended)

Secrets are fetched from your secret backend (Vault, AWS Secrets Manager, etc.):

```yaml
# platform/externalsecrets/clustersecretstore.yaml
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: vault-backend
spec:
  provider:
    vault:
      server: "https://vault.example.com"
      # ... authentication config
```

For each tenant, an ExternalSecret is created that fetches:
- `admin-password`
- `s3-access-key`
- `s3-secret-key`
- `db-password`

### Option B: Fallback Secret Generator Job

If no external secret backend is available, a Kubernetes Job generates secrets:

```yaml
# The Job runs once per tenant namespace
# Generates cryptographically secure random secrets
# Stores them as Kubernetes Secrets
```

**DR Implications**:
- Secrets exist only in-cluster
- Must be backed up separately (Velero, etcd backup, etc.)
- Document secret export procedure:
  ```bash
  # Export secrets for DR (run periodically, store securely)
  kubectl get secret -n nc-$TENANT nextcloud-secrets -o yaml > secrets-$TENANT.yaml
  # Encrypt and store in secure location (NOT in Git!)
  ```

### Required Secrets per Tenant

| Secret Key | Description | Source |
|------------|-------------|--------|
| `admin-password` | Nextcloud admin password | ESO/Generated |
| `s3-access-key` | Ceph RGW access key | ESO/Pre-provisioned |
| `s3-secret-key` | Ceph RGW secret key | ESO/Pre-provisioned |
| `db-password` | PostgreSQL password | ESO/Pre-provisioned |

## Upgrade Strategy

### Version Upgrade Process

1. **Update chart version in `values/common.yaml`**:
   ```yaml
   chart:
     version: "5.2.0"  # New version
   ```

2. **Canary rollout**:
   - The `tenant-canary` is configured with `wave: 0`
   - Argo CD syncs canary first
   - Wait for health checks to pass

3. **Validation checks on canary**:
   ```bash
   # Connect to canary pod
   kubectl exec -it -n nc-canary deploy/nextcloud -- bash
   
   # Run health checks
   php occ status
   php occ maintenance:repair --dry-run
   php occ db:add-missing-indices --dry-run
   
   # WebDAV test (from outside cluster)
   curl -u admin:$PASSWORD -X PUT \
     -T testfile.txt \
     https://canary.nextcloud.example.com/remote.php/dav/files/admin/testfile.txt
   
   curl -u admin:$PASSWORD \
     https://canary.nextcloud.example.com/remote.php/dav/files/admin/testfile.txt
   ```

4. **Wave rollout**:
   - Tenants are assigned waves (0-3)
   - After canary (wave 0) is healthy, wave 1 syncs
   - Continue through all waves

5. **Monitor during rollout**:
   - Watch Prometheus metrics
   - Check for S3 errors, DB connection issues
   - Verify cron jobs completing

### Rollback Procedures

**Argo CD Rollback (quick)**:
```bash
# Get previous revision
argocd app history nc-<tenant>

# Rollback to previous revision
argocd app rollback nc-<tenant> <revision>
```

**Chart Version Rollback**:
```bash
# Revert values/common.yaml to previous version
git revert HEAD
git push

# Or manually edit and push
```

**Emergency Rollback (all tenants)**:
```bash
# Suspend ApplicationSet
kubectl patch applicationset nextcloud-tenants \
  -n argocd \
  --type=merge \
  -p '{"spec":{"syncPolicy":{"automated":null}}}'

# Rollback individual apps
for tenant in canary example; do
  argocd app rollback nc-$tenant 1
done
```

## Observability

### Prometheus Annotations

All deployments include Prometheus scrape annotations:
```yaml
annotations:
  prometheus.io/scrape: "true"
  prometheus.io/port: "9090"
  prometheus.io/path: "/metrics"
```

### ServiceMonitors

ServiceMonitors are created for:
- Nextcloud (PHP-FPM metrics)
- Redis
- PgBouncer

### Recommended Alerts

Configure these alerts in your Prometheus/Alertmanager:

```yaml
groups:
  - name: nextcloud
    rules:
      # S3 Errors
      - alert: NextcloudS3Errors
        expr: increase(nextcloud_s3_errors_total[5m]) > 0
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Nextcloud S3 errors detected"
          
      # DB Connection Pool Saturation
      - alert: PgBouncerPoolSaturation
        expr: pgbouncer_pools_server_active_connections / pgbouncer_pools_server_max_connections > 0.8
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "PgBouncer connection pool > 80% utilized"
          
      # Redis Failures
      - alert: RedisDown
        expr: redis_up == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "Redis is down"
          
      # Cron Failures
      - alert: NextcloudCronFailed
        expr: nextcloud_cron_last_success_timestamp < time() - 900
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Nextcloud cron hasn't run in 15 minutes"
          
      # High Memory Usage
      - alert: NextcloudHighMemory
        expr: container_memory_usage_bytes{container="nextcloud"} / container_spec_memory_limit_bytes > 0.9
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Nextcloud container memory > 90%"
```

## Environment Configuration

### Accept Environment
- Lower resource limits
- Single replica
- Debug logging enabled
- Shorter retention periods

### Production Environment
- Full resource allocation
- Multiple replicas (HPA)
- Standard logging
- Full retention periods

## Tenant-Specific Settings

Each tenant YAML supports these overrides:

| Setting | Description | Default |
|---------|-------------|---------|
| `tenant.name` | Unique tenant identifier | Required |
| `tenant.environment` | `accept` or `prod` | Required |
| `tenant.hostname` | Primary hostname | Required |
| `tenant.s3.bucket` | S3 bucket name | Required |
| `tenant.customDomain` | Additional domain | None |
| `tenant.resources.*` | Resource requests/limits | From env |
| `tenant.wave` | Upgrade wave (0-3) | 1 |
| `tenant.replicas` | Pod replica count | From env |

## CI/CD Quality Gates

### On Every PR/Push

1. **YAML Lint** (`yamllint`)
2. **Kubernetes Schema Validation** (`kubeconform`)
3. **Helm Checks**:
   - `helm lint`
   - `helm template` for all tenants
4. **Policy Checks** (`kube-score`, `conftest`)
5. **Secret Scanning** (`gitleaks`)
6. **Values Validation** (`scripts/validate-values.sh`)

### Local Validation

```bash
# Run all checks locally
./scripts/validate-values.sh
./scripts/smoke-checks.sh
```

## FAQ

### Q: What if I need custom Nextcloud apps?

A: Build a custom image with apps pre-installed:
```dockerfile
FROM nextcloud:stable
RUN mkdir -p /usr/src/nextcloud/custom_apps
COPY my-app /usr/src/nextcloud/custom_apps/
```

Reference in tenant values:
```yaml
tenant:
  image:
    repository: my-registry/nextcloud-custom
    tag: "1.0.0"
```

### Q: How do I handle large file uploads?

A: The configuration includes:
- PHP memory limit: 2048M
- Nginx timeouts: 1800s
- These are configurable per-tenant if needed

### Q: Can I use a different S3 provider?

A: Yes, update the S3 endpoint in environment values:
```yaml
s3:
  endpoint: "https://s3.my-provider.com"
  region: "us-east-1"
  pathStyle: true
  sslVerify: true
```

### Q: What about email/SMTP?

A: Configure in tenant values:
```yaml
tenant:
  mail:
    enabled: true
    fromAddress: noreply
    domain: example.com
    smtp:
      host: smtp.example.com
      port: 587
      secure: tls
```

## License

MIT License - See LICENSE file for details.

## Contributing

1. Fork the repository
2. Create a feature branch
3. Run `./scripts/validate-values.sh` and `./scripts/smoke-checks.sh`
4. Submit a PR

All PRs must pass CI checks before merging.

