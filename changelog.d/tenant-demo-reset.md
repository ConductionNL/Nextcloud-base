### Toegevoegd: 2026-10-14 (nachtelijke demo-reset, uit tenzij aangezet)

Een openbare demo-tenant vult zich met wat bezoekers maken. Nieuwe opt-in
component `tenant.components.demoReset` zet zo'n tenant elke nacht terug naar
een gouden momentopname en laadt daarna de voorbeeldsets opnieuw. Aanleiding:
de demogemeente Zuiddrecht (`zuiddrecht-prod`).

Nieuwe lokale chart `charts/tenant-demo-reset` en een aparte ApplicationSet
`nextcloud-tenant-demo-reset` met een post-selector op
`tenant.components.demoReset.enabled`. Zelfde afweging als
`nextcloud-tenant-routes`: geen vierde source in `nextcloud-tenants`, dus de
bestaande tenant-Applications veranderen niet.

De chart levert een ServiceAccount met alleen `pods` get/list en `pods/exec`,
het script als ConfigMap, een nachtelijke CronJob en een CronJob
`demo-reset-golden` die een mens afvuurt. Alles loopt via `kubectl exec` in de
bestaande pods. De momentopname is een template-database in de eigen Postgres
plus een kopie van de datamap op dezelfde PVC.

Veiligheid: `confirmWipe` moet de tenantnaam herhalen (validator, chart en
script). De reset stopt voordat er iets gewist is bij een S3 primary
objectstore, een andere instanceid, of een database en map van verschillende
momenten. Faalt hij daarna, dan blijft de onderhoudsmodus aan. Redis wordt
alleen voor deze instantie geleegd (`occ memcache:distributed:clear`).

Validator: vijftien nieuwe cases. Nieuwe suite
`nextcloud-platform/tests/run-demo-reset-tests.sh`, gedraaid door
`scripts/verify.sh`. Docs: `docs/DEMO-RESET.md`.

Optioneel `limitApps` (`apps` + `exceptGroups`): na de voorbeeldsets zet de
reset elke app uit `apps` aan voor alle groepen behalve `exceptGroups`, per app
apart; een app die zich niet tot groepen laat beperken gaat aan voor iedereen,
met een WARN. Nodig omdat een set groepen aanmaakt die in de momentopname nog
niet bestaan, en omdat de install-hook bij een pin-bump een groepsbeperking
laat vervallen. Eerste gebruik: werkplek-apps alleen voor medewerkers in
Zuiddrecht, inwoners zien het portaal.

**Openstaand:** de ApplicationSet komt pas na een handmatige sync van
`nextcloud-platform-bootstrap`. Het image `alpine/k8s:1.29.2` is op tag
gepind, niet op digest. Nooit op een cluster gedraaid.
