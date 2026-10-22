### Gewijzigd — 2026-10-22 (Nextcloud-image naar 32.0.15-fpm, security)

De platform-default in `values/common.yaml` gaat van `nextcloud:32.0.13-fpm` naar
`nextcloud:32.0.15-fpm` vanwege een kritieke security-release. Dit raakt de 84
tenants zonder eigen `image:`-override. Het is een patch-bump binnen 32.0.x, dus
geen downgrade en geen grote schema-sprong. De wijziging is goedgekeurd door de
backend lead, buiten de gebruikelijke canary-eerst-volgorde vanwege de urgentie.

Niet meegenomen:

- `live-prod` pinde al `32.0.15-fpm` in zijn eigen tenant-bestand en blijft
  ongewijzigd.
- De zeven soap-tenants (`ermelo-prod`, `harderwijk-prod`, `meerinzicht-prod`,
  `rijswijk-accept`, `rijswijk-prod`, `vaals-accept`, `zeewolde-prod`) blijven op
  `32.0.6-fpm-soap`: er bestaat nog geen 32.0.15-soap-image in
  `ConductionNL/nextcloud-images`. Naar het officiële image zetten zou soap
  (Woo BCT) laten vallen.
