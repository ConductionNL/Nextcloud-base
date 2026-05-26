Guide the user through adding a new tenant to the Nextcloud platform. The argument is the tenant name: $ARGUMENTS

## Rules

Adding a tenant config file is **allowed at any time, including office hours and weekends**.

No NetworkPolicy changes are required when adding a tenant — the ApplicationSet automatically labels every tenant namespace with `app.kubernetes.io/part-of: nextcloud-platform`, and the Redis/PgBouncer NetworkPolicies already allow all namespaces with that label.

Check the current UTC time with `date -u` before starting so the user is aware of the context.

## Checklist

Work through these steps in order.

### 1. Determine tenant details
If not fully provided in `$ARGUMENTS`, ask the user for:
- **Tenant name** — convention: `{organisation}-{environment}` (e.g., `alkmaar-accept`, `alkmaar-prod`). Valid env suffixes: `accept`, `test`, `demo`, `prod`. `test` and `demo` both run on accept env values; the suffix is intent only.
- **Environment** — `accept` or `prod` (use `accept` for `-accept`, `-test`, and `-demo` tenants)
- **Database type** — `mariadb`, `postgres`, or `external` (external uses shared PgBouncer)
- **Wave** — 0 for canary, 1+ for standard tenants
- **Hostname** — three cases:
  - **Default (canonical):** leave blank — derives `{org}.commonground.nu` (prod) or `{org}.{env}.commonground.nu` (accept/test). Don't set `hostname:`.
  - **Migration of existing env:** set `hostname: {org}.migrate.commonground.nu`. Validator emits a warning; cut over later with `/cutover-tenant`.
  - **External domain or non-canonical subdomain** (e.g. `test.conduction.nl`, `softwarecatalogus.performance.tilburg-test.commonground.nu`): set `hostname: <full-fqdn>` AND `hostnameOverride: true`. The flag tells the validator the deviation is deliberate.
- **Apps to install** — default: opencatalogi, openconnector, openregister. Only these three support version-pinning via `tenant.apps.versions.{app}`. Other apps (e.g. `softwarecatalogus`) install via app-store fallback without pin support.
- **S3_ACCESS_KEY** / **S3_SECRET_KEY** — read from `scripts/.env` (gitignored). Check that file first before asking the user.

### 2. Create the tenant values file
Scripts and values are relative to the working directory (`nextcloud-platform/`).

- Destination: `values/tenants/tenant-{name}.yaml`

**Write only the minimal `tenant:` block.** Everything else (mariadb config, hooks, ingress, resources, podLabels, etc.) is already defined in `common.yaml` and the env/db values files — do NOT copy those sections into the tenant file.

The standard minimal file looks like this:
```yaml
---
tenant:
  name: {tenant-name}
  environment: prod          # or accept
  wave: "1"                  # "0" for canary
  dbType: mariadb            # mariadb|postgres|external
  apps:
    enabled:
      - opencatalogi
      - openconnector
      - openregister
```

Only if the user explicitly requested a migration hostname, add it inside the `tenant:` block:
```yaml
  hostname: {org}.migrate.commonground.nu  # temp: remove after migration to {org}.commonground.nu
```

For an **external domain or non-canonical subdomain**, add both lines inside the `tenant:` block:
```yaml
  hostname: <full-fqdn>          # e.g. test.conduction.nl
  hostnameOverride: true         # validator opt-in: bypass commonground.nu convention
```

To **pin Conduction app versions**, add `versions:` under `apps:`:
```yaml
  apps:
    enabled:
      - opencatalogi
      - openregister
    versions:
      opencatalogi: "0.7.9-beta.6"
      openregister: "0.2.12-unstable.7"
```
Only `opencatalogi`, `openconnector`, `openregister` support pinning (wired in `argo/applicationsets/nextcloud-tenants.yaml`). Pinning other apps requires extending the ApplicationSet + install hooks first (platform change, sync-window-bound).

The Kubernetes namespace equals the tenant name exactly (e.g., `zuiddrecht-prod`), auto-created and auto-labeled by Argo CD.

### 3. Generate the Kubernetes secret
S3 credentials are in `scripts/.env` (gitignored). Source the file, then run:

```bash
set -a && source scripts/.env && set +a
./scripts/create-tenant-secret.sh {tenant-name} \
  --{dbType} \
  --namespace {tenant-name} \
  --generate-passwords
```

Run this command and show the full output to the user. The script will print all generated credentials — remind the user to **save them securely now**, as they cannot be retrieved from the cluster later.

If the script fails because `kubectl` is not configured or the cluster is unreachable, explain the error and show the user the exact command to run manually once they have cluster access.

### 4. Validate
Run validation on the **specific new file(s)** — the script exits on the first errored file, so a global run may not reach a freshly-added tenant:
```bash
bash scripts/validate-values.sh values/tenants/tenant-{name}.yaml
```
A migration hostname or `hostnameOverride: true` produces a **warning** (not an error) — this is expected and safe to proceed. Fix any **errors** before proceeding. (The shared `conftest` Rego guardrails step at the end may fail due to a Rego v0/v1 syntax issue — pre-existing, unrelated to your tenant change.)

### 5. Commit
Stage only the new tenant file:
- `values/tenants/tenant-{name}.yaml`

Suggest a commit message: `add tenant: {name}`

Remind the user: Argo CD will automatically detect the new tenant file and create the Application. No manual Argo CD steps are required unless they want to trigger an immediate sync (use `/sync-tenant {name}` with `--refresh-appset` since it is a new app).

### 6. Summary
Provide a summary of:
- What was created
- Whether the secret was successfully applied to the cluster, or still needs to be done manually
- The expected Argo CD behaviour after pushing
- If using a migration hostname: remind the user that after sign-off, run `/cutover-tenant {name}` to switch to the canonical domain.
