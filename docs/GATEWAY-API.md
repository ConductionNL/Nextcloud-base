---
last_reviewed: 2026-08-17
owner: info@conduction.nl
---

# Gateway API-route voor een Nextcloud-tenant

Het platform migreert van ingress-nginx (upstream gearchiveerd, geen
CVE-patches meer) naar Gateway API met Envoy Gateway. De achtergrond en de
platformkant staan in `cluster-infra/docs/gateway-api.md`; deze pagina gaat over
de Nextcloud-kant.

## De verdeling

Cluster-infra bezit de `Gateway`. Deze repo bezit de **route** van een tenant:
`charts/tenant-httproute`, meegerenderd door de ApplicationSet `nextcloud-tenants`
als vierde source, precies zoals `tenant-hpa` en `tenant-secret`. Cluster-infra
heeft daardoor geen schrijfrecht in tenant-namespaces nodig.

De chart levert twee objecten: de `HTTPRoute` en een `ReferenceGrant` die de
Gateway het TLS-secret van deze tenant laat lezen. Die grant hoort hier omdat
een ReferenceGrant altijd staat in de namespace die iets weggeeft.

## Aanzetten

In `nextcloud-platform/values/tenants/tenant-<naam>.yaml`:

    gateway:
      nextcloud: true
      sectionName: https-<listener>

`sectionName` is **verplicht**. De chart faalt hard zonder, en dat is met opzet
— zie de volgende paragraaf. De vlaggen `frontend` en `nextcloud` staan los, want
een tenant kan zijn WOO-frontend eerder migreren dan zijn Nextcloud.

Zonder `gateway:`-blok rendert er niets extra's, ook geen `enabled: false`. Een
blok dat altijd meegaat zou alle 84 Applications tegelijk laten hersyncen.

## Waarom dit nog niet schaalt

De frontends hebben het makkelijk: `*.openwoo.app` en `*.accept.openwoo.app`
vallen onder één wildcard-certificaat, dus één listener bedient de hele vloot.

Nextcloud-hosts staan onder `commonground.nu` en krijgen **elk een eigen
certificaat via HTTP-01**. Daardoor heeft elke tenant een eigen listener op de
gedeelde Gateway nodig, met een eigen `certificateRef`. Dat werkt voor een
canary en niet voor 84 tenants.

De oplossing is dezelfde die voor openwoo.app al genomen is: een
wildcard-certificaat voor `*.commonground.nu` en `*.accept.commonground.nu` via
DNS-01. De zone staat al bij Cloudflare en de ClusterIssuer `letsencrypt-dns`
bestaat al. Dat besluit is nog niet genomen; tot dan is de listener handwerk per
tenant in `cluster-infra/envoy-gateway/config/gateway.yaml`.

## Wat de route vertaalt

De annotaties uit `values/common.yaml` worden filters. De waarden zijn **gemeten**
aan de response van een draaiende tenant, niet afgeleid uit de annotaties — dat
scheelde twee fouten, want `nginx.ingress.kubernetes.io/hsts-max-age` is geen
geldige annotatie maar een ConfigMap-instelling.

| nginx | HTTPRoute |
|---|---|
| `proxy-*-timeout: 1800` | `timeouts.request` + `backendRequest` — **niet optioneel**, Envoy's default is 15s |
| `enable-cors` + `cors-allow-headers` | `CORS`-filter |
| `hsts*` | `ResponseHeaderModifier` |
| `use-forwarded-headers`, `enable-real-ip` | `ClientTrafficPolicy` op Gateway-niveau (cluster-infra) |
| `proxy-body-size: 16G` | niets — Envoy buffert niet by default |

Níét vertaald, omdat het niet op de Ingress staat: de webfinger-, nodeinfo-,
host-meta- en CalDAV/CardDAV-omleidingen. Die zitten in de nginx-sidecar in de
pod (`values/common.yaml`, `nginx.config.default`) en blijven onveranderd achter
de HTTPRoute staan.

## Wat er gebeurt als je het aanzet — en wat níét

De HTTPRoute komt náást de Ingress. Het verkeer verschuift **niet**: het
DNS-record blijft naar ingress-nginx wijzen, want external-dns laat een bestaand
record met rust zolang de Ingress bestaat. Gemeten 2026-08-17.

De cutover is dus het weghalen van de Ingress. Doe dat niet lichtvaardig: het
certificaat van deze host wordt via HTTP-01 over díé Ingress vernieuwd. Verdwijnt
hij voordat cert-manager's `--enable-gateway-api` aanstaat (die vlag staat nu
uit), dan breekt de vernieuwing stil en pas bij de eerstvolgende renewal.

## Valideren

Een `curl` op de hostnaam raakt nog nginx. Forceer de resolutie:

    IP=81.24.11.239
    H=<tenant>.accept.commonground.nu
    curl -sI --resolve "$H:443:$IP" "https://$H/status.php"
    curl -sI --resolve "$H:443:$IP" "https://$H/.well-known/caldav"
    curl -sI --resolve "$H:80:$IP"  "http://$H/"

Verwacht 200, 301, 308. Doe daarnaast een upload boven de drempel en een request
dat langer dan 15 seconden duurt — dat is wat de `timeouts` moeten bewijzen.

Vier verschillen met nginx zijn bekend en gemeten; ze staan met uitleg in
`cluster-infra/docs/gateway-api.md`. Geen ervan is een regressie, maar ze zijn
zichtbaar voor een client en horen langs de eigenaar vóór een cutover.
