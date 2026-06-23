# Documentatieoverzicht

Begin bij **`ARCHITECTURE.md`** voor het grote plaatje; duik daarna in het hoofdstuk dat je
nodig hebt. Laatst geverifieerd 2026-06-23.

> **Codeberg vs GitHub:** Argo CD deployt vanaf **Codeberg** (`codeberg` remote). De
> GitHub-remote is een *mirror* die Argo negeert — `git push origin …` deployt dus niet.
> Push naar de `codeberg` remote. Zie `ARCHITECTURE.md` §1-2.

## Hoofdstuk 0 - Het grote plaatje

- `ARCHITECTURE.md` - **start hier**: repos, GitOps-/secret-/auth-flows, namespace-conventie,
  bekende issues. De architectuur woont hier (niet langer in de top-`README.md`).

## Hoofdstuk 1 - Wat is dit platform?

- `../README.md` - korte platformintro + verwijzing naar deze docs
- `DATABASE.md` - databaseopties (MariaDB / in-cluster PG / external PG) en keuzes
- `SECRETS.md` - secretsbeheer: script-applied vs ESO (managed tenants)

## Hoofdstuk 2 - Tenants toevoegen of wijzigen

- `ADDING-TENANT.md` - tenant toevoegen (tenant-bestand, waarden, secrets)
- `REMOVING-TENANT.md` - tenant veilig verwijderen (let op: namespace wordt **niet**
  automatisch opgeruimd — `preserveResourcesOnDeletion: true`)
- `CONFIG-CHANGES.md` - Nextcloud-config wijzigen via GitOps (env-var vs config.php)
- `CHECKS-AND-BALANCES.md` - PR-classificatie, labels, checks en gates

## Hoofdstuk 3 - Canary ring en rollouts

- `ROLLOUTS.md` - canary-ring model en promotieflow (`tenant.chartVersion`, `tenant.canary`)
- `UPGRADE.md` - upgradeprocedure en relatie met de canary-aanpak

## Hoofdstuk 4 - Technische documentatie en operations

- `OPERATIONS.md` - operationele runbooks (reset, troubleshooting, PVC-resize, logs)
- `CHECKS-AND-BALANCES.md` - technische checks/verify workflows

## Conventies (gelden overal)

- **Namespace = kale tenant-naam** (bv. `straatje-accept`). De Argo-*applicatie* heet
  `nc-<tenant>`, maar de namespace is de kale naam — niet `nc-<tenant>`.
- **Chart-versie** staat in de ApplicationSet (`targetRevision`, default `8.9.0`) en
  per-tenant via `tenant.chartVersion` — niet in `values/common.yaml`.

## Labels (PR governance)

Elke PR moet exact één passend label hebben (in GitHub; CI-governance leeft daar, deploy
gebeurt via Codeberg):

- `change/tenant-additive` - alleen tenant-bestanden
- `change/platform` - platform/mixed wijzigingen
