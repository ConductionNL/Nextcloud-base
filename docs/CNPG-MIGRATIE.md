---
last_reviewed: 2026-08-04
owner: info@conduction.nl
---

# WP4 — Migratieplan losse Postgres → CNPG

Opgesteld 2026-08-04 op basis van metingen op con-prod
(`garden-wh2mnkj--con-prod-external`). Het cluster is live; alle cijfers zijn
momentopnamen van die dag.

> **Herkomst.** MCP `conduction-docs` heeft **geen** CNPG-migratieprocedure. De
> enige treffers zijn `KeyCloak/ARCHITECTURE.md` (CNPG via OLM/Helm, werkende
> referentie-opstelling, `last_reviewed` 2026-07-06, owner info@conduction.nl) en
> `Nextcloud-base/docs/DATABASE.md` § *Using CloudNativePG Operator*, dat
> zichzelf markeert als *"Aspirational / not implemented"*. Er is dus niets om
> tegen af te stemmen — dat is een gat in de documentatie, geen zoekfout.

## 1. Samenvatting en advies

**Migreer niet op grond van kosten.** Die claim is gemeten en houdt geen stand
(§2). En de tweede kandidaat-reden is er ook niet: **dataveiligheid is hier geen
as.**

Uitgangspunt, vastgesteld 2026-08-04: de databases bevatten afgeleide toon-data.
Het platform haalt op bij de bron en toont alleen; de bron houdt de bewaarplicht.
Er is daarom geen backup-, PITR- of retentie-eis. Databaseverlies is een
**beschikbaarheidsprobleem** — opnieuw inrichten en opnieuw ophalen — geen
gegevensverlies.

Daarmee blijft één reden over: **operationeel gemak.** Minder objecten om te
beheren, upgrades door een operator in plaats van 58 keer handwerk, één plek voor
tuning. Dat is een legitieme reden, maar het is een reden van een andere orde dan
kosten of dataveiligheid, en hij moet ook zo behandeld worden: de winst is
beheerslast, en de prijs is blast radius (§6, F2).

Het advies is daarom niet "nee", maar: **kwantificeer eerst de beheerslast die je
wint, en accepteer expliciet de hersteltijd die je inruilt.** Dit plan is
uitvoerbaar, maar niet vóór de poorten in §5 dicht zijn — die zijn geen
formaliteit, want het prototype is er al één keer op gesneuveld (§3).

## 2. Waarom de kostenclaim weg is

Gemeten over 14 dagen (Prometheus-retentie is 15d; `[30d]`-windows leveren stil
afgekapte data).

| | som van individuele pieken | piek van de som | consolidatiewinst |
|---|---|---|---|
| memory | 7,54 GiB | 3,14 GiB | 4,41 GiB (58%) |
| cpu | 3,32 cores | 1,16 cores | 2,16 cores (65%) |

Percentueel mooi, absoluut verwaarloosbaar: **4,4 GiB RAM en 2,2 cores** is de
volledige multiplexing-winst over 58 tenants. Ter vergelijking: het cluster heeft
1310 GiB en 271 cores allocatable.

De twee posten die er wél waren, zijn met WP1–WP3 al geadresseerd zónder
migratie:

- **Requests:** 30 GiB en 30 cores aan reservering bleek een neveneffect van een
  limits-only-blok in `values/common.yaml`. Opgelost in commit `d76e443`
  (requests worden nu expliciet gezet). Na hersync: ~14 GiB en ~3 cores.
- **Storage:** 145 volumes opgeruimd. Vergt geen migratie. Zie de correctie
  hieronder voor wat dat werkelijk oplevert.

### Nominale versus gefactureerde capaciteit — correctie

De oorspronkelijke inventarisatie noemde **2280 GiB opruimbaar**. Dat cijfer is te
hoog, en de reden is de moeite waard omdat hij op elke storage-meting in dit
cluster van toepassing is.

Er zijn twee soorten storageclasses, en alleen de eerste kost geld:

| provisioner | classes | betekenis |
|---|---|---|
| `cinder.csi.openstack.org` | `default`, `tier-1`, `tier-2`, `cinder-rwx` | echte OpenStack-volumes — dit staat op de factuur |
| `cluster.local/nfs-server-provisioner` | `nfs`, `nfs-v4` | submappen op één NFS-server-pod |

De NFS-provisioner handhaaft **geen quota**: de `capacity` van een NFS-PVC is een
nominaal getal, geen reservering. Die volumes leven allemaal op één Cinder-volume
van 500Gi (`data-nfs-server-provisioner-0` in namespace `default`), en dat volume
blijft 500Gi hoe veel NFS-PVC's je ook aanmaakt of weggooit.

Uitkomst van de opruiming van 2026-08-04 — 145 PV's verwijderd:

| soort | PV's | GiB | daadwerkelijk vrijgemaakt |
|---|---|---|---|
| Cinder | 65 | 1045 | **ja — 1045 GiB** |
| NFS | 80 | 1080 | nee, nominaal |

**De werkelijke besparing is dus ~1045 GiB, niet 2280.** Elke PVC-gebaseerde
storagetelling in dit cluster (inclusief de 9705 GiB die eerder als totaal
provisioned is gerapporteerd) telt nominale NFS-capaciteit mee en overschat
daarmee de factuur. Splits op provisioner voordat je een storagecijfer aan een
besluit hangt.

### De storage-vergelijking eerlijk gemaakt

Op papier lijkt consolidatie storage te sparen: 58 × 8Gi = 464 GiB provisioned
voor 14,4 GiB werkelijke data, tegenover 3 × 50Gi = 150 GiB voor een CNPG-cluster.
Dat is ~314 GiB winst.

Die winst verdampt zodra je de alternatieve route meeneemt: de losse PVC's
right-sizen naar bijvoorbeeld 2Gi geeft 116 GiB — *minder* dan de CNPG-variant.
Beide routes vereisen het hercreëren van volumes, want een PVC kan niet krimpen
(`allowVolumeExpansion: true` is eenrichtingsverkeer). Consolidatie wint hier dus
niet; het is een andere manier om hetzelfde volume-hercreëerwerk te doen.

**Conclusie:** er is na WP3 geen kostenargument meer over. Wat overblijft is
functionaliteit.

## 3. Wat de prototype-storing ons leert

Het beoogde doelwit bestaat al en is dood. Dit is de belangrijkste input voor dit
plan.

`nextcloud-pg` in namespace `nextcloud-platform`, aangemaakt ~62 dagen geleden,
beheerd door Argo-app `platform-postgres`, gedeclareerd in
`nextcloud-platform/platform/postgres/cluster.yaml`:

| | waarde |
|---|---|
| `spec.instances` | 3 (0 ready) |
| image | `ghcr.io/cloudnative-pg/postgresql:17.2` |
| storage | 50Gi per instance |
| `spec.backup` | **afwezig** |
| bootstrap | `initdb`, `database: postgres` |
| resources | requests 250m/512Mi, limits 2/2Gi — correct, mét requests |
| affinity | `podAntiAffinityType: preferred`, per zone |
| CNPG-operator | 1.25.0 |

De faalreden, letterlijk uit `status.phaseReason`:

> One or more instances were previously created, but no PersistentVolumeClaims
> (PVCs) exist. The cluster is in an unrecoverable state. To resolve this,
> restore the cluster from a recent backup.

Het door de operator voorgeschreven herstelpad — *restore from a recent backup* —
bestond niet, want `spec.backup` was nooit geconfigureerd. Er zat geen tenantdata
in (bootstrap `initdb`, nooit in gebruik genomen; geen enkel tenantbestand
verwijst naar `nextcloud-pg`), dus de schade bleef bij verloren tijd.

Drie lessen, elk direct omgezet in een poort in §5:

1. **Een gedeelde database zonder werkende restore is geen gedeelde database.**
   Dit is precies de faalmodus die 58 losse pods *niet* hebben: daar kost het
   verlies van één PVC één tenant, niet alle.
2. **Argo verbergt dit.** De app staat op `sync=Synced`, `health=Suspended`. Een
   onherstelbare database leest in de GitOps-console dus als in-orde. Niemand
   werd gewaarschuwd, 62 dagen lang.
3. **`prune: true` + `selfHeal: true` op een app met PVC's onder
   `reclaimPolicy: Delete` is een datavernietigingspad.** De app heeft beide aan.
   Wat de PVC's precies heeft weggehaald is niet vastgesteld — de events zijn
   verlopen — maar deze combinatie is een plausibele route en moet in elk geval
   afgedekt zijn voordat er tenantdata op staat.

## 4. Wat de drijfveer wél en niet is

| As | Wat CNPG brengt | Weegt dit hier? |
|---|---|---|
| **Backups / PITR** | WAL-archivering naar S3, `ScheduledBackup`, herstel op tijdstip | **Nee.** Geen bewaarplicht op het platform; data komt van de bron. |
| **Gegevensverlies** | Bescherming tegen corruptie/verlies | **Nee.** Verlies = opnieuw ophalen, geen onherstelbare schade. |
| **Hersteltijd na verlies** | Restore in minuten i.p.v. opnieuw ophalen | **Ja** — maar dit is een *nieuwe* afhankelijkheid, zie hieronder. |
| **HA / failover** | Primary + replica, automatische failover | Alleen als er een beschikbaarheidsnorm is. Nu niet benoemd. |
| **Rolling updates / beheer** | Operator-gestuurd i.p.v. 58× handwerk | **Ja — dit is de eigenlijke drijfveer.** |

### De as die overblijft: hersteltijd

Omdat er geen backup-eis is, wordt herstel na verlies gelijk aan *opnieuw
inrichten en opnieuw ophalen bij de bron*. Dat is nu goedkoop omdat het per tenant
gaat: één kapotte PVC raakt één gemeente. Na consolidatie raakt hetzelfde
incident alle tenants op dat cluster tegelijk.

Daarmee verschuift de vraag van "hoeveel data verlies ik" naar **"hoe lang duurt
het om N tenants opnieuw op te halen, en is dat geautomatiseerd?"** Dat is de
enige harde vraag die dit plan blokkeert, en hij is meetbaar in plaats van
politiek. Zonder antwoord is F2 niet te beoordelen.

Twee dingen om vóór §6 vast te stellen:

1. **Is de her-ingest geautomatiseerd en getest?** Zo ja: hoe lang per tenant, en
   hoe lang voor een heel cluster? Zo nee: dan is de her-ingest zélf het
   herstelpad dat eerst moet bestaan — niet een backup.
2. **Hoeveel beheerslast win je echt?** Tel het concreet: hoeveel handelingen
   kostte de laatste Postgres-upgrade over 58 tenants, en wat zou dezelfde
   upgrade op 1–3 CNPG-clusters kosten? Zonder dat getal is "operationeel gemak"
   een gevoel, en dan staat er niets tegenover de blast radius.

### De backup-situatie, geverifieerd

Cluster-breed gecontroleerd op 2026-08-04:

- `ScheduledBackup` / `Backup` CR's (CNPG): **geen**
- Velero of een andere backup-operator: **geen namespace aanwezig**
- CronJobs die een `pg_dump`/`mysqldump` doen: **geen**
- `VolumeSnapshot`: **één**, en die is stuk —
  `helmond/helmond-mariadb-snap-20260211`, aangemaakt 2026-02-11, met
  `volumeSnapshotClassName: <VUL_HIER_CLASS_IN>` en als status
  *"Failed to get snapshot class with error volumesnapshotclass
  `<VUL_HIER_CLASS_IN>` not found"*.

Dat er geen backups zijn is, gegeven §1, **geen bevinding en geen probleem** — het
is een bewuste consequentie van "ophalen bij de bron, alleen tonen". Het staat
hier alleen vastgelegd zodat niemand later concludeert dat het een omissie was.

De kapotte VolumeSnapshot is wél een bevinding, maar om een andere reden: een
template-placeholder (`<VUL_HIER_CLASS_IN>`) is als echte resource aangemaakt en
heeft daarna 173 dagen stil gefaald zonder dat iemand het merkte. Dat is hetzelfde
patroon als het secret-template-incident van 2026-07-13 (een voorbeeldbestand dat
applybaar was), en het bevestigt §3, les 2: **er is niets dat stille storing in de
databaselaag opmerkt.** Dat blijft relevant ná consolidatie, want dan is één
stille storing er één met N tenants erachter. Poort P3 dekt dit.

## 5. Poorten — geen tenantdata voordat alle vier dicht zijn

Elke poort is aantoonbaar af te tekenen. Geen enkele mag "later".

**P1 — Een getest herstelpad. Backup is daarvoor niet de enige route.**
Omdat er geen backup-eis is (§1, §4), gaat deze poort niet over backups maar over
de vraag: *als dit cluster morgen zijn PVC's kwijt is, hoe komen N tenants dan
terug, en hoe lang duurt dat?* Twee legitieme antwoorden:

- **Geautomatiseerde her-ingest.** Aantoonbaar: één tenant volledig opnieuw
  opgehaald bij de bron, met gemeten doorlooptijd, en die tijd × N ligt binnen wat
  §4 acceptabel noemt.
- **Of wél een backup**, puur als versnelling van hersteltijd — niet als
  dataveiligheid. Dan geldt: aftekenen op een **uitgevoerde restore**, niet op de
  configuratie. Een onbewezen backup is geen backup; dat is de les van §3, waar
  het voorgeschreven herstelpad op papier bestond en in werkelijkheid niet.

Wat niet mag: deze poort openlaten met "we halen het toch opnieuw op" zonder dat
iemand dat één keer heeft gedaan en geklokt. Dat is exact de fout van §3 in een
andere jas.

**P2 — Herstel-runbook bestaat en is nagelopen door iemand anders dan de auteur.**
Op te nemen in `docs/`. Minimaal: het herstelpad uit P1 (her-ingest of restore),
en expliciet de faalmodus uit §3 — instances zonder PVC's, waarvoor de operator
zelf geen uitweg biedt.

**P3 — Alerting op databasegezondheid.**
Nu niets: `monitoring/prometheus/rules/` op `origin/main` heeft mappen voor
certmanager, coredns, deploy, hpa, images, ingress, nextcloud, pods en storage —
**geen enkele regel voor CNPG of Postgres** (geverifieerd op `origin/main`, niet
op de werkbranch). Nodig vóór migratie:
- CNPG-cluster niet `Ready` → alert
- `readyInstances < instances` → alert
- als voor een backup is gekozen (P1): laatste geslaagde backup te oud → alert
- Argo `health=Suspended` op een database-app → alert (§3, les 2)

**P4 — Datavernietigingspad afgedekt.**
Voor de app die het cluster beheert: PVC's uitsluiten van prune, of
`reclaimPolicy: Retain` op de storageclass die CNPG gebruikt, of beide. Plus een
expliciete review of `prune`/`selfHeal` op deze app aan moeten blijven staan.

## 6. Fasering, ná de poorten

Alleen uitvoeren als de twee getallen uit §4 er zijn — gewonnen beheerslast en
hersteltijd × N — en §5 dicht is.

**F0 — Herbouw en herbevestig het doelwit.** Bepaal eerst of `nextcloud-pg`
wordt gerepareerd of schoon opnieuw wordt neergezet. Gezien de staat
(`unrecoverable`, geen data) is opnieuw neerzetten waarschijnlijk goedkoper dan
repareren. Herzie daarbij `bootstrap.initdb.database: postgres` — een applicatie
hoort niet in de `postgres`-database te leven.

**F1 — Hermeet de businesscase.** WP3 is gecommit maar bestaande pods houden hun
bevroren spec tot ze opnieuw worden aangemaakt. Meet ná hersync opnieuw wat §2
meet. Als de winst dan nog steeds ~4 GiB is, staat vast dat dit een
functionaliteitsproject is en geen kostenproject — leg dat vast, zodat het later
niet opnieuw als besparing wordt verkocht.

**F2 — Bepaal het aantal clusters en de blast radius.** Nu: 58 storingsdomeinen,
één tenant per stuk. Na consolidatie: zoveel als er clusters zijn. Dit is de
kernafweging en hij moet expliciet worden gemaakt en geaccepteerd, niet
weggerekend. Eén cluster voor 58 gemeenten betekent dat één corrupte WAL alle
gemeenten raakt. Overweeg groepering (per wave, per omgeving) in plaats van één.

**F3 — Eén tenant, in accept.** Een wegwerpbare tenant (`nc-example`-achtig, geen
gemeente). Volledige cyclus: migreren, verifiëren, en **de restore uitvoeren**.

**F4 — Canary in productie.** De bestaande canary-tenant. Minimaal een volle week
meelopen, met de alerts uit P3 actief, voordat er een tweede volgt.

**F5 — Waves.** Volg de bestaande `tenant.wave`-indeling (0 = canary, 1+ =
productie). Per wave een expliciet go/no-go. Bij elke tenant geldt de bestaande
regel uit `docs/DATABASE.md`: maintenance mode aan, dumpen, importeren,
verifiëren, maintenance mode uit.

**F6 — Documentatie bijwerken in dezelfde wijziging.** `docs/DATABASE.md`
§ CloudNativePG van *"Aspirational / not implemented"* naar de feitelijke
procedure, en de vergelijkingstabel in dat document herzien: die noemt nu drie
opties en zal er vier moeten noemen, of één moeten afvoeren.

## 7. Rollback

Per tenant, zolang de wave niet is afgesloten: de oude per-tenant PVC blijft
staan tot expliciete aftekening. Dat is precies de bucket-A-situatie uit
`INVENTARIS.md` (een MariaDB-volume naast een actieve Postgres) — die volumes
zijn nu als opruimbaar geclassificeerd omdat de migratie *af* is. Tijdens een
lopende migratie zijn ze het rollbackpad en mogen ze niet mee in een opruimronde.

Voorwaarde: de terugweg is pas echt een terugweg als hij één keer gelopen is (F3).

## 8. Wat dit plan niet doet

- Geen uitspraak over MariaDB. Dat is met 126 PVC's / 1056 GiB en 60 containers
  de grotere post, en dezelfde vraag geldt daar. Als consolidatie ergens loont,
  is het eerder daar dan bij Postgres — maar dat is niet gemeten in dit traject.
- Geen uitspraak over de drie `postgresql`-pods in `opencatalogi-poc`. Die komen
  uit een andere bron, hebben al expliciete requests, en vallen buiten dit
  platform.
- Geen aanbeveling over pgbouncer. Er staat een deployment in
  `nextcloud-platform/platform/pgbouncer/`, er draait geen pod, en er is geen
  CNPG `Pooler` in het cluster. Onduidelijk of dit nog bedoeld is; uitzoeken vóór
  F0, anders bouw je een tweede halve poolinglaag.

## 9. Open vragen

1. Hoe lang duurt een volledige her-ingest bij de bron, per tenant en per
   cluster, en is die geautomatiseerd? (§4, P1 — **blokkerend**)
2. Hoeveel beheerhandelingen win je concreet? Neem de laatste Postgres-upgrade als
   maatstaf: 58 tenants nu, tegenover 1–3 clusters straks. (§4 — **blokkerend**,
   want zonder dit getal staat er niets tegenover de blast radius)
3. Hoeveel clusters, en wordt de blast radius van 58 → N expliciet geaccepteerd?
   (F2 — blokkerend)
4. Wat is er met de PVC's van `nextcloud-pg` gebeurd? Niet vastgesteld; events
   verlopen. Als het `prune` was, raakt dat P4 direct.
5. Blijft pgbouncer in het plaatje? (§8)
6. Mag de kapotte `VolumeSnapshot` in `helmond` weg, en hoeveel andere
   placeholder-resources staan er nog in het cluster? (§4) Dit plan raakt hem
   niet aan.
