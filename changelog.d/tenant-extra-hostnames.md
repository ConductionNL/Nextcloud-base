### Toegevoegd — 2026-10-13 (tenant.extraHostnames)

Een tenant kan nu op meer dan één hostnaam antwoorden. Nieuw optioneel veld
`tenant.extraHostnames` (lijst). De ApplicationSet `nextcloud-tenants`:

- zet elke extra host achter de primaire host in `nextcloud.trustedDomains`
  (en daarmee in `NEXTCLOUD_TRUSTED_DOMAINS`);
- rendert via `extraManifests` een tweede Ingress `nextcloud-extra-hosts`,
  omdat chart 8.9.0 in zijn eigen Ingress alleen `nextcloud.host` als rule zet
  (`ingress.hosts` uit de ApplicationSet leest die chart niet);
- geeft elke extra host een eigen TLS-blok en dus een eigen Certificate via
  HTTP-01, zodat één host met nog niet kloppende DNS de andere niet tegenhoudt;
- neemt annotaties, `ingressClassName` en poort via de `tpl` van de chart over
  uit dezelfde values als de hoofd-Ingress: geen tweede kopie van de
  nginx-instellingen.

**Bestaande tenants renderen byte-identiek.** Het blok wordt alleen geëmit als
de lijst gezet is. Gemeten: alle 89 tenantbestanden op main en op deze branch
gerenderd (Argo-goTemplate met sprig en `missingkey=default`, daarna
`helm template` met chart 8.9.0 en dezelfde valueFiles-volgorde), values en
manifests per tenant byte voor byte gelijk.

`validate-values.sh` controleert het nieuwe veld (lijst, geldige DNS-namen,
geen dubbele, niet de primaire host, onder `commonground.nu` alleen de eigen
namen, unieke secretnaam ≤ 253) en weigert over alle tenantbestanden heen een host die
twee tenants claimen (primaire host, `extraHostnames`, `frontend.host`,
`frontend.extraHosts`), met fixtures in
`nextcloud-platform/tests/cases/tenant-extra-hostnames-*`.

Bekende beperkingen: `trusted_domains` wordt alleen bij de eerste installatie
geschreven; `charts/tenant-httproute` neemt nog één host. Zie
`docs/ADDING-TENANT.md`.
