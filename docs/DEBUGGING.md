---
last_reviewed: 2026-07-06
owner: info@conduction.nl
---

# Debugging: database, logs en status

Dagelijkse inspectie-commando's per tenant. Namespace = de kale
tenant-naam. Voor incidenten zie [EMERGENCY.md](EMERGENCY.md); voor de
database-keuzes zelf zie [DATABASE.md](DATABASE.md).

## Database Operaties

### MariaDB (in-cluster)

```bash
TENANT=canary
NS=$TENANT

# Database shell
kubectl exec -it -n $NS deploy/nextcloud-mariadb -- \
  mysql -u nextcloud -p nextcloud
# Password: zie secret mariadb-password

# Database backup
kubectl exec -n $NS deploy/nextcloud-mariadb -- \
  mysqldump -u nextcloud -p nextcloud > backup-$TENANT-$(date +%Y%m%d).sql

# Database restore
kubectl exec -i -n $NS deploy/nextcloud-mariadb -- \
  mysql -u nextcloud -p nextcloud < backup-$TENANT.sql
```

### External PostgreSQL

```bash
TENANT=canary
DB_HOST=your-postgres-host
DB_NAME=nextcloud_$TENANT

# Database shell
psql -h $DB_HOST -U nextcloud_$TENANT -d $DB_NAME

# Database backup
pg_dump -h $DB_HOST -U nextcloud_$TENANT -d $DB_NAME > backup-$TENANT-$(date +%Y%m%d).sql
```

## Logs en Debugging

### Nextcloud logs

```bash
TENANT=canary
NS=$TENANT

# Realtime logs
kubectl logs -n $NS deploy/nextcloud -f

# Nextcloud specifieke logs
kubectl exec -n $NS deploy/nextcloud -- tail -f /var/www/html/data/nextcloud.log
```

### Nextcloud status

```bash
kubectl exec -n $NS deploy/nextcloud -- php occ status
kubectl exec -n $NS deploy/nextcloud -- php occ check
kubectl exec -n $NS deploy/nextcloud -- php occ app:list
```

### Database check

```bash
kubectl exec -n $NS deploy/nextcloud -- php occ db:add-missing-indices --dry-run
kubectl exec -n $NS deploy/nextcloud -- php occ db:add-missing-columns --dry-run
```

### Maintenance mode

```bash
# Aanzetten
kubectl exec -n $NS deploy/nextcloud -- php occ maintenance:mode --on

# Uitzetten
kubectl exec -n $NS deploy/nextcloud -- php occ maintenance:mode --off
```

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
