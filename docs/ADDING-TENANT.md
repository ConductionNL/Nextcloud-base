---
last_reviewed: 2026-08-26
owner: info@conduction.nl
---

# Adding a New Tenant

This guide describes the steps required to add a new Nextcloud tenant to the platform.

> **Shortcut:** for a standard tenant, do not follow this guide by hand — use
> `platform.commonground.nu`. It opens the PR with the right defaults and the
> required label. This guide describes the manual route and what the portal does
> for you; see [Step 4](#4-open-a-pr--do-not-push-to-main).

## Prerequisites

- Access to the Git repository
- kubectl access to the cluster
- Knowledge of the tenant's hostname and environment (prod/accept)
- Permission to label PRs in this repository, if you are not going through the portal

## Choose Your Database

**PostgreSQL, unless a documented requirement forces otherwise.** MariaDB is
legacy and being phased out (decision of 2026-08-04) — see `docs/DATABASE.md`.

| Template | Database | Redis | When |
|----------|----------|-------|------|
| `tenant-template-postgres.yaml` | PostgreSQL | Per-tenant | **Default for every new tenant** |
| `tenant-template.yaml` | MariaDB | Platform (shared) | Legacy only — migrating an existing MariaDB dataset |

> **"The same as tenant X runs" is not a reason.** Copying the engine from a
> neighbouring tenant propagates a phase-out. Nor is a PHP-extension need such as
> soap: that is an `image:` concern and independent of `dbType`. The one sound
> reason to pick MariaDB is an existing MariaDB dataset that has to be imported
> as-is.
>
> Also keep the pair consistent: if `<org>-accept` is PostgreSQL, then
> `<org>-prod` on MariaDB means accept no longer tests prod.

## Steps

### 1. Create Tenant Values File

**Default: PostgreSQL (per-tenant Redis)**

```bash
cp nextcloud-platform/values/templates/tenant-template-postgres.yaml \
   nextcloud-platform/values/tenants/tenant-<name>.yaml
```

**Legacy: MariaDB (shared platform Redis)** — only for the migration case above

```bash
cp nextcloud-platform/values/templates/tenant-template.yaml \
   nextcloud-platform/values/tenants/tenant-<name>.yaml
```

Modern tenant files are **thin**: you only set `tenant.name`, `tenant.environment`,
`tenant.dbType` and the enabled `apps`. The ApplicationSet **derives** the hostname,
the enabled-app defaults and the S3 prefix from `tenant.name` + `tenant.environment` —
you do **not** hand-fill these. See `docs/ARCHITECTURE.md` for the big picture, and
`values/tenants/tenant-straatje-accept.yaml` for a real thin tenant file.

Edit the file and set:
- `tenant.name` → `<organisatie>-<omgeving>` (e.g., `myorg-accept`, `myorg-prod`)
- `tenant.environment` → `accept` or `prod`
- `tenant.dbType` → `postgres` (default voor nieuwe tenants), `mariadb` (legacy)
  of `external`. Verplicht veld: laat je het weg, dan faalt `validate-values.sh`.
  Kies `mariadb` alleen bewust — zie `docs/DATABASE.md`.
- `tenant.apps.enabled` → the apps to install
- `tenant.apps.versions` → optional per-app version pins (see below)

Hostname is derived (`<org>.<env>.commonground.nu` for accept/test, `<org>.commonground.nu`
for prod). Set `tenant.hostname` only if you need to override it. PostgreSQL database
naming is handled by the chart/template defaults — there is no `{{DATABASE_NAME}}` to fill
in modern tenant files.

#### Pinning app versions

`tenant.apps.versions` is optional. Leave a key out and the tenant tracks the
latest release of that app; set it and the version is pinned in Git.

```yaml
tenant:
  apps:
    enabled:
      - opencatalogi
      - openconnector
      - openregister
    # Optional pins. Quote the value; no leading 'v'.
    versions:
      opencatalogi: "0.7.12"
      openconnector: "0.2.16"
      openregister: "0.2.11"
```

**Only three keys are wired.** `opencatalogi`, `openconnector` and `openregister`
are mapped by `argo/applicationsets/nextcloud-tenants.yaml` to the env vars
`OPENCATALOGI_VERSION`, `OPENCONNECTOR_VERSION` and `OPENREGISTER_VERSION`. The
validator has no allowlist of app names, so **any other key passes validation and
is then silently ignored** — a pin that never takes effect. Adding a fourth
pinnable app means adding it to the ApplicationSet too.

**Accepted format**, enforced by `validate_app_versions_format()` in
`scripts/validate-values.sh`:

```
^[0-9]+[.][0-9]+[.][0-9]+([-.][0-9A-Za-z][0-9A-Za-z.-]*)?$
```

| Rule | Detail |
|---|---|
| Core | three numeric parts, `MAJOR.MINOR.PATCH` — `0.7` is rejected |
| Leading `v` | rejected, with its own error message |
| Suffix | optional; separated by `-` or `.`, must start alphanumeric, then alphanumerics, dots and hyphens |
| Empty / absent | no pin — the ApplicationSet passes `""` and the app tracks latest |

Valid: `"0.7.12"`, `"0.2.16"`, `"0.2.8-beta.7"`, `"0.2.10-unstable.4"`,
`"0.2.12-beta.20260410072957"`.
Rejected: `"v0.7.12"`, `"0.7"`, `"0.7.x"`, `"latest"`.

> Not to be confused with `tenant.chartVersion`, which pins the **Helm chart**
> and is stricter: exactly `X.Y.Z`, no suffix (`"8.9.0"` yes, `"8.9.0-rc1"` no).
> See `docs/UPGRADE.md`.

#### Overriding the Nextcloud image

The platform image is set once in `values/common.yaml` (`nextcloud:32.0.13-fpm`).
A tenant that needs a different build — a PHP extension the official image does
not ship, for instance — overrides it with a **top-level** `image:` block in its
own tenant file:

```yaml
tenant:
  name: myorg-accept
  # ...

# Top-level, NOT under `tenant:` — this is a chart value, not a hub field.
image:
  registry: ghcr.io
  repository: conductionnl/nextcloud-images
  tag: "32.0.6-fpm-soap"
```

This works because the tenant file is the **last** entry in the ApplicationSet's
`valueFiles` list (`argo/applicationsets/nextcloud-tenants.yaml`), so it wins over
`common.yaml`. `registry` is absent from `common.yaml` and is added by the deep
merge; `repository` and `tag` are replaced.

Live example: `values/tenants/tenant-rijswijk-accept.yaml`, which runs the
soap-enabled build from `ConductionNL/nextcloud-images`.

**Three rules, each learned the hard way:**

| Rule | Why |
|---|---|
| Always a patch-version tag, never a floating one (`fpm-soap`, `latest`) | With `pullPolicy: IfNotPresent` the running version depends on when a node last pulled. On 2026-08-19 `fpm-soap` moved from `sha256:31123c8c` to `sha256:80310a36` with no change in Git. |
| Never add a `digest:` field | Chart 8.9.0 does not render it. The podspec ends up with the tag only, so Git claims something the cluster is not doing. |
| **Never point an existing tenant at a lower version** | See below. |

> ### ⚠️ The override must not downgrade a running tenant
>
> `/var/www/html` is a PVC, so the installed version survives a pod restart. The
> upstream Nextcloud entrypoint compares that version against the image and exits 1
> when the image is older — "downgrading is not supported". The pod goes into
> CrashLoopBackOff, and with `selfHeal: true` Argo keeps retrying. Recovery is
> reverting the tenant file, not `kubectl`.
>
> So a tenant on `32.0.13-fpm` **cannot** be moved to `32.0.6-fpm-soap`. Build the
> variant at the version the tenant already runs (or higher) first — in
> `ConductionNL/nextcloud-images` the workflow derives the version number from the
> `FROM` line in `soap-client/Dockerfile`.
>
> The namespaces already on `32.0.6-fpm-soap` (`beek`, `bct`, `sluis`) are **not**
> a precedent: they are legacy standalone Applications on chart 6.4.1 straight from
> `nextcloud.github.io/helm`, not tenants of the `nextcloud-tenants` ApplicationSet.
> They never upgraded past 32.0.6; they did not downgrade to it.

`validate-values.sh` has no top-level key allowlist, so an `image:` block passes
validation as-is — the rules above are not machine-checked.

Validate before pushing:

```bash
./nextcloud-platform/scripts/validate-values.sh \
  nextcloud-platform/values/tenants/tenant-<name>.yaml
```

### 2. NetworkPolicies — no action needed

> **Nothing to do here.** This step used to require hand-editing an allowlist.
> It does not any more; the section is kept so the step numbering below still
> matches older runbooks and the Troubleshooting entries.

The platform NetworkPolicies in front of the shared Redis and PgBouncer select
tenant namespaces **by label**, not by name:

```yaml
- from:
    - namespaceSelector:
        matchLabels:
          app.kubernetes.io/part-of: nextcloud-platform
```

Argo CD stamps that label on every tenant namespace it creates, via
`managedNamespaceMetadata` in `argo/applicationsets/nextcloud-tenants.yaml`. A
new tenant is therefore allowed the moment its namespace exists — see the
comment in `platform/redis/networkpolicy.yaml`: *"no manual updates are needed
when adding new tenants."*

Both `platform/redis/networkpolicy.yaml` and `platform/pgbouncer/networkpolicy.yaml`
work this way, for MariaDB and PostgreSQL tenants alike.

> If the namespace was created **by hand** (`kubectl create namespace`) rather
> than by Argo, it carries no label and the tenant cannot reach Redis or
> PgBouncer. Either let Argo create it, or add the label yourself:
> `kubectl label namespace <tenant> app.kubernetes.io/part-of=nextcloud-platform`

### 3. Create Secrets

Before Argo CD can deploy the tenant, secrets must exist in the namespace.

**Recommended: Use the secret creation script**

```bash
cd nextcloud-platform/scripts

# Copy and edit the env template
cp env.example .env
nano .env  # Fill in your credentials

# Geef de db-vlag altijd expliciet mee — de script-default staat nog op
# --mariadb, terwijl het platform postgres als default heeft.

# For PostgreSQL tenant (platform-default):
./create-tenant-secret.sh <tenant-name> --postgres

# For MariaDB tenant (legacy):
./create-tenant-secret.sh <tenant-name> --mariadb

# Or auto-generate all passwords:
./create-tenant-secret.sh <tenant-name> --postgres --generate-passwords
```

**Alternative: Manual secret creation**

```bash
# Create namespace first (Argo CD will also create it, but secrets need to exist)
# The namespace is the bare tenant name (e.g. myorg-accept), NOT nc-<tenant>.
kubectl create namespace <tenant-name>

# MariaDB secrets
kubectl create secret generic nextcloud-secrets \
  --namespace=<tenant-name> \
  --from-literal=nextcloud-username='admin@example.com' \
  --from-literal=nextcloud-password='<secure-password>' \
  --from-literal=s3-access-key='<s3-access-key>' \
  --from-literal=s3-secret-key='<s3-secret-key>' \
  --from-literal=mariadb-password='<db-password>' \
  --from-literal=mariadb-root-password='<root-password>' \
  --from-literal=nextcloud-secret="$(openssl rand -base64 48)"

# PostgreSQL secrets (includes redis-password)
kubectl create secret generic nextcloud-secrets \
  --namespace=<tenant-name> \
  --from-literal=nextcloud-username='admin@example.com' \
  --from-literal=nextcloud-password='<secure-password>' \
  --from-literal=s3-access-key='<s3-access-key>' \
  --from-literal=s3-secret-key='<s3-secret-key>' \
  --from-literal=postgres-password='<postgres-admin-password>' \
  --from-literal=db-username='nextcloud' \
  --from-literal=db-password='<db-password>' \
  --from-literal=redis-password='<redis-password>' \
  --from-literal=nextcloud-secret="$(openssl rand -base64 48)"
```

### 4. Open a PR — do not push to main

> **The normal route is the portal, not your shell.**
> `platform.commonground.nu` (the openwoo-provisioner control-plane, repo
> `ConductionNL/openwoo-app-config`) opens the tenant PR for you: it renders the
> thin tenant file, defaults `dbType` to `postgres`, records `requested-by: <your
> SSO e-mail>` in the commit trailer and PR body, **and applies the required
> label**.

#### Image overrides: use the portal, not the manual route

**The portal supports a top-level `image:` block** — three fields (registry,
repository, tag) behind a collapsed *Afwijkende Nextcloud-image* section — and it
is the route to prefer, because the portal enforces the version rules that this
page can only state:

| Rule | How the portal enforces it |
|---|---|
| Always a patch tag, never a floating one | a tag without a version number is rejected |
| Never a `digest:` field | there is no field for it |
| **Never point an existing tenant at a lower version** | refused, comparing against the tenant file / `common.yaml` and against what Argo sees running |

It also warns when the tenant file existed before and was removed — the namespace
and its PVC may still be there (`preserveResourcesOnDeletion: true`) — and names
the removed file's `dbType` and image so an engine switch is visible. That
warning goes into the PR body, so the reviewer sees it too.

`tenant-harderwijk-prod.yaml` was written by hand on 2026-08-26, before this
existed. Nobody validated the image choice on that PR, and the version rule was
nearly broken: the file it replaced ran 32.0.13 while the new one pinned 32.0.6.
It landed safely only because the namespace happened to be cleaned up.

`dbType` never needed the manual route either — it is a dropdown in the portal, so
a legacy MariaDB tenant can be requested there like any other.

Version pins are in the portal too: one field per app, blank by default. Only
`opencatalogi`, `openconnector` and `openregister` are offered, because those are
the three the ApplicationSet wires — a pin on any other name passes
`validate-values.sh` and then does nothing, so the portal refuses it rather than
accepting a pin that never takes effect.

#### When the manual route is still the answer

For a field the portal does not model. It renders `name`, `environment`, `wave`,
`dbType`, `secrets`, `apps` (`enabled` + `versions`), `frontend` and the top-level
`image:`. Anything else — `tenant.hostname`, `tenant.chartVersion`,
`tenant.namespace`, a bucket override — is hand-written, and a tenant file
carrying such a field stays **read-only** in the portal so that saving can never
silently drop it.

Two things follow for any hand-written PR:

- You set the `change/tenant-additive` label yourself (see below). Since
  2026-08-26 `main` requires the governance checks, so a forgotten label **blocks
  the merge** instead of quietly deploying.
- None of the guards above run. Re-read the three rules and the downgrade warning
  under [Overriding the Nextcloud image](#overriding-the-nextcloud-image) first —
  in particular: check whether the namespace still exists from an earlier life of
  the tenant, because `preserveResourcesOnDeletion: true` keeps the PVC.

Whichever route you take, the change lands through a **pull request against
`main`**. Do not push straight to `main`: the governance gate lives on the PR, so
a direct push skips it.

```bash
git switch -c add-tenant/<name>
git add nextcloud-platform/values/tenants/tenant-<name>.yaml
git commit -m "add tenant: <name>"
git push -u origin add-tenant/<name>
gh pr create --base main --title "add tenant: <name>"
```

#### The `change/tenant-additive` label is required

`.github/workflows/governance-check.yaml` classifies the diff with
`nextcloud-platform/scripts/classify-change.sh` and then **fails unless the
matching label is on the PR**:

| Classification | Required label |
|---|---|
| tenant-only diff | `change/tenant-additive` |
| platform or mixed diff | `change/platform` |

That workflow only *reads* `github.event.pull_request.labels`; it never adds one.
The automation lives in the portal (`webgui/server.py`, `TENANT_PR_LABEL`), so:

- **PR opened via the portal** → the label is set for you, nothing to do.
- **PR opened by hand** (`gh pr create`, or an edit in the GitHub web UI) → set it
  yourself or the check stays red:
  `gh pr edit <number> --add-label change/tenant-additive`

A local `pre-commit` hook cannot cover this. The label is PR metadata on GitHub,
not a file in the tree, so it has nothing to do with whether you cloned the repo
— it must be set on the PR either way. See `docs/CHECKS-AND-BALANCES.md`.

#### After the merge: Argo follows `release`, not `main`

Argo CD reads GitHub, but the git generator of the `nextcloud-tenants`
ApplicationSet follows the **`release`** ref (`release-accept` for accept
tenants), not `main`. A tenant file sitting on `main` produces no `Application`
at all.

`.github/workflows/promote-tenant-changes.yaml` closes that gap: on every push to
`main` it re-runs the same classification, and for a `tenant-additive` change it
fast-forwards both `release` and `release-accept` to that commit — right away,
outside the evening window. For a tenant addition the merge is therefore the last
manual step.

Platform and mixed changes are deliberately **not** promoted by that workflow.
Those go through the canary gate in `scheduled-merge.yaml`.

### 5. Sync Argo CD

After push, Argo CD should detect the new tenant file and create a new `Application`.

In practice, if you want immediate reconcile (recommended), refresh the existing
ApplicationSet — do **not** re-apply the manifest file (see warning below):

```bash
# 1) Force ApplicationSet refresh (reconciles against Git)
kubectl -n argocd annotate applicationset nextcloud-tenants \
  argocd.argoproj.io/application-set-refresh="true" --overwrite

# 2) Check if the tenant Application appears (named nc-<tenant>, e.g. nc-myorg-accept)
kubectl -n argocd get applications | grep <tenant-name>
```

> For an existing AppSet the annotate-refresh above is usually enough. Re-applying the
> manifest (`kubectl -n argocd apply -f .../nextcloud-tenants.yaml`) is also supported —
> the canary override now uses a templated filename + `helm.ignoreMissingValueFiles: true`,
> so the manifest is valid YAML. (It previously failed at ~line 62 due to a `{{- if }}`
> list-control line; that has been fixed.)

Expected timing:

- Usually visible within **seconds to 1 minute**
- If not visible after **2-3 minutes**, go to Troubleshooting below

### 6. Verify Deployment

```bash
# Check application status (the Application is named nc-<tenant>)
kubectl -n argocd get applications | grep <tenant-name>

# Check pods
kubectl get pods -n <tenant-namespace>

# Verify Nextcloud is running
kubectl exec -n <tenant-namespace> deploy/nextcloud -c nextcloud -- php occ status
```

**Verwacht op de eerste sync van een managed tenant:** de pod meldt kort
`MountVolume.SetUp failed ... secret "nextcloud-secrets" not found`. De
ExternalSecret en de workload zitten in dezelfde Application, en de `Secret`
bestaat pas ná een ESO-reconcile. Kubelet retryt de mount, dus dit heelt
zichzelf binnen een minuut. Blijft het staan, zie
[SECRETS.md § Eerste sync](SECRETS.md#eerste-sync--een-verse-tenant-ziet-even-geen-secret).

## Cutting Over from a Migration Hostname

When a tenant was onboarded with a temporary `{org}.migrate.commonground.nu` hostname, the final
step is cutting over to the canonical domain.

### Why this is needed

Nextcloud writes `trusted_domains` and `overwrite.cli.url` to `config/config.php` in the persistent
volume during initial installation. The Helm chart does not patch this file post-install. When you
remove the `tenant.hostname` migrate override, the startup probe starts sending
`Host: {org}.commonground.nu` — but `config.php` only trusts the old migrate domain, causing HTTP 400.

### Cutover procedure

1. **Remove the migrate hostname** from the tenant values file:
   ```yaml
   # Remove this line:
   hostname: {org}.migrate.commonground.nu
   ```
   Commit and push. Argo CD will sync and roll the pod with the new probe hostname.

2. **Run the cutover script** to patch the live pod:
   ```bash
   ./scripts/cutover-tenant.sh {tenant-name}
   ```
   This adds the canonical hostname to `trusted_domains` and updates `overwrite.cli.url`.

3. **Verify** the pod becomes healthy:
   ```bash
   kubectl get pods -n {tenant-name} -w
   curl -sI https://{org}.commonground.nu/status.php
   ```

Or use the skill: `/cutover-tenant {tenant-name}`

### What the script does

- Derives the canonical hostname from the tenant name (mirrors ApplicationSet logic)
- Adds `{org}.commonground.nu` to `trusted_domains` at index 1 (preserves `localhost` at index 0)
- Sets `overwrite.cli.url` to `https://{org}.commonground.nu`
- Prints the verified final config

## Troubleshooting

### "Redis server went away" or connection errors

The tenant namespace is missing the label the platform NetworkPolicies select on.
Check it and add it if absent:

```bash
kubectl get namespace <tenant> -o jsonpath='{.metadata.labels}'
kubectl label namespace <tenant> app.kubernetes.io/part-of=nextcloud-platform
```

Argo sets this label on namespaces it creates; a hand-made namespace does not
have it. See Step 2 above.

### Pods stuck in "CreateContainerConfigError"

Secrets are missing. See Step 3 above.

### Application not appearing in Argo CD

Use this order (most common causes first):

1. **Confirm file was pushed to `main` on GitHub**
   - Argo only watches Git (not your local files), and it reads **GitHub**
     (`ConductionNL`) since 2026-08-03. Make sure it landed on `main` via
     `origin` — a branch on Codeberg will not deploy.

2. **Confirm tenant file is valid**
   - Filename must match `tenant-*.yaml`
   - Location must be `nextcloud-platform/values/tenants/`
   - Validate:
     ```bash
     ./nextcloud-platform/scripts/validate-values.sh \
       nextcloud-platform/values/tenants/tenant-<name>.yaml
     ```

3. **Force ApplicationSet reconcile**
   ```bash
   kubectl -n argocd annotate applicationset nextcloud-tenants \
     argocd.argoproj.io/application-set-refresh="true" --overwrite
   ```
   > The annotate refresh is usually enough; re-applying the manifest also works now
   > (the canary `{{- if }}` list-control line was replaced by a templated filename +
   > `helm.ignoreMissingValueFiles`). See Step 5.

4. **Check ApplicationSet status message**
   ```bash
   kubectl -n argocd get applicationset nextcloud-tenants \
     -o jsonpath='{.status.conditions[*].message}{"\n"}'
   ```

5. **Check controller logs (if still missing)**
   ```bash
   kubectl logs -n argocd -l app.kubernetes.io/name=argocd-applicationset-controller
   ```

6. **Check sync window**
   - Outside allowed sync window, app may exist but not progress/sync yet.

## Checklist

### All Tenants
- [ ] Tenant values file created (`tenant-<name>.yaml`) — thin: name/environment/dbType/apps
- [ ] `tenant.name`, `tenant.environment`, `tenant.dbType`, `tenant.apps.enabled` set (hostname derived)
- [ ] Any `tenant.apps.versions` pins use a wired app name and a valid format (`validate-values.sh` green)
- [ ] Any top-level `image:` override uses a patch-version tag, has no `digest:`, and is not lower than the version the tenant already runs
- [ ] Namespace created (bare tenant name, e.g. `myorg-accept`)
- [ ] Secrets created in namespace (use `create-tenant-secret.sh`)
- [ ] Opened as a PR against `main` — not pushed directly
- [ ] `change/tenant-additive` label on the PR (automatic via the portal; by hand otherwise)
- [ ] `governance-check` and `ci` green
- [ ] After merge: `release` / `release-accept` advanced (`promote-tenant-changes` ran)
- [ ] Argo CD Application synced
- [ ] Pods running (3/3 for MariaDB, 4/4+ for PostgreSQL with Redis)
- [ ] Nextcloud accessible via browser

> NetworkPolicies need no checklist item any more — they select tenant namespaces
> by label, which Argo sets. See Step 2.

### PostgreSQL Tenants Only
- [ ] `tenant.dbType: postgres` set
- [ ] Per-tenant Redis pod running
