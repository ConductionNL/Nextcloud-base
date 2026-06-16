Add MULTIPLE tenants to the Nextcloud platform in one flow, including secrets. The argument is a list of tenant names (and optional shared settings): $ARGUMENTS

Use this instead of calling `/add-tenant` by hand N times or hand-rolling a bash loop. This IS the sanctioned batch path — it loops the same sanctioned scripts (`create-tenant-secret.sh`, `argocd-sync.sh`, `validate-values.sh`) internally.

## Rules

Adding tenant config files is **allowed at any time, including office hours and weekends** — these are TENANT changes (everything stays under `values/tenants/`), not platform changes.

No NetworkPolicy changes are needed — the ApplicationSet labels every tenant namespace `app.kubernetes.io/part-of: nextcloud-platform` and the Redis/PgBouncer policies already allow it.

## 1. Resolve the batch

From `$ARGUMENTS`, extract the list of tenant names. If shared settings are not given, apply these defaults and state them to the user (do not interrogate per-tenant):
- **environment** — derive from each name's suffix (`-accept`/`-test`/`-demo` → `accept`, `-prod` → `prod`). If a bare org name is given, ask once whether the whole batch is `accept` or `prod`.
- **dbType** — `postgres` (current standard) unless the user said otherwise for the batch.
- **wave** — `1`.
- **apps** — default three: opencatalogi, openconnector, openregister.
- **hostname** — canonical (leave blank). Only set per-tenant overrides if the user explicitly asked.

Echo the resolved list back as a short table (name · env · dbType) before creating, so the user can catch a typo. Skip any tenant whose file already exists and report it as "already present".

## 2. Create the tenant files

For each new tenant, write `values/tenants/tenant-{name}.yaml` with only the minimal `tenant:` block:
```yaml
---
tenant:
  name: {name}
  environment: accept        # or prod
  wave: "1"
  dbType: postgres
  apps:
    enabled:
      - opencatalogi
      - openconnector
      - openregister
```
Do NOT copy common/env/db sections into the file — they are inherited.

## 3. Generate secrets (always)

Secrets are mandatory for every new tenant. Source S3 creds once, then run the sanctioned generator per tenant. Capture output to a temp file and surface ONLY non-sensitive status — never print credential values:
```bash
set -a && source nextcloud-platform/scripts/.env && set +a
for t in {name1} {name2} ...; do
  bash nextcloud-platform/scripts/create-tenant-secret.sh "$t" --{dbType} --namespace "$t" --generate-passwords > /tmp/bsec.log 2>&1
  echo "$t exit=$?"; grep -iE 'created successfully|error|fail' /tmp/bsec.log | grep -viE 'password|salt|key'
done; rm -f /tmp/bsec.log
```
If the secret already exists for a tenant, skip it (do not overwrite — that rotates the DB password and breaks an initialised database). If `kubectl`/cluster is unreachable, report it and give the exact command to run later.

## 4. Validate

Validate the new files explicitly (the validator exits on the first errored file, so a global run may not reach fresh tenants):
```bash
bash nextcloud-platform/scripts/validate-values.sh values/tenants/tenant-{name1}.yaml values/tenants/tenant-{name2}.yaml ...
```
Known-and-ignorable: the shared `conftest` Rego step fails on a pre-existing v0/v1 syntax issue, and any `*vng*` file fails by design. Fix any real per-file errors before committing.

## 5. Commit

Stage only the new tenant files. Suggest one commit for the batch:
`add tenants: N accept environments ({dbType})` with the names in the body.

We are usually on `main` (protected). Per the user's workflow, tenant additions go directly on `main` and the **user pushes themselves** — do not push unless asked. Push target is `codeberg` (what Argo CD watches), not `origin` (legacy GitHub).

## 6. Sync (offer)

These are brand-new Applications, so offer to deploy with `/sync-tenant {names} --refresh-appset` once the user has pushed — the ApplicationSet must regenerate before the apps exist. Do not sync before the commit is pushed to `codeberg`.

## 7. Summary

Report a compact table: per tenant → file created, secret created/skipped, validation. Then state the commit, that the user pushes to `codeberg`, and the sync offer. Remind: generated credentials are not retrievable later.
