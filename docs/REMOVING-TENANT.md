---
last_reviewed: 2026-08-10
owner: info@conduction.nl
---

# Removing a Tenant

Deze guide beschrijft hoe je een tenant veilig verwijdert van het platform.
Dit is de **canonieke verwijderprocedure**; andere pagina's verwijzen hierheen.

## ⚠️ Belangrijke Waarschuwing

Het verwijderen van een tenant is **permanent**. Zorg dat je:

1. Backup hebt van alle data (zie [Backup sectie](#1-backup-maken))
2. Gebruikers hebt geïnformeerd
3. Zeker weet dat je de juiste tenant verwijdert

## Eén tenantbestand, twee Applications

Het tenantbestand voedt **twee** ApplicationSets, en dus twee Applications in
dezelfde namespace (`$TENANT`):

| Application | ApplicationSet | Repo | Volgt ref |
|---|---|---|---|
| `nc-$TENANT` | `nextcloud-tenants` | Nextcloud-base | `release` |
| `$TENANT-reactfront` | `react-tenants` | React-base | `HEAD` (main) |

Beide zetten `preserveResourcesOnDeletion: true`. Die vlag bewaart de
**resources**; de **Application zelf wordt wél verwijderd** door de
appset-controller zodra het tenantbestand uit de generator valt. Na stap 4 zijn
dus beide Applications weg, terwijl het Nextcloud-Deployment én het
frontend-Deployment + Ingress gewoon blijven draaien — **de frontend serveert
verkeer door** tot iemand opruimt. Zie `React-base/docs/ADDING-TENANT.md`.

---

## Overzicht Stappen

```
┌─────────────────────────────────────────────────────────────────┐
│                    Tenant Verwijderen                            │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  1. Backup maken (data + database)                              │
│                    ↓                                             │
│  2. Host uit .github/probe-hosts-*.txt halen  ← eerst!           │
│                    ↓                                             │
│  3. Tenant file verwijderen uit Git                             │
│                    ↓                                             │
│  4. Commit & Push                                                │
│                    ↓                                             │
│  5. Wachten tot Argo CD BEIDE Applications verwijdert           │
│     (nc-$TENANT én $TENANT-reactfront)                           │
│                    ↓                                             │
│  6. Handmatig namespace opruimen (Nextcloud + frontend)         │
│                    ↓                                             │
│  7. S3 data opruimen (optioneel)                                │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

Voor stap 5-7 bestaat gereedschap: **`openwoo-app-config/scripts/cleanup-tenant.sh`**
(andere repo). Het inventariseert wat er nog staat, verwijdert beide
Applications en de namespace, en werkt **plan-eerst**: zonder `--execute`
verandert het niets en lees je eerst wat er zou gebeuren.

```bash
# plan tonen (verandert niets)
./scripts/cleanup-tenant.sh --tenant $TENANT

# daadwerkelijk opruimen, met bevestiging
./scripts/cleanup-tenant.sh --tenant $TENANT --execute
```

Het script ruimt géén S3-data, DNS-records of handmatig gezaaide TLS-secrets op.

---

## Stap-voor-stap

### 1. Backup Maken

**Database backup:**

```bash
TENANT=<tenant-naam>

# MariaDB
kubectl exec -n $TENANT deploy/nextcloud-mariadb -- \
  mysqldump -u nextcloud -p nextcloud > backup-$TENANT-db-$(date +%Y%m%d).sql

# Of voor PostgreSQL — in-cluster Bitnami PostgreSQL in de tenant-namespace zelf.
# Er is GEEN gedeelde pgbouncer en GEEN per-tenant database-naam: values/db/postgres.yaml
# zet externalDatabase.enabled: false en auth.database/username op "nextcloud".
# De StatefulSet heet nextcloud-postgresql (releaseName "nextcloud" + subchart "postgresql").
kubectl exec -n $TENANT statefulset/nextcloud-postgresql -- \
  sh -c 'PGPASSWORD="$(cat /opt/bitnami/postgresql/secrets/db-password)" \
    pg_dump -h 127.0.0.1 -U "$POSTGRES_USER" "$POSTGRES_DATABASE"' \
  > backup-$TENANT-db-$(date +%Y%m%d).sql
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

### 2. Host uit de Probe-lijsten Halen

**Doe dit vóór stap 3, in dezelfde commit of eerder.**

`.github/probe-hosts-accept.txt` en `.github/probe-hosts-live.txt` bevatten een
steekproef van échte tenants. `.github/workflows/promote-tenant-changes.yaml`
leest beide lijsten (regel 97-99) en eist dat **álle** hosts erin HTTP 200 met
`"installed":true` geven. Faalt er één, dan draait de workflow de promotie terug
met `git push --force-with-lease` op `release` én `release-accept` (regel
147-151) en maakt een issue aan.

Een tenant verwijderen zonder hem eerst uit de lijst te halen betekent dus: de
host verdwijnt, de probe faalt, en **de promotieketen breekt voor iedereen** —
niet alleen voor jouw tenant.

```bash
# Welke host hoort bij deze tenant? Standaard <org>.<env>.commonground.nu
# (of <org>.commonground.nu voor prod), tenzij het tenantbestand
# tenant.hostname zet. Zie de appset-template.
grep -rn "$TENANT" .github/probe-hosts-accept.txt .github/probe-hosts-live.txt
```

Staat de host erin, haal hem eruit en zet er zo nodig een andere tenant met
dezelfde database-engine voor terug — de lijsten zijn bewust een steekproef per
engine. `scripts/verify.sh` bewaakt dat elke host in de lijsten bij een bestaand
tenantbestand hoort en faalt anders.

### 3. Tenant File Verwijderen

Verwijder het tenant values bestand:

```bash
git rm nextcloud-platform/values/tenants/tenant-$TENANT.yaml
```

De `nextcloud-tenants` ApplicationSet gebruikt een glob-generator
(`path: "nextcloud-platform/values/tenants/tenant-*.yaml"`), dus er is **geen
per-tenant `files` lijst** die je hoeft aan te passen. Het verwijderen van het
`tenant-$TENANT.yaml` bestand is voldoende om de tenant uit de generator te halen.

### 4. Commit en Push

```bash
git add -A
git commit -m "chore: remove tenant $TENANT"
git push origin main
```

### 5. Wachten op Argo CD

Argo CD verwijdert nu **beide** Applications — de Nextcloud-app en de
WOO PWA-frontend:

```bash
# Volg beide Applications
kubectl get application -n argocd -w \
  nc-$TENANT $TENANT-reactfront

# Of via Argo CD CLI
argocd app get nc-$TENANT
argocd app get $TENANT-reactfront
```

De Applications heten `nc-$TENANT` en `$TENANT-reactfront`, maar de namespace is
in beide gevallen de kale tenant-naam (`$TENANT`).

De Applications verdwijnen, maar de **resources blijven bestaan**
(`preserveResourcesOnDeletion: true`). Let op de timing: `nc-$TENANT` volgt
`release` en `$TENANT-reactfront` volgt `HEAD`, dus de frontend-Application
verdwijnt meestal éérder — al na de merge naar `main`, terwijl de
Nextcloud-Application pas na promotie naar `release` weggaat.

### 6. Namespace Opruimen (Nextcloud én Frontend)

Nu de Applications weg zijn, ruim handmatig de namespace op. **Zolang je dit
niet doet, blijft het frontend-Deployment draaien en blijft de Ingress verkeer
serveren op de publieke host** — een tenant die "verwijderd" heet maar gewoon
online staat.

Aanbevolen: `openwoo-app-config/scripts/cleanup-tenant.sh --tenant $TENANT`
(eerst zonder `--execute` voor het plan). Handmatig:

```bash
TENANT=<tenant-naam>

# Check wat er nog is — let expliciet op de frontend
kubectl get all -n $TENANT
kubectl get ingress -n $TENANT          # frontend + Nextcloud
kubectl get pvc -n $TENANT
kubectl get secrets -n $TENANT

# Als alles klopt, verwijder de namespace (haalt beide workloads weg)
kubectl delete namespace $TENANT
```

**Let op:** Dit verwijdert:
- Alle pods (Nextcloud, database én de WOO PWA-frontend)
- Alle PVCs (inclusief database data!)
- Alle secrets
- Alle Ingresses — pas hierna stopt de frontend met verkeer serveren
- Alle andere resources in de namespace

external-dns ruimt het DNS-record op zodra de Ingress weg is.

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

Beide ApplicationSets hebben `preserveResourcesOnDeletion: true` als safety
feature:

```yaml
# In nextcloud-platform/argo/applicationsets/nextcloud-tenants.yaml
# én in React-base react-platform/argo/applicationsets/react-tenants.yaml
spec:
  syncPolicy:
    preserveResourcesOnDeletion: true
```

**Wat de vlag wél en niet doet:** hij bewaart de *resources* die de Application
heeft uitgerold. De *Application zelf* wordt gewoon door de appset-controller
verwijderd zodra het tenantbestand uit de generator valt. Het is dus geen slot
op de Application, maar een slot op de data.

Dit voorkomt dat:
- Per ongeluk user data verdwijnt door een fout in Git
- Een verkeerde commit productiedata verwijdert
- Data verloren gaat voordat backup is gemaakt

**Handmatig opruimen is bewust een extra stap** zodat je zeker weet wat je doet.
De keerzijde: de frontend blijft verkeer serveren tot die stap gezet is.

---

## Snelle Referentie

```bash
TENANT=mijn-tenant

# 1. Backup (MariaDB-voorbeeld; zie stap 1 voor het PostgreSQL-commando)
kubectl exec -n $TENANT deploy/nextcloud-mariadb -- mysqldump -u nextcloud -p nextcloud > backup.sql
kubectl get secret nextcloud-secrets -n $TENANT -o yaml > secrets-backup.yaml

# 2. Host uit de probe-lijsten halen — ANDERS BREEKT DE PROMOTIEKETEN
grep -rn "$TENANT" .github/probe-hosts-accept.txt .github/probe-hosts-live.txt
# staat hij erin: verwijderen (en zo nodig vervangen door een andere tenant
# met dezelfde database-engine) in dezelfde commit of eerder

# 3. Git (alleen het tenant-bestand verwijderen; de glob-generator regelt de rest)
git rm nextcloud-platform/values/tenants/tenant-$TENANT.yaml
git commit -m "chore: remove tenant $TENANT"
git push origin main

# 4. Wacht tot BEIDE Applications weg zijn
kubectl get application -n argocd nc-$TENANT $TENANT-reactfront

# 5. Opruimen (namespace is de kale tenant-naam; hierna pas stopt de frontend)
#    Aanbevolen: openwoo-app-config/scripts/cleanup-tenant.sh --tenant $TENANT
#    (zonder --execute is dat een plan, geen wijziging)
kubectl delete namespace $TENANT

# 6. S3 (optioneel)
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
# Handmatig verwijderen — vergeet de frontend-Application niet
kubectl delete application nc-$TENANT -n argocd
kubectl delete application $TENANT-reactfront -n argocd

# Of via Argo CD CLI
argocd app delete nc-$TENANT
argocd app delete $TENANT-reactfront
```

### Frontend serveert nog verkeer na verwijdering

Verwacht gedrag zolang stap 6 niet gezet is: `preserveResourcesOnDeletion`
bewaart het Deployment en de Ingress. Controleer en ruim op:

```bash
kubectl get deploy,svc,ingress -n $TENANT -l app.kubernetes.io/part-of=react-platform
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
- `openwoo-app-config/scripts/cleanup-tenant.sh` - opruimgereedschap (plan-eerst)
- `React-base/docs/ADDING-TENANT.md` - frontend aan/uit en het `tenant.frontend:`-blok

