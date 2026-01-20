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

log_error() {
    echo -e "${RED}ERROR:${NC} $1" >&2
    ((ERRORS++))
}

log_warning() {
    echo -e "${YELLOW}WARNING:${NC} $1" >&2
    ((WARNINGS++))
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
    ".tenant.hostname"
    ".tenant.s3.bucket"
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

# Validate hostname format
validate_hostname() {
    local file="$1"
    local hostname
    hostname=$(yq eval '.tenant.hostname' "$file" 2>/dev/null)
    
    # Basic hostname validation (RFC 1123)
    if ! [[ "$hostname" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?(\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*$ ]]; then
        log_error "$file: Invalid hostname '$hostname'. Must be a valid DNS name."
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
    validate_environment "$file" || ((file_errors++))
    validate_hostname "$file" || ((file_errors++))
    validate_wave "$file" || ((file_errors++))
    validate_bucket "$file" || ((file_errors++))
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
        validate_tenant_file "$file"
        echo ""
    done
    
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

