### Gewijzigd — 2026-08-05 (PostgreSQL krijgt dezelfde probes als MariaDB)

`values/db/postgres.yaml` had geen `startupProbe`. Het opstartbudget was daarmee wat
liveness toestond: `initialDelaySeconds: 30` + 6×10s = **90 seconden**. Krapper dan
MariaDB had, en dat budget van 150s bleek op 2026-08-04 al te kort — twee
MariaDB-tenants kwamen in een oneindige CrashLoopBackOff omdat de kubelet de
container afschoot voordat de start klaar was.

PostgreSQL doet bij een onreine stop WAL-recovery voordat hij connecties opent. Hoe
groter de database, hoe reëler dat dit over 90 seconden gaat. Wordt hij daar middenin
afgeschoten, dan begint recovery elke ronde opnieuw en komt hij nooit klaar. Data
raakt niet corrupt — PostgreSQL is crash-safe — maar de tenant blijft down, en dat
ziet er van buiten precies zo uit als de storing van gisteren.

Nu 30s + 60×10s = 10 minuten, gelijk aan MariaDB en aan de platform-standaard voor de
Nextcloud-container. Liveness op `initialDelaySeconds: 30`, dus strakker dan het
chart-budget van 90s: een dode database wordt sneller opgemerkt, niet langzamer.

Geverifieerd met `helm template` per profiel: postgres en mariadb geven beide
`startup=630s liveness=30s`, en `external` levert terecht geen database.

Dit is bewust pas nu gedaan. Het raakt 48 accept- en 26 productie-tenants, en op
2026-08-05 bleek de canary-poort niets te keuren (probe groen 31s na de merge terwijl
Argo's reconcile 180s is). Die poort is eerst gerepareerd — timing, een streak, en
aankomst-verificatie via `/status.php` — zodat deze wijziging de eerste is die er
langs komt met een canary die de wijziging daadwerkelijk had.
