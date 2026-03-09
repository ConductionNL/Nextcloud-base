# Making Nextcloud Configuration Changes

## The Rule

**Never use `occ config:system:set` or edit `config.php` directly to make persistent changes.**

On tenants running the stateless model (emptyDir), `config.php` is regenerated on every pod
restart — manual changes are silently lost. On PVC-backed tenants, manual changes survive
restarts but are invisible to GitOps and will eventually drift or be overwritten.

All configuration changes go through Helm values → git → Argo CD.

---

## How to Add a Config Value

### Non-sensitive config (safe for git)

Add to the appropriate values file under `nextcloud.configs`:

```yaml
nextcloud:
  configs:
    custom.config.php: |
      <?php
      $CONFIG = array (
        'default_phone_region' => 'NL',
        'maintenance_window_start' => 1,
        'overwrite.cli.url' => 'https://example.commonground.nu',
      );
```

**Which file to edit:**

| Scope | File |
|-------|------|
| All tenants | `values/common.yaml` |
| All prod tenants | `values/env/prod.yaml` |
| All accept tenants | `values/env/accept.yaml` |
| Single tenant | `values/tenants/tenant-{name}.yaml` |
| Canary experiment | `values/canary-overrides.yaml` |

Multiple `.config.php` files are fine — Nextcloud merges everything in `config/` alphabetically.
Name them descriptively: `redis.config.php`, `s3.config.php`, `tenant.config.php`.

### Sensitive config (secrets, API keys)

Never put secrets in a config.php block in git. Two options:

**Option A — env var + getenv() in config:**
```yaml
# In values file (safe for git):
nextcloud:
  extraEnv:
    - name: SOME_API_KEY
      valueFrom:
        secretKeyRef:
          name: nextcloud-secrets
          key: some-api-key
  configs:
    integrations.config.php: |
      <?php
      $CONFIG = array (
        'some_integration_key' => getenv('SOME_API_KEY'),
      );
```

**Option B — Nextcloud native env vars (preferred where supported):**

Nextcloud reads several settings directly from env vars without needing a config block:
`SMTP_HOST`, `SMTP_PASSWORD`, `REDIS_HOST`, `REDIS_HOST_PASSWORD`, `OBJECTSTORE_S3_*`, etc.
Check the [Nextcloud env var docs](https://docs.nextcloud.com/server/latest/admin_manual/configuration_server/automatic_configuration.html)
before writing a config block — the env var approach is cleaner.

Add the secret key via `create-tenant-secret.sh` or directly to the `nextcloud-secrets`
Secret in the tenant namespace, then reference it with `secretKeyRef`.

---

## Workflow Summary

```
1. Identify config key needed
       ↓
2. Edit the appropriate values file
       ↓
3. git commit + push
       ↓
4. Argo CD detects change → rolling update
       ↓
5. Verify: kubectl exec ... -- php occ config:system:get <key>
```

## Diagnosing Current Config

`occ config:system:get` is fine for reading — it's writes that don't persist:

```bash
# Check a specific key
kubectl exec -n <namespace> deploy/nextcloud -c nextcloud -- \
  su -s /bin/sh www-data -c "php occ config:system:get trusted_domains"

# Dump full config (minus secrets)
kubectl exec -n <namespace> deploy/nextcloud -c nextcloud -- \
  su -s /bin/sh www-data -c "php occ config:list system"
```

## Current Status by Tenant Model

| Model | Tenants | config.php behaviour |
|-------|---------|---------------------|
| **Stateless (emptyDir)** | canary-prod | Regenerated on every pod start — values file is the only source of truth |
| **PVC-backed** | all others (today) | Persists across restarts — but GitOps is still the correct path |

All tenants will move to the stateless model as Phase 2 of `stateless-nextcloud-ha` rolls out.
