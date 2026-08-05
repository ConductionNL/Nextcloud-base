---
last_reviewed: 2026-08-05
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

## MariaDB komt niet op na een herstart

Faalvorm die op 2026-08-04 epe-prod en dinkelland-prod platlegde. Herkenbaar aan:
de mariadb-pod staat `0/1 Running` of `CrashLoopBackOff`, de nextcloud-pod blijft
op `Init:0/1` wachten, en het restart-aantal loopt op met een backoff naar 5
minuten.

### Herkennen

```bash
NS=<tenant>
kubectl -n "$NS" get pod | grep mariadb

# Laatste exit: 137 met reason "Error" = door de kubelet afgeschoten na een
# mislukte liveness probe. Reason "OOMKilled" zou een heel ander probleem zijn.
kubectl -n "$NS" get pod <pod> \
  -o jsonpath='{.status.containerStatuses[?(@.name=="mariadb")].lastState}'

# De beslissende regels: komt er na "Starting shutdown..." nog een
# "Shutdown completed"? Zo niet, dan hangt hij.
kubectl -n "$NS" logs <pod> -c mariadb | \
  grep -E 'Loading buffer|load aborted|Stopping mariadb|Shutdown completed'
```

Bevestiging dat hij hangt en niet werkt: `kubectl top pod -n "$NS"` toont enkele
millicores. Een database die aan het flushen is, verbruikt CPU.

### Oorzaak

De bitnami-entrypoint start mysqld eerst op de achtergrond voor `mysql_upgrade`
en stopt hem ~1 seconde na `ready for connections`. Valt die stop midden in het
laden van de buffer pool uit `ib_buffer_pool`, dan kan de afgebroken load de
shutdown laten deadlocken. Zonder startupProbe geldt alleen
`livenessProbe.initialDelaySeconds` als opstartbudget, dus volgt SIGKILL en
begint dezelfde cyclus opnieuw.

Het is een race, geen zekerheid: dezelfde pod kan er bij een volgende herstart
toevallig wél doorheen komen. Dat verklaart waarom dit jarenlang niemand raakte.

### Verhelpen

Zorg dat `values/db/mariadb.yaml` in de render zit — die zet
`innodb_buffer_pool_load_at_startup=0` en een startupProbe:

```bash
kubectl -n "$NS" get cm <release>-mariadb -o jsonpath='{.data.my\.cnf}' | \
  grep innodb_buffer_pool_load_at_startup
```

Staat de regel er niet, dan draait die tenant niet op de platform-waarden —
controleer of de Application wel door de ApplicationSet beheerd wordt
(`kubectl -n argocd get application <app> -o jsonpath='{.metadata.ownerReferences}'`).
Losse, met de hand gemaakte Applications vallen buiten dit contract.

Noodmaatregel als je niet op een sync kunt wachten: verwijder het verouderde
cache-bestand. Dat is alleen een warme-cache-hint, dus veilig — maar het
exec-venster is klein tijdens een crashloop, dus loop desnoods door tot het lukt:

```bash
until kubectl -n "$NS" exec <pod> -c mariadb -- \
  rm -f /bitnami/mariadb/data/ib_buffer_pool; do sleep 5; done
```

Bij de eerstvolgende nette shutdown wordt dat bestand opnieuw geschreven, dus dit
is geen oplossing — alleen tijdwinst.

### Wat níet werkt

Alleen het opstartbudget verruimen. Een deadlock wordt niet beter van meer tijd;
mysqld staat stil. De startupProbe in `values/db/mariadb.yaml` staat er voor een
ander en ernstiger geval: InnoDB crash recovery van een grote database kan
legitiem langer duren dan het chart-budget van ~150s, en wordt die middenin
afgeschoten dan begint recovery elke ronde opnieuw en komt hij nooit klaar.

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
