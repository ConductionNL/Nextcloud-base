---
last_reviewed: 2026-08-03
owner: info@conduction.nl
---

# Documentatieoverzicht

Begin bij **`ARCHITECTURE.md`** voor het grote plaatje; duik daarna in het
hoofdstuk dat je nodig hebt.

> **Waar Argo van deployt:** **GitHub** (`origin`,
> `ConductionNL/Nextcloud-base`), sinds de terugmigratie van 2026-08-03. Een
> merge naar `main` deployt dus wél — en met `selfHeal` op 81 van de 82 apps
> gebeurt dat fleet-wide en meteen. Zie `ARCHITECTURE.md` §1-2.
>
> Kom je nog de oude regel tegen ("Argo reads Codeberg, never GitHub"), dan is
> die achterhaald.

## Hoofdstuk 0 - Het grote plaatje

- `ARCHITECTURE.md` - **start hier**: repos, GitOps-/secret-/auth-flows,
  namespace-conventie, bekende issues.

## Hoofdstuk 1 - Wat is dit platform?

- `../README.md` - korte platformintro + verwijzing naar deze docs
- `DATABASE.md` - databaseopties (MariaDB / in-cluster PG / external PG) en keuzes
- `SECRETS.md` - secretsbeheer: script-applied vs ESO (managed tenants)

## Hoofdstuk 2 - Tenants toevoegen of wijzigen

- `ADDING-TENANT.md` - tenant toevoegen (tenant-bestand, waarden, secrets).
  De WOO PWA-frontend van een tenant leeft in de repo `React-base`.
- `REMOVING-TENANT.md` - tenant veilig verwijderen (let op: namespace wordt
  **niet** automatisch opgeruimd — `preserveResourcesOnDeletion: true`)
- `CONFIG-CHANGES.md` - Nextcloud-config wijzigen via GitOps (env-var vs config.php)
- `CHECKS-AND-BALANCES.md` - PR-classificatie, labels, checks en gates

## Hoofdstuk 3 - Canary ring en rollouts

- `ROLLOUTS.md` - canary-ring model en promotieflow (`tenant.chartVersion`, `tenant.canary`)
- `UPGRADE.md` - upgradeprocedure en relatie met de canary-aanpak

## Hoofdstuk 4 - Operationele runbooks

- `TENANT-OPERATIONS.md` - tenant reset, volledig verwijderen, opnieuw opzetten
- `STORAGE-OPERATIONS.md` - PVC resizen, S3-databeheer
- `DEBUGGING.md` - database-shell/backup, logs, occ-status, one-liners
- `EMERGENCY.md` - noodprocedures (crashloops, sync-falen, storage vol,
  alles uitschakelen)

## Conventies (gelden overal)

- **Namespace = kale tenant-naam** (bv. `straatje-accept`). De Argo-*applicatie*
  heet `nc-<tenant>`, maar de namespace is de kale naam — niet `nc-<tenant>`.
- **Chart-versie** staat in de ApplicationSet (`targetRevision`, default `8.9.0`)
  en per-tenant via `tenant.chartVersion` — niet in `values/common.yaml`.

## Labels (PR governance)

Elke PR moet exact één passend label hebben (in GitHub; CI-governance én
deploy leven daar):

- `change/tenant-additive` - alleen tenant-bestanden
- `change/platform` - platform/mixed wijzigingen
