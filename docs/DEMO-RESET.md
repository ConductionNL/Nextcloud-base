---
last_reviewed: 2026-10-14
owner: info@conduction.nl
---

# Demo-reset: een demo-tenant elke nacht terug naar een vaste stand

Een openbare demo vult zich met wat bezoekers maken: accounts, verzoeken,
dossiers, uploads. Met `tenant.components.demoReset` zet je zo'n tenant elke
nacht terug naar een gouden momentopname. Daarna laadt hij de voorbeeldsets
opnieuw, zodat relatieve datums weer vanaf vandaag tellen.

> **Dit wist elke nacht alles wat bezoekers maakten.** Zet het alleen aan op een
> demo-tenant. De validator en de chart eisen daarom dat
> `confirmWipe` letterlijk de tenantnaam herhaalt.

## Hoe het werkt

Een eigen ApplicationSet, `nextcloud-tenant-demo-reset`, rendert
`charts/tenant-demo-reset` in de namespace van de tenant. Dat gebeurt alleen
voor een tenant met `components.demoReset.enabled: true`. Voor de rest van de
vloot levert hij niets op. De bestaande `nc-<tenant>`-Applications veranderen
niet; zie de toelichting in de ApplicationSet voor waarom dit geen vierde
source is.

De chart levert vijf dingen:

| Resource | Wat |
|---|---|
| ServiceAccount, Role, RoleBinding `demo-reset` | Pods vinden en er een commando in starten (`pods` get/list, `pods/exec`). Niets anders, niets buiten de namespace. |
| ConfigMap `demo-reset-script` | Het script, `charts/tenant-demo-reset/files/demo-reset.sh`. |
| CronJob `demo-reset` | De nachtelijke reset. Standaard 04:15 Europe/Amsterdam. |
| CronJob `demo-reset-golden` | De momentopname. Draait nooit vanzelf; een mens vuurt hem af. |

De Job doet alles via `kubectl exec` in de pods die er al staan. occ draait in
de Nextcloud-container, psql in de Postgres-container. Zo draaien ze altijd in
de versie die de tenant zelf draait. De Job heeft geen databasewachtwoord en
geen netwerkpad naar Postgres nodig.

### Wat de momentopname is

| Deel | Waar | Hoe terug |
|---|---|---|
| Database | `nextcloud_demo_golden` in de eigen Postgres, als template, zonder connecties | `CREATE DATABASE ... TEMPLATE`, dan twee renames. Een bestandskopie op de server. |
| Datamap | `/var/www/demo-reset/golden/data` op de PVC `nextcloud-nextcloud` | Live-inhoud weg, kopie terug. |

`/var/www/` is de subPath `root` van de Nextcloud-chart. Die valt buiten de
codeboom die de image bij een upgrade met rsync overschrijft.

### Wat niet wordt teruggezet

| Wat | Waarom |
|---|---|
| `config/` | instanceid, passwordsalt en secret blijven van de draaiende tenant. De reset weigert een momentopname met een andere instanceid. |
| `custom_apps/` en `data/.conduction-apps-state` | Die zijn van de install-hook. Is een app na de momentopname nieuwer, dan volgt `occ upgrade`. |
| `nextcloud.log*`, `audit.log`, `conduction-apps.log` | Logs horen bij de draaiende tenant, niet bij de demo-stand. |

### Redis

De tenant gebruikt de gedeelde platform-Redis. Een `FLUSHALL` zou elke tenant
raken. De reset draait daarom `occ memcache:distributed:clear`. Dat wist alleen
de sleutels met de prefix van deze instantie (instanceid plus app-versies). Het
moet na `maintenance:mode --off`, want in onderhoudsmodus rekent Nextcloud met
een andere prefix.

De lokale cache (APCu) leeft in de php-fpm-master. De reset herlaadt php-fpm
(`kill -USR2 1`) zodat die leeg begint.

## Aanzetten

In het tenantbestand:

```yaml
tenant:
  name: zuiddrecht-prod
  dbType: postgres
  components:
    demoReset:
      enabled: true
      confirmWipe: zuiddrecht-prod
      exampleSets:
        - zuiddrecht
```

| Sleutel | Verplicht | Default | Betekenis |
|---|---|---|---|
| `enabled` | ja | | `true` of `false`, zonder aanhalingstekens. |
| `confirmWipe` | als `enabled: true` | | Letterlijk `tenant.name`. |
| `schedule` | nee | `15 4 * * *` | Cron met vijf velden, in Europe/Amsterdam. |
| `paused` | nee | `false` | `true` zet de nachtelijke CronJob stil. |
| `exampleSets` | nee | leeg | Sets voor `occ openregister:example-set:install`. Vraagt `openregister` in `apps.enabled`. |
| `exampleSetMode` | nee | `install` | `install` of `reinstall` (eerst `example-set:remove`). |
| `exampleSetPasswordSecret` | nee | | Naam van een Secret in de namespace met sleutel `demo-password`. Dan krijgt install `--password-from-env`; het wachtwoord gaat via stdin. |

De validator weigert: een onbekende sleutel, `enabled` als tekst, een andere
`confirmWipe`, `dbType` anders dan postgres, `tenant.canary: true` (S3), een
ongeldig schema, en sets zonder openregister.

### install of reinstall

`example-set:install` laat objecten die er al staan met rust ("kept"). Hun
datums schuiven dan niet op. Kies dus een van twee:

- **Momentopname vóór het laden, `install`.** De momentopname bevat de tenant
  met apps en instellingen, zonder voorbeeldset. Elke nacht laadt de reset de
  set vers, met datums vanaf vandaag. De eerste handmatige reset is de
  gecontroleerde lading.
- **Momentopname na het laden, `reinstall`.** De reset verwijdert de set en
  laadt hem opnieuw. Dit leunt op `example-set:remove`.

## De gouden momentopname nemen

Dit doet een mens, na een stand die klopt.

```bash
NS=zuiddrecht-prod
kubectl create job -n "$NS" --from=cronjob/demo-reset-golden "demo-reset-golden-$(date +%Y%m%d%H%M)"
kubectl logs -n "$NS" -f job/demo-reset-golden-<tijd>
```

De tenant staat een paar minuten in onderhoudsmodus. De Job weigert als de
tenant al in onderhoud staat. Een nieuwe momentopname vervangt de vorige pas als
hij compleet is.

## Wat er 's nachts gebeurt

1. Controles, voordat er iets verandert: precies één Nextcloud- en één
   Postgres-pod, geen andere demo-reset-Job, een complete momentopname, dezelfde
   instanceid, database en map van hetzelfde moment, geen S3 primary storage.
2. Onderhoudsmodus aan. Wachten tot een lopende `cron.php` klaar is.
3. `nextcloud_demo_incoming` maken uit de gouden database.
4. Vanaf hier is het onomkeerbaar. Live database wordt `..._previous`,
   incoming wordt live, previous gaat weg.
5. Datamap leeg (behalve logs en hook-state), kopie terug.
6. php-fpm herladen. `occ upgrade` als de app-code nieuwer is.
7. Onderhoudsmodus uit. `occ memcache:distributed:clear`.
8. Per set `occ openregister:example-set:install <set>`.
9. Eindcontrole: `occ status` en `status.php` via de service.
   `/var/www/demo-reset/last-reset` krijgt tijd en momentopname-id.

## Controleren of het werkte

```bash
NS=zuiddrecht-prod
kubectl get cronjob -n "$NS" demo-reset          # LAST SCHEDULE, SUSPEND
kubectl get jobs -n "$NS" -l app.kubernetes.io/name=tenant-demo-reset
kubectl logs -n "$NS" job/<laatste-job>           # eindigt met "klaar"
kubectl exec -n "$NS" deploy/nextcloud -c nextcloud -- cat /var/www/demo-reset/last-reset
```

## Als het misgaat

| Waar het faalt | Wat je ziet | Wat je doet |
|---|---|---|
| Bij een controle (stap 1) | Job `Failed`, melding eindigt op "Er is niets gewist." | De oorzaak staat in de melding. De tenant draait door. |
| Vóór stap 4 | "onderhoudsmodus gaat weer uit" | Niets; de tenant draait door zoals hij was. |
| Ná stap 4 | "de onderhoudsmodus BLIJFT AAN" | Start de reset opnieuw, zie hieronder. De momentopname is niet aangeraakt. |
| Bij het laden van een set (stap 8) | Job `Failed`, tenant in de lucht op de momentopname | Lees de occ-uitvoer in de log. Datums staan op de momentopname tot de volgende run. |

De reset met de hand starten:

```bash
kubectl create job -n "$NS" --from=cronjob/demo-reset "demo-reset-handmatig-$(date +%Y%m%d%H%M)"
```

De Job herhaalt zichzelf niet (`backoffLimit: 0`). Een tweede poging direct na
een fout raakt meestal dezelfde fout.

## Uitzetten en weghalen

Uitzetten: `paused: true` in het tenantbestand. De CronJob staat dan stil en de
momentopname blijft.

Weghalen gaat in drie stappen, want deze ApplicationSet heeft
`preserveResourcesOnDeletion: true`. Haal je alleen het blok weg, dan blijft de
CronJob staan en draait hij door.

1. Eerst `paused: true`, laten syncen.
2. Dan het blok `components.demoReset` weghalen.
3. Een mens ruimt op:

```bash
NS=zuiddrecht-prod
kubectl delete cronjob,role,rolebinding,serviceaccount,configmap -n "$NS" -l app.kubernetes.io/name=tenant-demo-reset
kubectl exec -n "$NS" deploy/nextcloud -c nextcloud -- rm -rf /var/www/demo-reset
kubectl exec -n "$NS" nextcloud-postgresql-0 -c postgresql -- sh -c \
  'PGPASSWORD="$(cat "$POSTGRES_POSTGRES_PASSWORD_FILE")" psql -h 127.0.0.1 -U postgres -d postgres \
   -c "ALTER DATABASE nextcloud_demo_golden WITH IS_TEMPLATE false" -c "DROP DATABASE nextcloud_demo_golden"'
```

## Voorwaarden op het cluster

- **De ApplicationSet moet er komen.** `argo/` heeft geen `automated`; een mens
  synct `nextcloud-platform-bootstrap` na de merge.
- **Het image `alpine/k8s:1.29.2`** moet te pullen zijn. Het is hetzelfde image
  als de credential-refresh CronJob in cluster-infra.
- **De AppProject `nextcloud-platform`** staat Role en RoleBinding al toe
  (sinds 2026-08-07) en CronJob via `batch`. Geen wijziging nodig.
- **Ruimte in Postgres.** Tijdens een reset staan er drie kopieën van de
  database: gouden, live en incoming. De PVC is 8Gi.
- **Ruimte op de Nextcloud-PVC.** De datamap staat er twee keer op.

## Grenzen

- Alleen `dbType: postgres`. De momentopname is een Postgres-template.
- Alleen een lokale datamap. Een tenant met een S3 primary objectstore
  (`canary-overrides.yaml`) stopt de reset voordat er iets gewist is. Met S3 zou
  een teruggezette database naar objecten wijzen die er niet meer zijn.
- Eén Nextcloud-pod. `replicaCount: 1` in prod; bij twee stopt de reset.
- Ingelogde bezoekers zijn na de reset uitgelogd. Hun inlogtokens stonden in de
  database, en die is teruggezet.

## Waarom zo, en niet anders

| Alternatief | Waarom niet |
|---|---|
| CNPG-backup en restore naar een tijdstip | Tenants draaien op de Bitnami-Postgres van de Nextcloud-chart, niet op CNPG. Zie `CNPG-MIGRATIE.md`. |
| `pg_dump` en `pg_restore` van een gouden dump | Werkt, maar trager, en de dump moet ergens staan. Een template-database is een bestandskopie op dezelfde server. |
| VolumeSnapshot van de PVC's | Er is geen werkende VolumeSnapshotClass (`CNPG-MIGRATIE.md` §4). En het terugzetten vraagt de PVC weg te halen, met Argo-drift als gevolg. |
| Een gouden prefix in S3 terugkopiëren | De bestanden van een gewone tenant staan niet in S3 maar op de PVC. |
