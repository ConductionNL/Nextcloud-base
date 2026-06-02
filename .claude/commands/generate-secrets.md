Generate (or repair) the per-tenant Kubernetes secret `nextcloud-secrets` for a Nextcloud tenant. The argument is the tenant name: $ARGUMENTS

## What this does

Creates the `nextcloud-secrets` Secret in the tenant namespace using the
sanctioned generator `scripts/create-tenant-secret.sh`. This is the **uniform
way** to provision tenant credentials — do not hand-craft secrets or run raw
`kubectl create secret`.

Use it when:
- A tenant exists but its `nextcloud-secrets` is missing (pods stuck in
  `Init:CreateContainerConfigError` / `CreateContainerConfigError`, or events
  show `secret "nextcloud-secrets" not found`).
- You are provisioning a brand-new tenant outside the `/add-tenant` flow.

## Rules / governance

- Secrets are **out-of-band by design** — they are generated in-cluster and are
  **never committed to Git** (`.gitignore` excludes `*.secret.yaml`, `secrets/`,
  `env.local`). Creating a secret is therefore **not** a GitOps change and is
  allowed at any time, including office hours.
- This cluster does **not** run the External Secrets Operator — the fallback
  in-cluster generator (this script) is the supported path. See `docs/SECRETS.md`.
- **Never print secret values.** Show only status lines (`secret/... created`)
  and key *names*, never the data.

## Steps

### 1. Resolve tenant details
From `$ARGUMENTS` (the tenant name). The Kubernetes namespace equals the tenant
name exactly (e.g. `conduction-demo` → namespace `conduction-demo`).

Read the database type from the tenant values file — do not guess:
```bash
grep -E '^\s*dbType:' nextcloud-platform/values/tenants/tenant-{name}.yaml
```
`dbType` is one of `mariadb`, `postgres`, or `external`. If the file or field is
missing, ask the user. (`postgres` also provisions a Redis password.)

### 2. Safety check — does the secret already exist?
```bash
kubectl get secret nextcloud-secrets -n {name} -o name 2>/dev/null
```
- **Not found** → safe to create. Continue.
- **Already exists** → **STOP and confirm with the user before overwriting.**
  Regenerating rotates `db-password`, `admin/nextcloud-password`, S3 keys, etc.
  Overwriting the DB password while the database is already initialised with the
  old one will break the tenant until the DB user password is also rotated. Only
  proceed on explicit user confirmation; otherwise stop.

### 3. Provide S3 credentials
S3 access/secret keys are read from `scripts/.env` (gitignored). Source it before
running the script so the generated secret carries working S3 credentials:
```bash
set -a && source nextcloud-platform/scripts/.env && set +a
```
If `scripts/.env` is absent, ask the user for `S3_ACCESS_KEY` / `S3_SECRET_KEY`
(or confirm `--generate-passwords` random S3 keys are acceptable for this tenant).

### 4. Generate the secret
Run via `bash` (the script is not guaranteed to be executable — a direct
`./script` can exit 126):
```bash
bash nextcloud-platform/scripts/create-tenant-secret.sh {name} \
  --{dbType} \
  --namespace {name} \
  --generate-passwords
```
Capture output to a temp file and surface only **non-sensitive status** to the
user (e.g. `secret/nextcloud-secrets created`, `Secret created successfully!`).
Filter out any line containing credential values, then delete the temp file:
```bash
bash nextcloud-platform/scripts/create-tenant-secret.sh {name} --{dbType} --namespace {name} --generate-passwords > /tmp/tenant-secret-out.log 2>&1
echo "exit=$?"
grep -iE 'created|configured|error|fail|missing' /tmp/tenant-secret-out.log \
  | grep -viE '=[A-Za-z0-9+/]{12,}|password|salt|access-key|secret-key'
rm -f /tmp/tenant-secret-out.log
```

If `kubectl` is not configured or the cluster is unreachable, show the user the
exact command to run themselves once they have cluster access.

### 5. Verify
Confirm the expected keys exist (names only, never values):
```bash
kubectl get secret nextcloud-secrets -n {name} \
  -o go-template='{{range $k,$v := .data}}{{$k}}{{"\n"}}{{end}}'
```
Expect: `db-password`, `db-username`, `nextcloud-password`, `nextcloud-secret`,
`nextcloud-username`, `s3-access-key`, `s3-secret-key`; plus `postgres-password`
and `redis-password` for `postgres`. A **stateless** tenant (canary /
`persistence.enabled: false`) additionally needs identity keys
(`nextcloud-instanceid`, `nextcloud-passwordsalt`) so the instance survives pod
restarts — confirm these are present for such tenants.

Then check the pods recover:
```bash
kubectl get pods -n {name}
```
`CreateContainerConfigError` / `FailedMount: secret ... not found` clears within
a minute once the secret exists.

### 6. Summary
Report: namespace, dbType, whether the secret was created or skipped (existing),
which keys are present, and current pod status. Remind the user that generated
credentials are not retrievable later — if this was a fresh tenant, capture the
admin password now from a secure source.
