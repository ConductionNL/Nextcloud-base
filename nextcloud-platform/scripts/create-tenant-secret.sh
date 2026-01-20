#!/usr/bin/env bash
#
# create-tenant-secret.sh - Create Kubernetes secrets for a Nextcloud tenant
#
# Usage:
#   ./scripts/create-tenant-secret.sh <tenant-name> [--generate-admin-password]
#
# Environment variables (set before running):
#   S3_ACCESS_KEY     - Fuga Cloud S3 access key
#   S3_SECRET_KEY     - Fuga Cloud S3 secret key
#   DB_PASSWORD       - PostgreSQL database password
#   ADMIN_PASSWORD    - Nextcloud admin password (optional, can be generated)
#
# Example:
#   export S3_ACCESS_KEY="your-access-key"
#   export S3_SECRET_KEY="your-secret-key"
#   export DB_PASSWORD="your-db-password"
#   ./scripts/create-tenant-secret.sh canary --generate-admin-password

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

usage() {
    echo "Usage: $0 <tenant-name> [--generate-admin-password]"
    echo ""
    echo "Creates Kubernetes secrets for a Nextcloud tenant."
    echo ""
    echo "Required environment variables:"
    echo "  S3_ACCESS_KEY     Fuga Cloud S3 access key"
    echo "  S3_SECRET_KEY     Fuga Cloud S3 secret key"
    echo "  DB_PASSWORD       PostgreSQL database password"
    echo ""
    echo "Optional environment variables:"
    echo "  ADMIN_PASSWORD    Nextcloud admin password (or use --generate-admin-password)"
    echo "  DB_USERNAME       Database username (default: nextcloud_<tenant>)"
    echo ""
    echo "Options:"
    echo "  --generate-admin-password    Generate a random admin password"
    echo "  --dry-run                    Show what would be created without applying"
    echo ""
    echo "Example:"
    echo "  export S3_ACCESS_KEY='your-key'"
    echo "  export S3_SECRET_KEY='your-secret'"
    echo "  export DB_PASSWORD='db-pass'"
    echo "  $0 canary --generate-admin-password"
    exit 1
}

# Generate secure random password
generate_password() {
    local length="${1:-24}"
    openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c "$length"
}

# Parse arguments
TENANT=""
GENERATE_ADMIN=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --generate-admin-password)
            GENERATE_ADMIN=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            if [ -z "$TENANT" ]; then
                TENANT="$1"
            else
                echo -e "${RED}Error: Unknown argument: $1${NC}"
                usage
            fi
            shift
            ;;
    esac
done

if [ -z "$TENANT" ]; then
    echo -e "${RED}Error: Tenant name is required${NC}"
    usage
fi

NAMESPACE="nc-${TENANT}"

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Creating secrets for tenant: ${TENANT}${NC}"
echo -e "${BLUE}Namespace: ${NAMESPACE}${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Validate required variables
missing_vars=()

if [ -z "${S3_ACCESS_KEY:-}" ]; then
    missing_vars+=("S3_ACCESS_KEY")
fi

if [ -z "${S3_SECRET_KEY:-}" ]; then
    missing_vars+=("S3_SECRET_KEY")
fi

if [ -z "${DB_PASSWORD:-}" ]; then
    missing_vars+=("DB_PASSWORD")
fi

if [ ${#missing_vars[@]} -gt 0 ]; then
    echo -e "${RED}Error: Missing required environment variables:${NC}"
    for var in "${missing_vars[@]}"; do
        echo "  - $var"
    done
    echo ""
    echo "Set them with:"
    for var in "${missing_vars[@]}"; do
        echo "  export $var='your-value'"
    done
    exit 1
fi

# Generate or use provided admin password
if [ "$GENERATE_ADMIN" = true ]; then
    ADMIN_PASSWORD=$(generate_password 24)
    echo -e "${GREEN}Generated admin password${NC}"
elif [ -z "${ADMIN_PASSWORD:-}" ]; then
    echo -e "${YELLOW}Warning: ADMIN_PASSWORD not set and --generate-admin-password not used${NC}"
    echo "Generating a random password..."
    ADMIN_PASSWORD=$(generate_password 24)
fi

# Generate Nextcloud secret (for encryption)
NEXTCLOUD_SECRET=$(generate_password 64)

# Database username
DB_USERNAME="${DB_USERNAME:-nextcloud_${TENANT}}"

echo ""
echo "Configuration:"
echo "  Tenant:        $TENANT"
echo "  Namespace:     $NAMESPACE"
echo "  DB Username:   $DB_USERNAME"
echo "  S3 Access Key: ${S3_ACCESS_KEY:0:8}..."
echo ""

# Create namespace if it doesn't exist
if [ "$DRY_RUN" = false ]; then
    kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
fi

# Create the secret YAML
SECRET_YAML=$(cat <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: nextcloud-secrets
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: nextcloud
    app.kubernetes.io/instance: ${TENANT}
    app.kubernetes.io/part-of: nextcloud-platform
    nextcloud.platform/tenant: ${TENANT}
type: Opaque
stringData:
  nextcloud-username: "admin"
  nextcloud-password: "${ADMIN_PASSWORD}"
  s3-access-key: "${S3_ACCESS_KEY}"
  s3-secret-key: "${S3_SECRET_KEY}"
  db-username: "${DB_USERNAME}"
  db-password: "${DB_PASSWORD}"
  redis-password: ""
  nextcloud-secret: "${NEXTCLOUD_SECRET}"
EOF
)

if [ "$DRY_RUN" = true ]; then
    echo -e "${YELLOW}DRY RUN - Would create:${NC}"
    echo ""
    echo "$SECRET_YAML"
    echo ""
else
    echo "Creating secret..."
    echo "$SECRET_YAML" | kubectl apply -f -
    
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}Secret created successfully!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo -e "${YELLOW}SAVE THESE CREDENTIALS SECURELY:${NC}"
    echo ""
    echo "  Tenant:         $TENANT"
    echo "  Namespace:      $NAMESPACE"
    echo "  Admin Username: admin"
    echo -e "  Admin Password: ${GREEN}${ADMIN_PASSWORD}${NC}"
    echo ""
    echo "Verify with:"
    echo "  kubectl get secret nextcloud-secrets -n $NAMESPACE"
    echo ""
fi

