---
last_reviewed: 2026-06-23
owner: mark
---

# Removing a Tenant

Deze guide beschrijft hoe je een tenant veilig verwijdert van het platform.

## ⚠️ Belangrijke Waarschuwing

Het verwijderen van een tenant is **permanent**. Zorg dat je:

1. Backup hebt van alle data (zie [Backup sectie](#1-backup-maken))
2. Gebruikers hebt geïnformeerd
3. Zeker weet dat je de juiste tenant verwijdert

---

## Overzicht Stappen

```
┌─────────────────────────────────────────────────────────────────┐
│                    Tenant Verwijderen                            │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  1. Backup maken (data + database)                              │
│                    ↓                                             │
│  2. Tenant file verwijderen uit Git                             │
│                    ↓                                             │
│  3. Commit & Push                                                │
│                    ↓                                             │
│  4. Wachten tot Argo CD Application verwijdert                  │
│                    ↓                                             │
│  5. Handmatig namespace opruimen                                │
│                    ↓                                             │
│  6. S3 data opruimen (optioneel)                                │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

---

## Stap-voor-stap

### 1. Backup Maken

**Database backup:**

```bash
TENANT=<tenant-naam>

# MariaDB
kubectl exec -n $TENANT deploy/nextcloud-mariadb -- \
  mysqldump -u nextcloud -p nextcloud > backup-$TENANT-db-$(date +%Y%m%d).sql

# Of voor PostgreSQL
kubectl exec -n $TENANT deploy/nextcloud -- \
  pg_dump -h pgbouncer.nextcloud-platform.svc.cluster.local \
  -U nextcloud_$TENANT nextcloud_$TENANT > backup-$TENANT-db-$(date +%Y%m%d).sql
```

**Secrets backup (voor het geval je moet herstellen):**

```bash
kubectl get secret nextcloud-secrets -n $TENANT -o yaml > backup-$TENANT-secrets.yaml
```

**S3 data backup (optioneel, als S3 bucket gedeeld is):**

```bash
aws --endpoint-url https://core.fuga.cloud:8080 s3 sync \
  s3://nextcloud/$TENANT/ \
  ./backup-$TENANT-s3/
```

### 2. Tenant File Verwijderen

Verwijder het tenant values bestand:

```bash
git rm nextcloud-platform/values/tenants/tenant-$TENANT.yaml
```

De `nextcloud-tenants` ApplicationSet gebruikt een glob-generator
(`path: "nextcloud-platform/values/tenants/tenant-*.yaml"`), dus er is **geen
per-tenant `files` lijst** die je hoeft aan te passen. Het verwijderen van het
`tenant-$TENANT.yaml` bestand is voldoende om de tenant uit de generator te halen.

### 3. Commit en Push

```bash
git add -A
git commit -m "chore: remove tenant $TENANT"
git push codeberg main
```

### 4. Wachten op Argo CD

Argo CD zal nu de Application verwijderen:

```bash
# Volg de Application status
kubectl get application nc-$TENANT -n argocd -w

# Of via Argo CD CLI
argocd app get nc-$TENANT
```

De Application heet `nc-$TENANT`, maar de namespace is de kale tenant-naam (`$TENANT`).

De Application verdwijnt, maar de **resources blijven bestaan** (`preserveResourcesOnDeletion: true`).

### 5. Namespace Opruimen

Nu de Application weg is, ruim handmatig de namespace op:

```bash
TENANT=<tenant-naam>

# Check wat er nog is
kubectl get all -n $TENANT
kubectl get pvc -n $TENANT
kubectl get secrets -n $TENANT

# Als alles klopt, verwijder de namespace
kubectl delete namespace $TENANT
```

**Let op:** Dit verwijdert:
- Alle pods
- Alle PVCs (inclusief database data!)
- Alle secrets
- Alle andere resources in de namespace

### 6. S3 Data Opruimen (Optioneel)

Als de tenant een eigen S3 prefix/bucket had:

```bash
TENANT=<tenant-naam>
BUCKET=nextcloud

# DRY RUN eerst!
aws --endpoint-url https://core.fuga.cloud:8080 s3 rm \
  s3://$BUCKET/$TENANT/ --recursive --dryrun

# Als alles klopt, daadwerkelijk verwijderen
aws --endpoint-url https://core.fuga.cloud:8080 s3 rm \
  s3://$BUCKET/$TENANT/ --recursive
```

---

## Waarom Handmatig Opruimen?

Het platform heeft `preserveResourcesOnDeletion: true` als safety feature:

```yaml
# In applicationsets/nextcloud-tenants.yaml
spec:
  syncPolicy:
    preserveResourcesOnDeletion: true
```

Dit voorkomt dat:
- Per ongeluk user data verdwijnt door een fout in Git
- Een verkeerde commit productie data verwijdert
- Data verloren gaat voordat backup is gemaakt

**Handmatig opruimen is bewust een extra stap** zodat je zeker weet wat je doet.

---

## Snelle Referentie

```bash
TENANT=mijn-tenant

# 1. Backup
kubectl exec -n $TENANT deploy/nextcloud-mariadb -- mysqldump -u nextcloud -p nextcloud > backup.sql
kubectl get secret nextcloud-secrets -n $TENANT -o yaml > secrets-backup.yaml

# 2. Git (alleen het tenant-bestand verwijderen; de glob-generator regelt de rest)
git rm nextcloud-platform/values/tenants/tenant-$TENANT.yaml
git commit -m "chore: remove tenant $TENANT"
git push codeberg main

# 3. Wacht tot Application weg is
kubectl get application nc-$TENANT -n argocd

# 4. Opruimen (namespace is de kale tenant-naam)
kubectl delete namespace $TENANT

# 5. S3 (optioneel)
aws --endpoint-url https://core.fuga.cloud:8080 s3 rm s3://nextcloud/$TENANT/ --recursive
```

---

## Troubleshooting

### Namespace hangt in "Terminating"

```bash
# Check wat de namespace blokkeert
kubectl get namespace $TENANT -o yaml

# Forceer verwijdering (alleen als veilig!)
kubectl patch namespace $TENANT -p '{"metadata":{"finalizers":[]}}' --type=merge
```

### Application bestaat nog

```bash
# Handmatig verwijderen
kubectl delete application nc-$TENANT -n argocd

# Of via Argo CD CLI
argocd app delete nc-$TENANT
```

### PVC blijft hangen

```bash
# Check PVC status
kubectl describe pvc -n $TENANT

# Forceer verwijdering
kubectl patch pvc <pvc-name> -n $TENANT -p '{"metadata":{"finalizers":[]}}' --type=merge
```

---

## Zie Ook

- [ADDING-TENANT.md](ADDING-TENANT.md) - Nieuwe tenant toevoegen
- [TENANT-OPERATIONS.md](TENANT-OPERATIONS.md) - Tenant reset (zonder verwijderen)
- [SECRETS.md](SECRETS.md) - Secrets backup en restore

