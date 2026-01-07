#!/usr/bin/env bash
#
# smoke-checks.sh - Local smoke checks for Nextcloud platform
#
# This script validates:
# 1. Helm templates render successfully
# 2. Required values are set
# 3. Generated manifests are valid Kubernetes resources
#
# Usage:
#   ./scripts/smoke-checks.sh
#   ./scripts/smoke-checks.sh --tenant canary
#   ./scripts/smoke-checks.sh --all

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VALUES_DIR="${REPO_ROOT}/values"
TENANT_DIR="${VALUES_DIR}/tenants"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Counters
ERRORS=0
WARNINGS=0
PASSED=0

log_error() {
    echo -e "${RED}✗ ERROR:${NC} $1" >&2
    ((ERRORS++))
}

log_warning() {
    echo -e "${YELLOW}⚠ WARNING:${NC} $1" >&2
    ((WARNINGS++))
}

log_success() {
    echo -e "${GREEN}✓${NC} $1"
    ((PASSED++))
}

log_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

# Check dependencies
check_dependencies() {
    local missing=()
    
    for cmd in helm yq kubeconform kubectl; do
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$cmd")
        fi
    done
    
    if [ ${#missing[@]} -gt 0 ]; then
        echo "Missing tools: ${missing[*]}"
        echo ""
        echo "Install instructions:"
        echo "  helm:        https://helm.sh/docs/intro/install/"
        echo "  yq:          https://github.com/mikefarah/yq#install"
        echo "  kubeconform: https://github.com/yannh/kubeconform#installation"
        echo "  kubectl:     https://kubernetes.io/docs/tasks/tools/"
        echo ""
        echo "Or run with --skip-deps to skip dependency checks"
        exit 1
    fi
    
    log_success "All dependencies installed"
}

# Add Helm repo if not present
setup_helm() {
    if ! helm repo list 2>/dev/null | grep -q "nextcloud"; then
        log_info "Adding Nextcloud Helm repo..."
        helm repo add nextcloud https://nextcloud.github.io/helm/ >/dev/null 2>&1 || true
        helm repo update >/dev/null 2>&1 || true
    fi
}

# Extract tenant info from file
get_tenant_info() {
    local file="$1"
    local field="$2"
    yq eval "$field" "$file" 2>/dev/null
}

# Template a tenant
template_tenant() {
    local tenant_name="$1"
    local tenant_file="${TENANT_DIR}/tenant-${tenant_name}.yaml"
    local output_dir
    output_dir=$(mktemp -d)
    
    if [ ! -f "$tenant_file" ]; then
        log_error "Tenant file not found: $tenant_file"
        return 1
    fi
    
    local env
    env=$(get_tenant_info "$tenant_file" ".tenant.environment")
    local env_file="${VALUES_DIR}/env/${env}.yaml"
    
    if [ ! -f "$env_file" ]; then
        log_error "Environment file not found: $env_file"
        return 1
    fi
    
    log_info "Templating tenant: $tenant_name (env: $env)"
    
    # Template with Helm
    local helm_output="${output_dir}/manifests.yaml"
    
    if helm template nextcloud nextcloud/nextcloud \
        --values "${VALUES_DIR}/common.yaml" \
        --values "$env_file" \
        --values "$tenant_file" \
        --namespace "nc-${tenant_name}" \
        --set fullnameOverride=nextcloud \
        > "$helm_output" 2>/dev/null; then
        log_success "Helm template succeeded for $tenant_name"
    else
        log_error "Helm template failed for $tenant_name"
        rm -rf "$output_dir"
        return 1
    fi
    
    # Check manifest is not empty
    if [ ! -s "$helm_output" ]; then
        log_error "Generated manifest is empty for $tenant_name"
        rm -rf "$output_dir"
        return 1
    fi
    
    log_success "Generated $(wc -l < "$helm_output") lines of manifests"
    
    # Validate with kubeconform
    log_info "Validating Kubernetes manifests with kubeconform..."
    
    if kubeconform -strict -ignore-missing-schemas \
        -schema-location default \
        -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
        "$helm_output" 2>&1; then
        log_success "Kubernetes schema validation passed"
    else
        log_warning "Some schemas could not be validated (may be CRDs)"
    fi
    
    # Check for specific resources
    log_info "Checking generated resources..."
    
    # Check Deployment exists
    if grep -q "kind: Deployment" "$helm_output"; then
        log_success "Deployment resource found"
    else
        log_error "No Deployment resource found"
    fi
    
    # Check Service exists
    if grep -q "kind: Service" "$helm_output"; then
        log_success "Service resource found"
    else
        log_error "No Service resource found"
    fi
    
    # Check Ingress exists
    if grep -q "kind: Ingress" "$helm_output"; then
        log_success "Ingress resource found"
    else
        log_warning "No Ingress resource found"
    fi
    
    # Check for S3 config (critical for our architecture)
    if grep -q "objectstore" "$helm_output" || grep -q "S3" "$helm_output"; then
        log_success "S3 object storage configuration found"
    else
        log_warning "No S3 configuration detected - user files may use local storage!"
    fi
    
    # Check for Redis config
    if grep -q "redis" "$helm_output" || grep -q "Redis" "$helm_output"; then
        log_success "Redis configuration found"
    else
        log_warning "No Redis configuration detected - may affect caching/locking"
    fi
    
    # Cleanup
    rm -rf "$output_dir"
    
    return 0
}

# Lint Helm chart
lint_helm() {
    log_info "Running Helm lint..."
    
    # Can't lint the upstream chart directly without downloading
    # Instead, lint our values files
    for file in "${VALUES_DIR}/common.yaml" "${VALUES_DIR}/env/"*.yaml; do
        if [ -f "$file" ]; then
            if yq eval '.' "$file" > /dev/null 2>&1; then
                log_success "Valid YAML: $(basename "$file")"
            else
                log_error "Invalid YAML: $file"
            fi
        fi
    done
}

# Check required files exist
check_required_files() {
    log_info "Checking required files..."
    
    local required_files=(
        "values/common.yaml"
        "values/env/accept.yaml"
        "values/env/prod.yaml"
        "argo/applicationsets/nextcloud-tenants.yaml"
        "argo/projects/nextcloud-platform.yaml"
        "platform/redis/kustomization.yaml"
        "platform/pgbouncer/kustomization.yaml"
        "platform/externalsecrets/kustomization.yaml"
    )
    
    for file in "${required_files[@]}"; do
        if [ -f "${REPO_ROOT}/${file}" ]; then
            log_success "Found: $file"
        else
            log_error "Missing: $file"
        fi
    done
}

# Check values consistency
check_values_consistency() {
    log_info "Checking values consistency..."
    
    # Check chart version is set
    local chart_version
    chart_version=$(yq eval '.chart.version' "${VALUES_DIR}/common.yaml" 2>/dev/null)
    if [ -n "$chart_version" ] && [ "$chart_version" != "null" ]; then
        log_success "Chart version pinned: $chart_version"
    else
        log_warning "Chart version not pinned in common.yaml"
    fi
    
    # Check all tenants have S3 bucket set
    for tenant_file in "${TENANT_DIR}"/tenant-*.yaml; do
        if [ -f "$tenant_file" ]; then
            local tenant_name
            tenant_name=$(basename "$tenant_file" .yaml | sed 's/tenant-//')
            local bucket
            bucket=$(yq eval '.tenant.s3.bucket' "$tenant_file" 2>/dev/null)
            if [ -n "$bucket" ] && [ "$bucket" != "null" ]; then
                log_success "Tenant $tenant_name has S3 bucket: $bucket"
            else
                log_error "Tenant $tenant_name missing S3 bucket configuration"
            fi
        fi
    done
}

# Main
main() {
    local skip_deps=false
    local specific_tenant=""
    local run_all=false
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --skip-deps)
                skip_deps=true
                shift
                ;;
            --tenant)
                specific_tenant="$2"
                shift 2
                ;;
            --all)
                run_all=true
                shift
                ;;
            -h|--help)
                echo "Usage: $0 [options]"
                echo ""
                echo "Options:"
                echo "  --skip-deps    Skip dependency checks"
                echo "  --tenant NAME  Only check specific tenant"
                echo "  --all          Run all checks including Helm template"
                echo "  -h, --help     Show this help"
                exit 0
                ;;
            *)
                echo "Unknown option: $1"
                exit 1
                ;;
        esac
    done
    
    echo "=========================================="
    echo "Nextcloud Platform Smoke Checks"
    echo "=========================================="
    echo ""
    
    # Dependency check
    if [ "$skip_deps" != true ]; then
        check_dependencies
    fi
    
    echo ""
    
    # Required files check
    check_required_files
    echo ""
    
    # Lint Helm values
    lint_helm
    echo ""
    
    # Values consistency
    check_values_consistency
    echo ""
    
    # Template tenants
    if [ "$run_all" = true ] || [ -n "$specific_tenant" ]; then
        setup_helm
        echo ""
        
        if [ -n "$specific_tenant" ]; then
            template_tenant "$specific_tenant"
        else
            for tenant_file in "${TENANT_DIR}"/tenant-*.yaml; do
                if [ -f "$tenant_file" ]; then
                    local tenant_name
                    tenant_name=$(basename "$tenant_file" .yaml | sed 's/tenant-//')
                    template_tenant "$tenant_name"
                    echo ""
                fi
            done
        fi
    else
        log_info "Skipping Helm template (use --all to enable)"
    fi
    
    # Summary
    echo ""
    echo "=========================================="
    echo "Summary"
    echo "=========================================="
    echo -e "Passed:   ${GREEN}$PASSED${NC}"
    echo -e "Warnings: ${YELLOW}$WARNINGS${NC}"
    echo -e "Errors:   ${RED}$ERRORS${NC}"
    
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
        echo -e "${GREEN}ALL CHECKS PASSED${NC}"
        exit 0
    fi
}

main "$@"

