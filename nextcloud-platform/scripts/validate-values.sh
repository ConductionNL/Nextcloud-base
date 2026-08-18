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

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TENANT_DIR="${REPO_ROOT}/values/tenants"

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
    if ! [[ "$hostname" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?(\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*$ ]]; then
        log_error "$file: Invalid hostname '$hostname'. Must be a valid DNS name."
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
    validate_chart_version_format "$file" || ((file_errors++))
    validate_hostname "$file" || ((file_errors++))
    validate_hostname_convention "$file" || ((file_errors++))
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

