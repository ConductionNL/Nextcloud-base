#!/usr/bin/env bash
# SPDX-License-Identifier: EUPL-1.2
# role: tool
#
# nextcloud-platform/tests/run-demo-reset-tests.sh: tests voor de demo-reset
# (charts/tenant-demo-reset, de ApplicationSet nextcloud-tenant-demo-reset en
# het script charts/tenant-demo-reset/files/demo-reset.sh).
#
# Drie delen:
#
#   chart        helm template: uit = leeg, aan = zes geldige resources
#                (kubeconform -strict), een verkeerde confirmWipe rendert niet,
#                paused en het wachtwoord-Secret komen goed door, het script in
#                de ConfigMap is byte-gelijk aan files/demo-reset.sh.
#   appset       het `values:`-blok van de ApplicationSet, gerenderd met Helm.
#                Helm en Argo gebruiken allebei text/template met Sprig; het
#                blok gebruikt overal `default`, dus het verschil in missingkey
#                speelt niet. Zo dekt CI het blok zonder Argo.
#   script       demo-reset.sh tegen een nep-kubectl. Bestandsoperaties in de
#                Nextcloud-container draaien ECHT, op een nep-boom onder een
#                mktemp-map (paden /var/www en /proc/1/comm worden omgezet).
#                Postgres is een map per database. `occ` is een stub die de
#                onderhoudsmodus bijhoudt en elke aanroep logt, met de stand van
#                de onderhoudsmodus erbij, zodat de volgorde toetsbaar is.
#                `kill` wordt nooit uitgevoerd, alleen gelogd.
#
# Writes: alleen in een eigen mktemp-map
# Idempotent: ja
# Requires: bash, helm, kubeconform, jq, tar, find, cp
#
# Usage:
#   ./run-demo-reset-tests.sh            # alle cases
#   VERBOSE=1 ./run-demo-reset-tests.sh  # toon de scriptuitvoer bij een falende case

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly REPO_ROOT="${SCRIPT_DIR}/../.."
readonly CHART="${REPO_ROOT}/charts/tenant-demo-reset"
readonly SCRIPT="${CHART}/files/demo-reset.sh"
readonly APPSET="${SCRIPT_DIR}/../argo/applicationsets/nextcloud-tenant-demo-reset.yaml"

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly NC='\033[0m'

PASSED=0
FAILED=0
CASE=""
CASE_OK=1

WORK="$(mktemp -d)"
readonly WORK
trap 'rm -rf "$WORK"' EXIT

for tool in helm kubeconform jq; do
    command -v "$tool" >/dev/null 2>&1 || { echo "error: $tool ontbreekt" >&2; exit 1; }
done

start() { CASE="$1"; CASE_OK=1; }
not() { ! "$@"; }
check() { # <omschrijving> <commando...>
    local what="$1"
    shift
    if ! "$@"; then
        printf "${RED}  mis${NC} %s: %s\n" "$CASE" "$what" >&2
        CASE_OK=0
    fi
}
finish() {
    if [ "$CASE_OK" -eq 1 ]; then
        printf "${GREEN}PASS${NC} %s\n" "$CASE"
        PASSED=$((PASSED + 1))
    else
        printf "${RED}FAIL${NC} %s\n" "$CASE" >&2
        if [ -n "${VERBOSE:-}" ] && [ -f "$WORK/out" ]; then sed 's/^/    /' "$WORK/out" >&2; fi
        FAILED=$((FAILED + 1))
    fi
}

# ---------------------------------------------------------------------------
# Deel 1: chart
# ---------------------------------------------------------------------------

ON=(--set demoReset.enabled=true --set tenant.name=zuiddrecht-prod
    --set tenant.host=cloud.zuiddrecht.nl --set demoReset.confirmWipe=zuiddrecht-prod
    --set 'demoReset.exampleSets={zuiddrecht}')

start "chart: uit rendert niets"
out="$(helm template t "$CHART" -n zuiddrecht-prod)"
check "lege render" test -z "${out//[[:space:]]/}"
finish

start "chart: aan rendert zes geldige resources"
helm template t "$CHART" -n zuiddrecht-prod "${ON[@]}" >"$WORK/on.yaml"
check "kubeconform -strict" kubeconform -strict -summary "$WORK/on.yaml" >/dev/null
kinds="$(grep -E '^kind:' "$WORK/on.yaml" | sort | tr '\n' ' ')"
check "kinds ($kinds)" test "$kinds" = "kind: ConfigMap kind: CronJob kind: CronJob kind: Role kind: RoleBinding kind: ServiceAccount "
check "reset-CronJob niet gepauzeerd" test "$(yq 'select(.kind == "CronJob" and .metadata.name == "demo-reset") | .spec.suspend' "$WORK/on.yaml")" = "false"
check "golden-CronJob altijd suspend" test "$(yq 'select(.kind == "CronJob" and .metadata.name == "demo-reset-golden") | .spec.suspend' "$WORK/on.yaml")" = "true"
check "Role alleen pods get/list en pods/exec create/get" test \
    "$(yq -o=json 'select(.kind == "Role") | .rules' "$WORK/on.yaml" | jq -c .)" = \
    '[{"apiGroups":[""],"resources":["pods"],"verbs":["get","list"]},{"apiGroups":[""],"resources":["pods/exec"],"verbs":["create","get"]}]'
# yq zet er één regeleinde achter; $(...) haalt aan beide kanten alle
# afsluitende regeleindes weg, de rest moet byte-gelijk zijn.
check "script in ConfigMap gelijk aan files/demo-reset.sh" test \
    "$(yq 'select(.kind == "ConfigMap") | .data["demo-reset.sh"]' "$WORK/on.yaml")" = "$(cat "$SCRIPT")"
check "geen requests (Resource Policy)" not grep -q 'requests:' "$WORK/on.yaml"
finish

start "chart: limitApps komt als env door, en ontbreekt als hij leeg is"
reset_env() { yq "select(.metadata.name == \"demo-reset\") | .spec.jobTemplate.spec.template.spec.containers[0].env[] | select(.name == \"$2\") | .value" "$1"; }
check "zonder limitApps geen LIMIT_APPS-env" test -z "$(reset_env "$WORK/on.yaml" LIMIT_APPS)"
helm template t "$CHART" -n zuiddrecht-prod "${ON[@]}" --set 'demoReset.limitApps.apps={dossiq,mail}' \
    --set 'demoReset.limitApps.exceptGroups={inwoners}' >"$WORK/l.yaml"
check "kubeconform" kubeconform -strict "$WORK/l.yaml" >/dev/null
check "LIMIT_APPS" test "$(reset_env "$WORK/l.yaml" LIMIT_APPS)" = "dossiq mail"
check "LIMIT_EXCEPT_GROUPS" test "$(reset_env "$WORK/l.yaml" LIMIT_EXCEPT_GROUPS)" = "inwoners"
finish

start "chart: verkeerde confirmWipe rendert niet"
set +e
err="$(helm template t "$CHART" -n zuiddrecht-prod "${ON[@]}" --set demoReset.confirmWipe=alkmaar-prod 2>&1)"
rc=$?
set -e
check "exit niet 0" test "$rc" -ne 0
check "melding noemt confirmWipe" grep -qF 'confirmWipe moet letterlijk de tenantnaam zijn' <<<"$err"
finish

start "chart: paused en wachtwoord-Secret"
helm template t "$CHART" -n zuiddrecht-prod "${ON[@]}" --set demoReset.paused=true \
    --set demoReset.exampleSetPasswordSecret=demo-reset-password >"$WORK/p.yaml"
check "kubeconform" kubeconform -strict "$WORK/p.yaml" >/dev/null
check "reset-CronJob suspend" test "$(yq 'select(.kind == "CronJob" and .metadata.name == "demo-reset") | .spec.suspend' "$WORK/p.yaml")" = "true"
check "PASSWORD_FILE gezet" grep -qF 'value: /secrets/demo-password' "$WORK/p.yaml"
check "Secret-volume" grep -qF 'secretName: "demo-reset-password"' "$WORK/p.yaml"
finish

# ---------------------------------------------------------------------------
# Deel 2: het values-blok van de ApplicationSet
# ---------------------------------------------------------------------------

render_appset_values() { # <tenantbestand> -> values op stdout
    local c="$WORK/appset-chart"
    rm -rf "$c" && mkdir -p "$c/templates"
    printf 'apiVersion: v2\nname: appset-values\nversion: 0.0.0\n' >"$c/Chart.yaml"
    { printf '{{- with .Values }}\n'; yq -r '.spec.template.spec.source.helm.values' "$APPSET"; printf '{{- end }}\n'; } >"$c/templates/values.yaml"
    helm template a "$c" -f "$1" --show-only templates/values.yaml | sed '1,/^# Source:/d'
}

start "appset: volledig blok"
cat >"$WORK/t1.yaml" <<'EOF'
tenant:
  name: zuiddrecht-prod
  environment: prod
  hostname: cloud.zuiddrecht.nl
  components:
    demoReset:
      enabled: true
      confirmWipe: zuiddrecht-prod
      schedule: "30 2 * * *"
      paused: true
      exampleSets: [zuiddrecht, extra]
      exampleSetMode: reinstall
      exampleSetPasswordSecret: demo-reset-password
      limitApps:
        apps: [dossiq, mail]
        exceptGroups: [inwoners]
EOF
render_appset_values "$WORK/t1.yaml" >"$WORK/v1.yaml"
check "host uit tenant.hostname" test "$(yq .tenant.host "$WORK/v1.yaml")" = "cloud.zuiddrecht.nl"
check "schedule" test "$(yq .demoReset.schedule "$WORK/v1.yaml")" = "30 2 * * *"
check "paused" test "$(yq .demoReset.paused "$WORK/v1.yaml")" = "true"
check "exampleSets" test "$(yq -o=json -I=0 .demoReset.exampleSets "$WORK/v1.yaml")" = '["zuiddrecht","extra"]'
check "mode" test "$(yq .demoReset.exampleSetMode "$WORK/v1.yaml")" = "reinstall"
check "limitApps.apps" test "$(yq -o=json -I=0 .demoReset.limitApps.apps "$WORK/v1.yaml")" = '["dossiq","mail"]'
check "limitApps.exceptGroups" test "$(yq -o=json -I=0 .demoReset.limitApps.exceptGroups "$WORK/v1.yaml")" = '["inwoners"]'
helm template t "$CHART" -n zuiddrecht-prod -f "$WORK/v1.yaml" >"$WORK/v1.manifests.yaml"
check "chart rendert met deze values" kubeconform -strict "$WORK/v1.manifests.yaml" >/dev/null
finish

start "appset: minimaal blok krijgt defaults en afgeleide host"
cat >"$WORK/t2.yaml" <<'EOF'
tenant:
  name: demo-accept
  environment: accept
  components:
    demoReset:
      enabled: true
      confirmWipe: demo-accept
EOF
render_appset_values "$WORK/t2.yaml" >"$WORK/v2.yaml"
check "afgeleide host" test "$(yq .tenant.host "$WORK/v2.yaml")" = "demo.accept.commonground.nu"
check "schedule default" test "$(yq .demoReset.schedule "$WORK/v2.yaml")" = "15 4 * * *"
check "paused default" test "$(yq .demoReset.paused "$WORK/v2.yaml")" = "false"
check "exampleSets leeg" test "$(yq -o=json -I=0 .demoReset.exampleSets "$WORK/v2.yaml")" = '[]'
check "mode default" test "$(yq .demoReset.exampleSetMode "$WORK/v2.yaml")" = "install"
check "limitApps.apps leeg" test "$(yq -o=json -I=0 .demoReset.limitApps.apps "$WORK/v2.yaml")" = '[]'
helm template t "$CHART" -n demo-accept -f "$WORK/v2.yaml" >"$WORK/v2.manifests.yaml"
check "chart rendert met deze values" kubeconform -strict "$WORK/v2.manifests.yaml" >/dev/null
finish

start "appset: selector matcht alleen enabled true"
check "selector-key" test "$(yq '.spec.generators[0].selector.matchExpressions[0].key' "$APPSET")" = "tenant.components.demoReset.enabled"
check "selector-waarde" test "$(yq -o=json -I=0 '.spec.generators[0].selector.matchExpressions[0].values' "$APPSET")" = '["true"]'
finish

# ---------------------------------------------------------------------------
# Deel 3: het script tegen een nep-kubectl
# ---------------------------------------------------------------------------

STUBS="$WORK/stubs"
mkdir -p "$STUBS"

# kubectl: get pods / get pod / exec. Alles komt in $FAKE_STATE/kubectl.log.
cat >"$STUBS/kubectl" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
S="$FAKE_STATE"
echo "$*" >>"$S/kubectl.log"
if [ "$1" = "get" ]; then
    case "$*" in
        *"app.kubernetes.io/name=tenant-demo-reset"*) echo -n "${FAKE_OWN_PODS-demo-reset-job-x}" ;;
        *"app.kubernetes.io/name=nextcloud,"*) echo -n "${FAKE_NC_PODS-nextcloud-abc}" ;;
        *"app.kubernetes.io/name=postgresql,"*) echo -n "nextcloud-postgresql-0" ;;
        *"{.spec.containers[*].name}"*) echo -n "nextcloud nextcloud-nginx nextcloud-cron" ;;
        *) echo "nep-kubectl: onbekende get: $*" >&2; exit 1 ;;
    esac
    exit 0
fi
[ "$1" = "exec" ] || { echo "nep-kubectl: onbekend: $*" >&2; exit 1; }
shift
container=""
while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
    case "$1" in -c) container="$2"; shift 2 ;; *) shift ;; esac
done
shift
case "$container" in
postgresql)
    if [ "$1" = "printenv" ]; then
        case "$2" in POSTGRES_DATABASE) echo nextcloud ;; POSTGRES_USER) echo nextcloud ;; *) exit 1 ;; esac
        exit 0
    fi
    exec "$FAKE_STUBS/fake-sql" "${@: -1}"
    ;;
nextcloud-cron)
    n="$(cat "$S/cron" 2>/dev/null || echo 0)"
    echo "$n"
    [ "$n" -gt 0 ] && echo $((n - 1)) >"$S/cron"
    exit 0
    ;;
nextcloud)
    if [ "$1" = "kill" ]; then echo "kill $*" >>"$S/occ.log"; exit 0; fi
    args=()
    for a in "$@"; do
        a="${a//\/var\/www/$FAKE_ROOT/var/www}"
        a="${a//\/proc\/1\/comm/$FAKE_ROOT/proc/1/comm}"
        args+=("$a")
    done
    if [ -n "${FAKE_FAIL_EXEC:-}" ] && [[ "${args[*]}" == *"$FAKE_FAIL_EXEC"* ]]; then
        echo "nep-kubectl: faalinjectie op '$FAKE_FAIL_EXEC'" >&2
        exit 1
    fi
    PATH="$FAKE_STUBS:$PATH" exec "${args[@]}"
    ;;
*) echo "nep-kubectl: onbekende container '$container'" >&2; exit 1 ;;
esac
EOF

# su -p www-data -s /bin/sh -c "<cmd>": draai <cmd> met dezelfde omgeving.
cat >"$STUBS/su" <<'EOF'
#!/usr/bin/env bash
while [ "$#" -gt 0 ] && [ "$1" != "-c" ]; do shift; done
exec sh -c "$2"
EOF

# php <pad>/occ <args>: de occ-stub. Logt "maint=<0|1> <args>".
cat >"$STUBS/php" <<'EOF'
#!/usr/bin/env bash
S="$FAKE_STATE"
shift
m=0; [ -f "$S/maintenance" ] && m=1
line="maint=$m $*"
[ -n "${OC_PASS:-}" ] && line="$line OC_PASS=$OC_PASS"
echo "$line" >>"$S/occ.log"
if [ -n "${FAKE_FAIL_OCC:-}" ] && [[ "$*" == *"$FAKE_FAIL_OCC"* ]]; then exit 1; fi
case "$*" in
    "status --output=json")
        up=false; [ -f "$S/needs-upgrade" ] && up=true
        mm=false; [ "$m" = 1 ] && mm=true
        echo "{\"installed\":true,\"version\":\"32.0.13.1\",\"versionstring\":\"32.0.13\",\"maintenance\":$mm,\"needsDbUpgrade\":$up}" ;;
    "config:system:get instanceid") echo "${FAKE_INSTANCEID-oc1234}" ;;
    "config:system:get objectstore") [ -n "${FAKE_OBJECTSTORE:-}" ] && { echo S3; exit 0; }; exit 1 ;;
    "maintenance:mode --on") touch "$S/maintenance" ;;
    "maintenance:mode --off") rm -f "$S/maintenance" ;;
    "app:list --output=json") echo '{"enabled":{"openregister":"2.1.41","dossiq":"0.4.53","spreed":"22.0.0"},"disabled":{"mail":"5.0.0"}}' ;;
    "group:list --output=json") echo "${FAKE_GROUPS-{\"admin\":[\"admin\"],\"inwoners\":[],\"medewerkers\":[]}}" ;;
    "app:enable --groups="*)
        if [ -n "${FAKE_NO_GROUP_LIMIT:-}" ] && [[ "$*" == *" $FAKE_NO_GROUP_LIMIT" ]]; then
            echo "$FAKE_NO_GROUP_LIMIT can't be enabled for groups." >&2; exit 1
        fi ;;
    "app:enable "*) ;;
    "upgrade") rm -f "$S/needs-upgrade" ;;
    "memcache:distributed:clear") ;;
    openregister:example-set:*)
        # App-commando's laden niet in onderhoudsmodus (core Console\Application).
        if [ "$m" = 1 ]; then echo "Command not found" >&2; exit 1; fi ;;
    *) echo "occ-stub: onbekend: $*" >&2; exit 1 ;;
esac
EOF

# Postgres als een map per database: $FAKE_STATE/db/<naam>/{content,template,comment}.
cat >"$STUBS/fake-sql" <<'EOF'
#!/usr/bin/env bash
S="$FAKE_STATE/db"
q="$1"
echo "$q" >>"$FAKE_STATE/sql.log"
if [ -n "${FAKE_FAIL_SQL:-}" ] && [[ "$q" =~ $FAKE_FAIL_SQL ]]; then echo "ERROR: faalinjectie" >&2; exit 1; fi
if [[ "$q" =~ ^SELECT\ 1\ FROM\ pg_database\ WHERE\ datname\ =\ \'([a-z_]+)\'$ ]]; then
    [ -d "$S/${BASH_REMATCH[1]}" ] && echo 1; exit 0
elif [[ "$q" =~ ^SELECT\ count\(pg_terminate_backend ]]; then
    echo 0
elif [[ "$q" =~ ^CREATE\ DATABASE\ \"([a-z_]+)\"\ TEMPLATE\ \"([a-z_]+)\" ]]; then
    d="${BASH_REMATCH[1]}"; t="${BASH_REMATCH[2]}"
    [ -d "$S/$t" ] && [ ! -d "$S/$d" ] || { echo "ERROR: create $d from $t" >&2; exit 1; }
    mkdir "$S/$d" && cp "$S/$t/content" "$S/$d/content"
elif [[ "$q" =~ ^ALTER\ DATABASE\ \"([a-z_]+)\"\ RENAME\ TO\ \"([a-z_]+)\"$ ]]; then
    [ -d "$S/${BASH_REMATCH[1]}" ] && [ ! -d "$S/${BASH_REMATCH[2]}" ] || { echo "ERROR: rename" >&2; exit 1; }
    mv "$S/${BASH_REMATCH[1]}" "$S/${BASH_REMATCH[2]}"
elif [[ "$q" =~ ^ALTER\ DATABASE\ \"([a-z_]+)\"\ WITH\ IS_TEMPLATE\ (true|false) ]]; then
    [ -d "$S/${BASH_REMATCH[1]}" ] || exit 1
    echo "${BASH_REMATCH[2]}" >"$S/${BASH_REMATCH[1]}/template"
elif [[ "$q" =~ ^DROP\ DATABASE\ \"([a-z_]+)\" ]]; then
    [ "$(cat "$S/${BASH_REMATCH[1]}/template" 2>/dev/null)" = "true" ] && { echo "ERROR: cannot drop a template database" >&2; exit 1; }
    rm -rf "${S:?}/${BASH_REMATCH[1]}"
elif [[ "$q" =~ ^COMMENT\ ON\ DATABASE\ \"([a-z_]+)\"\ IS\ \'(.*)\'$ ]]; then
    echo "${BASH_REMATCH[2]}" >"$S/${BASH_REMATCH[1]}/comment"
elif [[ "$q" =~ datname\ =\ \'([a-z_]+)\'$ ]] && [[ "$q" == *shobj_description* ]]; then
    cat "$S/${BASH_REMATCH[1]}/comment" 2>/dev/null; exit 0
elif [[ "$q" == *pg_size_pretty* ]]; then
    echo "8 MB"
else
    echo "fake-sql: onbekend: $q" >&2; exit 1
fi
EOF

# curl -fsS ... -H "Host: x" <url>: status.php uit de stand van de stub.
cat >"$STUBS/curl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_STATE/curl.log"
mm=false; [ -f "$FAKE_STATE/maintenance" ] && mm=true
echo "{\"installed\":true,\"maintenance\":$mm}"
EOF
chmod +x "$STUBS"/*

# Een verse tenant: live database "bezoekers", een datamap met logs, de
# state van de apps-hook en gebruikersbestanden.
new_tenant() {
    export FAKE_ROOT="$WORK/root" FAKE_STATE="$WORK/state" FAKE_STUBS="$STUBS"
    rm -rf "$FAKE_ROOT" "$FAKE_STATE"
    mkdir -p "$FAKE_STATE/db/nextcloud" "$FAKE_ROOT/proc/1" "$FAKE_ROOT/var/www/html/data/sanne/files" \
        "$FAKE_ROOT/var/www/html/data/appdata_oc1234"
    echo "php-fpm" >"$FAKE_ROOT/proc/1/comm"
    echo "demo" >"$FAKE_STATE/db/nextcloud/content"
    local d="$FAKE_ROOT/var/www/html/data"
    echo "brief" >"$d/sanne/files/brief.txt"
    echo "preview" >"$d/appdata_oc1234/p"
    echo "# Nextcloud data directory" >"$d/.ocdata"
    echo "log-voor" >"$d/nextcloud.log"
    echo "hook-state" >"$d/.conduction-apps-state"
    : >"$FAKE_STATE/kubectl.log"
    : >"$FAKE_STATE/occ.log"
    unset FAKE_FAIL_EXEC FAKE_FAIL_OCC FAKE_FAIL_SQL FAKE_OBJECTSTORE FAKE_INSTANCEID FAKE_OWN_PODS FAKE_NC_PODS \
        FAKE_GROUPS FAKE_NO_GROUP_LIMIT
}

# Bezoekers doen dingen: database anders, een upload, een verwijderd bestand,
# meer log.
visitors_were_here() {
    local d="$FAKE_ROOT/var/www/html/data"
    echo "bezoekers" >"$FAKE_STATE/db/nextcloud/content"
    mkdir -p "$d/bezoeker1/files" && echo "upload" >"$d/bezoeker1/files/upload.pdf"
    rm -f "$d/sanne/files/brief.txt"
    echo "log-na" >"$d/nextcloud.log"
    echo "hook-state-nieuw" >"$d/.conduction-apps-state"
}

run_script() { # <mode> ; zet RC en schrijft uitvoer naar $WORK/out
    set +e
    env PATH="$STUBS:$PATH" KUBECTL="$STUBS/kubectl" CURL="$STUBS/curl" WAIT_STEP=0 CRON_WAIT_TRIES=3 \
        POD_NAMESPACE=zuiddrecht-prod TENANT_NAME=zuiddrecht-prod TENANT_HOST=cloud.zuiddrecht.nl \
        CONFIRM_WIPE="${CONFIRM:-zuiddrecht-prod}" EXAMPLE_SETS="${SETS-zuiddrecht}" \
        EXAMPLE_SET_MODE="${SETMODE:-install}" PASSWORD_FILE="${PWFILE:-}" \
        LIMIT_APPS="${LIMITAPPS-}" LIMIT_EXCEPT_GROUPS="${LIMITEXCEPT-}" \
        bash "$SCRIPT" "$1" >"$WORK/out" 2>&1
    RC=$?
    set -e
}

db() { cat "$FAKE_STATE/db/$1/content" 2>/dev/null || echo "<geen>"; }
maint_on_now() { [ -f "$FAKE_STATE/maintenance" ]; }
data() { echo "$FAKE_ROOT/var/www/html/data/$1"; }
# Regelnummer van de eerste occ-aanroep die op het patroon past (0 = geen).
occ_line() { grep -n -m1 -F -- "$1" "$FAKE_STATE/occ.log" | cut -d: -f1 || true; }
before() { local a b; a="$(occ_line "$1")"; b="$(occ_line "$2")"; [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; }

golden_ready() {
    new_tenant
    run_script golden
    [ "$RC" -eq 0 ] || { cat "$WORK/out" >&2; echo "golden_ready faalde" >&2; exit 1; }
    : >"$FAKE_STATE/occ.log"
}

start "script: golden neemt database en datamap, zonder logs en hook-state"
new_tenant
echo 2 >"$FAKE_STATE/cron"
run_script golden
check "exit 0" test "$RC" -eq 0
check "gouden database is kopie" test "$(db nextcloud_demo_golden)" = "demo"
check "gouden database is template" test "$(cat "$FAKE_STATE/db/nextcloud_demo_golden/template")" = "true"
id="$(cat "$FAKE_ROOT/var/www/demo-reset/golden/COMPLETE" 2>/dev/null || true)"
check "COMPLETE heeft een id" test -n "$id"
check "database-commentaar hoort bij COMPLETE" test "$(cat "$FAKE_STATE/db/nextcloud_demo_golden/comment")" = "demo-reset $id"
check "manifest instanceid" test "$(jq -r .instanceid "$FAKE_ROOT/var/www/demo-reset/golden/manifest.json")" = "oc1234"
check "brief.txt in de momentopname" test -f "$FAKE_ROOT/var/www/demo-reset/golden/data/sanne/files/brief.txt"
check "nextcloud.log niet in de momentopname" test ! -e "$FAKE_ROOT/var/www/demo-reset/golden/data/nextcloud.log"
check ".conduction-apps-state niet in de momentopname" test ! -e "$FAKE_ROOT/var/www/demo-reset/golden/data/.conduction-apps-state"
check "geen incoming-database over" test ! -d "$FAKE_STATE/db/nextcloud_demo_incoming"
check "onderhoudsmodus weer uit" not maint_on_now
check "eerst onderhoud, dan kopie" grep -q 'CREATE DATABASE "nextcloud_demo_incoming" TEMPLATE "nextcloud"' "$FAKE_STATE/sql.log"
check "gewacht op cron" test "$(cat "$FAKE_STATE/cron")" = "0"
finish

start "script: golden weigert als de tenant al in onderhoud staat"
new_tenant
touch "$FAKE_STATE/maintenance"
run_script golden
check "exit 1" test "$RC" -eq 1
check "geen gouden database" test ! -d "$FAKE_STATE/db/nextcloud_demo_golden"
check "onderhoud blijft zoals het was (aan)" maint_on_now
finish

start "script: reset zet database en datamap terug, logs en hook-state blijven"
golden_ready
visitors_were_here
run_script reset
check "exit 0" test "$RC" -eq 0
check "database terug" test "$(db nextcloud)" = "demo"
check "gouden database staat er nog" test "$(db nextcloud_demo_golden)" = "demo"
check "geen previous/incoming over" test ! -d "$FAKE_STATE/db/nextcloud_demo_previous" -a ! -d "$FAKE_STATE/db/nextcloud_demo_incoming"
check "upload van bezoeker weg" test ! -e "$(data bezoeker1)"
check "brief.txt terug" test -f "$(data sanne/files/brief.txt)"
check "appdata terug" test -f "$(data appdata_oc1234/p)"
check "nextcloud.log blijft de live versie" test "$(cat "$(data nextcloud.log)")" = "log-na"
check "hook-state blijft de live versie" test "$(cat "$(data .conduction-apps-state)")" = "hook-state-nieuw"
check "onderhoudsmodus uit" not maint_on_now
check "onderhoud aan vóór de wissel" before "maintenance:mode --on" "maintenance:mode --off"
check "cache legen na onderhoud uit" before "maint=0 memcache:distributed:clear" "openregister:example-set:install"
check "cache legen niet in onderhoud" not grep -q 'maint=1 memcache:distributed:clear' "$FAKE_STATE/occ.log"
check "set laden buiten onderhoud" grep -q '^maint=0 openregister:example-set:install zuiddrecht$' "$FAKE_STATE/occ.log"
check "php-fpm herladen" grep -q '^kill kill -USR2 1$' "$FAKE_STATE/occ.log"
check "status.php met de tenant-host" grep -qF 'Host: cloud.zuiddrecht.nl' "$FAKE_STATE/curl.log"
check "last-reset geschreven" test -s "$FAKE_ROOT/var/www/demo-reset/last-reset"
finish

start "script: reset twee keer achter elkaar is gelijk"
run_script reset
check "exit 0" test "$RC" -eq 0
check "database nog steeds terug" test "$(db nextcloud)" = "demo"
check "brief.txt" test -f "$(data sanne/files/brief.txt)"
finish

start "script: reset zonder momentopname wist niets"
new_tenant
visitors_were_here
run_script reset
check "exit 1" test "$RC" -eq 1
check "melding" grep -qF 'geen geldige momentopname' "$WORK/out"
check "database onaangeroerd" test "$(db nextcloud)" = "bezoekers"
check "upload staat er nog" test -f "$(data bezoeker1/files/upload.pdf)"
check "nooit onderhoud aangezet" not grep -q 'maintenance:mode --on' "$FAKE_STATE/occ.log"
finish

start "script: momentopname van een andere instantie wordt geweigerd"
golden_ready
visitors_were_here
FAKE_INSTANCEID=ocANDERS run_script reset
check "exit 1" test "$RC" -eq 1
check "melding" grep -qF 'andere instantie' "$WORK/out"
check "database onaangeroerd" test "$(db nextcloud)" = "bezoekers"
finish

start "script: database en map van verschillende momenten worden geweigerd"
golden_ready
visitors_were_here
echo "demo-reset 19990101T000000Z" >"$FAKE_STATE/db/nextcloud_demo_golden/comment"
run_script reset
check "exit 1" test "$RC" -eq 1
check "melding" grep -qF 'hoort niet bij momentopname' "$WORK/out"
check "database onaangeroerd" test "$(db nextcloud)" = "bezoekers"
finish

start "script: S3 primary objectstore stopt alles"
golden_ready
visitors_were_here
FAKE_OBJECTSTORE=1 run_script reset
check "exit 1" test "$RC" -eq 1
check "melding" grep -qF 'S3 primary objectstore' "$WORK/out"
check "database onaangeroerd" test "$(db nextcloud)" = "bezoekers"
check "nooit onderhoud aangezet" not grep -q 'maintenance:mode --on' "$FAKE_STATE/occ.log"
finish

start "script: fout vóór het wissen zet onderhoud weer uit"
golden_ready
visitors_were_here
FAKE_FAIL_SQL='^CREATE DATABASE "nextcloud_demo_incoming"' run_script reset
check "exit 1" test "$RC" -eq 1
check "database onaangeroerd" test "$(db nextcloud)" = "bezoekers"
check "onderhoudsmodus weer uit" not maint_on_now
check "melding" grep -qF 'fout vóór het wissen' "$WORK/out"
finish

start "script: fout ná het wissen laat onderhoud AAN"
golden_ready
visitors_were_here
FAKE_FAIL_EXEC='cp -a' run_script reset
check "exit 1" test "$RC" -eq 1
check "onderhoudsmodus blijft aan" maint_on_now
check "melding" grep -qF 'BLIJFT AAN' "$WORK/out"
check "momentopname onaangeroerd" test "$(db nextcloud_demo_golden)" = "demo"
check "gouden map onaangeroerd" test -f "$FAKE_ROOT/var/www/demo-reset/golden/data/sanne/files/brief.txt"
# En een tweede run maakt het af, ook al stond onderhoud nog aan.
unset FAKE_FAIL_EXEC
run_script reset
check "herstart: exit 0" test "$RC" -eq 0
check "herstart: onderhoud uit" not maint_on_now
check "herstart: brief.txt terug" test -f "$(data sanne/files/brief.txt)"
finish

start "script: herstart na een wissel die halverwege stopte"
golden_ready
visitors_were_here
# Stand na een crash tussen de twee renames: live weg, previous en incoming er.
mv "$FAKE_STATE/db/nextcloud" "$FAKE_STATE/db/nextcloud_demo_previous"
mkdir "$FAKE_STATE/db/nextcloud_demo_incoming" && echo "demo" >"$FAKE_STATE/db/nextcloud_demo_incoming/content"
touch "$FAKE_STATE/maintenance"
run_script reset
check "exit 0" test "$RC" -eq 0
check "database terug" test "$(db nextcloud)" = "demo"
check "geen previous/incoming over" test ! -d "$FAKE_STATE/db/nextcloud_demo_previous" -a ! -d "$FAKE_STATE/db/nextcloud_demo_incoming"
check "onderhoud uit" not maint_on_now
finish

start "script: falende voorbeeldset laat de tenant op de momentopname, in de lucht"
golden_ready
visitors_were_here
FAKE_FAIL_OCC='openregister:example-set:install' run_script reset
check "exit 1" test "$RC" -eq 1
check "database terug" test "$(db nextcloud)" = "demo"
check "onderhoud uit" not maint_on_now
finish

start "script: reinstall verwijdert eerst, dan install"
golden_ready
SETMODE=reinstall run_script reset
check "exit 0" test "$RC" -eq 0
check "remove vóór install" before "openregister:example-set:remove zuiddrecht" "openregister:example-set:install zuiddrecht"
finish

start "script: wachtwoord gaat via stdin, nooit als argument"
golden_ready
printf 'geheim-demo-wachtwoord\n' >"$WORK/pw"
PWFILE="$WORK/pw" run_script reset
check "exit 0" test "$RC" -eq 0
check "install met --password-from-env en OC_PASS" grep -q 'openregister:example-set:install zuiddrecht --password-from-env OC_PASS=geheim-demo-wachtwoord' "$FAKE_STATE/occ.log"
check "wachtwoord niet in een kubectl-aanroep" not grep -q 'geheim-demo-wachtwoord' "$FAKE_STATE/kubectl.log"
check "wachtwoord niet in de uitvoer" not grep -q 'geheim-demo-wachtwoord' "$WORK/out"
finish

start "script: nieuwere app-code krijgt occ upgrade vóór onderhoud uit"
golden_ready
touch "$FAKE_STATE/needs-upgrade"
run_script reset
check "exit 0" test "$RC" -eq 0
check "upgrade in onderhoud" grep -q '^maint=1 upgrade$' "$FAKE_STATE/occ.log"
check "upgrade vóór onderhoud uit" before "maint=1 upgrade" "maintenance:mode --off"
finish

start "script: zonder voorbeeldsets alleen terugzetten"
golden_ready
SETS="" run_script reset
check "exit 0" test "$RC" -eq 0
check "geen example-set-aanroep" not grep -q 'example-set' "$FAKE_STATE/occ.log"
finish

start "script: verkeerde confirmWipe raakt de cluster niet"
golden_ready
: >"$FAKE_STATE/kubectl.log"
CONFIRM=alkmaar-prod run_script reset
check "exit 1" test "$RC" -eq 1
check "geen enkele kubectl-aanroep" test ! -s "$FAKE_STATE/kubectl.log"
finish

start "script: een tweede demo-reset-Job tegelijk stopt"
golden_ready
visitors_were_here
FAKE_OWN_PODS="demo-reset-a demo-reset-golden-b" run_script reset
check "exit 1" test "$RC" -eq 1
check "melding" grep -qF 'er loopt al een andere demo-reset-Job' "$WORK/out"
check "database onaangeroerd" test "$(db nextcloud)" = "bezoekers"
finish

start "script: twee Nextcloud-pods stopt (lege of dubbele waarde is een fout)"
golden_ready
FAKE_NC_PODS="nextcloud-a nextcloud-b" run_script reset
check "exit 1" test "$RC" -eq 1
check "melding" grep -qF 'precies één draaiende nextcloud-pod' "$WORK/out"
FAKE_NC_PODS="" run_script reset
check "geen pod: exit 1" test "$RC" -eq 1
finish

start "script: limitApps beperkt na de sets, per app, buiten onderhoud"
golden_ready
FAKE_NO_GROUP_LIMIT=spreed LIMITAPPS="dossiq spreed mail kalender" LIMITEXCEPT=inwoners run_script reset
check "exit 0" test "$RC" -eq 0
check "dossiq voor alle groepen behalve inwoners" grep -q '^maint=0 app:enable --groups=admin --groups=medewerkers dossiq$' "$FAKE_STATE/occ.log"
check "een uitgeschakelde app telt als geïnstalleerd" grep -q '^maint=0 app:enable --groups=admin --groups=medewerkers mail$' "$FAKE_STATE/occ.log"
check "inwoners nooit in --groups" not grep -q -- '--groups=inwoners' "$FAKE_STATE/occ.log"
check "spreed weigert groepen en gaat aan voor iedereen" grep -q '^maint=0 app:enable spreed$' "$FAKE_STATE/occ.log"
check "WARN voor spreed" grep -qF 'WARN: app spreed' "$WORK/out"
check "niet-geïnstalleerde app overgeslagen" grep -qF 'app kalender is niet geïnstalleerd' "$WORK/out"
check "kalender nooit aangezet" not grep -q 'app:enable.*kalender' "$FAKE_STATE/occ.log"
check "na de voorbeeldset" before "openregister:example-set:install zuiddrecht" "app:enable --groups=admin --groups=medewerkers dossiq"
finish

start "script: zonder limitApps geen groepsstap"
golden_ready
run_script reset
check "exit 0" test "$RC" -eq 0
check "geen group:list" not grep -q 'group:list' "$FAKE_STATE/occ.log"
check "geen app:enable" not grep -q 'app:enable' "$FAKE_STATE/occ.log"
finish

start "script: limitApps zonder uitzondering raakt de cluster niet"
golden_ready
: >"$FAKE_STATE/kubectl.log"
LIMITAPPS="dossiq" LIMITEXCEPT="" run_script reset
check "exit 1" test "$RC" -eq 1
check "melding" grep -qF 'LIMIT_APPS is gezet zonder LIMIT_EXCEPT_GROUPS' "$WORK/out"
check "geen enkele kubectl-aanroep" test ! -s "$FAKE_STATE/kubectl.log"
finish

start "script: geen groep over faalt zichtbaar, tenant blijft op de momentopname"
golden_ready
visitors_were_here
FAKE_GROUPS='{"inwoners":[]}' LIMITAPPS="dossiq" LIMITEXCEPT=inwoners run_script reset
check "exit 1" test "$RC" -eq 1
check "melding" grep -qF 'geen groepen over' "$WORK/out"
check "database terug" test "$(db nextcloud)" = "demo"
check "onderhoud uit" not maint_on_now
check "geen app:enable" not grep -q 'app:enable' "$FAKE_STATE/occ.log"
finish

start "script: groepsnaam die niet veilig door occ kan stopt de stap"
golden_ready
FAKE_GROUPS='{"admin":[],"a b;id":[],"inwoners":[]}' LIMITAPPS="dossiq" LIMITEXCEPT=inwoners run_script reset
check "exit 1" test "$RC" -eq 1
check "melding" grep -qF 'niet veilig door occ' "$WORK/out"
check "geen app:enable" not grep -q 'app:enable' "$FAKE_STATE/occ.log"
finish

echo
echo "tests: ${PASSED} geslaagd, ${FAILED} gefaald"
[[ $FAILED -eq 0 ]]
