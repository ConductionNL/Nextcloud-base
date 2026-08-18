### Verwijderd — 2026-08-17 (dode chart `platform/tenant-resources`, en wat dat blootlegde)

`nextcloud-platform/platform/tenant-resources/` is weg. De chart werd door geen
enkele ApplicationSet of Application aangeroepen, stond nergens in een
`sources`-lijst, en de laatste inhoudelijke commit is van 2026-03-16. In het
cluster is geen enkel object te vinden met zijn `helm.sh/chart`-label. Hij is dus
nooit uitgerold.

Dat is op zichzelf onschuldig. Het probleem is wat eraan hing:
`docs/HAVEN-COMPLIANCE.md` voerde deze chart op als de bron van vier controls.
Drie van die claims klopten niet.

| Claim in het compliance-document | Werkelijkheid, gemeten 2026-08-17 |
|---|---|
| elke tenant krijgt een `PodDisruptionBudget` uit deze chart | **nul** PDB's in de hele vloot selecteren de Nextcloud-workload; de enige PDB in een tenant-namespace komt uit de `postgresql`-subchart en beschermt de database |
| `NetworkPolicy` uit deze chart isoleert nieuwe tenants standaard | de Nextcloud-pod heeft **geen enkele** NetworkPolicy; wat er staat komt uit de postgresql-subchart (1) en de React-frontend (3) |
| `ServiceMonitor` uit deze chart | bestaat wél in elke tenant-namespace, maar komt uit de **upstream** nextcloud-chart |
| `ExternalSecret`, namespace, database-job uit deze chart | lopen via `charts/tenant-secret` en de scripts |

`HAVEN-COMPLIANCE.md` is gecorrigeerd: de secties 1, 5, 7 en 9 zeggen nu wat er
draait, met de meting erbij en de datum van de correctie. Het document schreef
zelf al voor wat er moest gebeuren — *"If a claim above stops matching the code,
fix the code or fix this document — do not let them drift apart."*

**Twee openstaande gaten, bewust niet in deze wijziging gedicht.** Geen PDB op de
Nextcloud-workload (beperkt gevolg zolang `replicaCount` 1 is en HPA uit staat,
maar het wordt echt zodra de HA-route landt), en geen NetworkPolicy op de
Nextcloud-pod. Dat laatste is geen documentatiefout maar een beveiligingsbesluit:
een default-deny over ~50 draaiende tenants hoort een eigen change met een
gefaseerde uitrol te zijn.
