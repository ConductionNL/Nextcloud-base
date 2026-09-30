---
last_reviewed: 2026-09-30
owner: info@conduction.nl
---

# Klantcertificaten: aanvragen, installeren en vernieuwen

Draait de frontend van een tenant op een eigen domein van de klant (bijvoorbeeld `open.roosendaal.nl`) met een gekocht certificaat, dan beheert cert-manager dat cert niet. De tenant staat dan op `frontend.tls.issuer: none` en het secret zaaien we met de hand. Deze pagina beschrijft de hele cyclus: CSR aanmaken, de bestanden van de CA verwerken, installeren, nameten en vernieuwen.

De velden van het `frontend.tls`-blok zelf staan in `React-base` → `docs/ADDING-TENANT.md` (TLS-velden). De tenant-bestanden staan in deze repo, onder `nextcloud-platform/values/tenants/`.

## 1. Een CSR aanmaken

Vraagt de klant een CSR, dan maken wij sleutel en CSR aan. De sleutel blijft bij Conduction; de klant krijgt alleen de `.csr`.

Het sleuteltype hangt af van de CA, dus check eerst wat die accepteert en kies het sterkste dat is toegestaan:

| CA | Accepteert | Kies |
|---|---|---|
| certSIGN | alleen RSA 2048 of 4096, met `sha256`/`sha384`/`sha512WithRSAEncryption` | RSA 4096 |
| Trust Provider | EC P-256 | EC P-256 |

Neem bij RSA nooit 2048: dat is in de internet.nl-audit van 2026-08-18 als phase-out aangemerkt (zie `React-base` → `docs/SECURITY-HEADERS.md`).

    umask 077
    openssl genrsa -out <host>.key 4096
    # of bij EC: openssl ecparam -name prime256v1 -genkey -noout -out <host>.key
    openssl req -new -sha256 -key <host>.key -out <host>.csr \
      -subj "/C=NL/ST=<provincie>/L=<plaats>/O=<organisatie>/CN=<host>" \
      -addext "subjectAltName=DNS:<host>"

Controleer vóór het versturen dat sleutel en CSR bij elkaar horen (beide regels moeten dezelfde hash geven) en dat subject, SAN en algoritmes kloppen. Gebruik `-text` nooit op de sleutel zelf, want dat print de private key.

    openssl pkey -in <host>.key -pubout | sha256sum
    openssl req -in <host>.csr -pubkey -noout | sha256sum
    openssl req -in <host>.csr -noout -verify -text

Bewaar sleutel en CSR in Passwork zodra ze gemaakt zijn. Een sleutel die kwijtraakt maakt het cert dat de CA erop uitgeeft onbruikbaar.

## 2. `fullchain.pem` samenstellen

Een CA levert meestal losse bestanden: het leaf-cert, één of meer intermediates en de root. Het secret wil één bestand met eerst het leaf en daarna de intermediate(s). De root hoort er niet in, want die hebben browsers zelf. Zonder intermediate vinden sommige clients de keten niet en melden ze een onvertrouwd cert.

Plak de bestanden niet met `cat` aan elkaar. De `.cer`-bestanden van Trust Provider hebben Windows-regeleinden en geen afsluitende newline, waardoor de END-regel van het leaf en de BEGIN-regel van de intermediate op één regel belanden. `openssl` accepteert dat, maar `kubectl create secret tls` weigert met `tls: failed to find any PEM data in certificate input`. Laat `openssl` elk cert opnieuw uitschrijven, dat levert schone PEM op:

    { openssl x509 -in <leaf>.cer; openssl x509 -in <intermediate>.cer; } > fullchain.pem

Controleer vóór het zaaien dat de keten klopt en dat `kubectl` het paar accepteert. De tweede regel stuurt niets naar het cluster en faalt ook als sleutel en cert niet bij elkaar horen:

    openssl verify -CAfile <root>.cer -untrusted fullchain.pem fullchain.pem
    kubectl create secret tls test --cert=fullchain.pem --key=<host>.key \
      --dry-run=client -o yaml > /dev/null

## 3. Installeren

De namespace is de kale tenant-naam en de secretnaam staat in het tenant-bestand onder `frontend.tls.secretName`.

### Nieuwe tenant, of een tenant die al op `none` staat

Zaai of vervang het secret met de replace-vorm. Die maakt het secret aan als het nog niet bestaat en vervangt de inhoud als het er al is. Bij een nieuwe tenant doe je dit vóórdat je de tenant-wijziging merget, anders serveert de Ingress even geen bruikbaar cert.

    kubectl -n <tenant> create secret tls <secretName> \
      --cert=fullchain.pem --key=<host>.key \
      --dry-run=client -o yaml | kubectl apply -f -

Een waarschuwing over een ontbrekende `last-applied-configuration`-annotatie is onschuldig als het secret oorspronkelijk door cert-manager is gemaakt.

Staat de tenant al op `none` maar serveert hij toch Let's Encrypt, dan hangt er nog een Certificate van vroeger. Doe dan eerst stap 2 van de volgende sectie.

### Een bestaande tenant omzetten van een issuer naar `none`

Staat een tenant op een issuer, dan beheert cert-manager het secret via een Certificate-object. Een klantcert dat je dan zaait, wordt bij de eerstvolgende vernieuwing weer overschreven met Let's Encrypt.

Het Certificate verdwijnt ook niet vanzelf als je naar `none` gaat. De ingress-shim maakt het aan zodra de annotatie verschijnt, maar ruimt het niet op als de annotatie weggaat. Het blijft Let's Encrypt in het secret vernieuwen, dus de Ingress serveert nooit het klantcert en niets waarschuwt. Gemeten op 29 september 2026: `noaberkracht-accept` stond sinds augustus op `none` en serveerde nog steeds Let's Encrypt, omdat het Certificate nog `Ready` was. Roosendaal had hetzelfde probleem.

De volgorde is daarom:

1. Zet `issuer: none` in het tenant-bestand en merge. Wacht tot Argo gesynct heeft, dus tot de annotatie van de Ingress af is. Lege uitvoer betekent klaar:

       kubectl -n <tenant> get ingress woo-website \
         -o jsonpath='{.metadata.annotations.cert-manager\.io/cluster-issuer}'

2. Verwijder het achtergebleven Certificate. Het secret blijft staan en serveert tot stap 3 het laatste Let's Encrypt-cert, dus er is geen onderbreking. Doe je dit vóórdat stap 1 klaar is, dan maakt cert-manager het Certificate meteen opnieuw aan.

       kubectl -n <tenant> delete certificate <secretName>

3. Zaai het klantcert met de replace-vorm hierboven.

## 4. Nameten

Meet wat er werkelijk geserveerd wordt, niet alleen wat in het secret zit:

    echo | openssl s_client -connect <host>:443 -servername <host> 2>/dev/null \
      | openssl x509 -noout -subject -issuer -dates

Staat de host achter Cloudflare for SaaS (CNAME naar `saas.openwoo.app`), dan zie je zo het edge-cert van Cloudflare en niet het klantcert. Het klantcert zit dan alleen op het stuk Cloudflare → origin. Meet de origin door rechtstreeks naar de loadbalancer te verbinden met de klanthost als SNI:

    echo | openssl s_client -connect 81.24.6.82:443 -servername <host> 2>/dev/null \
      | openssl x509 -noout -subject -issuer -dates

Wil de klant dat bezoekers het eigen cert zien, dan moet het ook als custom certificate op de custom hostname in Cloudflare. Dat is nog nergens beschreven: `cluster-infra/docs/cloudflare-ipv6.md` richt custom hostnames in met een Cloudflare-managed cert.

## 5. Vervaldatum en vernieuwen

Niets bewaakt de vervaldatum. Cert-manager kijkt niet naar dit secret, en de alert `CertificateExpiringSoon` leest een metriek die alleen voor Certificate-objecten bestaat. Zet de vervaldatum daarom:

- als commentaar bij `issuer: none` in het tenant-bestand;
- in de agenda, ruim vóór de vervaldatum, want de klant moet de verlenging bij de CA regelen.

Bij verlenging vraagt de klant meestal om een nieuwe CSR. Maak dan een nieuwe sleutel (stap 1), verwerk de nieuwe bestanden (stap 2) en vervang het secret met de replace-vorm (stap 3). De tenant staat al op `none`, dus aan het tenant-bestand verandert alleen de vervaldatum in het commentaar.

Het secret staat niet in git. Raakt de namespace kwijt, dan is het cert kwijt en is opnieuw zaaien vanuit Passwork de enige herstelweg.
