Cut over a tenant from its temporary `.migrate` domain to its canonical hostname. The argument is the tenant name: $ARGUMENTS

## Context

When a tenant is onboarded via a migration hostname (`{org}.migrate.commonground.nu`), the initial
Nextcloud installation writes that domain into `config/config.php` (persistent volume) as the only
trusted domain and `overwrite.cli.url`.

When the `tenant.hostname` migrate override is later removed from the tenant values file, the
ApplicationSet derives the canonical hostname and updates the Helm-rendered probe and ingress. But
`config/config.php` in the persistent volume is NOT automatically updated — causing the startup
probe to return HTTP 400 (untrusted domain).

This skill patches the live pod to add the canonical hostname to `trusted_domains` and update
`overwrite.cli.url`, resolving the 400 and completing the cutover.

## Rules

- This is a **tenant config operation** — allowed at any time, including office hours and weekends.
- The tenant values file must already have the `hostname:` migrate line removed and pushed to Git.
- Argo CD must have already synced (or be in progress syncing) so the pod is rolling with the new probe config.

## Steps

### 1. Resolve tenant name

If `$ARGUMENTS` is empty, ask the user for the tenant name (e.g. `roosendaal-prod`).

Derive the canonical hostname using the same logic as the ApplicationSet:
- Strip `-(accept|test|prod)` suffix to get `{org}`
- `prod` suffix → `{org}.commonground.nu`
- `accept` or `test` suffix → `{org}.{suffix}.commonground.nu`

Confirm with the user: "Cutting over `{tenant}` to `{canonical-host}` — correct?"

### 2. Verify the tenant values file has no migrate hostname

```bash
grep "hostname:" nextcloud-platform/values/tenants/tenant-{tenant}.yaml
```

If the migrate hostname is still in the file, **stop** and tell the user to remove it, commit, and push first. Do not run the cutover script against a tenant that is still configured with the old hostname.

### 3. Run the cutover script

```bash
bash nextcloud-platform/scripts/cutover-tenant.sh {tenant-name}
```

Show the full output. The script will:
- Find the running pod
- Print current trusted_domains
- Add the canonical hostname at index 1
- Update overwrite.cli.url
- Print the final verified config

### 4. Verify pod health

```bash
kubectl get pods -n {tenant-name}
```

Wait for all containers to show `Running` and ready (e.g. `3/3`). If the startup probe was already
failing, the pod may be mid-restart — give it up to 2 minutes.

If still not healthy after 2 minutes:
```bash
kubectl describe pod -n {tenant-name} -l app.kubernetes.io/name=nextcloud | tail -30
```

### 5. Smoke test

```bash
curl -sI https://{canonical-host}/status.php
```

Expect HTTP 200. Report the result.

### 6. Summary

Report:
- Whether the cutover succeeded
- The canonical URL the tenant is now reachable on
- Any follow-up actions needed (e.g. DNS TTL propagation, informing the tenant owner)
