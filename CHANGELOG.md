# Changelog

All notable changes to the Nextcloud multi-tenant GitOps platform are recorded here.

The format is loosely based on [Keep a Changelog](https://keepachangelog.com/).
Dates are in `YYYY-MM-DD` (Europe/Amsterdam). This file is the audit trail for
platform-level changes — update it in the same commit as the change.

## 2026-08-24 — OpenSpec-materiaal naar de plugin

De vier `openspec-*`-skills en de vier `opsx/`-commands stonden woordelijk óók
in `talos`: ruim 1.200 regels gevendorde third-party tekst (MIT, author
`openspec`) twee keer in versiebeheer. Drie van de vier commands waren
byte-identiek; het verschil bij de vierde was ASCII-art-indentatie, en de skills
verschilden op één regel (`generatedBy` 1.2.0 tegen 1.3.0).

Ze zijn verhuisd naar `engineering-baseline` in de marketplace
`ConductionNL/claude-plugins`, gepind op één versie. Wie de plugin heeft, heeft
ze in élke repo; wie hem niet heeft, mist ze hier. Dat is de afweging: dit is
generiek gereedschap zonder platformkennis, geen guardrail — een ontbrekende
skill kost gemak, geen bescherming. De tien eigen tenant-commands en de skill
`tenant-toevoegen` blijven staan, want die zijn wél repo-specifiek.

Geen inkomende verwijzingen: `grep` over docs, scripts en manifests op `opsx` en
`openspec-` gaf nul treffers buiten `.claude/` zelf.

## 2026-08-21 — Tenant gooisemeren-prod compleet gemaakt + eerste-sync-race

**Tenant.** De hernoeming van `gooisemeren-migrate-prod` naar `gooisemeren-prod`
(PR #85 + #86) leverde een tenantbestand van 22 regels waar het oude 44 had. De
naamswijziging zelf is goed — met naam `gooisemeren-prod` derived de
ApplicationSet `gooisemeren.commonground.nu` correct, dus `hostname` +
`hostnameOverride` mochten weg. Maar er ging meer mee dat wél nodig was.
Teruggezet in `values/tenants/tenant-gooisemeren-prod.yaml`, overgenomen van de
migrate-tenant:

| Veld | Terug op |
|---|---|
| `persistence.size` | `250Gi` (was platformdefault 50Gi) |
| `tenant.features.appapi` | `false` |
| `frontend.host` | `gooisemeren.openwoo.app` |
| `frontend.extraHosts` | `[open.gooisemeren.nl]` |
| `frontend.tls.secretName` | `gooisemeren-frontend-tls` |
| `branding.organisationName` | `gemeente Gooise Meren` |
| `branding.faviconUrl` | favicon uit de assets-repo |

Geverifieerd tegen de live stand: `gooisemeren-frontend-tls` in de
migrate-namespace is een Let's Encrypt multi-SAN cert voor
`gooisemeren.openwoo.app` + `open.gooisemeren.nl`, geldig t/m 2026-11-16;
storageclass `default` heeft `allowVolumeExpansion=true`, dus 50Gi→250Gi is een
online expansie. `frontend.extraHosts` en `frontend.tls.*` worden aantoonbaar
geconsumeerd door `react-tenants.yaml` in React-base.

**Twee handmatige stappen** die niet in Git kunnen: het TLS-secret uit de
migrate-namespace naar de nieuwe namespace copiëren (voorkomt een TLS-gat tot
cert-manager zelf heeft uitgegeven), en de data-kant van de cutover.

**Docs-gap: hernoemen bestond niet in de documentatie.** `grep -i rename docs/`
gaf nul treffers, in álle pagina's. De enige plek waar stond dat een naam de
namespace weggooit was een comment ín het tenantbestand — dat verdween mee met
de verwijdering. `docs/TENANT-OPERATIONS.md` heeft nu een sectie "Een tenant
hernoemen bestaat niet": welke drie dingen uit `tenant.name` worden afgeleid
(namespace, S3-prefix, database-PVC), dat de prefix hard-coded is zonder
override, en dat een naamswijziging dus een migratie is met een expliciet
databesluit vooraf.

**Eerste-sync-race.** Een verse managed tenant meldde
`MountVolume.SetUp failed ... secret "nextcloud-secrets" not found`. Niet de
generator: ESO stond gezond (`nextcloud-shared-store` Ready=True, seed aanwezig,
andere managed tenants `SecretSynced`). De ExternalSecret zit als derde source in
dezelfde Application als de workload en had geen sync-wave, dus Argo kende geen
ordening tussen het CRD-kind en de Deployment.

- `charts/tenant-secret/templates/externalsecret.yaml`: annotatie
  `argocd.argoproj.io/sync-wave: "-1"`.
- `docs/SECRETS.md`: nieuwe sectie "Eerste sync".
- `docs/ADDING-TENANT.md`: noot bij stap 6 dat deze melding verwacht is en
  zichzelf heelt.

Dit is een voorsprong, geen barrier: Argo heeft geen health-check voor
`ExternalSecret` en ziet hem healthy zodra de resource bestaat. Sluitend maken
vraagt `resource.customizations.health.external-secrets.io_ExternalSecret` in
`argocd-cm` — repo cluster-infra, staat er nu niet in. Nog open.

## 2026-08-19 — Docs: `tenant.apps.versions` gedocumenteerd

`docs/ADDING-TENANT.md` beschreef `tenant.apps.enabled` wel en
`tenant.apps.versions` nergens — niet in de stappen, niet in de checklist. Het
formaat stond alleen als commentaar in `values/templates/tenant-template.yaml`,
dus wie een versie wilde pinnen moest de template of de validator lezen.

Toegevoegd in stap 1: een subsectie "Pinning app versions" met het YAML-blok,
de regex die `validate_app_versions_format()` in `scripts/validate-values.sh`
afdwingt, geldige en afgekeurde voorbeelden, en het onderscheid met
`tenant.chartVersion` (strikter: exact `X.Y.Z`).

Expliciet opgeschreven omdat het een stille faalvorm is: alleen `opencatalogi`,
`openconnector` en `openregister` zijn bedraad in
`argo/applicationsets/nextcloud-tenants.yaml`. De validator kent geen allowlist
van appnamen, dus een vierde sleutel komt groen door de validatie en wordt
daarna genegeerd — een pin die niets doet.

Alleen documentatie; geen gedragswijziging. `last_reviewed` op 2026-08-19.

## 2026-08-18 (later 2) — IPv6-canary: de live-canary achter de Cloudflare-proxy

`tenant-canary-prod.yaml` krijgt `frontend.proxied: true`. React-base emit daarop
de external-dns-annotatie `cloudflare-proxied`, waardoor het DNS-record achter de
proxy komt en de host AAAA krijgt — onze loadbalancer is IPv4-only.

Eerst op de accept-canary gezet en weer weggehaald na een meting: Universal SSL
van Cloudflare dekt `openwoo.app` en `*.openwoo.app`, maar geen tweede niveau
zoals `*.accept.openwoo.app`. `canary.accept.openwoo.app` stond al geproxied in
Cloudflare en gaf daardoor een TLS-handshakefout. Voor accept-hosts is Advanced
Certificate Manager nodig (betaalde add-on); daarom loopt de canary via de
hostnaam met één label.

Eén tenant. Bewust niet als platform-default in React-base
`values/common.yaml`: alle 92 frontend-apps staan op auto-sync met selfHeal, dus
dat zou de hele vloot binnen minuten proxyen.

`validate-values.sh` kent `proxied` nu als geldige sleutel onder
`tenant.frontend` — die lijst moet gelijk blijven met wat de ApplicationSet leest.

Voorwaarde aan de Cloudflare-kant: een Configuration Rule met SSL Full (strict)
voor de geproxiede host. Die staat en is nagemeten.
## [Unreleased]

### Toegevoegd — 2026-08-18 (ondertekende security.txt voor dinkelland en tubbergen)

Twee tenant-bestanden krijgen een `frontend.wellKnown`-blok met een
PGP-ondertekende `security.txt` en de publieke sleutel waar het
`Encryption`-veld naar wijst: `tenant-dinkelland-prod.yaml` (host
`open.dinkelland.nl`) en `tenant-tubbergen-prod.yaml` (host
`open.tubbergen.nl`). Beide zijn ondertekend door `security@noaberkracht.nl`
(sleutel `8935D1F42231CDDFDE5AA6CD845F93DE817AA1F5`); de accept-tenant van
tubbergen krijgt niets, want het ondertekende bestand noemt de productiehost
als `Canonical`.

Aanleiding: audit op open.dinkelland.nl. Wat er stond was de ongetekende
Conduction-template zonder `Encryption`-veld, en `/.well-known/pgp-key.txt` viel
in de SPA-catch-all (status 200 met 5 MB HTML in plaats van een sleutel).

Consumerende kant: `wellKnown` wordt gelezen door de React-base ApplicationSet
en door `charts/woo-website` (ConfigMap + subPath-mount) — zie React-base
`docs/ADDING-TENANT.md`. De inhoud is byte-gevoelig: één gewijzigd teken maakt
de signatuur ongeldig zonder dat het aan de buitenkant opvalt. Bewezen na de
wijziging: `gpg --verify` op de gerenderde ConfigMap-inhoud geeft *Good
signature*.

`nextcloud-platform/scripts/validate-values.sh` kent `wellKnown` nu als geldige
sleutel onder `tenant.frontend` — die lijst moet gelijk blijven met wat de
ApplicationSet leest, anders wordt een veld stil genegeerd.

### Gewijzigd — 2026-08-11 (epe-prod: `issuer: none`, want CAA sluit Let's Encrypt uit)

`certificate/open-epe-nl-tls` in ns `epe-prod` bleef falen op een `invalid`
order. Reden uit de challenge: `403 urn:ietf:params:acme:error:caa`. Het
CAA-record van `epe.nl` staat alleen digicert, certSIGN, kpn, entrust, sectigo
en ssl.com toe — Let's Encrypt staat er niet bij en kan er dus nooit uitgeven.

- `nextcloud-platform/values/tenants/tenant-epe-prod.yaml`: `frontend.tls.issuer`
  op **`none`**, met `secretName: open-epe-nl-tls` en een comment die de CA, de
  vervaldatum en de herkomst vastlegt. Daarmee zet de `react-tenants`-
  ApplicationSet geen `cert-manager.io/cluster-issuer` meer op de ingress, is er
  geen ingress-shim en dus geen `Certificate` dat het klantcertificaat kan
  overschrijven.

Het certificaat zelf (Sectigo OV, `CN=open.epe.nl`, SAN ook `www.open.epe.nl`)
bestond al in de oude namespace `epe` als
`epe-prod-reactfront-woo-website-frontend-tls` en is met de hand overgezet naar
`epe-prod` onder de naam `open-epe-nl-tls`. Buiten git, conform
`openwoo-app-config/docs/custom-domain-cert.md`.

**Waarom het `tls`-blok niet weg mag.** Commit `d2e07d9` haalde het hele blok
weg om de LE-poging te stoppen. Dat stopt de poging, maar haalt ook de
verwijzing naar het secret weg: zonder `secretName` valt de ApplicationSet
terug op de default `wildcard-openwoo-tls` (`*.openwoo.app`), en die naam past
niet bij `open.epe.nl`. Argo synct dat, nginx serveert zijn fake-certificaat en
de site is stuk — met een geldig, geseed certificaat dat gewoon niet wordt
aangewezen. Leeg is dus niet hetzelfde als `none`; dat staat nu als comment in
het tenantbestand zelf.

**Let op bij verlenging:** dit certificaat verloopt **2026-09-02** en valt met
`issuer: none` buiten `CertificateExpiringSoon` — die alert leest een metriek
die cert-manager alleen voor `Certificate`-objecten produceert. Deze comment en
deze entry zijn de enige bewaking die er is.

### Gewijzigd — 2026-08-10 (docs-touched: documentatie wijzigt mee met de code)

De gates keken tot nu toe naar de hele boom en nooit naar wat je pusht. Daarmee
werd de docs-as-code-afspraak — documentatie wijzigt in dezelfde PR als de code
die zij beschrijft — door niets afgedwongen. `docs-touched` is de diff-gate die
dat wél doet.

- `.pre-commit-config.yaml`: techbook-pin van de kale sha
  `edf269eeea4fd28f150791a00d6600d645262a91` naar tag **`v0.2.0`**, en
  `- id: docs-touched` toegevoegd. Die twee horen bij elkaar: de hook bestaat
  pas vanaf `v0.2.0`, dus zonder de bump zou pre-commit hard falen op een
  onbekende hook-id.
- `.docs-touched.yaml` (nieuw): vier padregels — gedeelde values, Argo-wiring,
  tenant-charts, en de scripts/gates zelf. Elke regel draagt een `reason` die
  in de melding verschijnt, zodat de gate zichzelf uitlegt.
- `docs/CHECKS-AND-BALANCES.md`: korte verwijzing bij de bestaande gates.

**Mode is `warn`, met opzet.** De gate rapporteert volledig en geeft exit 0. We
willen eerst een periode zien wát hij zou tegenhouden voordat hij pushes gaat
weigeren; een padregel die te breed staat, merk je alleen door mee te kijken.
Naar `enforce` is een aparte, bewuste wijziging.

De padregels rijmen bewust met `nextcloud-platform/scripts/classify-change.sh`:
wat dat script "platform" noemt is docs-plichtig, en `values/tenants/tenant-*.yaml`
staat in `ignore`. Dat is de belangrijkste eigenschap van deze uitrol —
tenant-PR's zijn dagelijks werk en mogen nooit op een docs-gate stuklopen.
Nagemeten met een wegwerp-commit op één tenantbestand: geen bevinding.

Vrijstelling blijft per commit mogelijk via de trailer `Docs-not-needed: <reden>`.
Configformaat en verificatierecept staan in techbook `docs/docs-touched.md`.

### Gerepareerd — 2026-08-10 (server-side gate viel om op ontbrekend gereedschap)

De `gate`-job faalde met exit 1 en géén uitleg. Oorzaak: `smoke-checks.sh` eist
`helm`, `yq`, `kubeconform` en `kubectl`, en `kubeconform` staat niet op de
runner-image. De melding daarover gaat naar stdout, en `scripts/verify.sh` gooit
stdout weg met `>/dev/null` — vandaar de stille exit.

- `.github/workflows/ci.yml`: kubeconform installeren, versie én sha256 gepind
  (v0.8.0), plus een stap die vooraf luid meldt welk gereedschap ontbreekt in
  plaats van tien regels verderop stil om te vallen.

Lokaal draaide dezelfde gate al groen; het verschil zat uitsluitend in de runner.
### Gerepareerd — 2026-08-10 (verwijderpad: frontend, probe-lijsten en een backupcommando dat niet werkte)

`docs/REMOVING-TENANT.md` beschreef een verwijderpad dat op drie punten niet
overeenkwam met het platform.

**1. De frontend ontbrak volledig.** De pagina deed alsof er één Application per
tenant is. Er zijn er twee: `nc-<tenant>` (appset `nextcloud-tenants`, volgt
`release`) en `<tenant>-reactfront` (appset `react-tenants` in React-base, volgt
`HEAD`), in dezelfde namespace. Beide zetten `preserveResourcesOnDeletion: true`
— die vlag bewaart de *resources*, maar de *Application zelf* wordt wél door de
appset-controller verwijderd. Gevolg: na het verwijderen van het tenantbestand
blijven het frontend-Deployment en de Ingress draaien en **serveert de frontend
gewoon verkeer door** tot iemand opruimt. Toegevoegd aan het stappenoverzicht,
de stap-voor-stap, de snelle referentie en de troubleshooting.

**2. Het PostgreSQL-backupcommando werkte voor geen enkele tenant.** Het riep
`pg_dump -h pgbouncer.nextcloud-platform.svc.cluster.local -U nextcloud_$TENANT`
aan. Die topologie bestaat niet: `values/db/postgres.yaml` zet
`externalDatabase.enabled: false` en draait een in-cluster Bitnami PostgreSQL in
de tenant-namespace zelf, met database én user `nextcloud` (niet
`nextcloud_<tenant>`). Vervangen door een `kubectl exec` op
`statefulset/nextcloud-postgresql` (naam geverifieerd door de chart lokaal te
renderen) dat het wachtwoord uit het gemounte secret-bestand leest. Het
MariaDB-pad is bewust ongemoeid gelaten (legacy).

**3. Geen waarschuwing over de probe-lijsten.** `.github/probe-hosts-accept.txt`
en `probe-hosts-live.txt` bevatten vier échte tenants.
`.github/workflows/promote-tenant-changes.yaml` leest beide lijsten (regel
97-99) en eist dat álle hosts 200 + `"installed":true` geven; faalt er één, dan
draait hij de promotie terug met `--force-with-lease` op `release` en
`release-accept` (regel 147-151). Een tenant verwijderen zonder hem eerst uit de
lijst te halen breekt dus de promotieketen voor de hele vloot. Toegevoegd als
expliciete stap 2, vóór het verwijderen van het tenantbestand.

Verder genoemd: `openwoo-app-config/scripts/cleanup-tenant.sh` als het
gereedschap voor stap 5-7 (plan-eerst; zonder `--execute` verandert het niets).
Het werd door geen enkele doc in deze repo genoemd.

`docs/TENANT-OPERATIONS.md` verwijst nu naar `REMOVING-TENANT.md` als canonieke
procedure in plaats van de inhoud te herhalen, en noemt de tweede Application.

### Toegevoegd — 2026-08-10 (twee doc-asserties in `scripts/verify.sh`)

Deze repo had als een van de weinige geen doc-assertie.

- **Elke host in de probe-lijsten hoort bij een bestaand tenantbestand.** De
  host is niet de tenantnaam; de assertie leidt hem af zoals de appset dat doet
  (omgevingssuffix van `tenant.name`, terugval op `tenant.environment`, geen
  omgevingslabel voor prod, `tenant.hostname` overschrijft alles). Dekt nu 4
  hosts over 78 tenantbestanden.
- **Elk script in `nextcloud-platform/scripts/` heeft een regel in
  `docs/index.md`.** Patroon gelijk aan `cluster-config`. Hiervoor is een
  scripts-overzicht aan `docs/index.md` toegevoegd (10 scripts).

Beide gebruiken alleen `yq`, dat al in `Requires:` stond — geen nieuw
gereedschap.

### Gerepareerd — 2026-08-07 (betaalde klantcertificaten niet meer overschreven door Let's Encrypt)

Zeven frontends in `values/tenants/` gaan van `frontend.tls.issuer:
letsencrypt-prod` naar `issuer: none`.

**Aanleiding:** bij de woo-pwa-tls-rollout van 2 juni heeft cert-manager op
meerdere tenants het betaalde klantcertificaat in het cluster-secret
overschreven met Let's Encrypt (vastgelegd in
`CERTIFICATEN/UITVRAAG-betaalde-certs-20260603.md`). Voor zes daarvan zijn cert
én key bewaard gebleven en vandaag nog geldig, maar git stuurde nog steeds
Let's Encrypt aan — elk herstel zou opnieuw zijn overschreven. Meting in het
cluster op 2026-08-07 bevestigt dat in alle zes namespaces nog een LE-cert
staat waar een betaald cert hoort.

**Mechanisme:** de `react-tenants` ApplicationSet (React-base) zet alleen een
`cert-manager.io/cluster-issuer`-annotatie als de issuer gevuld is én niet
`none`. Zonder annotatie maakt de ingress-shim geen Certificate-object, dus
blijft een handmatig gezaaid secret staan. `buren-prod` draaide al zo.

| Tenant | Host | Uitgever | Vervalt |
|---|---|---|---|
| roosendaal-prod | open.roosendaal.nl | certSIGN | 2026-10-18 |
| roosendaal-accept | acceptatie-open.roosendaal.nl | certSIGN | 2026-10-18 |
| oudeijsselstreek-prod | open.oude-ijsselstreek.nl | certSIGN | 2027-02-14 |
| oudeijsselstreek-accept | acceptatie-open.oude-ijsselstreek.nl | certSIGN | 2027-02-14 |
| noaberkracht-accept | acceptatie-open.noaberkracht.nl | Trust Provider | 2026-10-13 |
| hofvantwente-accept | acceptatie-open.hofvantwente.nl | certSIGN | 2026-09-11 |

Daarnaast `noorderzijlvest-prod`: die stond op `issuer:
cert-manager-issuer-prod`, een ClusterIssuer die niet bestaat. Het Certificate
bleef op `Ready=False` staan en het Sectigo-cert (2026-11-27) overleefde bij
toeval. Nu expliciet `issuer: none`.

**Zutphen blijft bewust op Let's Encrypt**: geldig certSIGN-cert aanwezig, maar
de private key ontbreekt en moet bij de gemeente worden opgevraagd.

**Volgorde is niet vrijblijvend.** Deze wijziging haalt alleen de annotatie weg;
het bestaande LE-secret blijft werken, er valt niets om. Het betaalde cert in
het secret zetten is een aparte clustermutatie en moet ná deze merge gebeuren —
andersom pakt cert-manager het teruggezette cert binnen minuten weer af.

**Let op:** de `react-tenants` generator volgt `HEAD` (main), niet `release`.
Deze tenant-wijziging werkt dus direct bij de merge door op alle zeven
frontends, zonder promotieketen.

**Betaalde certs vernieuwen niet vanzelf** — de vervaldatums hierboven horen in
een agenda, niet alleen in dit bestand.

### Gewijzigd — 2026-08-05 (pullPolicy `Always` → `IfNotPresent`)

`values/common.yaml`: `image.pullPolicy` voor de hoofd-Nextcloud-image staat niet
langer op `Always`. Elke pod-start was daarmee een registry-round-trip naar Docker
Hub zonder dat er iets nieuws te halen was, en die tellen mee tegen de anonieme
limiet van 100 pulls/6u/IP.

**Aanleiding:** de Docker Hub Pro-credential uit de rollout van 2026-05-02 is
verlopen en geeft `401`. Hij wordt niet vernieuwd; het pull-secret is fleet-wide
teruggetrokken, dus de vloot pullt weer anoniem. Zie `cluster-config/CHANGELOG.md`
en `ROADMAP.md` 2026-08-03.

**Veilig** omdat `image.tag` een concrete versie is (`32.0.13-fpm`), niet zwevend.
Gaat die ooit floaten, dan moet dit terug naar `Always` — dat staat als
waarschuwing bij de waarde zelf.

**De fasering zit in de refs, niet in een values-bestand.** wave-0 (canary-prod,
canary-accept) volgt main en krijgt dit bij de merge; de andere 74 volgen `release`
en krijgen het pas bij promotie. Daarmee is dit de eerste wijziging die de
canary-poort echt doorloopt.

Twee eerdere versies van deze wijziging waren fout en zijn hier rechtgezet:
- De regel stond in `values/canary-overrides.yaml`. Dat bestand wordt geladen op
  `tenant.canary: true`, en die vlag staat op **geen enkele** tenant — de wijziging
  was dus een no-op. Verwijderd daar.
- Er werd `canary: true` toegevoegd aan `tenant-canary-accept.yaml` om dat te
  repareren. Dat zou de geparkeerde emptyDir/S3-PoC activeren op die tenant,
  inclusief de hardgecodeerde `trusted_domains: ['canary.commonground.nu']` en
  S3-prefix `canary-prod/` uit `canary-overrides.yaml` — canary-accept zou zijn
  eigen hostname niet meer vertrouwen. Teruggedraaid.
### Gewijzigd — 2026-08-05 (geplande merge werkt de hele wachtrij af)

`scheduled-merge.yaml` verwerkte standaard alleen de laagste openstaande wave, dus
één stap per avond. Dat was een zelfgemaakte flessenhals: vier klaarstaande PR's
zouden vier avonden kosten zonder dat het iets veiliger maakte. De veiligheid zit
in de canary-poort per PR en in het stoppen bij het eerste probleem, niet in
wachten tot morgen.

Eén run werkt nu de hele wachtrij af, in wave-orde en één PR per keer, met de
volledige keten per PR: merge → canary pollen → promoveren → vloot pollen. Waves
bepalen dus de volgorde, niet het tempo.

De `all_waves`-input is vervangen door `max_prs`: leeg bij een geplande run (hele
rij), een getal als je in een handmatige run bewust één stap wil zetten.

### 2026-08-03 — pre-commit-hookbron naar GitHub
- `.pre-commit-config.yaml`: de techbook-hook komt van
  `github.com/ConductionNL/techbook` in plaats van `codeberg.org`. De pin
  `edf269ee…` blijft ongewijzigd: die commit bestaat op beide forges en is
  daar voorouder van `main`. Host-only dus — de gates (`docs-contract`,
  `docs-claims`) gedragen zich identiek.
- Waarom: dit was de laatste harde Codeberg-afhankelijkheid buiten talos.
  Zolang die bestond moest `techbook` naar twee forges gepusht blijven
  worden, en dat is niet volgehouden — 7 van de 9 repos zijn daar uit
  elkaar gelopen. De bron van het patroon zat in
  `techbook/scripts/rollout_precommit_hook.sh`, dat deze URL in élke repo
  schreef; die is in dezelfde ronde omgezet.

### Gewijzigd — 2026-08-05 (canary-poort: twee refs, promotie en rollback)

Tot nu volgden alle 76 tenant-apps `HEAD` van main op alle drie hun git-sources.
Een merge naar main was daarmee de uitrol voor de hele vloot in één keer — er was
geen moment waarop je iets kon valideren voordat iedereen het kreeg. De canary was
alleen "eerst" doordat hij extra overrides had, niet in tijd.

**De ApplicationSet kiest nu per tenant een ref:**
- wave-0-tenants (`tenant.wave: "0"` — canary-prod en canary-accept) volgen `HEAD` (main)
- alle andere tenants volgen de branch `release`
- de git-generator volgt óók `release`, zodat een Application en de values waaruit
  hij rendert altijd van dezelfde commit komen. Zou de generator main volgen, dan
  bestond een nieuwe tenant-Application al terwijl zijn values-bestand nog niet op
  `release` staat; met `ignoreMissingValueFiles: true` wordt dat bestand dan stil
  overgeslagen en rendert de tenant met alleen de defaults. Dat faalt niet, het
  gaat verkeerd — vandaar deze keuze.

Alle drie de sources zijn omgezet; ze moeten dezelfde ref gebruiken, anders
rendert een tenant values van de ene commit tegen charts van een andere.

**`scheduled-merge.yaml` doet nu de hele keten:** probe vooraf, merge naar main
(alleen canary), canary pollen, bij gezond promoveren door `release` vooruit te
schuiven, daarna de vloot probeeren. Faalt de vloot na promotie, dan gaat
`release` terug naar de vorige commit — een pointer, geen revert, en main blijft
ongemoeid. Faalt canary, dan is de vloot per definitie nooit geraakt en wordt de
merge op main gereverteerd.

**Automatische revert is niet universeel.** Raakt de diff een image-tag, chart- of
`chartVersion`-regel, dan wordt er niet gereverteerd maar alleen gealarmeerd: zo'n
wijziging kan `occ upgrade` hebben gedraaid en een revert zet dan een oude binary
op een nieuw schema. De detectie is getest op vier echte commits — de image-tag-bump
wordt gevlagd, de values-config-wijzigingen niet.

Tenant-only PR's (`change/tenant-additive`) worden direct na de merge
gepromoveerd, zonder canary-poort: een nieuw tenant-bestand kan bestaande tenants
niet breken, en zonder promotie zou de generator de tenant helemaal niet zien.

**`promote-tenant-changes.yaml` dekt de onboarding-flow.** Zonder deze workflow
zou de ref-splitsing de tenant-provisioning stil breken: een PR `add tenant: X`
landt op main, maar de generator volgt `release` en ziet het bestand dus niet — er
komt geen Application en geen foutmelding. Deze workflow draait op elke push naar
main, classificeert de range met `scripts/classify-change.sh` (hetzelfde script als
de governance-gate, zodat "tenant-only" overal hetzelfde betekent) en promoveert
alleen bij `tenant-additive`. Buiten het avondvenster om, want tenant-toevoegingen
mogen op elk moment. Platform-wijzigingen laat hij expliciet staan; die horen door
de canary-poort.

Beide workflows delen de concurrency-groep `release-pointer`, zodat ze nooit
tegelijk aan dezelfde pointer zitten.

**De provisioner (`platform.commonground.nu` / openwoo-app-config) hoeft niet
aangepast.** Nagekeken in `webgui/gitlib.py`: hij opent de PR en pollt daarna
alleen de PR-status (`state`, `merged`) voor zijn dashboard — hij merget niet zelf,
en zijn basis is de env-var `TENANTS_BASE` met default `main`, wat main blijft. De
promotie zit repo-side. Wat hij wél niet doet is labels zetten; vandaag faalt de
governance-gate daarop en wordt er toch gemerged omdat main geen branch protection
heeft. Zet je die protection aan, dan moet de provisioner
`change/tenant-additive` gaan meesturen.

**Cutover.** Maak `release` aan op de huidige main vóórdat dit gemerged wordt.
Omdat `release` en main op dat moment identiek zijn, levert het omzetten van de ref
nul manifest-verschil op en herstart er geen enkele pod. Bestaat de branch niet als
de ApplicationSet dit oppikt, dan kunnen 74 apps hun bron niet resolven.

Twee beperkingen om te kennen:
- De canary wijkt structureel af van de rest: `persistence.enabled: false`
  (emptyDir) tegen een PVC bij de andere 74. Iets kan op canary werken en op een
  gewone tenant niet, juist door dat verschil. De poort is echt, niet waterdicht.
- De vloot-rollback is een force-push op `release`. Uitsluitend op die branch,
  nooit op main, en met `--force-with-lease` zodat een gelijktijdige promotie niet
  stil wordt overschreven.

Docs bijgewerkt: `CLAUDE.md` (de sectie Sync Windows stelde dat een merge naar main
direct fleet-wide uitrolt — dat is nu onwaar) en `docs/ARCHITECTURE.md` (aanvulling
op de golden rule over welke ref een tenant leest).

### Toegevoegd — 2026-08-05 (geplande merge na 17:00, in waves)

`.github/workflows/scheduled-merge.yaml` merget PR's automatisch na 17:00
Amsterdam, in wave-orde, en stopt bij het eerste probleem. Reden: een merge naar
main *is* de uitrol — 76 tenant-apps staan op `automated` sync met `selfHeal` —
maar Argo dwingt het uitrolvenster niet af (het deny-window in de AppProject dekt
alleen `platform-*`). Tot nu toe was "mergen na 17:00" iets wat iemand moest
onthouden.

Werking:
- **Opt-in per PR** via een `merge-wave/<n>`-label. Zonder dat label doet de
  workflow niets met een PR; er wordt nooit iets gemerged omdat het per ongeluk
  groen stond. Het change-label van de governance-gate blijft daarnaast vereist.
- **Eén wave per run.** Standaard verwerkt een run alleen de laagste openstaande
  wave, dus per avond één stap met een dag ertussen. `all_waves` als input doet
  de hele wachtrij in één keer.
- **Verificatie zonder credentials.** Na elke merge wordt `/status.php` van de
  hosts in `.github/merge-probe-hosts.txt` gecontroleerd op HTTP 200,
  `installed:true` en `maintenance:false`, met tien pogingen van 20s zodat een
  rolling update de tijd krijgt. De lijst dekt canary plus één MariaDB- en één
  PostgreSQL-tenant, zodat een fout die maar één engine raakt ook opvalt. Dit is
  bewust een publieke check: er zijn geen repo-secrets en dus geen cluster-toegang
  vanuit CI.
- **Escaleren, niet doorgaan.** Faalt een probe, dan stopt de run, blijven latere
  waves staan, en komt er een issue met de faalreden en de betrokken PR. Geen
  automatische rollback — die keuze is te ingrijpend voor een cron.
- Er wordt ook vóór de eerste merge geprobed. Was de vloot al niet gezond, dan
  wordt er niets gemerged.

Twee dingen expliciet:
- **Zomertijd.** GitHub-cron kent alleen UTC. Daarom vuren twee crons (15:05 en
  16:05 UTC) en beslist een check op `TZ=Europe/Amsterdam` welke doorgaat. De
  bestaande `office-hours-tenant-only-guard.yaml` doet dit fout — die rekent met
  `date -u` en verschuift daardoor twee uur in de zomer. Die workflow draait niet
  (hij staat in `nextcloud-platform/.github/`, dat GitHub negeert) en is hier niet
  aangeraakt.
- **Venster.** Ma–do vanaf 17:00 plus de nacht erna tot 07:00. Vrijdagavond en
  het weekend niet: dan is er niemand om een probleem op te pakken. De
  waarheidstabel voor die conditie is met twaalf gevallen getest.

Voorwaarde die nog niet geregeld is: `main` heeft **geen** branch protection —
geen required checks, geen required review. De workflow controleert daarom zelf
dat een PR groen en `MERGEABLE/CLEAN` is voordat hij merget, maar dat is een
vangnet in de automatisering en geen rem op de repo.

### Gewijzigd — 2026-08-05 (sync-window-governance: config en docs kloppend gemaakt)

Geen gedragswijziging. `CLAUDE.md` stelde dat de AppProject sync-blokkades tijdens
kantooruren afdwingt; dat gold niet voor de tenant-apps, en de configuratie
suggereerde het tegendeel van wat ze doet. Gemeten op het cluster:

| Wat | Afgedwongen? |
|---|---|
| `platform-*` (5 apps, AppProject `nextcloud-platform-core`) | Ja — ma–vr 07:00–17:00, ook niet handmatig |
| `argo/` zelf (app `nextcloud-platform-bootstrap`) | Geen window, maar ook geen `automated` — alleen handmatig |
| Tenant-apps `nc-*` (76) | Nee, en dat is opzet |

- `argo/projects/nextcloud-platform.yaml`: het deny-window verwijderd. Het stond op
  `applications: ["nextcloud-platform"]` en er bestaat geen applicatie met die naam
  — de tenant-apps heten `nc-<tenant>`. Het matchte dus niets en blokkeerde niets.
  Weggehaald omdat het dekking suggereerde die er niet is; de policy-comment erboven
  legt nu uit waarom dit project bewust géén window heeft, en wat je nodig hebt
  (`manualSync: true`) mocht iemand de keuze ooit willen omkeren.
- `CLAUDE.md`: de sectie Sync Windows splitst nu expliciet wat Argo technisch
  afdwingt van wat operationele discipline is, met een tabel per component. Toegevoegd
  dat fleet-wide values-wijzigingen (`values/common.yaml`, `values/env/`, `values/db/`)
  onder platform changes vallen en dat Argo ze niet remt — het moment van **mergen**
  is daar het uitrolmoment.

Bewust niet aangeraakt: het window in `nextcloud-platform-core.yaml` bevat dezelfde
dode `"nextcloud-platform"`-regel, maar dat window werkt via `platform-*`. Die regel
opruimen raakt de enige window die productie-platform-apps daadwerkelijk gate, voor
nul winst.

### Gewijzigd — 2026-08-03 (Codeberg-refs in de runbooks naar GitHub)
- Vervolg op de shadowban-PR: `docs/ARCHITECTURE.md` was omgezet, maar de
  runbooks droegen de oude instructie nog wél. Zeven bestanden gaven
  `git push codeberg` als deploy-stap — dat deployt niets meer en is dus
  een instructie die stil faalt: `index.md`, `UPGRADE.md`,
  `TENANT-OPERATIONS.md`, `ADDING-TENANT.md`, `STORAGE-OPERATIONS.md`,
  `REMOVING-TENANT.md`, `HAVEN-COMPLIANCE.md`.
- Overal `origin` in plaats van `codeberg`, met de opmerking erbij dat een
  merge naar `main` fleet-wide en meteen uitrolt (`selfHeal` op 81/82 apps).
  `last_reviewed` op alle zeven bijgewerkt.
- Bewust bewaard: de vermeldingen die *uitleggen* dat de oude regel
  achterhaald is, en de vaststelling in `ARCHITECTURE.md` dat
  `woo-website-template-apiv2` (22 apps) en `tilburg-woo-ui` (7) nog wél
  Codeberg lezen.
- **Niet aangeraakt** en apart te behandelen: de AppProject-`sourceRepos`
  (`argo/projects/*.yaml`) whitelisten `codeberg.org` juist voor die 29
  apps. Die refs weghalen vóór migratie van die twee repo's breekt ze.
  Historische CHANGELOG-regels blijven staan — audittrail.

### Gewijzigd — 2026-08-03 (shadowban opgeheven: Argo leest GitHub, niet Codeberg)
- `docs/ARCHITECTURE.md`: de "golden rule" stond op *"Argo reads Codeberg,
  never GitHub — a GitHub push will not deploy"*. Dat is sinds de
  terugmigratie **omgekeerd** en daarmee actief misleidend: het stuurde
  een maintainer naar een remote waar niets van deployt.
- Gemeten op het cluster (2026-08-03): 234 Argo-app-sources lezen
  `github.com/ConductionNL/Nextcloud-base.git`, 143 `React-base`, 8
  `cluster-infra`. Alleen `woo-website-template-apiv2` (22) en
  `tilburg-woo-ui` (7) staan nog op Codeberg. De repo-tabel, het
  GitOps-diagram en de agent-checklist zijn navenant bijgewerkt, met een
  expliciete blockquote dat de oude regel achterhaald is.
- Toegevoegd aan de golden rule: 81 van de 82 Nextcloud-base-apps staan
  op `automated` sync mét `selfHeal`, dus een merge naar `main` rolt
  fleet-wide en meteen uit. Pod-template-wijzigingen (image, tag,
  `pullPolicy`, resources) horen daarom in een eigen PR met uitrolvenster.
- `values/templates/tenant-template-postgres.yaml`: de comment *"GitHub
  org is shadowbanned; pull from Docker Hub, not ghcr.io"* vervangen. De
  ref blijft voorlopig op Docker Hub tot de mirror-migratie
  (`cluster-config/ROADMAP.md`), maar de reden ervoor bestaat niet meer.

### Gewijzigd — 2026-07-13 (eigenaarschap → info@conduction.nl, review WP8)
- Alle `owner:`-front-matter en CODEOWNERS omgezet van `mark` naar
  `info@conduction.nl` (opvolging na 2026-08-31). Voorbereid op branch
  `chore/wp8-ownership`; review, merge en push door een mens.

### Changed
- 2026-07-10: `values/tenants/tenant-canary-prod.yaml` — tijdelijk gespiegeld aan de
  accept-laag omdat canary-prod momenteel niet werkt. `tenant.environment` blijft
  `prod` (validate-values dwingt de naam-suffix-match af); de spiegel is een expliciet
  override-blok in het tenant-bestand (laatste valueFile wint): accept-resources
  (1 CPU/3Gi), geen pool-nodeSelector/anti-affinity/PDB, accept-probes, cron */15,
  www.conf terug naar 2048M, accept-INFO-logging. Identiteit (naam, namespace,
  hostname canary.commonground.nu, podLabels, DB, secrets) ongewijzigd.
  Terugdraaien: het blok onder de streep in het tenant-bestand verwijderen.

### Fixed
- **Disabled the prod HPA in the `tenant-hpa` AppSet source — it forced RS=2 onto RWO PVCs.**
  The `charts/tenant-hpa` source set `hpa.enabled: {{ eq .tenant.environment "prod" }}`
  with chart default `minReplicas: 2`. When the 4-source `nextcloud-tenants` AppSet was
  first brought live (2026-06-30), this created an HPA on every prod tenant that scaled the
  Nextcloud Deployment to 2 — but the data PVC is RWO Cinder (single-attach), so the 2nd
  replica was stuck `FailedAttachVolume` and every prod tenant went `Degraded` (no outage;
  the 1st pod kept serving). Set `hpa.enabled: false` fleet-wide to match `env/prod.yaml`
  (`replicaCount: 1`, HPA off until the stateless/S3-primary HA path lands). Remediation:
  deleted the orphaned `nextcloud` HPAs and scaled affected Deployments back to 1 (Argo
  `ignoreDifferences` on `/spec/replicas` keeps them there; no auto-revert).
- **`nextcloud-tenants` ApplicationSet is `kubectl apply`-able again.** The canary override
  was selected with a `{{- if }}` control line wrapping a `valueFiles` list item — valid as
  an Argo goTemplate but invalid YAML, so `kubectl apply -f` failed (`line 62: could not
  find expected ':'`) and the AppSet had gone stale since commit `4afa549`. Replaced it with
  a templated filename (`canary-overrides{{ if ne … "true" }}-DISABLED{{ end }}.yaml`) plus
  `helm.ignoreMissingValueFiles: true`: canary tenants load `canary-overrides.yaml`,
  non-canary resolve to a missing file that is skipped. Re-applying the manifest now
  propagates the `charts/tenant-secret` source to tenant apps, so managed tenants get their
  ESO `nextcloud-secrets` natively (the manual `helm template … | kubectl apply` stopgap is
  no longer required).
- **Tenant AppSet is now GitOps-managed.** Removed its deliberate exclusion from the
  `nextcloud-platform-bootstrap` root app (it was excluded only because of the invalid
  YAML, now fixed). Committing `nextcloud-tenants.yaml` to Codeberg main now reconciles via
  the bootstrap directory source — no more hand-applying the AppSet.

### Documentation
- **`nextcloud-platform/docs/` refreshed to match current reality (2026-06-23).** Added
  `docs/ARCHITECTURE.md` (cross-repo map: GitOps/secret/auth flows, conventions, known
  issues). Rewrote `SECRETS.md` for the real ESO model (kubernetes-provider store +
  generator, no Vault/AWS; key is `nextcloud-password`). Corrected pervasive errors across
  `ADDING-/REMOVING-TENANT.md`, `OPERATIONS.md`, `UPGRADE.md`, `DATABASE.md`: tenant
  **namespace = bare name** (not `nc-<tenant>`, which is the Argo *app* name); push to the
  **Codeberg** remote (GitHub is an ignored mirror); chart version lives in the
  ApplicationSet `targetRevision`/`tenant.chartVersion` (not `values/common.yaml`); tenant
  deletion does **not** auto-remove the namespace (`preserveResourcesOnDeletion: true`); and
  and how to refresh/apply the `nextcloud-tenants` AppSet (now fixed — see Fixed above).
  Top-level `README.md` slimmed to an entry point that links into `docs/`.

### Changed
- **ESO consumers moved `external-secrets.io/v1beta1` → `external-secrets.io/v1`.**
  cluster-infra pins ESO to chart `2.6.0` (appVersion v2.6.0); the 2.x major no longer
  serves `v1beta1`. Updated `platform/externalsecrets/clustersecretstore.yaml`
  (`ClusterSecretStore`) and `charts/tenant-secret/templates/externalsecret.yaml`
  (`ExternalSecret`). `ClusterGenerator` stays `generators.external-secrets.io/v1alpha1`;
  passwordSpec fields verified present in 2.6.0. No spec/field changes beyond the apiVersion.
- **AppProject `nextcloud-platform-core` widened** (`nextcloud-platform/argo/projects/nextcloud-platform-core.yaml`)
  so `platform-externalsecrets` can sync the ESO consumers: cluster-scoped
  `external-secrets.io/ClusterSecretStore` + `generators.external-secrets.io/ClusterGenerator`
  added to `clusterResourceWhitelist`, and `rbac.authorization.k8s.io/*` (the
  `external-secrets-reader` Role/RoleBinding) added to `namespaceResourceWhitelist`.
  Without this the app fails `SyncFailed: resource ... not permitted in project`.

### Added
- **External Secrets Operator — per-tenant secret generation (NEW tenants only).**
  The ESO *operator* is installed by cluster-infra; this repo adds the *consumers*:
  `platform/externalsecrets/clustersecretstore.yaml` now defines a real
  `ClusterSecretStore` (kubernetes provider, reads the shared Fuga S3 creds from a
  central `nextcloud-s3-seed` Secret) **+** a `ClusterGenerator` (Password) for the
  random per-tenant secrets; `rbac.yaml` gains a least-privilege
  `external-secrets-reader` SA/Role; `s3-seed-secret.example.yaml` documents the
  seed (out-of-band, never Git). A new Helm chart **`charts/tenant-secret`** renders
  a per-tenant `ExternalSecret` that assembles `nextcloud-secrets` (generated
  admin/db/redis/salt + seeded S3), with `refreshInterval: "0"` so it generates
  **once and never rotates**. Wired as a 4th source on the `nextcloud-tenants`
  ApplicationSet, **gated on `tenant.secrets.managed: true`** — existing tenants
  omit the flag, so their script-applied secrets are untouched (no rotation). The
  flag is set by the web-UI for new (web-created) tenants. `clustersecretstore.yaml`
  re-added to the externalsecrets kustomization (needs ESO CRDs → deploy cluster-infra
  first). Deploy in the platform sync window.
- **argo/applicationsets/openwoo-provision.yaml**: per-tenant WOO base-config
  provisioning (the "target track"). One Application per **accept** tenant
  (`tenant-*-accept.yaml` glob — never prod) renders the `openwoo-app-config`
  repo (a kustomize app: provisioner ConfigMap + Argo PostSync Job on a stock
  python image) into the tenant namespace and runs
  `provision.py all --skip-credentials` to converge the WOO base config
  (idempotent). The per-tenant source connection (URL/API-Interface-ID/key) is
  set out-of-band by an operator, not here. **Sync is manual to start** (validate
  canary-accept first, then expand, then enable `automated`); pin
  `targetRevision` to a release tag of openwoo-app-config.
- **bootstrap**: App-of-apps root Application
  (`nextcloud-platform/bootstrap/nextcloud-platform-bootstrap.yaml`) that makes
  `nextcloud-platform/argo/` (AppProjects, the `nextcloud-platform-components`
  ApplicationSet, and the bundled platform app) GitOps-managed instead of
  hand-applied — eliminating the live-patch drift this repo accumulated. Applied
  once by hand; manual sync to start (mirrors `react-platform`). Deliberately
  excludes `applicationsets/nextcloud-tenants.yaml` (raw Go-template `valueFiles`
  is not directory-source-safe + gated canary drift). See
  `nextcloud-platform/bootstrap/README.md`.
- **tooling**: `/generate-secrets` operator skill
  (`.claude/commands/generate-secrets.md`) — the uniform way to create or repair
  a tenant's in-cluster `nextcloud-secrets` via `create-tenant-secret.sh`,
  outside the full `/add-tenant` flow (e.g. a tenant whose secret was never
  provisioned). Confirms before overwriting an existing secret and never prints
  secret values.
- **argo/projects**: New `nextcloud-platform-core` AppProject
  (`nextcloud-platform/argo/projects/nextcloud-platform-core.yaml`) for the
  privileged platform-infrastructure apps. Unlike the tenant project
  `nextcloud-platform`, it whitelists `scheduling.k8s.io/PriorityClass` and does
  **not** blacklist `ResourceQuota`/`LimitRange` — which the platform `policies`
  app must manage. Adds an after-hours sync window (deny 07:00–17:00 Mon–Fri,
  `manualSync: false`) covering `nextcloud-platform` + `platform-*`; previously
  the `platform-*` component apps had no window.
- **argo/applicationsets**: Captured the previously untracked, live-only
  `nextcloud-platform-components` ApplicationSet into Git
  (`nextcloud-platform/argo/applicationsets/nextcloud-platform-components.yaml`)
  so the per-component platform apps are GitOps-managed.

### Removed
- **argo (bundled platform app)**: Retired the redundant bundled
  `nextcloud-platform` Application (`argo/applications/platform.yaml`) and its
  now-orphan root kustomization (`platform/kustomization.yaml`). Its only content
  was `externalsecrets/rbac.yaml` (the `nextcloud-secret-generator` SA/RBAC),
  which the dedicated `platform-externalsecrets` app already owns — the overlap
  caused a persistent `SharedResourceWarning` on that ClusterRole. Now
  `platform-externalsecrets` is the sole owner. The live retire is a one-time
  `kubectl delete application nextcloud-platform -n argocd --cascade=orphan`
  (orphan keeps the RBAC in place; no secret-generator downtime).

### Changed
- **values/common.yaml (session security)**: Added
  `remember_login_cookie_lifetime => 28800` (8h) to the `proxy.config.php` block,
  matching `session_lifetime`. The "stay logged in" cookie can no longer outlive
  the 8h session, so users re-authenticate at least daily — a deliberate
  fleet-wide security-posture decision (gov tenants). MUST NOT be set lower than
  `session_lifetime` or Nextcloud terminates the session early. Affects all
  tenants; rolls out wave-by-wave (canary first).
- **platform/pgbouncer**: Parked the pgbouncer Deployment at `replicas: 0`. The
  shared CNPG postgres backend (`nextcloud-pg`) is currently unrecoverable and
  there are 0 `dbType: external` tenants, so pgbouncer has no backend and no
  consumers — at `replicas: 2` it just CrashLoopBackOffs on "waiting for
  PostgreSQL backend". Restore to 2 once CNPG is recovered and an external tenant
  needs the pooler. File: `nextcloud-platform/platform/pgbouncer/deployment.yaml`.
- **values/templates (postgres)**: `tenant-template-postgres.yaml` postgres image
  moved from `ghcr.io/conductionnl/nextcloud-images:...sha-6b56bfeda` (pullPolicy
  `Always`) to `docker.io/conduction2022/nextcloud-images:postgres16-ext-sha-8abef67`
  pinned to digest `sha256:7478…b4f8c4` (pullPolicy `IfNotPresent`), matching
  `values/db/postgres.yaml`. New postgres tenants no longer template a dead
  ghcr.io pull (GitHub org shadowbanned).
- **argo (platform-components)**: Repointed the `nextcloud-platform-components`
  ApplicationSet `source.repoURL` from `github.com/conductionnl/Nextcloud-base`
  to `codeberg.org/conduction/Nextcloud-base` (GitHub org shadowbanned; Codeberg
  is canonical since 2026-06-01). The 2026-06-01 cutover patched the tenant
  ApplicationSet and bundled app but missed these component apps, leaving
  `platform-externalsecrets`/`platform-policies` stuck (Sync failed) on a dead
  source.
- **argo (platform apps → core project)**: Moved the bundled `nextcloud-platform`
  app and the `platform-*` component apps from project `nextcloud-platform` to
  `nextcloud-platform-core`. Fixes `platform-policies` SyncFailed
  (`PriorityClass`/`ResourceQuota`/`LimitRange` not permitted in the tenant
  project). Tenant apps stay on `nextcloud-platform` with the guardrail intact.
  - Verified: after the move + a fresh sync, `platform-policies` is
    Synced/Healthy; `platform-redis`/`-pgbouncer`/`-postgres` and the bundled
    `nextcloud-platform` app are Synced/Healthy.
- **platform/externalsecrets**: Excluded `clustersecretstore.yaml` from the
  kustomization. The `ClusterSecretStore` requires the external-secrets.io CRD,
  but the External Secrets Operator is not installed on this cluster (the
  fallback secret Job is used). Including it made `platform-externalsecrets`
  SyncFailed. Re-add only after ESO + CRDs are installed cluster-wide.
  - File: `nextcloud-platform/platform/externalsecrets/kustomization.yaml`
  - Note: takes effect once merged to Codeberg `main` (the app syncs `HEAD`).
- **db/postgres**: Moved the in-cluster PostgreSQL image from
  `ghcr.io/conductionnl/nextcloud-images` to
  `docker.io/conduction2022/nextcloud-images:postgres16-ext-sha-8abef67`.
  Pinned to digest `sha256:7478927e1ad48c28d491a2589683fe6cb7a4f8468cece491915990e988b4f8c4`
  for immutability/auditability, and switched `pullPolicy` from `Always` to
  `IfNotPresent` (redundant given the digest pin).
  - File: `nextcloud-platform/values/db/postgres.yaml`
  - Scope: platform-wide — affects all tenants with `dbType: postgres`. The
    StatefulSet rolls a new DB image, causing brief per-tenant DB downtime on
    pod restart. Sync after 17:00 Amsterdam per the sync-window rules.
  - Verified: tag + digest confirmed present on Docker Hub; `helm template`
    renders `repository@digest` on the `postgresql` DB-server container;
    `smoke-checks.sh --tenant conduction-test` passes (21 checks, 0 errors).
  - Note: the chart's `postgresql-isready` init-container still references the
    image by tag (chart helper does not propagate the digest). Low relevance —
    transient `pg_isready` readiness check, no data or running workload impact.

### Fixed
- **platform/externalsecrets**: Removed the stray `nextcloud-secrets` Namespace
  from `externalsecrets/rbac.yaml` (the kustomization's `namespace:` directive
  renamed it to `nextcloud-platform`, so `platform-externalsecrets` co-claimed
  the platform namespace alongside the bootstrap-managed project file → a
  `SharedResourceWarning` that kept the bootstrap app `OutOfSync`). The namespace
  is now owned solely by the project file (full pod-security labels);
  `platform-externalsecrets` keeps `CreateNamespace=true`.

## History

Earlier changes predate this changelog. See `git log` for full detail. Recent
notable entries:

- 2026-06-01 — Added tenant `pipelinq-server-prod`.
- 2026-06-01 — Argo: dropped the `nc-*` office-hours sync window.
- 2026-06-01 — Argo: pointed sources to Codeberg (GitHub org shadowbanned).
- 2026-05-26 — Added tenants `softwarecatalogus-tilburg-test`,
  `conduction-test`, `conduction-demo`; validator gained `hostnameOverride`
  flag and `-demo` suffix support.
