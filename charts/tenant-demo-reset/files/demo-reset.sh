#!/usr/bin/env bash
# SPDX-License-Identifier: EUPL-1.2
# role: tool
#
# demo-reset.sh: zet een demo-tenant terug naar een gouden momentopname.
#
#   demo-reset.sh golden   neem de momentopname (door een mens gestart)
#   demo-reset.sh reset    zet hem terug en laad de voorbeeldsets opnieuw
#                          (elke nacht, vanuit de CronJob)
#
# Draait in een Job in de namespace van de tenant en doet ALLES via
# `kubectl exec` in de pods die er al staan: occ in de Nextcloud-container,
# psql in de Postgres-container. Daardoor draaien occ en psql altijd in exact
# de versie die de tenant zelf draait, en heeft deze Job geen image-tag, geen
# databasewachtwoord en geen netwerkpad naar Postgres nodig. Het enige recht
# is `pods/exec` in de eigen namespace (zie templates/rbac.yaml).
#
# Wat de momentopname is, en waar hij staat:
#
#   database   een kopie van de tenant-database binnen dezelfde Postgres,
#              `<db>_demo_golden`, als template gemarkeerd en zonder
#              connecties. Terugzetten is CREATE DATABASE ... TEMPLATE: een
#              bestandskopie op de server, geen dump en geen restore.
#   bestanden  een kopie van de datamap (/var/www/html/data) naar
#              /var/www/demo-reset/golden op dezelfde PVC. /var/www/ is de
#              subPath `root` van de chart en valt buiten de codeboom die de
#              image-entrypoint bij een upgrade met rsync overschrijft.
#
# Wat NIET wordt teruggezet, met opzet:
#
#   config/       instanceid, passwordsalt en secret blijven die van de
#                 draaiende tenant. De momentopname weigert terug te zetten als
#                 de instanceid niet gelijk is aan die in de momentopname.
#   custom_apps/  de app-code is van de install-hook, net als zijn state-bestand
#                 data/.conduction-apps-state. Een app die na de momentopname
#                 nieuwer is geworden, krijgt na het terugzetten `occ upgrade`.
#   logs          nextcloud.log*, audit.log en conduction-apps.log blijven staan.
#
# Gedrag bij falen:
#
#   - Vóór de eerste onomkeerbare stap: onderhoudsmodus weer uit (als deze Job
#     hem aanzette), de tenant draait door zoals hij was.
#   - Ná de eerste onomkeerbare stap: onderhoudsmodus BLIJFT AAN. Een half
#     teruggezette tenant hoort niet te serveren. De momentopname zelf is niet
#     aangeraakt, dus de Job opnieuw starten maakt het af.
#   - Faalt alleen het laden van de voorbeeldsets, dan is de tenant al terug op
#     de momentopname en blijft hij in de lucht; de Job faalt wel zichtbaar.
#
# Writes: de tenant-database, de datamap en /var/www/demo-reset van de tenant
# Idempotent: ja; een herhaalde run zet opnieuw dezelfde momentopname terug
# Requires: bash, kubectl, jq, curl (alpine/k8s heeft ze alle drie)

set -euo pipefail

MODE="${1:-}"
case "${MODE}" in
  golden | reset) ;;
  *)
    echo "gebruik: demo-reset.sh golden|reset" >&2
    exit 2
    ;;
esac

KUBECTL="${KUBECTL:-kubectl}"
CURL="${CURL:-curl}"
WAIT_STEP="${WAIT_STEP:-5}"
CRON_WAIT_TRIES="${CRON_WAIT_TRIES:-180}"

readonly STORE="/var/www/demo-reset"
readonly DATA="/var/www/html/data"
readonly OCC="php /var/www/html/occ"

log() { printf '%s demo-reset %s: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${MODE}" "$*"; }
die() {
  log "FOUT: $*" >&2
  exit 1
}

# Een lege waarde is een fout, nooit een default. Zie docs/DEMO-RESET.md.
require() {
  local name="$1"
  [ -n "${!name:-}" ] || die "${name} is leeg. De chart hoort hem te zetten; zonder hem doet deze Job niets."
}

require POD_NAMESPACE
require TENANT_NAME
require TENANT_HOST
require CONFIRM_WIPE

# De bevestiging staat in het tenantbestand en moet de tenantnaam letterlijk
# herhalen. De validator en de chart toetsen dit ook; hier nog een keer, omdat
# dit de laatste plek is vóór het wissen.
[ "${CONFIRM_WIPE}" = "${TENANT_NAME}" ] ||
  die "confirmWipe '${CONFIRM_WIPE}' is niet de tenantnaam '${TENANT_NAME}'. Er wordt niets gewist."

readonly NS="${POD_NAMESPACE}"
readonly STATUS_URL="${STATUS_URL:-http://nextcloud.${NS}.svc.cluster.local:8080/status.php}"
EXAMPLE_SETS="${EXAMPLE_SETS:-}"
EXAMPLE_SET_MODE="${EXAMPLE_SET_MODE:-install}"
PASSWORD_FILE="${PASSWORD_FILE:-}"
LIMIT_APPS="${LIMIT_APPS:-}"
LIMIT_EXCEPT_GROUPS="${LIMIT_EXCEPT_GROUPS:-}"

case "${EXAMPLE_SET_MODE}" in
  install | reinstall) ;;
  *) die "EXAMPLE_SET_MODE '${EXAMPLE_SET_MODE}' is onbekend; verwacht install of reinstall." ;;
esac
for set_id in ${EXAMPLE_SETS}; do
  [[ "${set_id}" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || die "voorbeeldset '${set_id}' heeft een ongeldige naam."
done
if [ -n "${PASSWORD_FILE}" ] && [ ! -s "${PASSWORD_FILE}" ]; then
  die "PASSWORD_FILE ${PASSWORD_FILE} is leeg of bestaat niet. Er is niets gewist."
fi
for app in ${LIMIT_APPS}; do
  [[ "${app}" =~ ^[a-z][a-z0-9_]{0,63}$ ]] || die "app '${app}' in LIMIT_APPS is geen app-id. Er is niets gewist."
done
for group in ${LIMIT_EXCEPT_GROUPS}; do
  [[ "${group}" =~ ^[A-Za-z0-9._@-]{1,64}$ ]] || die "groep '${group}' in LIMIT_EXCEPT_GROUPS heeft een ongeldige naam. Er is niets gewist."
done
if [ -n "${LIMIT_APPS}" ] && [ -z "${LIMIT_EXCEPT_GROUPS}" ]; then
  die "LIMIT_APPS is gezet zonder LIMIT_EXCEPT_GROUPS; dan krijgt elke groep de apps en beperkt de stap niets. Er is niets gewist."
fi

# ---------------------------------------------------------------------------
# Pods en exec
# ---------------------------------------------------------------------------

one_pod() {
  local selector="$1" what="$2" names
  local -a pods
  names="$("${KUBECTL}" get pods -n "${NS}" -l "${selector}" \
    --field-selector=status.phase=Running -o jsonpath='{.items[*].metadata.name}')"
  read -r -a pods <<<"${names}"
  [ "${#pods[@]}" -eq 1 ] ||
    die "verwacht precies één draaiende ${what}-pod in ${NS}, gevonden: ${#pods[@]} (${names:-geen})."
  printf '%s' "${pods[0]}"
}

nc() { "${KUBECTL}" exec -n "${NS}" "${NC_POD}" -c nextcloud -- "$@"; }
nc_in() { "${KUBECTL}" exec -i -n "${NS}" "${NC_POD}" -c nextcloud -- "$@"; }

# occ als www-data, op dezelfde manier als de entrypoint van de image het doet
# (`su -p` houdt de omgeving van de container, dus ook REDIS_HOST en de S3-env).
# Alleen vaste woorden en gevalideerde set-namen komen hier doorheen.
occ() { nc su -p www-data -s /bin/sh -c "${OCC} $*"; }

pg() { "${KUBECTL}" exec -n "${NS}" "${PG_POD}" -c postgresql -- "$@"; }

# Eén SQL-statement als de postgres-superuser, via 127.0.0.1 in de pod zelf.
# Het wachtwoord leest de pod uit zijn eigen secret-bestand (Bitnami
# usePasswordFiles) of env; het komt nooit in deze Job.
sql() {
  # shellcheck disable=SC2016 # $-variabelen horen in de Postgres-pod uitgewerkt te worden
  pg sh -c 'PGPASSWORD="${POSTGRES_POSTGRES_PASSWORD:-$(cat "${POSTGRES_POSTGRES_PASSWORD_FILE}")}" exec psql -X -q -v ON_ERROR_STOP=1 -h 127.0.0.1 -U postgres -d postgres -At -c "$1"' sql "$1"
}

db_exists() { [ "$(sql "SELECT 1 FROM pg_database WHERE datname = '$1'")" = "1" ]; }

terminate() {
  sql "SELECT count(pg_terminate_backend(pid)) FROM pg_stat_activity WHERE datname = '$1' AND pid <> pg_backend_pid()" >/dev/null
}

# CREATE DATABASE ... TEMPLATE en RENAME weigeren zolang er nog een connectie
# op de bron staat. In onderhoudsmodus komen er geen nieuwe bij, maar een
# lopend verzoek kan net nog bezig zijn: kort opnieuw proberen.
with_retry() {
  local i
  for i in 1 2 3 4 5; do
    "$@" && return 0
    log "nog connecties op de database, poging ${i} van 5"
    sleep "${WAIT_STEP}"
  done
  return 1
}

clone_db() { # <bron> <doel> [eigenaar]
  terminate "$1"
  sql "CREATE DATABASE \"$2\" TEMPLATE \"$1\"${3:+ OWNER \"$3\"}"
}

rename_db() { # <van> <naar>
  terminate "$1"
  sql "ALTER DATABASE \"$1\" RENAME TO \"$2\""
}

drop_db() { # <naam>; een template moet eerst geen template meer zijn
  if db_exists "$1"; then
    sql "ALTER DATABASE \"$1\" WITH IS_TEMPLATE false"
    sql "DROP DATABASE \"$1\" WITH (FORCE)"
  fi
}

# ---------------------------------------------------------------------------
# Onderhoudsmodus en cron
# ---------------------------------------------------------------------------

MAINT_BY_US=0
DESTRUCTIVE=0

maint_on() {
  occ maintenance:mode --on >/dev/null
  MAINT_BY_US=1
  log "onderhoudsmodus aan"
}

maint_off() {
  occ maintenance:mode --off >/dev/null
  MAINT_BY_US=0
  log "onderhoudsmodus uit"
}

# cron.php stopt zelf in onderhoudsmodus, maar een run die al liep loopt door.
# Wacht tot er geen meer is. Het patroon `cron[.]php` matcht niet zichzelf.
wait_for_cron() {
  local containers i n
  containers="$("${KUBECTL}" get pod -n "${NS}" "${NC_POD}" -o jsonpath='{.spec.containers[*].name}')"
  if [[ " ${containers} " != *" nextcloud-cron "* ]]; then
    log "geen nextcloud-cron-container in de pod, niets om op te wachten"
    return 0
  fi
  for ((i = 1; i <= CRON_WAIT_TRIES; i++)); do
    n="$("${KUBECTL}" exec -n "${NS}" "${NC_POD}" -c nextcloud-cron -- \
      sh -c 'grep -l "cron[.]php" /proc/[0-9]*/cmdline 2>/dev/null | wc -l')"
    if [ "${n//[[:space:]]/}" = "0" ]; then
      return 0
    fi
    [ "${i}" -eq 1 ] && log "cron.php loopt nog, wachten"
    sleep "${WAIT_STEP}"
  done
  die "cron.php loopt na ${CRON_WAIT_TRIES} pogingen nog steeds."
}

on_exit() {
  local rc=$?
  if [ "${rc}" -ne 0 ]; then
    if [ "${DESTRUCTIVE}" -eq 1 ]; then
      log "FOUT na de eerste onomkeerbare stap: de onderhoudsmodus BLIJFT AAN." >&2
      log "De momentopname is niet aangeraakt. Start de Job opnieuw (docs/DEMO-RESET.md)." >&2
    elif [ "${MAINT_BY_US}" -eq 1 ]; then
      log "fout vóór het wissen: onderhoudsmodus gaat weer uit, de tenant draait door zoals hij was" >&2
      maint_off || log "onderhoudsmodus uitzetten mislukte ook; zet hem met de hand uit" >&2
    fi
  fi
  exit "${rc}"
}
trap on_exit EXIT

# ---------------------------------------------------------------------------
# Gedeelde voorcontrole
# ---------------------------------------------------------------------------

# De gouden en de nachtelijke Job mogen nooit tegelijk lopen. concurrencyPolicy
# dekt alleen runs van dezelfde CronJob; deze check dekt ze samen.
OWN_RUNS="$("${KUBECTL}" get pods -n "${NS}" -l app.kubernetes.io/name=tenant-demo-reset \
  --field-selector=status.phase=Running -o jsonpath='{.items[*].metadata.name}')"
read -r -a own_runs <<<"${OWN_RUNS}"
[ "${#own_runs[@]}" -le 1 ] ||
  die "er loopt al een andere demo-reset-Job (${OWN_RUNS}). Er is niets veranderd."

NC_POD="$(one_pod 'app.kubernetes.io/name=nextcloud,app.kubernetes.io/component=app' nextcloud)"
PG_POD="$(one_pod 'app.kubernetes.io/name=postgresql,app.kubernetes.io/component=primary' postgresql)"
log "nextcloud-pod ${NC_POD}, postgres-pod ${PG_POD}"

LIVE_DB="$(pg printenv POSTGRES_DATABASE || true)"
DB_OWNER="$(pg printenv POSTGRES_USER || true)"
for v in LIVE_DB DB_OWNER; do
  [[ "${!v}" =~ ^[a-z_][a-z0-9_]{0,40}$ ]] ||
    die "${v} uit de Postgres-pod is leeg of geen gewone naam ('${!v}'). Is dit een tenant met dbType postgres?"
done
readonly GOLDEN_DB="${LIVE_DB}_demo_golden"
readonly INCOMING_DB="${LIVE_DB}_demo_incoming"
readonly PREVIOUS_DB="${LIVE_DB}_demo_previous"

STATUS="$(occ status --output=json)"
jq -e '.installed == true' >/dev/null <<<"${STATUS}" || die "Nextcloud is niet geïnstalleerd volgens occ status."

INSTANCEID="$(occ config:system:get instanceid || true)"
[ -n "${INSTANCEID}" ] || die "instanceid is leeg in config.php."

# Deze component zet alleen een lokale datamap terug. Staan de bestanden in S3
# (primary objectstore), dan zou een teruggezette database naar objecten
# wijzen die er niet meer zijn. Dan stoppen in plaats van half werk.
if occ config:system:get objectstore >/dev/null 2>&1; then
  die "deze tenant heeft een S3 primary objectstore. demo-reset zet alleen een lokale datamap terug; er is niets gewist."
fi

# ---------------------------------------------------------------------------
# golden: neem de momentopname
# ---------------------------------------------------------------------------

take_golden() {
  jq -e '.maintenance == false' >/dev/null <<<"${STATUS}" ||
    die "de tenant staat al in onderhoudsmodus. Is iemand anders bezig? Er is niets veranderd."

  local apps id
  apps="$(occ app:list --output=json)"
  id="$(date -u +%Y%m%dT%H%M%SZ)"

  maint_on
  wait_for_cron

  log "database ${LIVE_DB} kopiëren naar ${INCOMING_DB}"
  drop_db "${INCOMING_DB}"
  with_retry clone_db "${LIVE_DB}" "${INCOMING_DB}"

  log "datamap kopiëren naar ${STORE}/incoming"
  nc sh -c "rm -rf '${STORE}/incoming' && mkdir -p '${STORE}/incoming/data' && cd '${DATA}' && \
tar -cf - --exclude=./nextcloud.log --exclude='./nextcloud.log.*' --exclude=./audit.log \
--exclude=./conduction-apps.log --exclude=./.conduction-apps-state . | tar -xpf - -C '${STORE}/incoming/data'"

  # De live staat is vanaf hier niet meer nodig: zo kort mogelijk offline.
  maint_off

  jq -n --arg id "${id}" --arg instanceid "${INSTANCEID}" --arg tenant "${TENANT_NAME}" \
    --arg database "${LIVE_DB}" --argjson status "${STATUS}" --argjson apps "${apps}" \
    '{id: $id, tenant: $tenant, instanceid: $instanceid, database: $database,
      nextcloud: $status.versionstring, apps: $apps.enabled}' |
    nc_in sh -c "cat > '${STORE}/incoming/manifest.json'"

  # Wisselen. Eerst de oude momentopname ongeldig maken, dan pas de database en
  # de map vervangen: een run die halverwege stopt laat zo nooit een
  # database en een map achter die van verschillende momenten zijn maar
  # geldig lijken.
  log "momentopname ${id} wordt de gouden"
  nc rm -f "${STORE}/golden/COMPLETE"
  drop_db "${GOLDEN_DB}"
  with_retry rename_db "${INCOMING_DB}" "${GOLDEN_DB}"
  sql "COMMENT ON DATABASE \"${GOLDEN_DB}\" IS 'demo-reset ${id}'"
  sql "ALTER DATABASE \"${GOLDEN_DB}\" WITH IS_TEMPLATE true ALLOW_CONNECTIONS false"
  nc sh -c "rm -rf '${STORE}/golden' && mv '${STORE}/incoming' '${STORE}/golden' && echo '${id}' > '${STORE}/golden/COMPLETE'"

  log "klaar: momentopname ${id}, database $(sql "SELECT pg_size_pretty(pg_database_size('${GOLDEN_DB}'))"), bestanden $(nc du -sh "${STORE}/golden" | cut -f1)"
}

# ---------------------------------------------------------------------------
# reset: zet de momentopname terug
# ---------------------------------------------------------------------------

load_example_sets() {
  local set_id args
  for set_id in ${EXAMPLE_SETS}; do
    if [ "${EXAMPLE_SET_MODE}" = "reinstall" ]; then
      log "voorbeeldset ${set_id} verwijderen"
      occ openregister:example-set:remove "${set_id}"
    fi
    log "voorbeeldset ${set_id} laden"
    if [ -n "${PASSWORD_FILE}" ]; then
      # Het wachtwoord gaat over stdin, niet als argument: dan staat het niet in
      # de exec-aanroep en dus niet in een audit-log van de API-server.
      args="openregister:example-set:install ${set_id} --password-from-env"
      # shellcheck disable=SC2016 # OC_PASS hoort in de Nextcloud-container gelezen te worden
      nc_in sh -c 'IFS= read -r OC_PASS; export OC_PASS; exec su -p www-data -s /bin/sh -c "$1"' sh "${OCC} ${args}" <"${PASSWORD_FILE}"
    else
      occ openregister:example-set:install "${set_id}"
    fi
  done
}

# Zet elke app uit LIMIT_APPS aan voor alle groepen behalve LIMIT_EXCEPT_GROUPS.
# Draait na de voorbeeldsets, omdat een set groepen aanmaakt die er in de
# momentopname nog niet waren. Een app die Nextcloud niet tot groepen laat
# beperken (bv. spreed, photos, activity) gaat aan voor iedereen, met een WARN.
# Per app apart: één weigering in een gezamenlijke aanroep liet de rest uit.
limit_apps_to_groups() {
  local groups_json apps_json app group g except
  local -a groups=() group_args=()
  [ -n "${LIMIT_APPS}" ] || return 0

  groups_json="$(occ group:list --output=json)"
  while IFS= read -r group; do
    except=0
    for g in ${LIMIT_EXCEPT_GROUPS}; do [ "${group}" = "${g}" ] && except=1; done
    [ "${except}" = 1 ] && continue
    [[ "${group}" =~ ^[A-Za-z0-9._@-]{1,64}$ ]] ||
      die "groep '${group}' heeft een naam die niet veilig door occ kan; apps niet beperkt."
    groups+=("${group}")
  done < <(jq -r 'keys[]' <<<"${groups_json}")
  [ "${#groups[@]}" -gt 0 ] ||
    die "geen groepen over na het weglaten van '${LIMIT_EXCEPT_GROUPS}'; apps niet beperkt."
  for group in "${groups[@]}"; do group_args+=("--groups=${group}"); done

  apps_json="$(occ app:list --output=json)"
  for app in ${LIMIT_APPS}; do
    if ! jq -e --arg a "${app}" '(.enabled // {}) + (.disabled // {}) | has($a)' >/dev/null <<<"${apps_json}"; then
      log "app ${app} is niet geïnstalleerd; overgeslagen"
      continue
    fi
    if occ app:enable "${group_args[@]}" "${app}" >/dev/null; then
      log "app ${app} beperkt tot ${#groups[@]} groepen"
    else
      log "WARN: app ${app} laat zich niet tot groepen beperken; aan voor iedereen" >&2
      occ app:enable "${app}" >/dev/null
    fi
  done
}

reset_to_golden() {
  local golden_id manifest golden_comment

  golden_id="$(nc cat "${STORE}/golden/COMPLETE" 2>/dev/null || true)"
  [ -n "${golden_id}" ] ||
    die "geen geldige momentopname (${STORE}/golden/COMPLETE ontbreekt). Neem er eerst een: docs/DEMO-RESET.md. Er is niets gewist."
  manifest="$(nc cat "${STORE}/golden/manifest.json")"
  [ "$(jq -r .id <<<"${manifest}")" = "${golden_id}" ] ||
    die "manifest.json hoort niet bij COMPLETE (${golden_id}). Er is niets gewist."
  [ "$(jq -r .instanceid <<<"${manifest}")" = "${INSTANCEID}" ] ||
    die "de momentopname is van een andere instantie (instanceid verschilt). Er is niets gewist."
  db_exists "${GOLDEN_DB}" || die "database ${GOLDEN_DB} ontbreekt. Er is niets gewist."
  golden_comment="$(sql "SELECT shobj_description(oid, 'pg_database') FROM pg_database WHERE datname = '${GOLDEN_DB}'")"
  [ "${golden_comment}" = "demo-reset ${golden_id}" ] ||
    die "database ${GOLDEN_DB} ('${golden_comment}') hoort niet bij momentopname ${golden_id}. Er is niets gewist."
  log "momentopname ${golden_id} terugzetten"

  if jq -e '.maintenance == true' >/dev/null <<<"${STATUS}"; then
    log "de tenant stond al in onderhoudsmodus (vorige run gefaald?); doorgaan, en hij gaat aan het eind uit"
  else
    maint_on
  fi
  wait_for_cron

  drop_db "${INCOMING_DB}"
  clone_db "${GOLDEN_DB}" "${INCOMING_DB}" "${DB_OWNER}"

  # Vanaf hier is de bezoekersstaat weg zodra het lukt, en half als het faalt.
  DESTRUCTIVE=1
  drop_db "${PREVIOUS_DB}"
  if db_exists "${LIVE_DB}"; then
    with_retry rename_db "${LIVE_DB}" "${PREVIOUS_DB}"
  else
    log "database ${LIVE_DB} bestaat niet (vorige run stopte tijdens de wissel); doorgaan"
  fi
  rename_db "${INCOMING_DB}" "${LIVE_DB}"
  drop_db "${PREVIOUS_DB}"
  log "database teruggezet"

  nc sh -c "find '${DATA}' -mindepth 1 -maxdepth 1 ! -name nextcloud.log ! -name 'nextcloud.log.*' \
! -name audit.log ! -name conduction-apps.log ! -name .conduction-apps-state -exec rm -rf {} + && \
cp -a '${STORE}/golden/data/.' '${DATA}/'"
  log "datamap teruggezet"

  # APCu (memcache.local) leeft in het geheugen van de php-fpm-master. Een
  # reload (USR2) begint met een leeg geheugen. Faalt dat, dan verlopen die
  # waarden vanzelf; geen reden om de tenant offline te houden.
  # shellcheck disable=SC2016 # /proc/1/comm hoort in de Nextcloud-container gelezen te worden
  if nc sh -c 'case "$(cat /proc/1/comm)" in php-fpm*) exit 0 ;; esac; exit 1'; then
    if nc kill -USR2 1; then
      log "php-fpm herladen (lokale cache leeg)"
    else
      log "php-fpm herladen mislukte; ga door"
    fi
  else
    log "PID 1 is geen php-fpm; lokale cache niet geleegd"
  fi

  if occ status --output=json | jq -e '.needsDbUpgrade == true' >/dev/null; then
    log "de app-code is nieuwer dan de momentopname: occ upgrade"
    occ upgrade
  fi

  maint_off
  # Gedeelde Redis: alleen de sleutels van deze instantie (prefix = instanceid +
  # app-versies), nooit FLUSHALL. Moet NA maintenance:mode --off, want in
  # onderhoudsmodus rekent Nextcloud met een andere prefix.
  occ memcache:distributed:clear >/dev/null
  DESTRUCTIVE=0
  log "tenant staat op momentopname ${golden_id}"

  load_example_sets
  limit_apps_to_groups

  STATUS="$(occ status --output=json)"
  jq -e '.installed == true and .maintenance == false and .needsDbUpgrade == false' >/dev/null <<<"${STATUS}" ||
    die "occ status na afloop klopt niet: ${STATUS}"
  "${CURL}" -fsS --max-time 30 -H "Host: ${TENANT_HOST}" "${STATUS_URL}" |
    jq -e '.installed == true and .maintenance == false' >/dev/null ||
    die "status.php via de service geeft geen gezonde tenant."

  nc sh -c "echo '$(date -u +%Y-%m-%dT%H:%M:%SZ) ${golden_id}' > '${STORE}/last-reset'"
  log "klaar"
}

case "${MODE}" in
  golden) take_golden ;;
  reset) reset_to_golden ;;
esac
