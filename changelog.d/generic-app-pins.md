### Gewijzigd — 2026-10-13 (generieke app-pins, elke Conduction-app op een GitHub-release)

`tenant.apps.versions` is generiek geworden. Elke sleutel is een app-id, de waarde
een versie, ook unstable prereleases van `development`. Zo kan een demo-tenant
portaliq, dossiq, pipelinq en de rest op een build van `development` draaien.
Besloten door Ruben op 2026-10-13.

- De ApplicationSet geeft alle pins mee als `CONDUCTION_APP_VERSIONS="id=versie ..."`,
  alleen als een tenant iets pint. De drie oude env vars blijven en winnen.
- De install-hook in `values/common.yaml` haalt een gepinde app van
  `github.com/ConductionNL/<id>/releases/download/v<versie>/<id>-<versie>.tar.gz`
  en controleert hem vóór hij iets vervangt: `.sha256` als de release die
  publiceert (een integriteitscheck tegen een kapotte download, geen
  herkomstcontrole: de checksum komt uit dezelfde release), één topmap gelijk
  aan het id, geen absolute of `..`-paden, geen symlinks of hardlinks, het id en
  de gepinde versie in `appinfo/info.xml`, en na `occ app:enable` de gepinde
  versie. Stond de app al aan, dan doet `occ app:enable` op Nextcloud 32 niets;
  de hook draait dan één keer `occ upgrade`, na alle pins, en controleert de
  versie daarna. Beide downloads gaan alleen over https, ook bij een redirect,
  en hebben tijdsgrenzen. Falen is luid (log en stderr), laat de app staan en
  schrijft geen state, dus de volgende start probeert opnieuw. Een start die
  niets installeert of vervangt slaat `db:add-missing-indices` en
  `maintenance:repair --include-expensive` over; de ERROR staat er dan nog
  steeds. De vorige code (ook een gebundelde `apps/<id>`) gaat tijdens de wissel
  opzij en komt terug als verplaatsen, enable, upgrade of de versiecheck faalt.
  Voorheen werd een mislukte download stil geslikt, de gebundelde app al
  verwijderd en de state toch geschreven.
- De state-sleutel bevat nu elke pin. Voor de drie oude apps is hij byte voor
  byte gelijk aan de oude sleutel, zodat bestaande tenants niet herinstalleren.
- `before-starting` en `post-installation` zijn één script via een YAML-anker.
- `validate-values.sh` weigert een pin voor een app die niet in
  `tenant.apps.enabled` staat, en een sleutel die geen app-id is.
- Nieuw: `nextcloud-platform/tests/run-hook-tests.sh`, met pariteit tegen de
  bevroren oude hook. Draait mee in `scripts/verify.sh`.

De openconnector-pin was niet kapot: releases tot 0.2.24 heten nog
`openconnector-*.tar.gz` en werken. Latere builds zijn de app `integriq`; die
pin je onder `integriq`.

Blast radius: de hooktekst verandert voor élke tenant, dus de `hooks-hash`
annotatie verandert en elke tenant-pod herstart in het platformvenster. De
bootstrap zelf slaat over voor tenants waarvan de state al klopt.
