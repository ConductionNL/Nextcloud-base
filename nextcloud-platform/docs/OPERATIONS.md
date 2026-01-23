# Operations Guide

Dit document beschrijft veelvoorkomende operationele taken voor het Nextcloud platform.

## Inhoudsopgave

- [Tenant Reset (Data wissen)](#tenant-reset-data-wissen)
- [Tenant Volledig Verwijderen](#tenant-volledig-verwijderen)
- [Tenant Opnieuw Opzetten](#tenant-opnieuw-opzetten)
- [PVC Resizen](#pvc-resizen)
- [S3 Data Beheer](#s3-data-beheer)
- [Database Operaties](#database-operaties)
- [Logs en Debugging](#logs-en-debugging)
- [Noodprocedures](#noodprocedures)

---

## Tenant Reset (Data wissen)

Reset een tenant naar een schone staat **zonder** de configuratie te verwijderen.

### Alleen PVCs resetten (snelste methode)

```bash
TENANT=canary

# 1. Scale down de deployment
kubectl scale deployment nextcloud -n nc-$TENANT --replicas=0
kubectl scale deployment nextcloud-mariadb -n nc-$TENANT --replicas=0  # indien MariaDB

# 2. Wacht tot pods weg zijn
kubectl wait --for=delete pod -l app.kubernetes.io/name=nextcloud -n nc-$TENANT --timeout=60s

# 3. Verwijder alle PVCs
kubectl delete pvc --all -n nc-$TENANT

# 4. Scale up (nieuwe lege PVCs worden aangemaakt)
kubectl scale deployment nextcloud-mariadb -n nc-$TENANT --replicas=1  # indien MariaDB
kubectl scale deployment nextcloud -n nc-$TENANT --replicas=1

# 5. Wacht op nieuwe pods
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=nextcloud -n nc-$TENANT --timeout=300s
```

### Volledige reset inclusief secrets

```bash
TENANT=canary

# 1. Scale down
kubectl scale deployment nextcloud -n nc-$TENANT --replicas=0
kubectl scale deployment nextcloud-mariadb -n nc-$TENANT --replicas=0

# 2. Verwijder PVCs en secrets
kubectl delete pvc --all -n nc-$TENANT
kubectl delete secret nextcloud-secrets -n nc-$TENANT

# 3. Maak nieuwe secrets aan
kubectl create secret generic nextcloud-secrets \
  --namespace=nc-$TENANT \
  --from-literal=nextcloud-username=admin \
  --from-literal=nextcloud-password="$(openssl rand -base64 24)" \
  --from-literal=s3-access-key='<YOUR_S3_ACCESS_KEY>' \
  --from-literal=s3-secret-key='<YOUR_S3_SECRET_KEY>' \
  --from-literal=mariadb-root-password="$(openssl rand -base64 24)" \
  --from-literal=mariadb-password="$(openssl rand -base64 24)" \
  --from-literal=redis-password='' \
  --from-literal=nextcloud-secret="$(openssl rand -base64 48)"

# 4. Scale up
kubectl scale deployment nextcloud-mariadb -n nc-$TENANT --replicas=1
kubectl scale deployment nextcloud -n nc-$TENANT --replicas=1

# 5. Noteer het nieuwe admin wachtwoord!
kubectl get secret nextcloud-secrets -n nc-$TENANT -o jsonpath='{.data.nextcloud-password}' | base64 -d
```

---

## Tenant Volledig Verwijderen

### Via GitOps (aanbevolen)

```bash
TENANT=canary

# 1. Verwijder tenant bestand uit Git
git rm nextcloud-platform/values/tenants/tenant-$TENANT.yaml
git commit -m "chore: remove tenant $TENANT"
git push

# 2. Argo CD verwijdert automatisch:
#    - Application
#    - Namespace (nc-$TENANT)
#    - Alle resources

# 3. Verifieer
kubectl get ns nc-$TENANT  # Should return "not found"
kubectl get application nc-$TENANT -n argocd  # Should return "not found"
```

### Handmatig (sneller, maar niet GitOps)

```bash
TENANT=canary

# 1. Verwijder Argo CD Application
kubectl delete application nc-$TENANT -n argocd

# 2. Verwijder namespace (cascade delete)
kubectl delete namespace nc-$TENANT

# 3. Verifieer
kubectl get ns nc-$TENANT
```

**Let op:** Dit verwijdert NIET:
- S3 data (zie [S3 Data Beheer](#s3-data-beheer))
- Database in externe PostgreSQL (indien gebruikt)
- DNS records

---

## Tenant Opnieuw Opzetten

### Na handmatige verwijdering

```bash
TENANT=canary

# 1. Trigger Argo CD ApplicationSet refresh
kubectl annotate applicationset nextcloud-tenants -n argocd \
  refresh="$(date +%s)" --overwrite

# Of forceer sync via CLI
argocd appset generate nextcloud-tenants --refresh
```

### Na GitOps verwijdering

```bash
TENANT=canary

# 1. Herstel of maak nieuw tenant bestand
cp nextcloud-platform/values/templates/tenant-template.yaml \
   nextcloud-platform/values/tenants/tenant-$TENANT.yaml

# 2. Pas configuratie aan
# Edit nextcloud-platform/values/tenants/tenant-$TENANT.yaml

# 3. Maak secret aan VOORDAT je commit
kubectl create namespace nc-$TENANT
kubectl create secret generic nextcloud-secrets \
  --namespace=nc-$TENANT \
  --from-literal=nextcloud-username=admin \
  --from-literal=nextcloud-password="$(openssl rand -base64 24)" \
  --from-literal=s3-access-key='<YOUR_S3_ACCESS_KEY>' \
  --from-literal=s3-secret-key='<YOUR_S3_SECRET_KEY>' \
  --from-literal=mariadb-root-password="$(openssl rand -base64 24)" \
  --from-literal=mariadb-password="$(openssl rand -base64 24)" \
  --from-literal=redis-password='' \
  --from-literal=nextcloud-secret="$(openssl rand -base64 48)"

# 4. Commit en push
git add nextcloud-platform/values/tenants/tenant-$TENANT.yaml
git commit -m "feat: add tenant $TENANT"
git push

# 5. Noteer admin wachtwoord
kubectl get secret nextcloud-secrets -n nc-$TENANT -o jsonpath='{.data.nextcloud-password}' | base64 -d
```

---

## PVC Resizen

**Let op:** Niet alle storage classes ondersteunen volume expansion!

### Check of resizing mogelijk is

```bash
kubectl get storageclass -o jsonpath='{range .items[*]}{.metadata.name}: {.allowVolumeExpansion}{"\n"}{end}'
```

### PVC vergroten (indien ondersteund)

```bash
TENANT=canary
NEW_SIZE=50Gi

# 1. Patch de PVC
kubectl patch pvc nextcloud -n nc-$TENANT \
  -p '{"spec":{"resources":{"requests":{"storage":"'$NEW_SIZE'"}}}}'

# 2. Verifieer
kubectl get pvc -n nc-$TENANT
```

### PVC vergroten (indien NIET ondersteund)

```bash
TENANT=canary

# 1. Maak backup van data
kubectl exec -n nc-$TENANT deploy/nextcloud -- tar czf /tmp/backup.tar.gz /var/www/html

# 2. Kopieer backup naar lokaal
kubectl cp nc-$TENANT/$(kubectl get pod -n nc-$TENANT -l app.kubernetes.io/name=nextcloud -o jsonpath='{.items[0].metadata.name}'):/tmp/backup.tar.gz ./backup.tar.gz

# 3. Scale down
kubectl scale deployment nextcloud -n nc-$TENANT --replicas=0

# 4. Verwijder oude PVC
kubectl delete pvc nextcloud -n nc-$TENANT

# 5. Update PVC size in values en sync
# Edit tenant yaml: persistence.size: 50Gi
git commit -am "chore: increase PVC size for $TENANT"
git push

# 6. Wacht op nieuwe PVC en pod
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=nextcloud -n nc-$TENANT --timeout=300s

# 7. Restore backup
kubectl cp ./backup.tar.gz nc-$TENANT/$(kubectl get pod -n nc-$TENANT -l app.kubernetes.io/name=nextcloud -o jsonpath='{.items[0].metadata.name}'):/tmp/backup.tar.gz
kubectl exec -n nc-$TENANT deploy/nextcloud -- tar xzf /tmp/backup.tar.gz -C /
```

---

## S3 Data Beheer

### S3 data bekijken

```bash
TENANT=canary
BUCKET=nextcloud

# List objects
aws --endpoint-url https://core.fuga.cloud:8080 s3 ls s3://$BUCKET/$TENANT/ --recursive

# Totale grootte
aws --endpoint-url https://core.fuga.cloud:8080 s3 ls s3://$BUCKET/$TENANT/ --recursive --summarize
```

### S3 data verwijderen

```bash
TENANT=canary
BUCKET=nextcloud

# ⚠️ WAARSCHUWING: Dit verwijdert ALLE user data permanent!

# Dry-run eerst
aws --endpoint-url https://core.fuga.cloud:8080 s3 rm s3://$BUCKET/$TENANT/ --recursive --dryrun

# Daadwerkelijk verwijderen
aws --endpoint-url https://core.fuga.cloud:8080 s3 rm s3://$BUCKET/$TENANT/ --recursive
```

### S3 data migreren naar andere bucket/prefix

```bash
OLD_PREFIX=canary
NEW_PREFIX=canary-v2
BUCKET=nextcloud

aws --endpoint-url https://core.fuga.cloud:8080 s3 sync \
  s3://$BUCKET/$OLD_PREFIX/ \
  s3://$BUCKET/$NEW_PREFIX/
```

---

## Database Operaties

### MariaDB (in-cluster)

#### Database shell

```bash
TENANT=canary

kubectl exec -it -n nc-$TENANT deploy/nextcloud-mariadb -- \
  mysql -u nextcloud -p nextcloud
# Password: zie secret mariadb-password
```

#### Database backup

```bash
TENANT=canary

kubectl exec -n nc-$TENANT deploy/nextcloud-mariadb -- \
  mysqldump -u nextcloud -p nextcloud > backup-$TENANT-$(date +%Y%m%d).sql
```

#### Database restore

```bash
TENANT=canary

kubectl exec -i -n nc-$TENANT deploy/nextcloud-mariadb -- \
  mysql -u nextcloud -p nextcloud < backup-$TENANT.sql
```

### External PostgreSQL

#### Database shell

```bash
TENANT=canary
DB_HOST=your-postgres-host
DB_NAME=nextcloud_$TENANT

psql -h $DB_HOST -U nextcloud_$TENANT -d $DB_NAME
```

#### Database backup

```bash
pg_dump -h $DB_HOST -U nextcloud_$TENANT -d $DB_NAME > backup-$TENANT-$(date +%Y%m%d).sql
```

---

## Logs en Debugging

### Nextcloud logs

```bash
TENANT=canary

# Realtime logs
kubectl logs -n nc-$TENANT deploy/nextcloud -f

# Nextcloud specifieke logs
kubectl exec -n nc-$TENANT deploy/nextcloud -- tail -f /var/www/html/data/nextcloud.log
```

### Nextcloud status

```bash
TENANT=canary

kubectl exec -n nc-$TENANT deploy/nextcloud -- php occ status
kubectl exec -n nc-$TENANT deploy/nextcloud -- php occ check
kubectl exec -n nc-$TENANT deploy/nextcloud -- php occ app:list
```

### Database check

```bash
TENANT=canary

kubectl exec -n nc-$TENANT deploy/nextcloud -- php occ db:add-missing-indices --dry-run
kubectl exec -n nc-$TENANT deploy/nextcloud -- php occ db:add-missing-columns --dry-run
```

### Maintenance mode

```bash
TENANT=canary

# Aanzetten
kubectl exec -n nc-$TENANT deploy/nextcloud -- php occ maintenance:mode --on

# Uitzetten
kubectl exec -n nc-$TENANT deploy/nextcloud -- php occ maintenance:mode --off
```

---

## Noodprocedures

### Pod crasht continu

```bash
TENANT=canary

# 1. Check events
kubectl describe pod -n nc-$TENANT -l app.kubernetes.io/name=nextcloud

# 2. Check logs van crashed pod
kubectl logs -n nc-$TENANT -l app.kubernetes.io/name=nextcloud --previous

# 3. Tijdelijk maintenance mode via env var
kubectl set env deployment/nextcloud -n nc-$TENANT NEXTCLOUD_MAINTENANCE=1

# 4. Start debug pod
kubectl run debug -n nc-$TENANT --rm -it --image=nextcloud:30.0.4-fpm -- bash
```

### Argo CD sync faalt

```bash
TENANT=canary

# 1. Check Application status
argocd app get nc-$TENANT

# 2. Bekijk sync errors
argocd app sync nc-$TENANT --dry-run

# 3. Force refresh
argocd app refresh nc-$TENANT --hard-refresh

# 4. Handmatige sync met prune
argocd app sync nc-$TENANT --prune --force
```

### Storage vol

```bash
TENANT=canary

# 1. Check PVC usage
kubectl exec -n nc-$TENANT deploy/nextcloud -- df -h

# 2. Vind grote bestanden
kubectl exec -n nc-$TENANT deploy/nextcloud -- du -sh /var/www/html/* | sort -hr | head -20

# 3. Cleanup logs
kubectl exec -n nc-$TENANT deploy/nextcloud -- rm -rf /var/www/html/data/nextcloud.log.*

# 4. Cleanup trashbin (per user)
kubectl exec -n nc-$TENANT deploy/nextcloud -- php occ trashbin:cleanup --all-users
```

### Alle tenants uitschakelen (noodgeval)

```bash
# Suspend alle Argo CD syncs
kubectl patch applicationset nextcloud-tenants -n argocd \
  --type=merge \
  -p '{"spec":{"template":{"spec":{"syncPolicy":{"automated":null}}}}}'

# Re-enable na incident
kubectl patch applicationset nextcloud-tenants -n argocd \
  --type=merge \
  -p '{"spec":{"template":{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}}}'
```

---

## Handige One-liners

```bash
# Alle tenant namespaces
kubectl get ns -l app.kubernetes.io/part-of=nextcloud-platform

# Alle PVCs over alle tenants
kubectl get pvc -A -l app.kubernetes.io/name=nextcloud

# Resource usage per tenant
kubectl top pods -A -l app.kubernetes.io/name=nextcloud

# Alle Nextcloud applications in Argo CD
argocd app list -l app.kubernetes.io/part-of=nextcloud-platform

# Quick health check alle tenants
for ns in $(kubectl get ns -l app.kubernetes.io/part-of=nextcloud-platform -o name | cut -d/ -f2); do
  echo "=== $ns ==="
  kubectl exec -n $ns deploy/nextcloud -- php occ status 2>/dev/null | grep -E "installed|version|maintenance"
done
```

