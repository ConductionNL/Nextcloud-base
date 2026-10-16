### Gewijzigd — 2026-10-15 (Postgres: max_locks_per_transaction naar 1024)

`values/db/postgres.yaml` zet `max_locks_per_transaction = 1024` via
`postgresql.primary.extendedConfiguration`; de default was 64. OpenRegister zoekt
met één UNION over al zijn schematabellen, en bij ~1.329 tabellen gaf dat
`out of shared memory, increase max_locks_per_transaction` (gezien bij de
generale repetitie van demogemeente Zuiddrecht).

Gemeten op `postgres16-ext-sha-8abef67`: 1.329 tabellen met 8 indexen (11.963
locks in één transactie) faalt op 64 en slaagt op 1024. `shared_memory_size`
gaat van 143MB naar 189MB, binnen de geheugenlimiet van 512Mi.

Blast radius: alle tenants met `dbType: postgres` krijgen een nieuwe ConfigMap
`nextcloud-postgresql-extended-configuration` en een nieuwe checksum-annotatie op
de StatefulSet, dus elke in-cluster Postgres herstart één keer. Tenants op
`dbType: external` en `mariadb` veranderen niet.
