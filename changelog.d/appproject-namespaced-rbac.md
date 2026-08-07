### Gewijzigd — 2026-08-07 (AppProject staat namespaced RBAC toe)

`namespaceResourceWhitelist` van het AppProject `nextcloud-platform` accepteert
nu `rbac.authorization.k8s.io/Role` en `RoleBinding`.

Aanleiding: de control-plane van `openwoo-app-config` kon niet meer syncen.
Die app wil zijn eigen pod `get`/`update` geven op één ConfigMap in zijn eigen
namespace, en kreeg per resource

    resource rbac.authorization.k8s.io:Role is not permitted in project nextcloud-platform

Eén ongeldige task laat de hele sync falen, dus ook de rest van die app bleef
staan (`OutOfSync`, wel `Healthy` — de draaiende pod was niet geraakt).

De situatie was omgekeerd aan wat je zou verwachten. De
`clusterResourceWhitelist` stond `ClusterRole` en `ClusterRoleBinding` al toe,
maar de namespaced variant niet. Van die twee is een `Role` juist de smallere:
hij geldt in precies één namespace. Het gevolg was dat een app die een recht
binnen zijn eigen namespace wilde verlenen, geen andere uitweg had dan een
cluster-brede toekenning — het tegenovergestelde van least privilege.

Dit verruimt het project dus niet wezenlijks; het maakt de smalle variant
beschikbaar naast de brede die er al was. Wie binnen dit project een `Role`
aanmaakt kan daarmee geen rechten verlenen die met een `ClusterRole` niet ook
al konden.

Geen effect op bestaande apps: het is een uitbreiding van een whitelist, geen
wijziging aan een bestaande regel. Tenants renderen ongewijzigd
(`./scripts/verify.sh` groen, validator + smoke-render over alle tenants).
