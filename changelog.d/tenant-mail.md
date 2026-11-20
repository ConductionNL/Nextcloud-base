### Toegevoegd — 2026-10-14 (uitgaande mail per tenant, opt-in)

Een tenant kan nu mail versturen via SMTP met `tenant.mail` in zijn
tenantbestand (`enabled`, `fromAddress`, `domain`, optioneel `port` en
`secure`). Aanleiding: de demotenant `zuiddrecht-prod` heeft mail nodig voor
registratie en notificaties, en geen tenant op het platform had SMTP.

- De ApplicationSet zet bij `tenant.mail.enabled: true` de env vars
  `MAIL_FROM_ADDRESS`, `MAIL_DOMAIN`, `SMTP_SECURE`, `SMTP_PORT` en, uit
  `nextcloud-secrets`, `SMTP_HOST`, `SMTP_NAME`, `SMTP_PASSWORD`, en zet
  `nextcloud.defaultConfigs.smtp.config.php` aan voor alleen die tenant.
- De secret-sleutels (`smtp-host`, `smtp-username`, `smtp-password`) zijn
  `optional`. Bewust niet via `nextcloud.mail.enabled` van de chart: daar zijn
  ze verplicht en blijft de pod in `CreateContainerConfigError` zolang ze
  ontbreken.
- `create-tenant-secret.sh` schrijft de `smtp-*` sleutels mee als `SMTP_HOST`,
  `SMTP_USERNAME` en `SMTP_PASSWORD` gezet zijn (alle drie of geen).
  `env.example` noemde ze al, het script deed er niets mee.
- `validate-values.sh` controleert `tenant.mail`; elf nieuwe fixtures in
  `tests/cases/tenant-mail-*`.

Blast radius: geen. Alle 89 tenants renderen byte voor byte gelijk (values en
manifests, vergeleken met `helm template` en de goTemplate-emulatie van de
ApplicationSet). Alleen een tenant die `tenant.mail` zet, krijgt nieuwe env vars
en een extra configbestand, en herstart dus.

Nog niet: SMTP-sleutels voor tenants met `tenant.secrets.managed: true` (ESO).
