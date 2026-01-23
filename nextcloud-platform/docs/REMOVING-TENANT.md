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
│  3. ApplicationSet generator updaten                            │
│                    ↓                                             │
│  4. Commit & Push                                                │
│                    ↓                                             │
│  5. Wachten tot Argo CD Application verwijdert                  │
│                    ↓                                             │
│  6. Handmatig namespace opruimen                                │
│                    ↓                                             │
│  7. S3 data opruimen (optioneel)                                │
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
kubectl exec -n nc-$TENANT deploy/nextcloud-mariadb -- \
  mysqldump -u nextcloud -p nextcloud > backup-$TENANT-db-$(date +%Y%m%d).sql

# Of voor PostgreSQL
kubectl exec -n nc-$TENANT deploy/nextcloud -- \
  pg_dump -h pgbouncer.nextcloud-platform.svc.cluster.local \
  -U nextcloud_$TENANT nextcloud_$TENANT > backup-$TENANT-db-$(date +%Y%m%d).sql
```

**Secrets backup (voor het geval je moet herstellen):**

```bash
kubectl get secret nextcloud-secrets -n nc-$TENANT -o yaml > backup-$TENANT-secrets.yaml
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

### 3. ApplicationSet Updaten

Bewerk `nextcloud-platform/argo/applicationsets/nextcloud-tenants.yaml` en verwijder de tenant uit de `files` lijst:

```yaml
generators:
  - git:
      files:
        - path: "nextcloud-platform/values/tenants/tenant-canary.yaml"
        # - path: "nextcloud-platform/values/tenants/tenant-$TENANT.yaml"  ← VERWIJDER DEZE REGEL
```

### 4. Commit en Push

```bash
git add -A
git commit -m "chore: remove tenant $TENANT"
git push origin main
```

### 5. Wachten op Argo CD

Argo CD zal nu de Application verwijderen:

```bash
# Volg de Application status
kubectl get application nc-$TENANT -n argocd -w

# Of via Argo CD CLI
argocd app get nc-$TENANT
```

De Application verdwijnt, maar de **resources blijven bestaan** (`preserveResourcesOnDeletion: true`).

### 6. Namespace Opruimen

Nu de Application weg is, ruim handmatig de namespace op:

```bash
TENANT=<tenant-naam>

# Check wat er nog is
kubectl get all -n nc-$TENANT
kubectl get pvc -n nc-$TENANT
kubectl get secrets -n nc-$TENANT

# Als alles klopt, verwijder de namespace
kubectl delete namespace nc-$TENANT
```

**Let op:** Dit verwijdert:
- Alle pods
- Alle PVCs (inclusief database data!)
- Alle secrets
- Alle andere resources in de namespace

### 7. S3 Data Opruimen (Optioneel)

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
kubectl exec -n nc-$TENANT deploy/nextcloud-mariadb -- mysqldump -u nextcloud -p nextcloud > backup.sql
kubectl get secret nextcloud-secrets -n nc-$TENANT -o yaml > secrets-backup.yaml

# 2. Git
git rm nextcloud-platform/values/tenants/tenant-$TENANT.yaml
# + Edit applicationsets/nextcloud-tenants.yaml
git commit -m "chore: remove tenant $TENANT"
git push

# 3. Wacht tot Application weg is
kubectl get application nc-$TENANT -n argocd

# 4. Opruimen
kubectl delete namespace nc-$TENANT

# 5. S3 (optioneel)
aws --endpoint-url https://core.fuga.cloud:8080 s3 rm s3://nextcloud/$TENANT/ --recursive
```

---

## Troubleshooting

### Namespace hangt in "Terminating"

```bash
# Check wat de namespace blokkeert
kubectl get namespace nc-$TENANT -o yaml

# Forceer verwijdering (alleen als veilig!)
kubectl patch namespace nc-$TENANT -p '{"metadata":{"finalizers":[]}}' --type=merge
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
kubectl describe pvc -n nc-$TENANT

# Forceer verwijdering
kubectl patch pvc <pvc-name> -n nc-$TENANT -p '{"metadata":{"finalizers":[]}}' --type=merge
```

---

## Zie Ook

- [ADDING-TENANT.md](ADDING-TENANT.md) - Nieuwe tenant toevoegen
- [OPERATIONS.md](OPERATIONS.md) - Tenant reset (zonder verwijderen)
- [SECRETS.md](SECRETS.md) - Secrets backup en restore

