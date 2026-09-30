### Toegevoegd — 2026-09-30 (runbook klantcertificaten)

Nieuw: `docs/KLANTCERTIFICATEN.md`, de hele cyclus van een gekocht cert op een klantdomein. Het runbook beschrijft het aanmaken van de CSR, het samenstellen van `fullchain.pem`, het installeren met `issuer: none`, het nameten en het vernieuwen.

Aanleiding: de CSR's voor Roosendaal (certSIGN) werden op 2026-09-30 afgekeurd. Ze waren gemaakt met EC P-256, naar het voorbeeld van de Trust Provider-set van Dinkelland, Tubbergen en Noaberkracht, maar certSIGN accepteert alleen RSA 2048 of 4096. Er stond nergens hoe je een CSR maakt, dus het sleuteltype is gekopieerd in plaats van gekozen. Het runbook zegt nu dat je eerst checkt wat de CA accepteert, en dat je bij RSA 4096 neemt (RSA-2048 is in de audit van 2026-08-18 als phase-out aangemerkt).

De stappen voor `fullchain.pem`, het omzetten van een bestaande tenant naar `none` en het nameten achter Cloudflare for SaaS stonden als niet-gepushte wijziging in `React-base` → `docs/ADDING-TENANT.md`. Ze staan nu hier, omdat de tenant-bestanden in deze repo staan. `ADDING-TENANT.md` in React-base linkt ernaar.
