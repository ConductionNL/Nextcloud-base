---
last_reviewed: 2026-07-10
owner: info@conduction.nl
---

# Agent-cataloog (referentie)

Guardrails voor agents in deze repo, per het handboek-formaat
(org → Werken met agents). **Niet in dit cataloog = eerst vragen.**

## Operaties

| Operatie | Autonomie | Idempotentie | Verificatie |
|---|---|---|---|
| Tenant-bestand aanmaken (`values/tenants/tenant-<org>-<env>.yaml` uit de template) | **voorstel-eerst** (toon het volledige bestand, schrijf pas na akkoord — creatie-regel 2026-07-10) | declaratief: bestand bestaat al → geen tweede aanmaak (check eerst) | `./scripts/verify.sh` (validator + smoke-render) groen |
| Frontend-blok (`tenant.frontend:`): nieuw toevoegen **voorstel-eerst**, bestaand wijzigen autonoom | zie creatie-regel | gewenste staat in het bestand; gelijke staat → geen diff | verify hier én react-base `./scripts/verify.sh` (vloot-render) |
| Tenant-waarden wijzigen (resources, apps, phpMemoryLimit) | autonoom | idem (declaratief bestand) | verify groen; render-diff tonen bij twijfel |
| Docs bijwerken (zelfde wijziging als de code) | autonoom | tekstueel; front-matter `last_reviewed` bijwerken | docs-contract-gate |
| Tenant-bestand verwijderen | mens-vereist | n.v.t. (voorbereiding is een diff) | agent bereidt voor; mens beslist + pusht; REMOVING-TENANT.md |
| Secrets aanmaken (`create-tenant-secret.sh`, kubectl create secret) | mens-vereist | scripts zijn idempotent, maar secret-handling blijft mensenwerk | mens draait; agent mag het commando klaarzetten |
| Elke `kubectl`/Argo-mutatie (scale, delete, patch, sync) | mens-vereist | — | agent levert exact commando + rollback; mens voert uit |
| Chart-/platform-upgrade, canary-promotie, wave-wijziging | mens-vereist | — | ROLLOUTS.md-flow; sync windows gelden |
| Push naar welke remote dan ook | mens-vereist | — | pre-push gates draaien bij de mens |
| `git push --no-verify`, secrets/tokens in git, live edits buiten GitOps | verboden | — | — |

## Grondwaarheid en gedrag

- Handboek (MCP `conduction-docs`) boven modelkennis; de docs van deze
  repo beschrijven de werkelijke flows — bij twijfel eerst lezen.
- GET-check-first: vóór elke wijziging de huidige staat lezen (bestaat
  het bestand, wat rendert er nu); een herhaalde run op een correcte
  staat wijzigt niets en zegt dat.
- Argo CD sync't main met selfHeal: handmatige cluster-wijzigingen
  worden teruggedraaid — wijzig via git of niet.
