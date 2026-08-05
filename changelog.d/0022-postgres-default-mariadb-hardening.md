### Gewijzigd — 2026-08-05 (PostgreSQL wordt de default; MariaDB-opstart gehard)

Aanleiding: epe-prod en dinkelland-prod lagen op 2026-08-04 plat na een
`kubectl rollout restart`. De bitnami-entrypoint start mysqld eerst op de
achtergrond voor `mysql_upgrade` en stopt hem ~1s na `ready for connections`.
Valt die stop midden in het laden van de buffer pool uit `ib_buffer_pool`, dan kan
de afgebroken load de shutdown laten deadlocken — geen `Shutdown completed`,
mysqld idle op ~7m CPU. Zonder startupProbe gold alleen
`livenessProbe.initialDelaySeconds` (120s) als opstartbudget, dus volgde SIGKILL
op ~150s (exit 137) en herhaalde de cyclus zich tot een backoff van 5 minuten.
Het is een race: dezelfde pod kwam er bij een volgende poging toevallig wél door.

**PostgreSQL is nu de default database.** MariaDB blijft ondersteund als
expliciete legacy-keuze.
- `argo/applicationsets/nextcloud-tenants.yaml`: `default "mariadb"` → `"postgres"`
  op beide plekken (valueFiles-selectie en de tenant-secret chart).
- `values/common.yaml`: `database.type` → `postgres`, `mariadb.enabled` → `false`,
  toelichting bijgewerkt. `postgresql.enabled` blijft bewust `false`: de
  enabled-toggles zijn eigendom van de profiel-laag `values/db/*.yaml`, die later
  wordt gemerged en dus altijd beslist.
- `values/templates/tenant-template.yaml`: `dbType: postgres`, en het ingebouwde
  `mariadb:`-blok verwijderd. Dat blok pinde MariaDB **11.2** en overschreef als
  laatste merge-laag de hele profiel-laag — een nieuwe tenant liep zo alle
  platform-defaults mis.
- `scripts/create-tenant-secret.sh` is **niet** meegegaan: de commit-gate weigert
  het bestand op twee bestaande ShellCheck-bevindingen (SC2034, regels 211-212).
  De script-default staat dus nog op `--mariadb`; de docs waarschuwen expliciet
  om de vlag altijd mee te geven. Zie Openstaand.

Geen bestaande tenant raakt hierdoor van engine: alle tenant-bestanden hebben al
een expliciete `tenant.dbType`, en `.tenant.dbType` stond al in `REQUIRED_FIELDS`
van `scripts/validate-values.sh`. De default is dus een vangnet, geen werkend
codepad voor bestaande tenants.

**MariaDB-profiel gehard** (`values/db/mariadb.yaml`):
- `primary.configuration` met `innodb_buffer_pool_load_at_startup=0`. Geen load
  bij het opstarten, dus niets om af te breken. Prijs: koude cache na herstart.
  Let op: dit blok **vervangt** de my.cnf van de subchart. De inhoud is de
  gerenderde chart-default van chart 8.9.0 plus die ene regel; bij een
  chart-upgrade opnieuw vergelijken (commando staat in het bestand).
- `primary.startupProbe`: budget 30s + 60×10s = 10 minuten, gelijk aan de
  platform-standaard voor de Nextcloud-container. Dit lost de deadlock niet op —
  die wordt niet beter van meer tijd — maar dekt het ernstiger geval: InnoDB
  crash recovery van een grote database duurt legitiem langer dan 150s, en wordt
  die middenin afgeschoten dan begint recovery elke ronde opnieuw.
- `primary.livenessProbe` op `initialDelaySeconds: 30`: scherp zodra de
  startupProbe geslaagd is, dus een dode DB wordt sneller opgemerkt dan met het
  blinde venster van 120s.

Geen image-pin toegevoegd: chart 8.9.0 rendert al
`bitnamilegacy/mariadb:11.4.6-debian-12-r0`. De 39 pods die in het cluster nog op
`11.3.2` staan, draaien dus niet op deze chart-render — dat is een aparte
inventarisatie.

**Documentatie:**
- `docs/HAVEN-COMPLIANCE.md` §3 stelde onvoorwaardelijk dat liveness, readiness
  én startupProbe alle drie aan staan met een opstartbudget van 10 minuten. Dat
  gold alleen de Nextcloud-container; de database-subcharts hadden geen enkele
  startupProbe. Nu per component gespecificeerd, met gemeten budgetten.
- `docs/DEBUGGING.md`: nieuwe sectie "MariaDB komt niet op na een herstart". De
  runbook had nul dekking voor crashloops en probes.
- `docs/DATABASE.md`: default-flip, MariaDB als legacy gemarkeerd, en de
  opstartvalkuil met probe-tabel beschreven.
- `docs/ADDING-TENANT.md`, `CLAUDE.md`: dbType-guidance en secret-commando's.
- `docs/CNPG-MIGRATIE.md`, `README.md`, `docs/index.md`: de consolidatie-afweging
  uit PR #14, die in deze PR is opgenomen.

**Openstaand:**
- `scripts/create-tenant-secret.sh`: default nog `mariadb`. Het bestand is
  geblokkeerd door twee bestaande SC2034-bevindingen: `NEXTCLOUD_INSTANCEID` en
  `NEXTCLOUD_PASSWORDSALT` worden op regel 211-212 gegenereerd en daarna nergens
  gebruikt — ze belanden dus niet in het secret. Dat is geen gevolg van deze
  wijziging, maar moet eerst beoordeeld worden (bedoeld en vergeten, of dode
  code?) voordat het script aangepast wordt.
- `values/db/postgres.yaml` heeft dezelfde probe-correctie niet en draait op
  30s + 6×10s = 90s opstartbudget — krapper dan MariaDB had. Bewust buiten deze
  wijziging: raakt de meerderheid van de tenants en verdient een eigen venster.
- epe-prod en dinkelland-prod worden **niet** door deze ApplicationSet beheerd
  (geen ownerReferences, geen `tenant-*-prod.yaml`). Daar is de fix op
  2026-08-04 met `kubectl patch` op de live Application gezet en gaat verloren
  als iemand ze later onder de ApplicationSet brengt.
- `values/templates/tenant-template-postgres.yaml` is nu grotendeels dubbel met
  `tenant-template.yaml`; samenvoegen is een aparte opruiming.
