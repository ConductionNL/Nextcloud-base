# Secrets Management

How tenant secrets work on this platform. Last verified 2026-06-23.

> **No secrets in Git, ever.** `.env` and key material are git-ignored; `gitleaks` runs in
> CI. The data below is created in-cluster / out-of-band, never committed.

## Two mechanisms

Every tenant ends up with one `Secret` named **`nextcloud-secrets`** in its namespace
(the namespace is the **bare tenant name**, e.g. `straatje-accept` — *not* `nc-<tenant>`,
that is the Argo *application* name). How it gets there depends on the tenant:

| Tenant kind | Mechanism | How |
|---|---|---|
| **Existing / script-applied** | `scripts/create-tenant-secret.sh` writes `nextcloud-secrets` directly | the original method; not rotated |
| **Managed (new / web-created)** | **ESO** assembles `nextcloud-secrets` declaratively | tenant file sets `tenant.secrets.managed: true` |

A managed tenant's ExternalSecret renders **only** when `tenant.secrets.managed: true`. If
it is absent/false the ESO path is skipped entirely, so existing tenants' script-applied
secrets are never touched.

## Mechanism A — script (existing tenants)

```bash
cd nextcloud-platform/scripts
cp env.example .env          # fill in real S3/DB creds (git-ignored)
./create-tenant-secret.sh <tenant> --postgres --generate-passwords   # or --mariadb
```

## Mechanism B — ESO (managed tenants)

The **External Secrets Operator** itself is installed by the **cluster-infra** repo (it is a
cluster-wide capability, not part of this repo). This repo only adds the **consumers**, in
`platform/externalsecrets/`:

- **`ClusterSecretStore` `nextcloud-shared-store`** — uses the ESO **kubernetes provider**:
  the "external" source is an in-cluster seed Secret. **No Vault, no AWS Secrets Manager.**
- **`ClusterGenerator` `nextcloud-password`** — a Password generator for the per-tenant
  random secrets (admin / db / redis / nextcloud salt).
- A per-tenant **`ExternalSecret`** from `charts/tenant-secret` combines the two into the
  tenant's `nextcloud-secrets`. `refreshInterval: "0"` → generated **once**, never rotated
  out from under a running tenant; `deletionPolicy: Retain`.

```
  seed Secret (shared S3 creds)            ClusterGenerator (random per-tenant pw)
  nextcloud-platform/nextcloud-s3-seed     "nextcloud-password"
            │                                        │
            └────────► ClusterSecretStore ◄──────────┘
                       "nextcloud-shared-store"
                                 │
                                 ▼
                  ExternalSecret (charts/tenant-secret)  ──►  Secret "nextcloud-secrets"
                  in ns <tenant>                               in ns <tenant>
```

API versions: `external-secrets.io/v1` (ESO 2.x dropped the served `v1beta1`);
`ClusterGenerator` is `generators.external-secrets.io/v1alpha1`.

### The shared S3 seed (out-of-band)

The Fuga S3 access/secret keys are the **same for every tenant**. ESO reads them from one
central seed Secret `nextcloud-platform/nextcloud-s3-seed`, created out-of-band (never in
Git). The live values already exist in any tenant's `nextcloud-secrets`, so the seed is
seeded by copying from an existing tenant:

```bash
kubectl get secret nextcloud-secrets -n acato-accept -o json \
  | jq '{apiVersion:"v1",kind:"Secret",type:"Opaque",
         metadata:{name:"nextcloud-s3-seed",namespace:"nextcloud-platform"},
         data:{"s3-access-key":.data["s3-access-key"],"s3-secret-key":.data["s3-secret-key"]}}' \
  | kubectl apply -f -
```

### Manual render (fallback)

Normally the per-tenant ExternalSecret is produced by the `nextcloud-tenants` ApplicationSet
(source `charts/tenant-secret`), so a managed tenant gets `nextcloud-secrets` automatically.
If you need to (re)create it by hand — e.g. before the AppSet has reconciled — render it
directly:

```bash
helm template nextcloud-secret charts/tenant-secret -n <tenant> \
  --set secrets.managed=true --set tenant.name=<tenant> --set tenant.dbType=postgres \
  | kubectl apply -n <tenant> -f -
```

## Keys in `nextcloud-secrets`

| Key | Description | Postgres | MariaDB |
|---|---|:--:|:--:|
| `nextcloud-username` | admin user (`admin`) | ✅ | ✅ |
| `nextcloud-password` | admin password | ✅ | ✅ |
| `nextcloud-secret` | Nextcloud `secret` (instance) | ✅ | ✅ |
| `s3-access-key` / `s3-secret-key` | Ceph RGW / Fuga S3 creds (shared seed) | ✅ | ✅ |
| `db-username` / `db-password` | database user/password | ✅ | ✅ |
| `postgres-password` | Postgres admin | ✅ | — |
| `redis-password` | per-tenant Redis | ✅ | — |
| `mariadb-password` / `mariadb-root-password` | MariaDB user/root | — | ✅ |

> The admin-password key is **`nextcloud-password`** (not `admin-password`).

## Verify

```bash
kubectl get externalsecret -n <tenant>                 # managed tenants
kubectl get secret -n <tenant> nextcloud-secrets
kubectl get clustersecretstore nextcloud-shared-store  # want: Ready=True
kubectl get clustergenerator nextcloud-password
```

## Rotate / retrieve

`refreshInterval: "0"` means ESO does **not** auto-rotate. To rotate, patch (or delete +
re-render) `nextcloud-secrets` and roll the tenant:

```bash
kubectl rollout restart deployment -n <tenant> nextcloud
```

Retrieve the admin password:

```bash
kubectl get secret nextcloud-secrets -n <tenant> \
  -o jsonpath='{.data.nextcloud-password}' | base64 -d
```

## Best practices

- Never commit secrets; keep `.env` git-ignored; `gitleaks` in CI.
- Least privilege: S3 keys scoped to the bucket, DB users to their database.
- Back up secrets out-of-band (encrypted), never to Git.

## Troubleshooting

```bash
# ExternalSecret not syncing
kubectl describe externalsecret -n <tenant> nextcloud-secrets
kubectl logs -n external-secrets deploy/external-secrets
kubectl get clustersecretstore nextcloud-shared-store -o yaml   # Ready=True?
# Roadmap: secret access is not yet role-scoped — anyone with `kubectl get secret`
# can currently read tenant secrets. Tightening this (RBAC) is a planned improvement.
```
