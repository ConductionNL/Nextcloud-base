#!/usr/bin/env bash
# SPDX-License-Identifier: EUPL-1.2
# role: tool
#
# nextcloud-platform/tests/run-hook-tests.sh — fixture-tests voor de
# Conduction-apps install-hook (nextcloud.hooks.before-starting en
# post-installation in values/common.yaml).
#
# De hook draait in de Nextcloud-pod, maar hij is gewoon bash. Deze suite haalt
# de tekst uit common.yaml en draait hem lokaal tegen een nep-/var/www/html
# (CONDUCTION_NC_ROOT), met stubs voor `php` (occ), `curl` (GitHub-releases uit
# een fixture-map) en `chown`. tar, sha256sum en awk zijn echt.
#
# Twee soorten cases:
#
#   pariteit  de bevroren oude hook (hook-fixtures/legacy-before-starting.sh,
#             van main vóór de generieke pins) en de huidige hook draaien op
#             identieke fixtures. occ-aanroepen, downloads, de bestandsboom en
#             het state-bestand moeten gelijk zijn. Dat is het bewijs dat een
#             bestaande tenant hetzelfde gedrag houdt.
#   nieuw     generieke pins, checksum, mapnaam, links, info.xml-id, falen dat luid
#             is en niets half achterlaat, state-sleutel per pin.
#
# Writes: alleen in een eigen mktemp-map
# Idempotent: ja
# Requires: bash, yq, tar, gzip, sha256sum, awk, python3
#
# Usage:
#   ./run-hook-tests.sh            # alle cases
#   VERBOSE=1 ./run-hook-tests.sh  # toon de hook-log bij een falende case

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly COMMON="${SCRIPT_DIR}/../values/common.yaml"
readonly LEGACY_HOOK="${SCRIPT_DIR}/hook-fixtures/legacy-before-starting.sh"

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

# ---------------------------------------------------------------------------
# Stubs
# ---------------------------------------------------------------------------
STUBS="${WORK}/stubs"
mkdir -p "$STUBS"

# php occ <cmd>: gedraagt zich als Nextcloud 32.0.13 voor wat de hook gebruikt.
# Per tenant-root houdt hij in $STUB_DIR/enabled/<id> de OPGESLAGEN versie
# (appconfig installed_version) bij, los van de code in custom_apps of apps:
#   app:enable   een app die al aan staat: '<id> already enabled', verder niets
#                (core/Command/App/Enable.php). Anders slaat hij de versie uit
#                info.xml op, zoals installApp doet.
#   app:list     toont voor een ingeschakelde app de opgeslagen versie, niet die
#                uit info.xml (core/Command/App/ListApps.php).
#   upgrade      werkt de opgeslagen versie bij van elke ingeschakelde app
#                waarvan info.xml nieuwer is; anders 'No upgrade required.'
#                (core/Command/Upgrade.php).
#   status       needsDbUpgrade: true zolang zo'n app bestaat.
# Faalinjectie: STUB_ENABLE_FAIL=<id> laat app:enable van die app falen (bv.
# max-version), STUB_UPGRADE_NOOP=1 laat upgrade niets bijwerken (een app-
# upgrade die mislukt). Elke aanroep komt in $STUB_DIR/calls.
cat > "${STUBS}/php" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$STUB_DIR/calls"
[ "${1:-}" = "occ" ] || exit 1
shift
info_version() { grep -o '<version>[^<]*</version>' "$1" | head -1 | sed -e 's#<version>##' -e 's#</version>##'; }
code_version() { # de versie in info.xml van de code die Nextcloud laadt
  local d
  for d in "$NC_FAKE_ROOT/custom_apps/$1" "$NC_FAKE_ROOT/apps/$1"; do
    if [ -f "$d/appinfo/info.xml" ]; then info_version "$d/appinfo/info.xml"; return 0; fi
  done
  return 1
}
newer() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]; }
needs_upgrade() { # <id>: code nieuwer dan de opgeslagen versie
  local code
  code="$(code_version "$1")" || return 1
  newer "$code" "$(cat "$STUB_DIR/enabled/$1")"
}
case "${1:-}" in
  app:list)
    echo "Enabled:"
    for f in "$STUB_DIR"/enabled/*; do
      [ -e "$f" ] || continue
      echo "  - $(basename "$f"): $(cat "$f")"
    done
    ;;
  app:install)
    if [ -e "$STUB_DIR/enabled/$2" ]; then echo "$2 already installed" >&2; exit 1; fi
    if [ -f "$STUB_DIR/appstore/$2" ]; then cp "$STUB_DIR/appstore/$2" "$STUB_DIR/enabled/$2"; exit 0; fi
    echo "Could not download app $2" >&2; exit 1
    ;;
  app:enable)
    if [ -e "$STUB_DIR/enabled/$2" ]; then echo "$2 already enabled"; exit 0; fi
    if [ "${STUB_ENABLE_FAIL:-}" = "$2" ]; then echo "App \"$2\" cannot be installed because it is not compatible with this version of the server."; exit 1; fi
    if v="$(code_version "$2")"; then echo "$v" > "$STUB_DIR/enabled/$2"; echo "$2 $v enabled"; exit 0; fi
    echo "$2 not found"; exit 1
    ;;
  upgrade)
    if [ -n "${STUB_UPGRADE_NOOP:-}" ]; then echo "Exception: app upgrade failed"; exit 5; fi
    done_any=0
    for f in "$STUB_DIR"/enabled/*; do
      [ -e "$f" ] || continue
      id="$(basename "$f")"
      if needs_upgrade "$id"; then code_version "$id" > "$f"; echo "Updated $id"; done_any=1; fi
    done
    [ "$done_any" = 1 ] || echo "No upgrade required."
    ;;
  status)
    nu=false
    for f in "$STUB_DIR"/enabled/*; do
      [ -e "$f" ] || continue
      if needs_upgrade "$(basename "$f")"; then nu=true; fi
    done
    echo "  - needsDbUpgrade: $nu"
    ;;
  *) exit 0 ;;
esac
EOF

# curl: serveert https://github.com/<pad> uit $STUB_DIR/release/<pad>. De
# volledige aanroep komt in $STUB_DIR/curl-args (voor de grenzen-check).
cat > "${STUBS}/curl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$STUB_DIR/curl-args"
out="" fmt="" failflag=0 url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift ;;
    -w) fmt="$2"; shift ;;
    --retry|--retry-delay|--retry-max-time|--connect-timeout|--max-time|--proto|--proto-redir) shift ;;
    --*) ;;
    -*) [[ "$1" == *f* ]] && failflag=1 ;;
    http*) url="$1" ;;
  esac
  shift
done
echo "$url" >> "$STUB_DIR/curl-calls"
src="$STUB_DIR/release${url#https://github.com}"
if [ -f "$src" ]; then
  cp "$src" "$out"
  [ -n "$fmt" ] && printf '200'
  exit 0
fi
if [ "$failflag" = 1 ]; then echo "curl: (22) The requested URL returned error: 404" >&2; exit 22; fi
printf 'Not Found' > "$out"
[ -n "$fmt" ] && printf '404'
exit 0
EOF

printf '#!/usr/bin/env bash\nexit 0\n' > "${STUBS}/chown"

# mv: echt, behalve met STUB_MV_FAIL=1: dan faalt de stap die de nieuwe code
# uit de staging-map naar custom_apps zet (bv. een vol of read-only volume).
cat > "${STUBS}/mv" <<'EOF'
#!/usr/bin/env bash
if [ -n "${STUB_MV_FAIL:-}" ] && [[ "${1:-}" == *"/.conduction-staging-"* ]]; then
  echo "mv: cannot move '$1': No space left on device" >&2; exit 1
fi
exec /bin/mv "$@"
EOF
chmod +x "${STUBS}/php" "${STUBS}/curl" "${STUBS}/chown" "${STUBS}/mv"

# ---------------------------------------------------------------------------
# Hooks
# ---------------------------------------------------------------------------
NEW_HOOK="${WORK}/hooks/before-starting/helm.sh"
mkdir -p "$(dirname "$NEW_HOOK")"
yq 'explode(.) | .nextcloud.hooks.before-starting' "$COMMON" > "$NEW_HOOK"
POST_INSTALL_HOOK="${WORK}/post.sh"
yq 'explode(.) | .nextcloud.hooks.post-installation' "$COMMON" > "$POST_INSTALL_HOOK"

# ---------------------------------------------------------------------------
# Fixture-helpers. Een "tenant" is een map met root/ (nep /var/www/html) en
# stub/ (occ-staat, appstore, releases, aanroeplogs).
# ---------------------------------------------------------------------------
new_tenant() {
    local t="${WORK}/t/$1"
    rm -rf "$t"
    mkdir -p "$t/root/config" "$t/root/data" "$t/root/apps" "$t/root/custom_apps" "$t/root/tmp" \
        "$t/stub/enabled" "$t/stub/appstore" "$t/stub/release"
    echo '<?php $CONFIG = array();' > "$t/root/config/config.php"
    : > "$t/stub/calls"
    : > "$t/stub/curl-calls"
    echo "$t"
}

# make_app_dir <dir> <id> <version>
make_app_dir() {
    mkdir -p "$1/appinfo" "$1/lib"
    printf '<?xml version="1.0"?>\n<info>\n  <id>%s</id>\n  <name>%s</name>\n  <version>%s</version>\n</info>\n' \
        "$2" "$2" "$3" > "$1/appinfo/info.xml"
    echo "<?php // $2 $3" > "$1/lib/App.php"
}

# make_release <tenant> <repo> <version> [sha=good|bad|none] [folder] [xml-id] [xml-version] [asset-id]
# Legt een GitHub-release neer zoals de vloot hem publiceert.
make_release() {
    local t="$1" repo="$2" ver="$3" sha="${4:-good}" folder="${5:-$2}" xid="${6:-$2}" xver="${7:-$3}" asset_id="${8:-$2}"
    local dir="$t/stub/release/ConductionNL/$repo/releases/download/v$ver"
    local asset="$dir/$asset_id-$ver.tar.gz" src="${WORK}/src-$$-$RANDOM"
    mkdir -p "$dir" "$src"
    make_app_dir "$src/$folder" "$xid" "$xver"
    tar -czf "$asset" -C "$src" "$folder"
    rm -rf "$src"
    case "$sha" in
        good) echo "$(sha256sum "$asset" | awk '{print $1}')  $asset_id-$ver.tar.gz" > "$asset.sha256" ;;
        bad) echo "$(printf '0%.0s' {1..64})  $asset_id-$ver.tar.gz" > "$asset.sha256" ;;
        none) ;;
    esac
}

# run_hook <tenant> <script> [VAR=waarde ...] — schone omgeving, geen lekkende env.
run_hook() {
    local t="$1" script="$2"
    shift 2
    local hook="$script"
    if [ "$script" = "legacy" ]; then
        # De oude hook kent alleen /var/www/html en /tmp; die worden hier de nep-root.
        hook="$t/legacy/before-starting/helm.sh"
        mkdir -p "$(dirname "$hook")"
        # Volgorde telt: eerst /tmp/, anders herschrijft die regel de al
        # vervangen nep-root (die zelf onder /tmp staat).
        sed -e "s#/tmp/#$t/root/tmp/#g" -e "s#/var/www/html#$t/root#g" "$LEGACY_HOOK" > "$hook"
        grep -q "/var/www/html" "$hook" && { echo "legacy-hook niet volledig omgezet" >&2; exit 1; }
    fi
    local rc=0
    (cd "$t/root" && env -i PATH="${STUBS}:/usr/bin:/bin" HOME="$t" STUB_DIR="$t/stub" \
        NC_FAKE_ROOT="$t/root" CONDUCTION_NC_ROOT="$t/root" TMPDIR="$t/root/tmp" "$@" \
        bash "$hook" > "$t/stdout" 2> "$t/stderr") || rc=$?
    echo "$rc" > "$t/rc"
}

# Wat telt als gedrag: occ-aanroepen, tarball-downloads (de .sha256-check is
# nieuw en telt niet mee), de app-bomen en het state-bestand.
snapshot() {
    local t="$1"
    echo "## occ"; cat "$t/stub/calls"
    echo "## downloads"; grep -v '\.sha256$' "$t/stub/curl-calls" || true
    echo "## enabled"; for f in "$t/stub/enabled"/*; do [ -e "$f" ] && echo "$(basename "$f")=$(cat "$f")"; done
    echo "## tree"; (cd "$t/root" && find apps custom_apps -path '*/appinfo/info.xml' | sort | while read -r f; do
        echo "$f $(grep -o '<version>[^<]*</version>' "$f")"; done)
    echo "## state"; cat "$t/root/data/.conduction-apps-state" 2>/dev/null || echo "(geen)"
}

# occ status zoals een beheerder hem na de start zou draaien (telt niet als
# hook-aanroep).
occ_status() {
    STUB_DIR="$1/stub" NC_FAKE_ROOT="$1/root" "${STUBS}/php" occ status
    sed -i '$d' "$1/stub/calls"
}

# ---------------------------------------------------------------------------
# Asserties
# ---------------------------------------------------------------------------
begin() { CASE="$1"; CASE_OK=1; }
nok() {
    printf "${RED}FAIL${NC} %s — %s\n" "$CASE" "$1" >&2
    CASE_OK=0
}
end() {
    if [ "$CASE_OK" = 1 ]; then
        printf "${GREEN}PASS${NC} %s\n" "$CASE"; PASSED=$((PASSED + 1))
    else
        FAILED=$((FAILED + 1))
        if [ -n "${VERBOSE:-}" ] && [ -n "${1:-}" ]; then sed 's/^/    /' "$1/root/data/conduction-apps.log" >&2 || true; fi
    fi
}
expect_eq() { [ "$1" = "$2" ] || nok "$3: verwacht '$2', kreeg '$1'"; }
expect_file_has() { grep -qF -- "$2" "$1" 2>/dev/null || nok "$(basename "$1") mist '$2'"; }
expect_file_lacks() { if grep -qF -- "$2" "$1" 2>/dev/null; then nok "$(basename "$1") bevat onverwacht '$2'"; fi; }
expect_state() { expect_eq "$(cat "$1/root/data/.conduction-apps-state" 2>/dev/null || echo '(geen)')" "$2" "state"; }
expect_app() { # <tenant> <custom_apps|apps> <id> <versie|absent>
    local f="$1/root/$2/$3/appinfo/info.xml"
    if [ "$4" = "absent" ]; then [ ! -e "$1/root/$2/$3" ] || nok "$2/$3 bestaat nog"; return; fi
    grep -qF "<version>$4</version>" "$f" 2>/dev/null || nok "$2/$3 is niet versie $4"
}
expect_no_leftovers() {
    local left
    left="$(find "$1/root/custom_apps" -maxdepth 1 -name '.conduction-staging-*' | wc -l)"
    expect_eq "$left" "0" "staging-mappen achtergebleven"
    left="$(find "$1/root/custom_apps" "$1/root/apps" -maxdepth 1 -name '.conduction-previous-*' | wc -l)"
    expect_eq "$left" "0" "opzijgezette vorige versies achtergebleven"
    left="$(find "$1/root/tmp" -mindepth 1 -maxdepth 1 -name 'conduction-*' | wc -l)"
    expect_eq "$left" "0" "tijdelijke downloadmappen achtergebleven"
}

# Pariteit: <naam> <setup-functie> [VAR=waarde ...]
parity() {
    local name="$1" setup="$2"
    shift 2
    begin "pariteit: $name"
    local a b
    a="$(new_tenant "p-old")"; b="$(new_tenant "p-new")"
    "$setup" "$a"; "$setup" "$b"
    run_hook "$a" legacy "$@"
    run_hook "$b" "$NEW_HOOK" "$@"
    snapshot "$a" > "$a/snap"; snapshot "$b" > "$b/snap"
    if ! diff -u "$a/snap" "$b/snap" > "$WORK/diff"; then
        nok "gedrag wijkt af van de oude hook:"
        sed 's/^/    /' "$WORK/diff" >&2
    fi
    expect_eq "$(cat "$b/rc")" "0" "exitcode nieuwe hook"
    expect_eq "$(wc -c < "$b/stderr" | tr -d ' ')" "0" "stderr nieuwe hook (geen fouten verwacht)"
    end "$b"
}

# ---------------------------------------------------------------------------
# Setups voor de pariteitscases (de vloot zoals hij nu is)
# ---------------------------------------------------------------------------
LEGACY_PINS_OLD=(OPENCATALOGI_VERSION=0.7.12 OPENCONNECTOR_VERSION=0.2.16 OPENREGISTER_VERSION=0.2.11)
LEGACY_PINS_NEW=(OPENCATALOGI_VERSION=1.0.9 OPENCONNECTOR_VERSION=0.2.20 OPENREGISTER_VERSION=1.1.5)
APPS3="CONDUCTION_APPS=opencatalogi openconnector openregister"

setup_legacy_old() { # gouda-prod-achtig: oude releases zonder .sha256, gebundelde openregister in /apps
    make_release "$1" opencatalogi 0.7.12 none
    make_release "$1" openconnector 0.2.16 none
    make_release "$1" openregister 0.2.11 none
    make_app_dir "$1/root/apps/openregister" openregister 0.0.1
}
setup_legacy_new() { # almere-accept-achtig: deels met .sha256
    make_release "$1" opencatalogi 1.0.9 good
    make_release "$1" openconnector 0.2.20 none
    make_release "$1" openregister 1.1.5 good
}
setup_unpinned() {
    echo "1.0.0" > "$1/stub/enabled/opencatalogi"
    echo "0.2.30" > "$1/stub/appstore/openconnector"
    echo "1.2.0" > "$1/stub/appstore/openregister"
}
setup_mixed() {
    echo "1.2.0" > "$1/stub/appstore/openregister"
    echo "1.2.27" > "$1/stub/appstore/thematiq"
    echo "1.0.0" > "$1/stub/enabled/opencatalogi"
}
setup_partial_failure() { # openconnector-release ontbreekt
    make_release "$1" opencatalogi 1.0.9 good
    make_release "$1" openregister 1.1.5 good
}
setup_nothing() { :; }
setup_no_config() { rm -f "$1/root/config/config.php"; }

parity "drie oude pins, releases zonder checksum, gebundelde app" setup_legacy_old "$APPS3" "${LEGACY_PINS_OLD[@]}"
parity "drie oude pins, deels met checksum" setup_legacy_new "$APPS3" "${LEGACY_PINS_NEW[@]}"
parity "geen pins, drie oude apps uit de appstore" setup_unpinned "$APPS3"
parity "geen pins, CONDUCTION_APPS leeg (default-lijst)" setup_unpinned
parity "geen pins, extra app uit de appstore" setup_mixed "CONDUCTION_APPS=opencatalogi openregister thematiq"
parity "uitgeschakeld" setup_legacy_new "CONDUCTION_APPS_ENABLED=false" "$APPS3" "${LEGACY_PINS_NEW[@]}"
parity "Nextcloud nog niet geconfigureerd" setup_no_config "$APPS3" "${LEGACY_PINS_NEW[@]}"
parity "geen pins, niets te doen" setup_nothing "CONDUCTION_APPS=opencatalogi"

# De kern van achterwaartse compatibiliteit: een state die de OUDE hook schreef,
# moet de nieuwe hook als 'klaar' herkennen. Ook nu de ApplicationSet voor die
# tenants CONDUCTION_APP_VERSIONS meegeeft. Anders installeert de hele vloot
# opnieuw bij de herstart die de nieuwe hooktekst veroorzaakt.
begin "pariteit: state van de oude hook wordt herkend (geen herinstallatie)"
t="$(new_tenant state-compat)"
setup_legacy_new "$t"
run_hook "$t" legacy "$APPS3" "${LEGACY_PINS_NEW[@]}"
before="$(cat "$t/root/data/.conduction-apps-state")"
: > "$t/stub/calls"; : > "$t/stub/curl-calls"
run_hook "$t" "$NEW_HOOK" "$APPS3" "${LEGACY_PINS_NEW[@]}" \
    "CONDUCTION_APP_VERSIONS=opencatalogi=1.0.9 openconnector=0.2.20 openregister=1.1.5"
expect_eq "$(wc -l < "$t/stub/calls" | tr -d ' ')" "0" "occ-aanroepen"
expect_eq "$(wc -l < "$t/stub/curl-calls" | tr -d ' ')" "0" "downloads"
expect_state "$t" "$before"
expect_file_has "$t/root/data/conduction-apps.log" "already in desired state (skip)"
end "$t"

# Bewust verschil: een pin-bump op een app die al aan staat. De oude hook
# verving de code en riep alleen app:enable aan; op Nextcloud 32 doet dat niets
# voor een ingeschakelde app, dus bleef de instantie op "upgrade vereist" staan.
# De nieuwe hook draait daarna `occ upgrade`. Daarom geen pariteit voor dit
# geval, wel voor geen pin, ongewijzigde pin en state van de oude hook (boven).
begin "verschil: pin-bump op een ingeschakelde app (oude hook liet 'upgrade vereist' achter)"
a="$(new_tenant bump-old)"; b="$(new_tenant bump-new)"
for x in "$a" "$b"; do
    make_release "$x" openregister 1.1.5 good
    make_app_dir "$x/root/custom_apps/openregister" openregister 1.1.4
    echo "1.1.4" > "$x/stub/enabled/openregister"
done
run_hook "$a" legacy "CONDUCTION_APPS=openregister" "OPENREGISTER_VERSION=1.1.5"
run_hook "$b" "$NEW_HOOK" "CONDUCTION_APPS=openregister" "OPENREGISTER_VERSION=1.1.5"
expect_eq "$(occ_status "$a")" "  - needsDbUpgrade: true" "occ status na de oude hook"
expect_eq "$(occ_status "$b")" "  - needsDbUpgrade: false" "occ status na de nieuwe hook"
expect_eq "$(cat "$b/stub/enabled/openregister")" "1.1.5" "opgeslagen versie na de nieuwe hook"
expect_state "$b" "APPS=openregister;OPENCATALOGI_VERSION=;OPENCONNECTOR_VERSION=;OPENREGISTER_VERSION=1.1.5"
end "$b"

# ---------------------------------------------------------------------------
# Nieuw gedrag
# ---------------------------------------------------------------------------
PQ1="0.2.10-unstable.20261012182937"
PQ2="0.2.11-unstable.20261014090000"
OR1="2.1.41-unstable.20261012091248"
DEMO_APPS="CONDUCTION_APPS=openregister portaliq dossiq"
echo "0.4.40" > "${WORK}/dossiq-store"

setup_demo() {
    make_release "$1" portaliq "$PQ1" good
    make_release "$1" openregister "$OR1" good
    cp "${WORK}/dossiq-store" "$1/stub/appstore/dossiq"
}

begin "nieuw: generieke pin installeert een unstable build van GitHub"
t="$(new_tenant demo)"
setup_demo "$t"
run_hook "$t" "$NEW_HOOK" "$DEMO_APPS" "OPENREGISTER_VERSION=$OR1" \
    "CONDUCTION_APP_VERSIONS=openregister=$OR1 portaliq=$PQ1"
expect_eq "$(cat "$t/rc")" "0" "exitcode"
expect_app "$t" custom_apps portaliq "$PQ1"
expect_app "$t" custom_apps openregister "$OR1"
expect_file_has "$t/stub/curl-calls" "https://github.com/ConductionNL/portaliq/releases/download/v$PQ1/portaliq-$PQ1.tar.gz"
expect_file_has "$t/root/data/conduction-apps.log" "portaliq v$PQ1: sha256 verified"
expect_file_has "$t/stub/calls" "occ app:install dossiq"
expect_eq "$(cat "$t/stub/enabled/portaliq")" "$PQ1" "enabled versie portaliq"
expect_state "$t" "APPS=openregister portaliq dossiq;OPENCATALOGI_VERSION=;OPENCONNECTOR_VERSION=;OPENREGISTER_VERSION=$OR1;PINS=portaliq=$PQ1"
expect_eq "$(wc -c < "$t/stderr" | tr -d ' ')" "0" "stderr"
expect_no_leftovers "$t"
# Elke download (tarball en .sha256) alleen over https en met tijdsgrenzen.
expect_eq "$(wc -l < "$t/stub/curl-args" | tr -d ' ')" "4" "curl-aanroepen"
expect_eq "$(grep -c -- '--proto =https --proto-redir =https --connect-timeout [0-9]* --max-time [0-9]* ' "$t/stub/curl-args")" "4" \
    "curl-aanroepen met --proto/--proto-redir =https, --connect-timeout en --max-time"
end "$t"

begin "nieuw: een gewijzigde pin herinstalleert die app"
make_release "$t" portaliq "$PQ2" good
: > "$t/stub/curl-calls"
run_hook "$t" "$NEW_HOOK" "$DEMO_APPS" "OPENREGISTER_VERSION=$OR1" \
    "CONDUCTION_APP_VERSIONS=openregister=$OR1 portaliq=$PQ2"
expect_app "$t" custom_apps portaliq "$PQ2"
expect_file_has "$t/stub/curl-calls" "portaliq-$PQ2.tar.gz"
expect_state "$t" "APPS=openregister portaliq dossiq;OPENCATALOGI_VERSION=;OPENCONNECTOR_VERSION=;OPENREGISTER_VERSION=$OR1;PINS=portaliq=$PQ2"
# portaliq stond al aan: app:enable doet dan niets, alleen `occ upgrade` zet de
# opgeslagen versie op de nieuwe code.
expect_file_has "$t/stub/calls" "occ upgrade"
expect_eq "$(cat "$t/stub/enabled/portaliq")" "$PQ2" "opgeslagen versie portaliq"
expect_eq "$(occ_status "$t")" "  - needsDbUpgrade: false" "occ status na de bump"
expect_eq "$(wc -c < "$t/stderr" | tr -d ' ')" "0" "stderr"
end "$t"

begin "nieuw: dezelfde pins nog eens is een no-op"
: > "$t/stub/calls"; : > "$t/stub/curl-calls"
run_hook "$t" "$NEW_HOOK" "$DEMO_APPS" "OPENREGISTER_VERSION=$OR1" \
    "CONDUCTION_APP_VERSIONS=portaliq=$PQ2 openregister=$OR1"
expect_eq "$(wc -l < "$t/stub/calls" | tr -d ' ')" "0" "occ-aanroepen"
expect_eq "$(wc -l < "$t/stub/curl-calls" | tr -d ' ')" "0" "downloads (volgorde van pins maakt niet uit)"
end "$t"

# Een mislukte pin: luid, niets half, geen state, volgende start probeert opnieuw.
fail_case() { # <naam> <setup> <verwachte-logtekst> [env...]
    local name="$1" setup="$2" needle="$3"
    shift 3
    begin "nieuw: $name"
    local t
    t="$(new_tenant "f-$RANDOM")"
    make_app_dir "$t/root/custom_apps/portaliq" portaliq 0.2.1
    echo "0.2.1" > "$t/stub/enabled/portaliq"
    "$setup" "$t"
    run_hook "$t" "$NEW_HOOK" "CONDUCTION_APPS=portaliq" "$@"
    expect_eq "$(cat "$t/rc")" "0" "exitcode (pod moet blijven starten)"
    expect_file_has "$t/root/data/conduction-apps.log" "ERROR: "
    expect_file_has "$t/root/data/conduction-apps.log" "$needle"
    expect_file_has "$t/root/data/conduction-apps.log" "INCOMPLETE"
    expect_file_has "$t/stderr" "conduction-apps ERROR"
    expect_app "$t" custom_apps portaliq 0.2.1
    expect_file_lacks "$t/stub/calls" "app:enable portaliq"
    expect_state "$t" "(geen)"
    expect_no_leftovers "$t"
    end "$t"
}
f_missing() { :; }
f_badsha() { make_release "$1" portaliq "$PQ1" bad; }
f_wrongfolder() { make_release "$1" portaliq "$PQ1" good integriq integriq; }
f_wrongid() { make_release "$1" portaliq "$PQ1" good portaliq notportaliq; }
f_abs() {
    make_release "$1" portaliq "$PQ1" none
    local asset="$1/stub/release/ConductionNL/portaliq/releases/download/v$PQ1/portaliq-$PQ1.tar.gz"
    mkdir -p "$1/evil"; echo x > "$1/evil/x"
    tar -czPf "$asset" "$1/evil/x"
}
f_garbage() {
    make_release "$1" portaliq "$PQ1" none
    echo "not a tarball" > "$1/stub/release/ConductionNL/portaliq/releases/download/v$PQ1/portaliq-$PQ1.tar.gz"
}
f_wrongver() { make_release "$1" portaliq "$PQ1" good portaliq portaliq 9.9.9; }
# Een verder geldige release met één link-entry erbij (python3 tarfile, zodat
# het doel letterlijk in de tarball staat). <soort>: abs | dotdot | hard
add_link_entry() {
    local asset="$1/stub/release/ConductionNL/portaliq/releases/download/v$PQ1/portaliq-$PQ1.tar.gz"
    python3 -I - "$asset" "$2" <<'PY_EOF'
import io, sys, tarfile
asset, kind = sys.argv[1], sys.argv[2]
with tarfile.open(asset) as src:
    members = [(m, src.extractfile(m).read() if m.isfile() else None) for m in src.getmembers()]
link = tarfile.TarInfo("portaliq/cfg.css")
if kind == "abs":
    link.type, link.linkname = tarfile.SYMTYPE, "/var/www/html/config/config.php"
elif kind == "dotdot":
    link.type, link.linkname = tarfile.SYMTYPE, "../../outside_rel"
else:
    link.type, link.linkname = tarfile.LNKTYPE, "portaliq/appinfo/info.xml"
with tarfile.open(asset, "w:gz") as dst:
    for m, data in members:
        dst.addfile(m, None if data is None else io.BytesIO(data))
    dst.addfile(link)
PY_EOF
}
f_symlink_abs() { make_release "$1" portaliq "$PQ1" none; add_link_entry "$1" abs; }
f_symlink_dotdot() { make_release "$1" portaliq "$PQ1" none; add_link_entry "$1" dotdot; }
f_hardlink() { make_release "$1" portaliq "$PQ1" none; add_link_entry "$1" hard; }

fail_case "release bestaat niet (404)" f_missing "GitHub download failed" "CONDUCTION_APP_VERSIONS=portaliq=$PQ1"
fail_case "checksum klopt niet" f_badsha "sha256 mismatch" "CONDUCTION_APP_VERSIONS=portaliq=$PQ1"
fail_case "tarball heeft een andere topmap" f_wrongfolder "top folder of portaliq-$PQ1.tar.gz is 'integriq'" "CONDUCTION_APP_VERSIONS=portaliq=$PQ1"
fail_case "info.xml noemt een ander app-id" f_wrongid "has id 'notportaliq'" "CONDUCTION_APP_VERSIONS=portaliq=$PQ1"
fail_case "tarball met absoluut pad" f_abs "absolute or '..' paths" "CONDUCTION_APP_VERSIONS=portaliq=$PQ1"
fail_case "tarball met symlink naar een absoluut pad" f_symlink_abs "contains link entries" "CONDUCTION_APP_VERSIONS=portaliq=$PQ1"
fail_case "tarball met symlink naar '..'" f_symlink_dotdot "contains link entries" "CONDUCTION_APP_VERSIONS=portaliq=$PQ1"
fail_case "tarball met hardlink" f_hardlink "contains link entries" "CONDUCTION_APP_VERSIONS=portaliq=$PQ1"
fail_case "download is geen tar.gz" f_garbage "is not a readable tar.gz" "CONDUCTION_APP_VERSIONS=portaliq=$PQ1"
fail_case "ongeldige pin-tekst, app blijft staan (geen appstore-fallback)" f_missing "invalid pin 'portaliq=v0.2.10'" \
    "CONDUCTION_APP_VERSIONS=portaliq=v0.2.10"

begin "nieuw: pin zonder app-id faalt luid zonder de hook te breken"
t="$(new_tenant noid)"
echo "1.0.0" > "$t/stub/enabled/opencatalogi"
run_hook "$t" "$NEW_HOOK" "CONDUCTION_APPS=opencatalogi" "CONDUCTION_APP_VERSIONS==0.2.10"
expect_eq "$(cat "$t/rc")" "0" "exitcode"
expect_file_has "$t/root/data/conduction-apps.log" "invalid pin '=0.2.10'"
expect_file_has "$t/stderr" "conduction-apps ERROR"
expect_state "$t" "(geen)"
end "$t"

# Een andere versie in info.xml dan de pin faalt vóór er iets vervangen wordt.
fail_case "info.xml noemt een andere versie dan de pin" f_wrongver "info.xml says version '9.9.9'" \
    "CONDUCTION_APP_VERSIONS=portaliq=$PQ1"
# De nieuwe code naar custom_apps zetten faalt: de vorige versie staat terug.
f_good() { make_release "$1" portaliq "$PQ1" good; }
fail_case "verplaatsen naar custom_apps faalt, vorige versie blijft" f_good "moving into custom_apps failed" \
    "CONDUCTION_APP_VERSIONS=portaliq=$PQ1" "STUB_MV_FAIL=1"

begin "nieuw: enable faalt, de vorige (uitgeschakelde) versie staat terug"
t="$(new_tenant enablefail)"
make_app_dir "$t/root/custom_apps/portaliq" portaliq 0.2.1
make_release "$t" portaliq "$PQ1" good
run_hook "$t" "$NEW_HOOK" "CONDUCTION_APPS=portaliq" "CONDUCTION_APP_VERSIONS=portaliq=$PQ1" "STUB_ENABLE_FAIL=portaliq"
expect_eq "$(cat "$t/rc")" "0" "exitcode"
expect_file_has "$t/root/data/conduction-apps.log" "occ app:enable portaliq failed"
expect_file_has "$t/root/data/conduction-apps.log" "previous version restored"
expect_file_has "$t/stderr" "conduction-apps ERROR"
expect_app "$t" custom_apps portaliq 0.2.1
expect_state "$t" "(geen)"
expect_no_leftovers "$t"
end "$t"

begin "nieuw: versiecheck na occ upgrade faalt, vorige versie en gebundelde app staan terug"
t="$(new_tenant upgradefail)"
make_app_dir "$t/root/custom_apps/portaliq" portaliq 0.2.1
echo "0.2.1" > "$t/stub/enabled/portaliq"
make_app_dir "$t/root/apps/openconnector" openconnector 0.2.24
echo "0.2.24" > "$t/stub/enabled/openconnector"
make_release "$t" portaliq "$PQ1" good
make_release "$t" openconnector 0.2.25 good
run_hook "$t" "$NEW_HOOK" "CONDUCTION_APPS=portaliq openconnector" "OPENCONNECTOR_VERSION=0.2.25" \
    "CONDUCTION_APP_VERSIONS=portaliq=$PQ1" "STUB_UPGRADE_NOOP=1"
expect_eq "$(cat "$t/rc")" "0" "exitcode"
expect_file_has "$t/root/data/conduction-apps.log" "occ upgrade failed"
expect_file_has "$t/root/data/conduction-apps.log" "Nextcloud reports '0.2.1' after occ upgrade"
expect_file_has "$t/root/data/conduction-apps.log" "Nextcloud reports '0.2.24' after occ upgrade"
expect_app "$t" custom_apps portaliq 0.2.1
expect_app "$t" apps openconnector 0.2.24
expect_app "$t" custom_apps openconnector absent
expect_eq "$(occ_status "$t")" "  - needsDbUpgrade: false" "occ status na het terugzetten"
expect_state "$t" "(geen)"
expect_no_leftovers "$t"
end "$t"

begin "nieuw: openconnector gepind op een integriq-build faalt luid en laat de gebundelde app staan"
t="$(new_tenant oc-integriq)"
# integriq-tijdperk: de repo heet integriq, het asset ook. Onder de naam
# openconnector bestaat die tarball niet, dus 404.
make_release "$t" integriq 0.4.12-unstable.20261012180338 good
make_app_dir "$t/root/apps/openconnector" openconnector 0.2.24
echo "0.2.24" > "$t/stub/enabled/openconnector"
run_hook "$t" "$NEW_HOOK" "CONDUCTION_APPS=openconnector" "OPENCONNECTOR_VERSION=0.4.12-unstable.20261012180338"
expect_file_has "$t/root/data/conduction-apps.log" "GitHub download failed"
expect_app "$t" apps openconnector 0.2.24
expect_state "$t" "(geen)"
end "$t"

begin "nieuw: integriq zelf pinnen werkt"
run_hook "$t" "$NEW_HOOK" "CONDUCTION_APPS=integriq" "CONDUCTION_APP_VERSIONS=integriq=0.4.12-unstable.20261012180338"
expect_app "$t" custom_apps integriq 0.4.12-unstable.20261012180338
expect_state "$t" "APPS=integriq;OPENCATALOGI_VERSION=;OPENCONNECTOR_VERSION=;OPENREGISTER_VERSION=;PINS=integriq=0.4.12-unstable.20261012180338"
end "$t"

begin "nieuw: na een mislukte run slaagt de volgende start als de release er is"
t="$(new_tenant retry)"
# Achtergebleven staging van een eerdere, afgebroken run (andere PID).
mkdir -p "$t/root/custom_apps/.conduction-staging-portaliq.1/portaliq"
run_hook "$t" "$NEW_HOOK" "CONDUCTION_APPS=portaliq" "CONDUCTION_APP_VERSIONS=portaliq=$PQ1"
expect_state "$t" "(geen)"
make_release "$t" portaliq "$PQ1" good
run_hook "$t" "$NEW_HOOK" "CONDUCTION_APPS=portaliq" "CONDUCTION_APP_VERSIONS=portaliq=$PQ1"
expect_app "$t" custom_apps portaliq "$PQ1"
expect_state "$t" "APPS=portaliq;OPENCATALOGI_VERSION=;OPENCONNECTOR_VERSION=;OPENREGISTER_VERSION=;PINS=portaliq=$PQ1"
expect_no_leftovers "$t"
end "$t"

begin "nieuw: een afgebroken swap wordt hersteld, ook als de download daarna faalt"
t="$(new_tenant interrupted)"
# Een eerdere run (andere PID) zette portaliq opzij en werd toen gestopt.
make_app_dir "$t/root/custom_apps/.conduction-previous-portaliq.1" portaliq 0.2.1
echo "0.2.1" > "$t/stub/enabled/portaliq"
run_hook "$t" "$NEW_HOOK" "CONDUCTION_APPS=portaliq" "CONDUCTION_APP_VERSIONS=portaliq=$PQ1"
expect_file_has "$t/root/data/conduction-apps.log" "left aside by an interrupted run"
expect_app "$t" custom_apps portaliq 0.2.1
expect_no_leftovers "$t"
end "$t"

begin "nieuw: pin voor een app die niet in CONDUCTION_APPS staat wordt niet geïnstalleerd"
t="$(new_tenant notenabled)"
make_release "$t" portaliq "$PQ1" good
echo "1.0.0" > "$t/stub/enabled/opencatalogi"
run_hook "$t" "$NEW_HOOK" "CONDUCTION_APPS=opencatalogi" "CONDUCTION_APP_VERSIONS=portaliq=$PQ1"
expect_file_has "$t/root/data/conduction-apps.log" "portaliq is pinned but not in CONDUCTION_APPS"
expect_eq "$(wc -l < "$t/stub/curl-calls" | tr -d ' ')" "0" "downloads"
expect_app "$t" custom_apps portaliq absent
end "$t"

begin "nieuw: legacy env var wint van de generieke lijst"
t="$(new_tenant precedence)"
make_release "$t" openregister 1.1.5 good
run_hook "$t" "$NEW_HOOK" "CONDUCTION_APPS=openregister" "OPENREGISTER_VERSION=1.1.5" \
    "CONDUCTION_APP_VERSIONS=openregister=$OR1"
expect_app "$t" custom_apps openregister 1.1.5
expect_file_has "$t/root/data/conduction-apps.log" "openregister pinned twice"
end "$t"

begin "nieuw: before-starting en post-installation zijn dezelfde tekst"
if ! cmp -s "$NEW_HOOK" "$POST_INSTALL_HOOK"; then nok "de twee hooks verschillen"; fi
[ "$(wc -l < "$NEW_HOOK")" -gt 100 ] || nok "hooktekst leeg of afgekapt"
end

echo
echo "hook-tests: ${PASSED} geslaagd, ${FAILED} gefaald"
[ "$FAILED" -eq 0 ]
