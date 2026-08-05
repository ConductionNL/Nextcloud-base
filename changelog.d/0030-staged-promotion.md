### Gewijzigd — 2026-08-05 (accept vóór productie, en de poort meet nu iets)

Twee dingen. De eerste is een correctie op een fout in de poort zelf.

**De poort keurde niets.** `SETTLE_SECONDS` stond op 30 en de probe was tevreden
met één gezonde meting. Argo's `timeout.reconciliation` staat echter op de default
van 180s, en daarna moet de pod nog rollen. In run `31033945944` slaagde de
canary-probe 31 seconden na de merge, op poging 1 — de canary liep op dat moment
nog op de oude commit. Gemeten bewijs: een vloot-tenant stond pas ~3 minuten na de
promotie op de nieuwe revisie. Alle vier de PR's van die avond zijn dus
gepromoveerd op basis van een canary die de wijziging nog niet had. Er is niets
gesloopt, maar dat was geluk.

Nu: `SETTLE_SECONDS` 300 (reconcile plus pod-roll) en `HEALTHY_STREAK` 3, dus drie
opeenvolgende gezonde rondes voordat een laag als gezond geldt. Eén slechte ronde
zet de teller terug — het gaat om een aaneengesloten gezonde periode, niet om een
gemiddelde.

**Accept en productie werden tegelijk geraakt.** De hele vloot hing aan één ref.
Nu drie:

| Groep | Ref | Aantal |
|---|---|---|
| `tenant.wave: "0"` | `HEAD` (main) | 2 |
| `tenant.environment: accept` | `release-accept` | 48 |
| de rest | `release` | 26 |

De keten per PR is daarmee main → canary → `release-accept` → accept → `release` →
productie, met een gezondheidscheck en een eigen rollback-pointer per stap. Een fout
die accept sloopt komt niet bij productie. Rollback blijft per laag één pointer
terugzetten; main blijft ongemoeid.

`promote-tenant-changes.yaml` schuift bij een tenant-only push beide refs vooruit.
Zou alleen `release-accept` schuiven, dan bestaat de Application van een nieuwe
accept-tenant niet, want de generator volgt `release`.

Probe-lijsten gesplitst in drie: `probe-hosts-canary.txt`,
`probe-hosts-accept.txt` en `probe-hosts-live.txt`, elk met een MariaDB- en een
PostgreSQL-tenant. Alle vier de nieuwe hosts zijn getest op HTTP 200 met
`installed:true`.

**Cutover:** maak `release-accept` aan op de huidige main vóórdat dit gemerged
wordt, en sync daarna `nextcloud-platform-bootstrap`. Bestaat de branch niet als de
ApplicationSet dit oppikt, dan kunnen 48 apps hun bron niet resolven.

**Wat deze poort nog niet doet:** hij bewijst niet dat de wijziging is aangekomen,
alleen dat er niets is omgevallen. Een langere wachttijd maakt dat waarschijnlijker,
niet zeker. Echte verificatie vraagt dat CI de gedeployde revisie van de Argo-app
kan uitvragen, en daarvoor is een token nodig dat er nu niet is.
