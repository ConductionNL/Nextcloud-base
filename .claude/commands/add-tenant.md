Guide the user through adding a new tenant to the Nextcloud platform. The argument is the tenant name: $ARGUMENTS

## Rules

Adding a tenant config file is **allowed at any time, including office hours and weekends**.

No NetworkPolicy changes are required when adding a tenant — the ApplicationSet automatically labels every tenant namespace with `app.kubernetes.io/part-of: nextcloud-platform`, and the Redis/PgBouncer NetworkPolicies already allow all namespaces with that label.

Check the current UTC time with `date -u` before starting so the user is aware of the context.

## Checklist

Work through these steps in order.

### 1. Determine tenant details
If not fully provided in `$ARGUMENTS`, ask the user for:
- **Tenant name** — convention: `{organisation}-{environment}` (e.g., `alkmaar-accept`, `alkmaar-prod`)
- **Environment** — `accept` or `prod` (use `accept` for both `-accept` and `-test` tenants)
- **Database type** — `mariadb`, `postgres`, or `external` (external uses shared PgBouncer)
- **Wave** — 0 for canary, 1+ for standard tenants
- **Hostname** — two options:
  - **Migration tenant (recommended for new prod onboarding)**: use `{org}.migrate.commonground.nu` — temporary domain to validate before cutover. Validation warns, does not error. After sign-off, remove the hostname override to fall back to the derived default.
  - **Direct**: leave blank to use the derived default (`{org}.commonground.nu` for prod, `{org}.{env}.commonground.nu` for accept/test)
- **Apps to install** — default: opencatalogi, openconnector, openregister
- **S3_ACCESS_KEY** / **S3_SECRET_KEY** — read from `scripts/.env` (gitignored). Check that file first before asking the user.

### 2. Create the tenant values file
Scripts and values are relative to the working directory (`nextcloud-platform/`).

- Source template: `values/templates/tenant-template.yaml` (for mariadb) or `values/templates/tenant-template-postgres.yaml` (for postgres/external)
- Destination: `values/tenants/tenant-{name}.yaml`

Read the template, then create the new tenant file with all `{{TENANT_NAME}}` and `{{HOSTNAME}}` placeholders replaced with actual values. Set environment, wave, dbType, and apps correctly. Remove comments that are not relevant to this tenant's configuration.

If using a migration hostname, add it explicitly with a cutover comment:
```yaml
hostname: {org}.migrate.commonground.nu  # temp: remove after migration to {org}.commonground.nu
```

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
Run validation to catch issues early:
```bash
./scripts/validate-values.sh
```
A migration hostname produces a **warning** (not an error) — this is expected and safe to proceed. Fix any **errors** before proceeding.

### 5. Commit
Stage only the new tenant file:
- `values/tenants/tenant-{name}.yaml`

Suggest a commit message: `add tenant: {name}` (or `add tenant: {name} (migrate domain)` if using a temporary hostname)

Remind the user: Argo CD will automatically detect the new tenant file and create the Application. No manual Argo CD steps are required unless they want to trigger an immediate sync (use `/sync-tenant {name}` with `--refresh-appset` since it is a new app).

### 6. Summary
Provide a summary of:
- What was created
- Whether the secret was successfully applied to the cluster, or still needs to be done manually
- The expected Argo CD behaviour after pushing
- If using a migration hostname: remind the user that after sign-off, the cutover is to remove the `hostname:` line from the tenant file and push — Argo CD will update the Ingress automatically.
