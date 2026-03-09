#!/usr/bin/env bash
#
# cutover-tenant.sh - Cut over a tenant from a .migrate domain to its canonical hostname
#
# After removing the `tenant.hostname` migrate override from a tenant values file,
# Nextcloud's persistent config.php still trusts only the old migration domain.
# This script patches trusted_domains and overwrite.cli.url in the live pod so
# the startup probe passes and the tenant becomes healthy on the new domain.
#
# Usage:
#   ./scripts/cutover-tenant.sh <tenant-name>
#
# Example:
#   ./scripts/cutover-tenant.sh roosendaal-prod
#
# Prerequisites:
#   - kubectl configured and pointing at the right cluster
#   - Tenant values file already updated (hostname override removed) and pushed to Git
#   - Argo CD sync already triggered (pod rolling with new hostname in probe)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

usage() {
    echo "Usage: $0 <tenant-name>"
    echo ""
    echo "Example: $0 roosendaal-prod"
    exit 1
}

if [[ $# -lt 1 ]]; then
    usage
fi

TENANT="$1"
NAMESPACE="$TENANT"

# Derive canonical hostname from tenant name (mirrors ApplicationSet logic)
# Strips -(accept|test|prod) suffix to get org, then builds hostname
if [[ "$TENANT" =~ ^(.+)-(accept|test|prod)$ ]]; then
    ORG="${BASH_REMATCH[1]}"
    SUFFIX="${BASH_REMATCH[2]}"
    if [[ "$SUFFIX" == "prod" ]]; then
        CANONICAL_HOST="${ORG}.commonground.nu"
    else
        CANONICAL_HOST="${ORG}.${SUFFIX}.commonground.nu"
    fi
else
    echo -e "${RED}ERROR:${NC} Tenant name '$TENANT' does not follow convention <org>-(accept|test|prod)"
    exit 1
fi

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Cutover: $TENANT${NC}"
echo -e "${BLUE}Canonical hostname: $CANONICAL_HOST${NC}"
echo -e "${BLUE}Namespace: $NAMESPACE${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Find the running Nextcloud pod
echo -e "${BLUE}Finding Nextcloud pod...${NC}"
POD=$(kubectl get pod -n "$NAMESPACE" \
    -l app.kubernetes.io/name=nextcloud \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

if [[ -z "$POD" ]]; then
    echo -e "${RED}ERROR:${NC} No Nextcloud pod found in namespace '$NAMESPACE'"
    echo "Is the tenant deployed and the namespace correct?"
    exit 1
fi

echo "Pod: $POD"
echo ""

# Check current trusted_domains
echo -e "${BLUE}Current trusted_domains:${NC}"
kubectl exec -n "$NAMESPACE" "$POD" -c nextcloud -- \
    php occ config:system:get trusted_domains 2>/dev/null || true
echo ""

# Check if canonical host is already trusted
ALREADY_TRUSTED=$(kubectl exec -n "$NAMESPACE" "$POD" -c nextcloud -- \
    php occ config:system:get trusted_domains 2>/dev/null | grep -c "^${CANONICAL_HOST}$" || true)

if [[ "$ALREADY_TRUSTED" -gt 0 ]]; then
    echo -e "${GREEN}OK:${NC} '$CANONICAL_HOST' is already trusted — nothing to do for trusted_domains"
else
    echo -e "${BLUE}Adding '$CANONICAL_HOST' to trusted_domains (index 1)...${NC}"
    kubectl exec -n "$NAMESPACE" "$POD" -c nextcloud -- \
        php occ config:system:set trusted_domains 1 --value="$CANONICAL_HOST"
    echo -e "${GREEN}OK:${NC} trusted_domains updated"
fi

echo ""

# Update overwrite.cli.url
echo -e "${BLUE}Updating overwrite.cli.url...${NC}"
kubectl exec -n "$NAMESPACE" "$POD" -c nextcloud -- \
    php occ config:system:set overwrite.cli.url --value="https://${CANONICAL_HOST}"
echo -e "${GREEN}OK:${NC} overwrite.cli.url set to https://${CANONICAL_HOST}"

echo ""

# Verify
echo -e "${BLUE}Verifying config...${NC}"
echo "trusted_domains:"
kubectl exec -n "$NAMESPACE" "$POD" -c nextcloud -- \
    php occ config:system:get trusted_domains 2>/dev/null
echo ""
echo "overwrite.cli.url:"
kubectl exec -n "$NAMESPACE" "$POD" -c nextcloud -- \
    php occ config:system:get overwrite.cli.url 2>/dev/null

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Cutover complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "Next steps:"
echo "  1. Wait for pod to become 3/3 Ready:"
echo "     kubectl get pods -n $NAMESPACE -w"
echo "  2. Verify Nextcloud is reachable:"
echo "     curl -I https://${CANONICAL_HOST}/status.php"
echo "  3. Remove the migrate hostname override from the tenant values file if not done yet,"
echo "     commit and push."
