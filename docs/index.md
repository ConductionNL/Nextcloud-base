---
last_reviewed: 2026-08-10
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
- `CNPG-MIGRATIE.md` - afweging en plan voor consolidatie naar CloudNativePG.
  Bevat de meting die de kostenclaim onderuit haalt: **nog niet besloten**
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

## Hoofdstuk 5 - Scripts

De scripts in `nextcloud-platform/scripts/`. `scripts/verify.sh` bewaakt dat
deze lijst compleet blijft.

| Script | Wat het doet |
|---|---|
| `validate-values.sh` | Valideert alle tenant-bestanden (vereiste velden, verboden velden, patronen) |
| `smoke-checks.sh` | Rendert de Helm-charts per tenant en valideert de manifests |
| `check-themes.sh` | Handmatige audit: toetst `themeClassname` aan conduction-theme én aan de CSS-bundle van een draaiend frontend-pod (geen CI-check, zie het script voor de reden) |
| `classify-change.sh` | Classificeert een commit-range als `platform`, `tenant-additive` of `mixed` (gebruikt door de promotie-workflow) |
| `collect-changelog.sh` | Voegt de per-PR changelog-fragmenten samen tot één sectie |
| `create-platform-secrets.sh` | Maakt het platform-secret `pgbouncer-credentials` aan |
| `create-postgres-admin-secret.sh` | Maakt het PostgreSQL-adminsecret dat de provisioning-Job gebruikt om tenant-databases en -users aan te maken |
| `create-tenant-secret.sh` | Maakt `nextcloud-secrets` voor één tenant (`--postgres` of MariaDB) |
| `cutover-tenant.sh` | Patcht `trusted_domains` en `overwrite.cli.url` in de live pod na het weghalen van een `tenant.hostname`-migratieoverride |
| `argocd-sync.sh` | Forceert een hard refresh + sync voor één of meer Argo Applications |
| `install-dev-tools.sh` | Installeert lokale tooling (yamllint, kubeconform, kube-score, conftest, gitleaks) |

Verwijderen doe je niet met een script uit deze repo, maar met
`openwoo-app-config/scripts/cleanup-tenant.sh` — zie `REMOVING-TENANT.md`.

### Tests

`nextcloud-platform/tests/run-tests.sh` houdt elke check in
`validate-values.sh` aan een goed- én een foutgeval (`tests/cases/`, per case
een `.yaml` met precies één afwijking en een `.expect` met `PASS` of de
vereiste deelstrings). `scripts/verify.sh` draait de suite mee.

Dat de validator over de echte vloot groen is, zegt alleen dat de huidige
bestanden schoon zijn — niet dat een check nog aanslaat op een fout die niemand
meer maakt. Een nieuwe check hoort dus met minstens twee cases te komen.

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
