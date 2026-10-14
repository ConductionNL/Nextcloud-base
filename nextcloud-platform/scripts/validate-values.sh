#!/usr/bin/env bash
#
# validate-values.sh - Validate tenant YAML files
#
# This script validates:
# 1. YAML syntax
# 2. Required fields are present
# 3. No disallowed fields are present
# 4. Field values match expected patterns
#
# Usage:
#   ./scripts/validate-values.sh [tenant-file.yaml ...]
#   ./scripts/validate-values.sh  # validates all tenants
#   ./scripts/validate-values.sh --dump-host-claims  # host-register (zie build_host_claims)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# VALIDATE_TENANT_DIR: alleen voor tests/run-tests.sh (fixtures met een eigen vloot)
TENANT_DIR="${VALIDATE_TENANT_DIR:-${REPO_ROOT}/values/tenants}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Counters
ERRORS=0
WARNINGS=0

# NB: tel op met $((...)) en niet met ((...)). Een post-increment vanaf 0 levert
# de waarde 0 op, dus exitstatus 1 — en met `set -euo pipefail` breekt een kale
# aanroep van deze functie dan de hele run af.
log_error() {
    echo -e "${RED}ERROR:${NC} $1" >&2
    ERRORS=$((ERRORS + 1))
}

log_warning() {
    echo -e "${YELLOW}WARNING:${NC} $1" >&2
    WARNINGS=$((WARNINGS + 1))
}

log_success() {
    echo -e "${GREEN}OK:${NC} $1"
}

# Check if required tools are installed
check_dependencies() {
    local missing=()
    
    if ! command -v yq &> /dev/null; then
        missing+=("yq")
    fi
    
    if ! command -v yamllint &> /dev/null; then
        missing+=("yamllint")
    fi
    
    if [ ${#missing[@]} -gt 0 ]; then
        echo "Missing required tools: ${missing[*]}"
        echo "Install with:"
        echo "  pip install yamllint"
        echo "  # For yq: https://github.com/mikefarah/yq#install"
        exit 1
    fi
}

# Validate YAML syntax
validate_yaml_syntax() {
    local file="$1"
    
    if ! yamllint -d "{extends: relaxed, rules: {line-length: {max: 200}}}" "$file" 2>/dev/null; then
        log_error "$file: YAML syntax error"
        return 1
    fi
    
    return 0
}

# Required fields for tenant files
REQUIRED_FIELDS=(
    ".tenant.name"
    ".tenant.environment"
    ".tenant.dbType"
    ".tenant.apps.enabled"
)

# Validate required fields
validate_required_fields() {
    local file="$1"
    local has_error=0
    
    for field in "${REQUIRED_FIELDS[@]}"; do
        local value
        value=$(yq eval "$field" "$file" 2>/dev/null)
        
        if [ "$value" = "null" ] || [ -z "$value" ]; then
            log_error "$file: Missing required field: $field"
            has_error=1
        fi
    done
    
    return $has_error
}

# Disallowed fields (these should not be in tenant files)
DISALLOWED_FIELDS=(
    ".secrets"
    ".adminPassword"
    ".s3AccessKey"
    ".s3SecretKey"
    ".dbPassword"
)

# Validate no disallowed fields
validate_no_disallowed_fields() {
    local file="$1"
    local has_error=0
    
    for field in "${DISALLOWED_FIELDS[@]}"; do
        local value
        value=$(yq eval "$field" "$file" 2>/dev/null)
        
        if [ "$value" != "null" ] && [ -n "$value" ]; then
            log_error "$file: Disallowed field found (potential secret): $field"
            has_error=1
        fi
    done
    
    return $has_error
}

# Validate tenant name format
validate_tenant_name() {
    local file="$1"
    local name
    name=$(yq eval '.tenant.name' "$file" 2>/dev/null)
    
    # Tenant name should be lowercase alphanumeric with hyphens
    if ! [[ "$name" =~ ^[a-z][a-z0-9-]*[a-z0-9]$ ]] && ! [[ "$name" =~ ^[a-z]$ ]]; then
        log_error "$file: Invalid tenant name '$name'. Must be lowercase alphanumeric with hyphens, start with letter."
        return 1
    fi
    
    # Check length (Kubernetes namespace limit)
    if [ ${#name} -gt 63 ]; then
        log_error "$file: Tenant name '$name' too long (max 63 chars)"
        return 1
    fi
    
    return 0
}

# Validate tenant naming convention: <org>-<env>
# env suffix must be one of: accept, test, demo, prod
# Note: 'demo' tenants use accept env values (same as 'test') — the suffix communicates
# intent (long-lived demo / sandbox), while runtime config is identical to accept.
validate_tenant_name_convention() {
    local file="$1"
    local name env suffix org
    name=$(yq eval '.tenant.name' "$file" 2>/dev/null)
    env=$(yq eval '.tenant.environment' "$file" 2>/dev/null)

    if ! [[ "$name" =~ ^(.+)-(accept|test|demo|prod)$ ]]; then
        log_error "$file: tenant.name '$name' must follow convention '<org>-<accept|test|demo|prod>' (e.g. 'alkmaar-accept')"
        return 1
    fi

    org="${BASH_REMATCH[1]}"
    suffix="${BASH_REMATCH[2]}"

    case "$suffix" in
        prod)
            if [ "$env" != "prod" ]; then
                log_error "$file: tenant.environment must be 'prod' when tenant.name ends with '-prod' (got '$env')"
                return 1
            fi
            ;;
        accept|test|demo)
            if [ "$env" != "accept" ]; then
                log_error "$file: tenant.environment must be 'accept' when tenant.name ends with '-$suffix' (got '$env')"
                return 1
            fi
            ;;
    esac

    # org must still be a valid k8s-style name segment
    if ! [[ "$org" =~ ^[a-z][a-z0-9-]*[a-z0-9]$ ]] && ! [[ "$org" =~ ^[a-z]$ ]]; then
        log_error "$file: organization part '$org' (from tenant.name '$name') is invalid"
        return 1
    fi

    return 0
}

# Validate namespace convention: tenant.namespace (if set) must equal tenant.name
validate_namespace_convention() {
    local file="$1"
    local name namespace
    name=$(yq eval '.tenant.name' "$file" 2>/dev/null)
    namespace=$(yq eval '.tenant.namespace' "$file" 2>/dev/null)

    if [ "$namespace" = "null" ] || [ -z "$namespace" ]; then
        # optional; defaulted by ArgoCD ApplicationSet to tenant.name
        return 0
    fi

    if [ "$namespace" != "$name" ]; then
        log_error "$file: tenant.namespace '$namespace' must equal tenant.name '$name' (namespace per env)"
        return 1
    fi

    return 0
}

# Validate environment
validate_environment() {
    local file="$1"
    local env
    env=$(yq eval '.tenant.environment' "$file" 2>/dev/null)
    
    case "$env" in
        accept|prod)
            return 0
            ;;
        *)
            log_error "$file: Invalid environment '$env'. Must be 'accept' or 'prod'."
            return 1
            ;;
    esac
}

# Validate database profile (optional)
validate_db_type() {
    local file="$1"
    local db
    db=$(yq eval '.tenant.dbType' "$file" 2>/dev/null)

    if [ "$db" = "null" ] || [ -z "$db" ]; then
        return 0
    fi

    case "$db" in
        mariadb|postgres|external)
            return 0
            ;;
        *)
            log_error "$file: Invalid tenant.dbType '$db'. Must be 'mariadb', 'postgres' or 'external'."
            return 1
            ;;
    esac
}

# Validate tenant apps model
validate_apps_enabled() {
    local file="$1"
    local count
    count=$(yq eval '.tenant.apps.enabled | length' "$file" 2>/dev/null)

    if [ "$count" = "null" ] || [ -z "$count" ]; then
        log_error "$file: tenant.apps.enabled must be a non-empty list"
        return 1
    fi

    if ! [[ "$count" =~ ^[0-9]+$ ]] || [ "$count" -lt 1 ]; then
        log_error "$file: tenant.apps.enabled must be a non-empty list"
        return 1
    fi

    return 0
}

validate_app_versions_format() {
    local file="$1"
    local keys key ver

    keys=$(yq eval -o=json '.tenant.apps.versions | keys // []' "$file" 2>/dev/null || echo "[]")
    # keys is JSON array of strings; extract with yq again for portability
    local key_count
    key_count=$(echo "$keys" | yq eval 'length' - 2>/dev/null || echo "0")

    if ! [[ "$key_count" =~ ^[0-9]+$ ]] || [ "$key_count" -eq 0 ]; then
        return 0
    fi

    # Version format: without leading 'v', e.g. 0.7.7 or 0.2.10-beta.20260410072957
    local ver_re='^[0-9]+[.][0-9]+[.][0-9]+([-.][0-9A-Za-z][0-9A-Za-z.-]*)?$'

    for i in $(seq 0 $((key_count-1))); do
        key=$(echo "$keys" | yq eval ".[$i]" - 2>/dev/null)
        ver=$(yq eval ".tenant.apps.versions.\"$key\"" "$file" 2>/dev/null)

        if [ "$ver" = "null" ] || [ -z "$ver" ]; then
            continue
        fi

        if [[ "$ver" =~ ^v ]]; then
            log_error "$file: tenant.apps.versions.$key must NOT start with 'v' (got '$ver')"
            return 1
        fi

        if ! [[ "$ver" =~ $ver_re ]]; then
            log_error "$file: tenant.apps.versions.$key has invalid version '$ver' (expected e.g. '0.7.7' or '0.2.10-unstable.4')"
            return 1
        fi
    done

    return 0
}

# Every key in tenant.apps.versions is an app id that the install hook pins
# (argo/applicationsets/nextcloud-tenants.yaml -> CONDUCTION_APP_VERSIONS).
# A pin for an app that is not enabled would never be installed, so it is an
# error instead of a silent no-op. The key also ends up in a download URL and
# a shell word, so it must look like a Nextcloud app id.
validate_app_versions_enabled() {
    local file="$1"
    local key key_count enabled errors=0
    local id_re='^[a-z][a-z0-9_]*$'

    key_count=$(yq eval '.tenant.apps.versions | select(tag == "!!map") | keys | length' "$file" 2>/dev/null)
    if ! [[ "$key_count" =~ ^[0-9]+$ ]] || [ "$key_count" -eq 0 ]; then
        return 0
    fi

    enabled=" $(yq eval '.tenant.apps.enabled // [] | .[]' "$file" 2>/dev/null | tr '\n' ' ') "

    while IFS= read -r key; do
        [ -z "$key" ] && continue
        if ! [[ "$key" =~ $id_re ]]; then
            log_error "$file: tenant.apps.versions.$key is not a valid app id (expected lowercase, e.g. 'portaliq')"
            errors=1
            continue
        fi
        if [[ "$enabled" != *" $key "* ]]; then
            log_error "$file: tenant.apps.versions.$key pins an app that is not in tenant.apps.enabled"
            errors=1
        fi
    done < <(yq eval '.tenant.apps.versions | keys | .[]' "$file" 2>/dev/null)

    return $errors
}

validate_chart_version_format() {
    local file="$1"
    local ver
    ver=$(yq eval '.tenant.chartVersion' "$file" 2>/dev/null)

    if [ "$ver" = "null" ] || [ -z "$ver" ]; then
        return 0
    fi

    if [[ "$ver" =~ ^v ]]; then
        log_error "$file: tenant.chartVersion must NOT start with 'v' (got '$ver')"
        return 1
    fi

    if ! [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log_error "$file: tenant.chartVersion '$ver' is invalid (expected e.g. '8.9.0')"
        return 1
    fi

    return 0
}

# Hostnaam zoals Kubernetes hem in een Ingress-rule accepteert (RFC 1123):
# labels van kleine letters, cijfers en koppeltekens, minstens één punt, elk
# label max 63 tekens en het geheel max 253, en het laatste label niet alleen
# cijfers (dan is het een IP-adres, dat Kubernetes niet als Ingress-host neemt).
# Anders weigert de API-server de Ingress en faalt de sync van de Application.
#
# Usage: is_valid_hostname <host>
is_valid_hostname() {
    local host="$1" label
    [[ "$host" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?(\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)+$ ]] || return 1
    [ ${#host} -le 253 ] || return 1
    [[ "${host##*.}" =~ ^[0-9]+$ ]] && return 1
    local IFS=.
    for label in $host; do
        [ ${#label} -le 63 ] || return 1
    done
    return 0
}

# Validate hostname format
validate_hostname() {
    local file="$1"
    local hostname
    hostname=$(yq eval '.tenant.hostname' "$file" 2>/dev/null)

    # Optional: if not set, hostname will be derived by ArgoCD ApplicationSet
    if [ "$hostname" = "null" ] || [ -z "$hostname" ]; then
        return 0
    fi
    
    # Basic hostname validation (RFC 1123)
    if ! is_valid_hostname "$hostname"; then
        log_error "$file: Invalid hostname '$hostname'. Must be a valid DNS name (at least one dot, labels max 63, total max 253, not an IP address)."
        return 1
    fi
    
    return 0
}

# Validate hostname matches commonground.nu convention derived from tenant.name
validate_hostname_convention() {
    local file="$1"
    local name hostname override org suffix expected
    name=$(yq eval '.tenant.name' "$file" 2>/dev/null)
    hostname=$(yq eval '.tenant.hostname' "$file" 2>/dev/null)
    override=$(yq eval '.tenant.hostnameOverride' "$file" 2>/dev/null)

    # Optional: if not set, hostname is derived from tenant.name by convention
    if [ "$hostname" = "null" ] || [ -z "$hostname" ]; then
        return 0
    fi

    # Explicit opt-out: tenant deliberately uses a non-canonical hostname (e.g. external domain)
    if [ "$override" = "true" ]; then
        log_warning "$file: tenant.hostname '$hostname' bypasses commonground.nu convention (tenant.hostnameOverride: true)"
        return 0
    fi

    if ! [[ "$name" =~ ^(.+)-(accept|test|demo|prod)$ ]]; then
        # validate_tenant_name_convention will report this
        return 0
    fi

    org="${BASH_REMATCH[1]}"
    suffix="${BASH_REMATCH[2]}"

    case "$suffix" in
        prod)
            expected="${org}.commonground.nu"
            migrate="${org}.migrate.commonground.nu"
            if [ "$hostname" = "$expected" ]; then
                return 0
            elif [ "$hostname" = "$migrate" ]; then
                log_warning "$file: tenant.hostname '$hostname' is a temporary migration domain — remember to cut over to '$expected'"
                return 0
            else
                log_error "$file: tenant.hostname '$hostname' does not match expected '$expected' or migration domain '$migrate' (derived from tenant.name '$name')"
                return 1
            fi
            ;;
        accept|test|demo)
            expected="${org}.${suffix}.commonground.nu"
            ;;
    esac

    if [ "$hostname" != "$expected" ]; then
        log_error "$file: tenant.hostname '$hostname' does not match expected '$expected' (derived from tenant.name '$name')"
        return 1
    fi

    return 0
}

# Primaire host zoals de ApplicationSet (argo/applicationsets/nextcloud-tenants.yaml)
# hem bepaalt: tenant.hostname, en anders afgeleid uit tenant.name. Houd dit
# gelijk met dat template. Let op: het template kent 'demo' niet als suffix,
# zo'n tenant valt terug op tenant.environment (bv. x-demo.accept.commonground.nu).
#
# Usage: primary_host <name> <environment> <hostname>
primary_host() {
    local name="$1" env="$2" hostname="$3" suffix="" org="$1" omgeving

    if [ -n "$hostname" ] && [ "$hostname" != "null" ]; then
        echo "$hostname"
        return 0
    fi

    if [[ "$name" =~ (accept|test|prod)$ ]]; then
        suffix="${BASH_REMATCH[1]}"
    fi
    if [[ "$name" =~ ^(.*)-(accept|test|prod)$ ]]; then
        org="${BASH_REMATCH[1]}"
    fi
    omgeving="${suffix:-$env}"

    if [ "$omgeving" = "prod" ]; then
        echo "${org}.commonground.nu"
    else
        echo "${org}.${omgeving}.commonground.nu"
    fi
}

# ingress.enabled zoals de render hem ziet: dezelfde valueFiles-volgorde als de
# ApplicationSet (common, env, db, canary-overrides, tenantbestand), de laatste
# die hem zet wint. De inline values van de ApplicationSet zetten hem niet.
#
# Usage: effective_ingress_enabled <file>
effective_ingress_enabled() {
    local file="$1" values="${REPO_ROOT}/values" env db canary value f result="false"
    env=$(yq eval '.tenant.environment // ""' "$file" 2>/dev/null)
    db=$(yq eval '.tenant.dbType // "postgres"' "$file" 2>/dev/null)
    canary=$(yq eval '.tenant.canary // ""' "$file" 2>/dev/null)
    local layers=("${values}/common.yaml" "${values}/env/${env}.yaml" "${values}/db/${db}.yaml")
    [ "$canary" = "true" ] && layers+=("${values}/canary-overrides.yaml")
    layers+=("$file")
    for f in "${layers[@]}"; do
        [ -f "$f" ] || continue
        value=$(yq eval '.ingress.enabled' "$f" 2>/dev/null)
        [ "$value" != "null" ] && [ -n "$value" ] && result="$value"
    done
    echo "$result"
}

# Validate tenant.extraHostnames (optioneel)
#
# Extra hostnamen op dezelfde Nextcloud. De ApplicationSet zet ze in
# trustedDomains en rendert er een tweede Ingress voor, met één TLS-secret
# "nextcloud-<tenant>-<host met streepjes>-tls" per host. Gecontroleerd:
# lijstvorm, geldige DNS-naam (geen IP-adres), geen dubbele, niet gelijk aan de
# primaire host, onder commonground.nu alleen hosts van de eigen tenant, een
# unieke secretnaam die Kubernetes accepteert (DNS-subdomein, max 253),
# ingress.enabled: true, en een apex-host (twee labels, zoals gemeente.nl)
# alleen met tenant.extraHostnamesAllowApex: true. Botsingen met hosts van andere tenants vangt
# validate_host_claims; een dubbele tenant.name vangt dump_host_claims.
validate_extra_hostnames() {
    local file="$1"
    local kind name hostname primary primary_bron
    kind=$(yq eval '.tenant.extraHostnames | type' "$file" 2>/dev/null)

    if [ "$kind" = "!!null" ] || [ -z "$kind" ]; then
        return 0
    fi

    if [ "$kind" != "!!seq" ]; then
        log_error "$file: tenant.extraHostnames moet een lijst zijn (got $kind)"
        return 1
    fi

    name=$(yq eval '.tenant.name' "$file" 2>/dev/null)
    hostname=$(yq eval '.tenant.hostname // ""' "$file" 2>/dev/null)
    primary=$(primary_host "$name" "$(yq eval '.tenant.environment' "$file" 2>/dev/null)" "$hostname")
    if [ -n "$hostname" ]; then
        primary_bron="die staat al in tenant.hostname"
    else
        primary_bron="afgeleid uit tenant.name, zoals de ApplicationSet doet"
    fi

    # Opt-in voor apex-hosts. HSTS met includeSubDomains op een apex dwingt
    # HTTPS af op elk subdomein van de klant, ook interne en http-only, en dat
    # is niet terug te draaien. Alleen met een expliciete true, en alleen als de
    # zone-eigenaar dat accepteert (docs/ADDING-TENANT.md).
    local allow_apex allow_apex_kind
    allow_apex_kind=$(yq eval '.tenant.extraHostnamesAllowApex | type' "$file" 2>/dev/null)
    allow_apex=$(yq eval '.tenant.extraHostnamesAllowApex' "$file" 2>/dev/null)
    local has_error=0
    if [ "$allow_apex_kind" != "!!null" ] && [ "$allow_apex_kind" != "!!bool" ]; then
        log_error "$file: tenant.extraHostnamesAllowApex moet true of false zijn (got $allow_apex_kind)"
        has_error=1
    fi

    local host seen=" " secret seen_secrets=" "
    while IFS= read -r host; do
        if ! is_valid_hostname "$host"; then
            log_error "$file: tenant.extraHostnames bevat ongeldige hostnaam '$host' (kleine letters, minstens één punt, labels max 63, totaal max 253, geen IP-adres)"
            has_error=1
            continue
        fi
        if [[ "$host" != *.*.* ]] && [ "$allow_apex" != "true" ]; then
            log_error "$file: tenant.extraHostnames bevat apex-host '$host'. Die krijgt HSTS met includeSubDomains, dus HTTPS-dwang op elk subdomein van de zone. Zet tenant.extraHostnamesAllowApex: true alleen als de zone-eigenaar dat accepteert (zie docs/ADDING-TENANT.md)"
            has_error=1
        fi
        if [ "$host" = "$primary" ]; then
            log_error "$file: tenant.extraHostnames bevat de primaire host '$host' ($primary_bron)"
            has_error=1
        fi
        # commonground.nu is van het platform: een extra host daaronder moet
        # volgens de naamconventie bij deze tenant horen.
        if [ "$host" != "$primary" ] && [[ "$host" == commonground.nu || "$host" == *.commonground.nu ]] \
            && ! convention_hosts "$name" | grep -qxF -- "$host"; then
            log_error "$file: tenant.extraHostnames bevat '$host' onder commonground.nu, maar die hoort niet bij tenant '$name' (toegestaan: $(convention_hosts "$name" | paste -sd ' '))"
            has_error=1
        fi
        if [[ "$seen" == *" $host "* ]]; then
            log_error "$file: tenant.extraHostnames bevat '$host' dubbel"
            has_error=1
            # De eerste keer zijn de overige checks voor deze host al gedaan
            continue
        fi
        seen="${seen}${host} "
        secret="nextcloud-${name}-${host//./-}-tls"
        if [ ${#secret} -gt 253 ]; then
            log_error "$file: TLS-secretnaam '$secret' voor '$host' is langer dan 253 tekens"
            has_error=1
        fi
        # Punten worden streepjes, dus a-b.nl en a.b.nl krijgen hetzelfde
        # secret: één Certificate dat maar één van beide hosts dekt.
        if [[ "$seen_secrets" == *" $secret "* ]]; then
            log_error "$file: TLS-secretnaam '$secret' voor '$host' is gelijk aan die van een andere extra host"
            has_error=1
        fi
        seen_secrets="${seen_secrets}${secret} "
    done < <(yq eval '.tenant.extraHostnames[]' "$file" 2>/dev/null)

    if [ $has_error -eq 0 ]; then
        log_warning "$file: tenant.extraHostnames gezet; DNS en HTTP-01 per host moeten kloppen (zie docs/ADDING-TENANT.md)"
    fi

    # De extra Ingress volgt ingress.enabled, net als die van de chart. Zonder
    # Ingress hebben de extra hosts geen enkele route: charts/tenant-httproute
    # neemt alleen de primaire host.
    if [ "$(effective_ingress_enabled "$file")" != "true" ]; then
        log_error "$file: tenant.extraHostnames vereist ingress.enabled: true. De extra hosts lopen via de nginx-Ingress zolang charts/tenant-httproute maar één host neemt (zie docs/GATEWAY-API.md)"
        has_error=1
    fi

    return $has_error
}

# Hosts onder commonground.nu die volgens de conventie bij deze tenant horen.
# Zelfde regel als validate_hostname_convention: prod krijgt <org>.commonground.nu
# en de migratiehost <org>.migrate.commonground.nu, de rest
# <org>.<suffix>.commonground.nu.
#
# Usage: convention_hosts <name>
convention_hosts() {
    local name="$1" org suffix
    [[ "$name" =~ ^(.+)-(accept|test|demo|prod)$ ]] || return 0
    org="${BASH_REMATCH[1]}"
    suffix="${BASH_REMATCH[2]}"
    if [ "$suffix" = "prod" ]; then
        echo "${org}.commonground.nu"
        echo "${org}.migrate.commonground.nu"
    else
        echo "${org}.${suffix}.commonground.nu"
    fi
}

# Alle hosts die één tenantbestand claimt, als regels "<host><TAB><bron>":
# de primaire host (zoals de ApplicationSet hem bepaalt), tenant.extraHostnames
# en de WOO-frontend (tenant.frontend.host en tenant.frontend.extraHosts, alleen
# als ze expliciet gezet zijn; de afgeleide frontend-host staat in React-base).
#
# Usage: tenant_host_claims <file>
tenant_host_claims() {
    local file="$1" name env hostname
    name=$(yq eval '.tenant.name // ""' "$file" 2>/dev/null) || return 0
    [ -z "$name" ] && return 0
    env=$(yq eval '.tenant.environment // ""' "$file" 2>/dev/null)
    hostname=$(yq eval '.tenant.hostname // ""' "$file" 2>/dev/null)
    printf '%s\tprimaire host\n' "$(primary_host "$name" "$env" "$hostname")"
    local bron host
    while read -r bron host; do
        [ -n "$host" ] && printf '%s\t%s\n' "$host" "$bron"
    done < <(yq eval '.tenant as $t | (
        [$t.extraHostnames // [] | select(tag == "!!seq") | .[] | to_string | "tenant.extraHostnames " + .] +
        [$t.frontend.host // null | select(. != null) | to_string | "tenant.frontend.host " + .] +
        [$t.frontend.extraHosts // [] | select(tag == "!!seq") | .[] | to_string | "tenant.frontend.extraHosts " + .]
    ) | .[]' "$file" 2>/dev/null || true)
}

# Absoluut pad met symlinks opgelost, zonder GNU realpath
abs_path() {
    local dir
    dir=$(cd "$(dirname "$1")" 2>/dev/null && pwd -P) || { echo "$1"; return 0; }
    echo "${dir}/$(basename "$1")"
}

# Host-register van values/tenants/, als regels "<host><TAB><tenant><TAB><bron>".
# Twee bestanden met dezelfde tenant.name zijn een fout: het register (en
# daarmee de botsingscheck) zou er stil één van overslaan.
dump_host_claims() {
    local -A by_name=()
    local file name has_error=0 host bron
    while IFS= read -r -d '' file; do
        name=$(yq eval '.tenant.name // ""' "$file" 2>/dev/null) || continue
        [ -z "$name" ] && continue
        if [ -n "${by_name[$name]:-}" ]; then
            log_error "$file: tenant.name '$name' staat ook in ${by_name[$name]}"
            has_error=$((has_error + 1))
            continue
        fi
        by_name["$name"]="$file"
    done < <(find "$TENANT_DIR" -name "tenant-*.yaml" -print0 2>/dev/null | sort -z)

    for name in "${!by_name[@]}"; do
        while IFS=$'\t' read -r host bron; do
            [ -z "$host" ] && continue
            printf '%s\t%s\t%s\n' "$host" "$name" "$bron"
        done < <(tenant_host_claims "${by_name[$name]}")
    done
    return $has_error
}

# Host-register over ALLE tenants: dat van values/tenants/, plus de bestanden op
# de commandoregel. Een bestand BUITEN values/tenants/ (een fixture, een
# gewijzigde kopie) vervangt het tenantbestand met dezelfde tenant.name, zodat
# het niet met zichzelf botst. Zo vergelijkt ook `validate-values.sh <één
# bestand>` met de rest van de vloot. Een bestand BINNEN values/tenants/ staat
# al in het register; een tweede daar met een bestaande naam is een fout.
#
# VALIDATE_HOST_CLAIMS_FILE: een register dat `validate-values.sh
# --dump-host-claims` eerder schreef (run-tests.sh bouwt het één keer). Ontbreekt
# het bestand, dan wordt het register gewoon opnieuw opgebouwd.
HOST_CLAIMS=""
build_host_claims() {
    local cache="${VALIDATE_HOST_CLAIMS_FILE:-}"
    if [ -n "$cache" ] && [ -f "$cache" ]; then
        HOST_CLAIMS=$(cat "$cache")
    else
        # Draait in een subshell: tel de fouten hier bij (de meldingen zelf
        # staan al op stderr)
        local dups=0
        HOST_CLAIMS=$(dump_host_claims) || dups=$?
        ERRORS=$((ERRORS + dups))
    fi
    [ -n "$HOST_CLAIMS" ] && HOST_CLAIMS+=$'\n'

    local tenant_dir file path name host bron
    tenant_dir=$(cd "$TENANT_DIR" 2>/dev/null && pwd -P) || tenant_dir="$TENANT_DIR"
    local -A overlay=()
    for file in "$@"; do
        path=$(abs_path "$file")
        [[ "$path" == "${tenant_dir}/"* ]] && continue
        name=$(yq eval '.tenant.name // ""' "$file" 2>/dev/null) || continue
        [ -z "$name" ] && continue
        if [ -n "${overlay[$name]:-}" ] && [ "${overlay[$name]}" != "$path" ]; then
            log_error "$file: tenant.name '$name' staat ook in ${overlay[$name]}"
            continue
        fi
        overlay["$name"]="$path"
    done

    for name in "${!overlay[@]}"; do
        HOST_CLAIMS=$(printf '%s' "$HOST_CLAIMS" | awk -F'\t' -v n="$name" '$2 != n')
        [ -n "$HOST_CLAIMS" ] && HOST_CLAIMS+=$'\n'
        while IFS=$'\t' read -r host bron; do
            [ -z "$host" ] && continue
            HOST_CLAIMS+="${host}"$'\t'"${name}"$'\t'"${bron}"$'\n'
        done < <(tenant_host_claims "${overlay[$name]}")
    done
}

# Geen host mag door twee tenants geclaimd worden. Een tweede Ingress voor
# dezelfde host (in een andere namespace) wordt door de admission-webhook van
# ingress-nginx geweigerd, of zonder webhook samengevoegd met die van de ander:
# dan gaat verkeer naar de verkeerde Nextcloud. Binnen één tenant mag een extra
# host ook niet de host van de eigen WOO-frontend zijn (een andere Ingress).
validate_host_claims() {
    local file="$1" name
    name=$(yq eval '.tenant.name // ""' "$file" 2>/dev/null) || return 0
    [ -z "$name" ] && return 0

    local own has_error=0 host bron other
    own=$(tenant_host_claims "$file")
    while IFS=$'\t' read -r host bron; do
        [ -z "$host" ] && continue
        while IFS=$'\t' read -r other; do
            [ -z "$other" ] && continue
            log_error "$file: host '$host' ($bron) wordt al geclaimd door tenant ${other}"
            has_error=1
        done < <(printf '%s' "$HOST_CLAIMS" | awk -F'\t' -v h="$host" -v n="$name" \
            '$1 == h && $2 != n { print "\x27" $2 "\x27 (" $3 ")" }')
        if [ "$bron" = "tenant.extraHostnames" ] \
            && printf '%s\n' "$own" | grep -qxF -e "${host}"$'\t'"tenant.frontend.host" -e "${host}"$'\t'"tenant.frontend.extraHosts"; then
            log_error "$file: tenant.extraHostnames bevat '$host', de host van de eigen WOO-frontend"
            has_error=1
        fi
    done <<<"$own"

    return $has_error
}

# Validate wave number
validate_wave() {
    local file="$1"
    local wave
    wave=$(yq eval '.tenant.wave // 1' "$file" 2>/dev/null)
    
    if ! [[ "$wave" =~ ^[0-9]+$ ]]; then
        log_error "$file: Invalid wave '$wave'. Must be a non-negative integer."
        return 1
    fi
    
    if [ "$wave" -gt 10 ]; then
        log_warning "$file: Wave '$wave' is unusually high. Are you sure?"
    fi
    
    return 0
}

# Validate bucket name
validate_bucket() {
    local file="$1"
    local bucket
    bucket=$(yq eval '.tenant.s3.bucket' "$file" 2>/dev/null)

    # Optional: bucket is typically global (env/common) and not per-tenant
    if [ "$bucket" = "null" ] || [ -z "$bucket" ]; then
        return 0
    fi
    
    # S3 bucket naming rules
    if ! [[ "$bucket" =~ ^[a-z0-9][a-z0-9.-]*[a-z0-9]$ ]] && ! [[ "$bucket" =~ ^[a-z0-9]$ ]]; then
        log_error "$file: Invalid bucket name '$bucket'. Must be lowercase alphanumeric with dots/hyphens."
        return 1
    fi
    
    if [ ${#bucket} -lt 3 ] || [ ${#bucket} -gt 63 ]; then
        log_error "$file: Bucket name '$bucket' must be 3-63 characters."
        return 1
    fi
    
    return 0
}

# Validate frontend image reference (tenant.frontend.registry/repository/tag)
#
# De WOO PWA image wordt door de React-base ApplicationSet samengesteld als
# "<registry>/<repository>:<tag>". Elk deel heeft dus zijn eigen veld. Een
# provisioningportal dat een volledige reference in één veld propt levert een
# ongeldige image op (bv. tag "woo-website-v2:V1.0.260422-development" rendert
# als "…/woo-website-v2:woo-website-v2:V1.0.260422-development"). Dat is op
# 2026-08-11 op epe-accept gebeurd; deze functie vangt het af.
validate_frontend_image() {
    local file="$1"
    local registry repository tag
    registry=$(yq eval '.tenant.frontend.registry' "$file" 2>/dev/null)
    repository=$(yq eval '.tenant.frontend.repository' "$file" 2>/dev/null)
    tag=$(yq eval '.tenant.frontend.tag' "$file" 2>/dev/null)

    local has_error=0

    # Tag: alleen het tag-deel. Geen '/' (repository) en geen ':' (scheidingsteken).
    if [ "$tag" != "null" ] && [ -n "$tag" ]; then
        if [[ "$tag" == *[/:]* ]]; then
            log_error "$file: tenant.frontend.tag '$tag' bevat '/' of ':'. Alleen het tag-deel hoort hier; gebruik tenant.frontend.repository en tenant.frontend.registry voor de rest."
            has_error=1
        elif ! [[ "$tag" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$ ]]; then
            log_error "$file: Invalid tenant.frontend.tag '$tag'. Must match ^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}\$."
            has_error=1
        fi
    fi

    # Repository: pad zonder registry-host en zonder tag.
    if [ "$repository" != "null" ] && [ -n "$repository" ]; then
        if [[ "$repository" == *:* ]]; then
            log_error "$file: tenant.frontend.repository '$repository' bevat ':'. De tag hoort in tenant.frontend.tag."
            has_error=1
        elif ! [[ "$repository" =~ ^[a-z0-9]+([._-][a-z0-9]+)*(/[a-z0-9]+([._-][a-z0-9]+)*)*$ ]]; then
            log_error "$file: Invalid tenant.frontend.repository '$repository'. Lowercase pad zonder leidende/afsluitende '/' (bv. 'conduction2022/woo-website-v2')."
            has_error=1
        fi
    fi

    # Registry: alleen een host met optionele poort, geen pad.
    if [ "$registry" != "null" ] && [ -n "$registry" ]; then
        if [[ "$registry" == */* ]]; then
            log_error "$file: tenant.frontend.registry '$registry' bevat '/'. Alleen de host hoort hier (bv. 'docker.io'); het pad hoort in tenant.frontend.repository."
            has_error=1
        elif ! [[ "$registry" =~ ^[a-z0-9]+([.-][a-z0-9]+)*(:[0-9]+)?$ ]]; then
            log_error "$file: Invalid tenant.frontend.registry '$registry'. Verwacht een host met optionele poort (bv. 'ghcr.io' of 'registry.local:5000')."
            has_error=1
        fi

        # Een registry zonder repository is betekenisloos: de ApplicationSet stelt
        # de reference alleen samen als er een repository is, dus de registry zou
        # stil genegeerd worden.
        if [ "$repository" = "null" ] || [ -z "$repository" ]; then
            log_error "$file: tenant.frontend.registry is gezet zonder tenant.frontend.repository. Zet beide, of geen van beide."
            has_error=1
        fi
    fi

    return $has_error
}

# Sleutels die de React-base ApplicationSet daadwerkelijk leest. Alles daarbuiten
# wordt stil genegeerd: een tenant met `thema:` i.p.v. `themeClassname:` valt
# terug op het basisthema zonder dat iemand het merkt. Bron:
# React-base/react-platform/argo/applicationsets/react-tenants.yaml — houd deze
# lijsten gelijk als daar een veld bijkomt.
FRONTEND_KEYS=(
    "enabled" "tag" "registry" "repository" "host" "upstreamHost"
    "apiBaseUrl" "tls" "extraHosts" "branding" "env" "wellKnown" "proxied"
)
FRONTEND_BRANDING_KEYS=(
    "organisationName" "themeClassname" "jumbotronImageUrl" "faviconUrl"
    "footerHideLogo"
)
FRONTEND_TLS_KEYS=("secretName" "issuer")

# Weiger onbekende sleutels onder tenant.frontend
validate_frontend_keys() {
    local file="$1"
    local has_error=0

    _check_keys() {
        local path="$1" label="$2"
        shift 2
        local allowed=("$@")
        local key
        while IFS= read -r key; do
            [ -z "$key" ] && continue
            local found=0
            for a in "${allowed[@]}"; do
                if [ "$key" = "$a" ]; then
                    found=1
                    break
                fi
            done
            if [ $found -eq 0 ]; then
                log_error "$file: Onbekende sleutel '$key' onder $label. Niets leest hem, dus hij wordt stil genegeerd. Toegestaan: ${allowed[*]}"
                has_error=1
            fi
        done < <(yq eval "$path // {} | keys | .[]" "$file" 2>/dev/null)
    }

    _check_keys '.tenant.frontend' 'tenant.frontend' "${FRONTEND_KEYS[@]}"
    _check_keys '.tenant.frontend.branding' 'tenant.frontend.branding' "${FRONTEND_BRANDING_KEYS[@]}"
    _check_keys '.tenant.frontend.tls' 'tenant.frontend.tls' "${FRONTEND_TLS_KEYS[@]}"

    return $has_error
}

# Validate branding: themeClassname-vorm
#
# De geldige thema's staan in ConductionNL/conduction-theme (map per thema,
# `<naam>-design-tokens` → klasse `<naam>-theme`) en worden in het image
# gebundeld. Die lijst wijzigt vaak en het image loopt erop achter, dus toetsen
# we hier alleen de VORM — een lijst in deze repo zou rood slaan op een thema dat
# net is toegevoegd. Voor de inhoudelijke toets: scripts/check-themes.sh.
#
# Vangt de praktijkfout: `-thema` i.p.v. `-theme` (noordwijk, dinkelland,
# 2026-08-11). De waarde gaat ongewijzigd door naar
# GATSBY_NL_DESIGN_THEME_CLASSNAME; een klasse die niet bestaat levert stilzwijgend
# geen thema op.
validate_frontend_branding() {
    local file="$1"
    local theme
    theme=$(yq eval '.tenant.frontend.branding.themeClassname // ""' "$file" 2>/dev/null)

    [ -z "$theme" ] && return 0

    if ! [[ "$theme" =~ ^[a-z0-9]+(-[a-z0-9]+)*-theme$ ]]; then
        log_error "$file: Invalid themeClassname '$theme'. Verwacht '<naam>-theme' (kleine letters, koppeltekens). Let op '-thema' i.p.v. '-theme'."
        return 1
    fi

    return 0
}

# Check for potential secrets in file content
check_for_secrets() {
    local file="$1"
    local has_warning=0
    
    # Patterns that might indicate secrets
    local patterns=(
        "password.*:"
        "secret.*:"
        "apikey.*:"
        "api_key.*:"
        "access_key.*:"
        "secret_key.*:"
        "token.*:"
    )
    
    for pattern in "${patterns[@]}"; do
        # Check if pattern exists with a value (not just a reference)
        if grep -iE "^\s*${pattern}\s*['\"]?[^{}$]" "$file" | grep -v "secretKeyRef" | grep -v "secretName" | grep -qv "Key:" ; then
            log_warning "$file: Potential hardcoded secret detected (pattern: $pattern)"
            has_warning=1
        fi
    done
    
    return $has_warning
}

# Validate a single tenant file
validate_tenant_file() {
    local file="$1"
    local filename
    filename=$(basename "$file")
    
    echo "Validating: $filename"
    
    # Check file naming convention
    if ! [[ "$filename" =~ ^tenant-[a-z][a-z0-9-]*\.yaml$ ]]; then
        log_warning "$file: Filename should match pattern 'tenant-<name>.yaml'"
    fi
    
    # Run all validations
    local file_errors=0
    
    validate_yaml_syntax "$file" || ((file_errors++))
    validate_required_fields "$file" || ((file_errors++))
    validate_no_disallowed_fields "$file" || ((file_errors++))
    validate_tenant_name "$file" || ((file_errors++))
    validate_tenant_name_convention "$file" || ((file_errors++))
    validate_namespace_convention "$file" || ((file_errors++))
    validate_environment "$file" || ((file_errors++))
    validate_db_type "$file" || ((file_errors++))
    validate_apps_enabled "$file" || ((file_errors++))
    validate_app_versions_format "$file" || ((file_errors++))
    validate_app_versions_enabled "$file" || ((file_errors++))
    validate_chart_version_format "$file" || ((file_errors++))
    validate_hostname "$file" || ((file_errors++))
    validate_hostname_convention "$file" || ((file_errors++))
    validate_extra_hostnames "$file" || ((file_errors++))
    validate_host_claims "$file" || ((file_errors++))
    validate_wave "$file" || ((file_errors++))
    validate_bucket "$file" || ((file_errors++))
    validate_frontend_image "$file" || ((file_errors++))
    validate_frontend_keys "$file" || ((file_errors++))
    validate_frontend_branding "$file" || ((file_errors++))
    check_for_secrets "$file" || true  # Warnings only
    
    if [ $file_errors -eq 0 ]; then
        log_success "$filename passed all validations"
    fi
    
    return $file_errors
}

# Main
main() {
    check_dependencies

    # --dump-host-claims: schrijf het host-register van values/tenants/ naar
    # stdout, voor VALIDATE_HOST_CLAIMS_FILE (zie build_host_claims)
    if [ "${1:-}" = "--dump-host-claims" ]; then
        dump_host_claims
        exit $?
    fi
    
    local files=()
    
    if [ $# -gt 0 ]; then
        files=("$@")
    else
        # Find all tenant files
        while IFS= read -r -d '' file; do
            files+=("$file")
        done < <(find "$TENANT_DIR" -name "tenant-*.yaml" -print0 2>/dev/null)
    fi
    
    if [ ${#files[@]} -eq 0 ]; then
        echo "No tenant files found in $TENANT_DIR"
        exit 0
    fi
    
    # Hosts van alle tenants, voor validate_host_claims
    build_host_claims "$@"

    echo "=========================================="
    echo "Validating ${#files[@]} tenant file(s)"
    echo "=========================================="
    echo ""
    
    for file in "${files[@]}"; do
        # `|| true`: validate_tenant_file geeft het aantal fouten terug, en een
        # kale aanroep zou met `set -e` de lus afbreken bij het eerste bestand
        # met een fout — de rest van de vloot bleef dan ongevalideerd en de
        # samenvatting verscheen nooit. De telling loopt via de globale ERRORS.
        validate_tenant_file "$file" || true
        echo ""
    done

    # Check shared values files for canary-only settings (guardrail)
    if command -v conftest &>/dev/null; then
        echo "=========================================="
        echo "Shared Values Guardrails (conftest)"
        echo "=========================================="
        local shared_files=()
        for f in \
            "${REPO_ROOT}/values/common.yaml" \
            "${REPO_ROOT}/values/env/prod.yaml" \
            "${REPO_ROOT}/values/env/accept.yaml"; do
            [ -f "$f" ] && shared_files+=("$f")
        done
        if [ ${#shared_files[@]} -gt 0 ]; then
            if conftest test "${shared_files[@]}" \
                --policy "${REPO_ROOT}/policy/" \
                --namespace values 2>&1; then
                log_success "Shared values guardrails passed"
            else
                log_error "Shared values guardrails FAILED — dangerous settings found in shared files"
                ((ERRORS++))
            fi
        fi
        echo ""
    else
        echo -e "${YELLOW}⚠${NC}  conftest not installed — skipping shared values guardrails (install: https://www.conftest.dev)"
    fi
    
    echo "=========================================="
    echo "Validation Summary"
    echo "=========================================="
    echo "Files validated: ${#files[@]}"
    echo "Errors: $ERRORS"
    echo "Warnings: $WARNINGS"
    
    if [ $ERRORS -gt 0 ]; then
        echo ""
        echo -e "${RED}FAILED: $ERRORS error(s) found${NC}"
        exit 1
    elif [ $WARNINGS -gt 0 ]; then
        echo ""
        echo -e "${YELLOW}PASSED with warnings${NC}"
        exit 0
    else
        echo ""
        echo -e "${GREEN}PASSED: All validations successful${NC}"
        exit 0
    fi
}

main "$@"

