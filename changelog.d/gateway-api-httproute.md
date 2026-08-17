### Toegevoegd — 2026-08-17 (Gateway API-route per tenant, uit tenzij aangezet)

Het platform migreert weg van ingress-nginx: upstream gearchiveerd op
2026-03-24, geen CVE-patches meer, en de controller draait met
`allow-snippet-annotations: true` + `annotations-risk-level: Critical` — elke
namespace met Ingress-rechten kan er nginx-configuratie mee injecteren.

Nieuwe lokale chart `charts/tenant-httproute`, meegerenderd door
`nextcloud-tenants` als vierde source, net als `tenant-hpa` en `tenant-secret`.
Levert een `HTTPRoute` naast de bestaande Ingress plus een `ReferenceGrant` die
de gedeelde Gateway het TLS-secret van de tenant laat lezen. Die grant hoort
hier omdat een ReferenceGrant altijd in de namespace staat die iets weggeeft.

Opt-in per tenant:

    gateway:
      nextcloud: true
      sectionName: https-<listener>

**Bestaande tenants zien geen enkele wijziging in hun values** — het blok wordt
alleen geëmit als de vlag er staat, ook geen `enabled: false`. Dat is opzet: een
blok dat altijd meegaat zou alle 84 Applications tegelijk laten hersyncen.
`canary-accept` is de enige tenant die hem aanzet.

Drie dingen die tijdens de bouw uit metingen bleken en niet uit de manifests:

- **De timeouts zijn niet optioneel.** Envoy's default route-timeout is 15
  seconden, nginx staat op 1800. Zonder expliciete `timeouts` breekt elke upload,
  en pas onder belasting.
- **De filterwaarden zijn gemeten, niet afgeleid.**
  `nginx.ingress.kubernetes.io/hsts-max-age` is geen geldige annotatie maar een
  ConfigMap-instelling, dus de `15552000` in `values/common.yaml` doet niets — op
  de lijn staat de controller-default `31536000`.
- **Aanzetten verschuift geen verkeer.** external-dns laat een bestaand record
  met rust zolang de Ingress bestaat. De cutover is het wéghalen van de Ingress,
  niet het bijzetten van de route — en daarbij breekt de HTTP-01-vernieuwing van
  het certificaat zolang cert-manager's `--enable-gateway-api` uit staat.

Wat níét vertaald hoefde: de webfinger-, nodeinfo-, host-meta- en
CalDAV/CardDAV-omleidingen staan niet op de Ingress maar in de nginx-sidecar in
de pod, en blijven daar onveranderd achter de HTTPRoute staan.

Bekende beperking: Nextcloud-hosts hebben elk een eigen HTTP-01-certificaat, dus
elke tenant heeft een eigen listener op de gedeelde Gateway nodig. Dat schaalt
niet naar 84. De oplossing is een DNS-01-wildcard voor `*.commonground.nu`,
zoals al gedaan is voor openwoo.app; dat besluit staat open.

Nieuwe pagina `docs/GATEWAY-API.md`.
