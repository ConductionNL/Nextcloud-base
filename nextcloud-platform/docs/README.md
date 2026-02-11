# Documentatieoverzicht

Deze documentatie is ingedeeld in 4 vaste hoofdstukken.

## Hoofdstuk 1 - Wat is dit platform?

Gebruik dit om snel het platformconcept en de architectuur te begrijpen.

- `../README.md` - platformintro, architectuur, repository-structuur
- `DATABASE.md` - databaseopties en keuzes
- `SECRETS.md` - secretsbeheer en aanpak

## Hoofdstuk 2 - Tenants toevoegen of wijzigen

Gebruik dit voor dagelijkse tenant-operaties (nieuw, wijzigen, verwijderen).

- `ADDING-TENANT.md` - tenant toevoegen (templates, waarden, secrets)
- `REMOVING-TENANT.md` - tenant veilig verwijderen
- `CHECKS-AND-BALANCES.md` - PR-classificatie, labels, checks en gates

## Hoofdstuk 3 - Canary ring en rollouts

Gebruik dit voor veilige promotie van platformwijzigingen en batch-rollouts.

- `ROLLOUTS.md` - canary ring model en promotieflow
- `UPGRADE.md` - upgradeprocedure en relatie met canary-aanpak

## Hoofdstuk 4 - Technische documentatie en operations

Gebruik dit voor diepere technische details en beheer.

- `OPERATIONS.md` - operationele runbooks (reset, troubleshooting, etc.)
- `CHECKS-AND-BALANCES.md` - technische checks/verify workflows

## Labels (PR governance)

Voor governance-checks moet elke PR exact een passend label hebben:

- `change/tenant-additive` - alleen tenant-bestanden
- `change/platform` - platform/mixed wijzigingen

Waar zet je dit:

1. Open de PR in GitHub
2. Rechterzijbalk -> **Labels**
3. Selecteer het juiste label

