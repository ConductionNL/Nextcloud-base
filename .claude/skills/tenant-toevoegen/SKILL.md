---
name: tenant-toevoegen
description: Voeg een Nextcloud-tenant toe (met optionele WOO-frontend) volgens het cataloog — GET-check-first, template, verify-gates. Gebruik bij "tenant toevoegen", "nieuwe gemeente", "tenant aanmaken".
---

# Tenant toevoegen

Volg het cataloog (`docs/agents.md`); dit is een **voorstel-eerst**-
operatie (creatie-regel): je schrijft het tenant-bestand pas ná
expliciet akkoord in de sessie. De push doet altijd een mens.

1. **GET-check-first**: bestaat
   `nextcloud-platform/values/tenants/tenant-<org>-<env>.yaml` al?
   Zo ja: meld "al aanwezig", toon de huidige inhoud en stop (geen diff
   bij tweede run — idempotentie-eis).
2. **Voorstel-eerst**: toon het volledige beoogde tenant-bestand (en de
   CHANGELOG-regel) in de sessie en wacht op expliciet akkoord vóór je
   iets schrijft. Geen akkoord = niets aanmaken.
8. Naamconventie: `<org>-<accept|test|demo|prod>`; hostnames buiten
   `commonground.nu` vereisen `hostnameOverride: true` met een
   commentaarregel waarom.
3. Kopieer `values/templates/tenant-template.yaml`; vul minimaal
   `tenant.name`, `tenant.environment`, `tenant.dbType`,
   `tenant.apps.enabled`. WOO-frontend? Voeg het `tenant.frontend:`-blok
   toe (zie de React-base sectie in het handboek via `conduction-docs`).
4. Secrets: bereid het commando voor
   (`scripts/create-tenant-secret.sh`), voer het NIET uit — mens-vereist.
5. Verify: `./scripts/verify.sh` moet groen; bij een frontend-blok ook
   `../react-base/scripts/verify.sh`.
6. Docs: geen (tenant-bestanden zijn self-describing), tenzij de
   wijziging een conventie raakt — dan de betreffende pagina mee.
7. Commit met heldere message; geef de push en het secret-commando aan
   de mens, met het Argo-gevolg erbij (appset maakt `nc-<naam>` +
   evt. `<naam>-reactfront`).
