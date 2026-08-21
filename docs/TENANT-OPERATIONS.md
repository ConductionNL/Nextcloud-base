---
last_reviewed: 2026-08-21
owner: info@conduction.nl
---

# Tenant-operaties: reset, verwijderen, opnieuw opzetten

Runbooks voor de tenant-levenscyclus. Namespace = de kale tenant-naam
(de Argo Applications heten `nc-<tenant>` en `<tenant>-reactfront`, de
namespace niet).

Eén tenantbestand levert **twee** Applications in dezelfde namespace: de
Nextcloud-app (`nc-<tenant>`, appset `nextcloud-tenants`) en de WOO
PWA-frontend (`<tenant>-reactfront`, appset `react-tenants` in React-base).
Elke operatie hieronder raakt beide.

## Een tenant hernoemen bestaat niet

`tenant.name` is geen label. Drie dingen worden er rechtstreeks uit afgeleid,
en ze verhuizen niet mee:

| Afgeleid uit `tenant.name` | Waar |
|---|---|
| de **namespace** | `nextcloud-tenants.yaml` → `destination.namespace` |
| de **S3-prefix** van de primary storage | `NEXTCLOUD_OBJECTSTORE_PREFIX` = `<naam>/`, hard-coded — er is geen override |
| de **database**, want die staat op een PVC in die namespace | `data-nextcloud-postgresql-0` |

Een naam wijzigen levert dus een **nieuwe, lege tenant** op: nieuwe namespace,
nieuwe PVC's, verse Postgres, en een S3-prefix waar niets in staat. De oude
namespace blijft achter met de PVC's (`preserveResourcesOnDeletion: true`) maar
zonder workload, en de bestanden blijven onder de oude prefix in de bucket.

Dit is op **2026-08-21** gebeurd: `gooisemeren-migrate-prod` werd verwijderd en
`gooisemeren-prod` aangemaakt, twee losse PR's via het webformulier. De
waarschuwing stond alleen als commentaar ín het oude tenantbestand en verdween
mee met de verwijdering — vandaar deze sectie.

Wil je toch een andere naam, dan is het een **migratie**, geen hernoeming:

1. Besluit vooraf wat er met de data gebeurt. Zonder dat besluit niet beginnen.
2. S3: de objecten van de oude prefix naar de nieuwe kopiëren, of de appset een
   prefix-override geven (die bestaat nu niet — dat is een aparte wijziging).
3. Database: dump uit de oude namespace, restore in de nieuwe.
4. Pas daarna het oude tenantbestand verwijderen.

Alleen de **hostname** wijzigen is wél een gewone operatie — zie
`docs/ADDING-TENANT.md` § Cutting Over from a Migration Hostname. Dat raakt de
namespace, de prefix en de database niet.

## Tenant Reset (Data wissen)

Reset een tenant naar een schone staat **zonder** de configuratie te verwijderen.

### Alleen PVCs resetten (snelste methode)

```bash
TENANT=canary
NS=$TENANT

# 1. Scale down de deployment
kubectl scale deployment nextcloud -n $NS --replicas=0
kubectl scale deployment nextcloud-mariadb -n $NS --replicas=0  # indien MariaDB

# 2. Wacht tot pods weg zijn
kubectl wait --for=delete pod -l app.kubernetes.io/name=nextcloud -n $NS --timeout=60s

# 3. Verwijder alle PVCs
kubectl delete pvc --all -n $NS

# 4. Scale up (nieuwe lege PVCs worden aangemaakt)
kubectl scale deployment nextcloud-mariadb -n $NS --replicas=1  # indien MariaDB
kubectl scale deployment nextcloud -n $NS --replicas=1

# 5. Wacht op nieuwe pods
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=nextcloud -n $NS --timeout=300s
```

### Volledige reset inclusief secrets

```bash
TENANT=canary
NS=$TENANT

# 1. Scale down
kubectl scale deployment nextcloud -n $NS --replicas=0
kubectl scale deployment nextcloud-mariadb -n $NS --replicas=0

# 2. Verwijder PVCs en secrets
kubectl delete pvc --all -n $NS
kubectl delete secret nextcloud-secrets -n $NS

# 3. Maak nieuwe secrets aan
kubectl create secret generic nextcloud-secrets \
  --namespace=$NS \
  --from-literal=nextcloud-username=admin \
  --from-literal=nextcloud-password="$(openssl rand -base64 24)" \
  --from-literal=s3-access-key='<YOUR_S3_ACCESS_KEY>' \
  --from-literal=s3-secret-key='<YOUR_S3_SECRET_KEY>' \
  --from-literal=mariadb-root-password="$(openssl rand -base64 24)" \
  --from-literal=mariadb-password="$(openssl rand -base64 24)" \
  --from-literal=redis-password='' \
  --from-literal=nextcloud-secret="$(openssl rand -base64 48)"

# 4. Scale up
kubectl scale deployment nextcloud-mariadb -n $NS --replicas=1
kubectl scale deployment nextcloud -n $NS --replicas=1

# 5. Noteer het nieuwe admin wachtwoord!
kubectl get secret nextcloud-secrets -n $NS -o jsonpath='{.data.nextcloud-password}' | base64 -d
```

## Tenant Volledig Verwijderen

> **De canonieke procedure staat in [REMOVING-TENANT.md](REMOVING-TENANT.md)**
> — inclusief backup, het uit de probe-lijsten halen van de host (verplichte
> stap vóór het verwijderen van het tenantbestand), de frontend, en het
> gereedschap `openwoo-app-config/scripts/cleanup-tenant.sh`. Volg die pagina;
> hieronder staat alleen de verkorte GitOps-variant en het handmatige noodpad.

### Via GitOps (aanbevolen)

```bash
TENANT=canary
NS=$TENANT

# 1. Haal de host van deze tenant eerst uit .github/probe-hosts-*.txt
#    (zie REMOVING-TENANT.md stap 2 — anders breekt de promotieketen)

# 2. Verwijder tenant bestand uit Git
git rm nextcloud-platform/values/tenants/tenant-$TENANT.yaml
git commit -m "chore: remove tenant $TENANT"
# Argo leest GitHub — push naar origin (een merge naar main deployt meteen)
git push origin

# 3. Argo CD verwijdert BEIDE Applications (nc-$TENANT en $TENANT-reactfront).
#    preserveResourcesOnDeletion: true bewaart de RESOURCES, niet de
#    Applications: de namespace, PVCs, secrets, deployments en de
#    frontend-Ingress blijven staan — de frontend serveert dus door.
#    Handmatige cleanup is vereist (zie hieronder).

# 4. Verifieer dat beide Applications weg zijn
kubectl get application -n argocd nc-$TENANT $TENANT-reactfront  # "not found"

# 5. De namespace bestaat NOG — ruim handmatig op indien gewenst
kubectl get ns $NS              # bestaat nog
kubectl delete namespace $NS    # handmatige cleanup (cascade delete)
```

### Handmatig (sneller, maar niet GitOps)

```bash
TENANT=canary
NS=$TENANT

# 1. Verwijder beide Argo CD Applications
kubectl delete application nc-$TENANT -n argocd
kubectl delete application $TENANT-reactfront -n argocd

# 2. Verwijder namespace (cascade delete — Nextcloud én frontend)
kubectl delete namespace $NS

# 3. Verifieer
kubectl get ns $NS
```

**Let op:** Dit verwijdert NIET:
- S3 data (zie [STORAGE-OPERATIONS.md](STORAGE-OPERATIONS.md))
- Database in externe PostgreSQL (indien gebruikt)
- DNS records
- De host in `.github/probe-hosts-accept.txt` / `probe-hosts-live.txt` —
  staat de tenant daarin, dan blijft de promotieketen falen tot je hem
  daar weghaalt

## Tenant Opnieuw Opzetten

### Na handmatige verwijdering

```bash
TENANT=canary

# Canonieke refresh: zet de Argo refresh-annotatie op de ApplicationSet.
# Argo pikt de gewijzigde annotatie op en re-evalueert de generator.
kubectl annotate applicationset nextcloud-tenants -n argocd \
  argocd.argoproj.io/refresh=hard --overwrite

# Idem voor de frontend-appset (React-base), die dezelfde tenantbestanden watcht
kubectl annotate applicationset react-tenants -n argocd \
  argocd.argoproj.io/refresh=hard --overwrite

# Dezelfde annotatie kan op de gegenereerde Application worden gezet:
kubectl annotate application nc-$TENANT -n argocd \
  argocd.argoproj.io/refresh=hard --overwrite

# (CLI-alternatief — vereist de argocd CLI met server-toegang)
argocd app get nc-$TENANT --refresh
```

### Na GitOps verwijdering

```bash
TENANT=canary
NS=$TENANT

# 1. Herstel of maak nieuw tenant bestand
cp nextcloud-platform/values/templates/tenant-template.yaml \
   nextcloud-platform/values/tenants/tenant-$TENANT.yaml

# 2. Pas configuratie aan
# Edit nextcloud-platform/values/tenants/tenant-$TENANT.yaml

# 3. Maak secret aan VOORDAT je commit
kubectl create namespace $NS
kubectl create secret generic nextcloud-secrets \
  --namespace=$NS \
  --from-literal=nextcloud-username=admin \
  --from-literal=nextcloud-password="$(openssl rand -base64 24)" \
  --from-literal=s3-access-key='<YOUR_S3_ACCESS_KEY>' \
  --from-literal=s3-secret-key='<YOUR_S3_SECRET_KEY>' \
  --from-literal=mariadb-root-password="$(openssl rand -base64 24)" \
  --from-literal=mariadb-password="$(openssl rand -base64 24)" \
  --from-literal=redis-password='' \
  --from-literal=nextcloud-secret="$(openssl rand -base64 48)"

# 4. Commit en push (Argo leest GitHub)
git add nextcloud-platform/values/tenants/tenant-$TENANT.yaml
git commit -m "feat: add tenant $TENANT"
git push origin

# 5. Noteer admin wachtwoord
kubectl get secret nextcloud-secrets -n $NS -o jsonpath='{.data.nextcloud-password}' | base64 -d
```
