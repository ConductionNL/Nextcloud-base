### Toegevoegd — 2026-08-05 (de poort wacht nu op aankomst, zonder credentials)

De poort meette gezondheid, niet of de wijziging was toegepast. Een langere
wachttijd maakt dat waarschijnlijker maar niet zeker. In plaats van Argo te
ondervragen — wat een productie-token in GitHub Actions zou vragen — ondervraagt de
workflow nu de tenant zelf.

`/status.php` geeft naast `installed` en `maintenance` ook `versionstring`. Dat is
het enige publieke signaal dat vertelt *wat* er draait. Per laag gebeurt nu dit:

- **Verandert `image.tag` in `values/common.yaml` door deze commit**, dan wordt de
  verwachte versie uit de commit gelezen en wacht de workflow tot elke host in die
  laag die versie rapporteert. Dat is echt bewijs van aankomst. Daarna pas de
  gezondheidscheck, want aangekomen is niet hetzelfde als stabiel.
- **Verandert de versie niet** (een config-wijziging), dan bestaat dat signaal niet.
  De workflow zegt dat dan expliciet in de log: "geen publiek aankomstsignaal, dit is
  een gezondheidscheck, geen bewijs dat de wijziging is toegepast", en valt terug op
  wachten plus de streak. Een groene run belooft daarmee niet meer dan hij gemeten
  heeft.

Dat dekt dus een deel van de gevallen, en dat deel is precies het risicovolste:
image- en versiewijzigingen zijn de enige die een datamigratie kunnen draaien.

**Geldigheid gecontroleerd.** De versie-extractie is getest op echte commits:
`e0786dc` (de tag-bump) geeft `32.0.13`, zijn parent `32.0.5`. En geen enkele
probe-tenant overschrijft `image.tag` — van de 25 `tag:`-regels in
`values/tenants/` staan er 22 onder `frontend:` (de reactfront) en één onder een
postgres-image; geen enkele onder de Nextcloud-`image:`.

**Eén probe-host bleek fout en is vervangen.** `baarn.commonground.nu` meldde
`30.0.4` terwijl de vloot op `32.0.13` staat. Reden: die host wordt geserveerd uit
namespace `baarn` door de losse Application `baarn-prod-nextcloud`, niet door
`nc-baarn-prod` — zelfde patroon als epe-prod en dinkelland-prod. Hij volgt `release`
dus niet en zou nooit een aankomstsignaal geven. Vervangen door
`buren.commonground.nu` (MariaDB, ApplicationSet-beheerd, op de juiste versie). In
`probe-hosts-live.txt` staat nu de controle die je bij het toevoegen van een host
moet doen.

Los daarvan opgemerkt, niet aangeraakt: `nc-baarn-prod` bestaat én er is een losse
`baarn-prod-nextcloud` in namespace `baarn` die het echte verkeer serveert. Dat is
een schaduw-deployment; de ApplicationSet-variant heeft geen ingress. Zelfde klasse
als epe en dinkelland.
