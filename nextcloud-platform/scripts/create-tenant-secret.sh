#!/usr/bin/env bash
#
# create-tenant-secret.sh - Create Kubernetes secrets for a Nextcloud tenant
#
# Usage:
#   ./scripts/create-tenant-secret.sh [tenant-name] [options]
#
# If tenant-name is not provided, reads from TENANT_NAME in .env
#
# Options:
#   --env-file <path>    Load environment from file (default: .env in script dir)
#   --generate-passwords Generate all passwords randomly
#   --dry-run            Show what would be created without applying
#   --postgres           Create secrets for PostgreSQL setup (incl. redis)
#   --mariadb            Create secrets for MariaDB setup (default)
#
# Example:
#   cp env.example .env
#   # Edit .env with your values
#   ./create-tenant-secret.sh
#
#   # Or specify tenant on command line:
#   ./create-tenant-secret.sh canary --postgres --generate-passwords

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

usage() {
    echo "Usage: $0 [tenant-name] [options]"
    echo ""
    echo "Creates Kubernetes secrets for a Nextcloud tenant."
    echo ""
    echo "Options:"
    echo "  --env-file <path>    Load from env file (default: .env in script dir)"
    echo "  --generate-passwords Generate all passwords randomly"
    echo "  --dry-run            Show what would be created"
    echo "  --postgres           PostgreSQL setup (with Redis)"
    echo "  --mariadb            MariaDB setup (default)"
    echo ""
    echo "Required in .env or environment:"
    echo "  TENANT_NAME          Tenant identifier"
    echo "  S3_ACCESS_KEY        S3 access key"
    echo "  S3_SECRET_KEY        S3 secret key"
    echo ""
    echo "For MariaDB (--mariadb, default):"
    echo "  MARIADB_ROOT_PASSWORD"
    echo "  MARIADB_PASSWORD"
    echo ""
    echo "For PostgreSQL (--postgres):"
    echo "  POSTGRES_PASSWORD    PostgreSQL admin password"
    echo "  DB_PASSWORD          Nextcloud user password"
    echo "  REDIS_PASSWORD       Redis password"
    echo ""
    echo "Example:"
    echo "  cp env.example .env && nano .env"
    echo "  $0"
    exit 1
}

# Generate secure random password
generate_password() {
    local length="${1:-24}"
    openssl rand -base64 48 | tr -dc 'a-zA-Z0-9!@#$%^&*()' | head -c "$length"
}

# Load .env file
load_env_file() {
    local env_file="$1"
    if [ -f "$env_file" ]; then
        echo -e "${BLUE}Loading environment from: ${env_file}${NC}"
        # Export variables from .env file (skip comments and empty lines)
        set -a
        # shellcheck disable=SC1090
        source "$env_file"
        set +a
        return 0
    fi
    return 1
}

# Parse arguments
TENANT=""
ENV_FILE="${SCRIPT_DIR}/.env"
GENERATE_PASSWORDS=false
DRY_RUN=false
DB_TYPE="mariadb"

while [[ $# -gt 0 ]]; do
    case $1 in
        --env-file)
            ENV_FILE="$2"
            shift 2
            ;;
        --generate-passwords)
            GENERATE_PASSWORDS=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --postgres)
            DB_TYPE="postgres"
            shift
            ;;
        --mariadb)
            DB_TYPE="mariadb"
            shift
            ;;
        -h|--help)
            usage
            ;;
        -*)
            echo -e "${RED}Error: Unknown option: $1${NC}"
            usage
            ;;
        *)
            if [ -z "$TENANT" ]; then
                TENANT="$1"
            else
                echo -e "${RED}Error: Unexpected argument: $1${NC}"
                usage
            fi
            shift
            ;;
    esac
done

# Try to load .env file
if [ -f "$ENV_FILE" ]; then
    load_env_file "$ENV_FILE"
else
    echo -e "${YELLOW}No .env file found at: ${ENV_FILE}${NC}"
    echo "Using existing environment variables..."
fi

# Use TENANT_NAME from env if not specified on command line
if [ -z "$TENANT" ]; then
    TENANT="${TENANT_NAME:-}"
fi

if [ -z "$TENANT" ]; then
    echo -e "${RED}Error: Tenant name is required${NC}"
    echo "Specify on command line or set TENANT_NAME in .env"
    echo ""
    usage
fi

NAMESPACE="nc-${TENANT}"

echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Creating secrets for tenant: ${TENANT}${NC}"
echo -e "${BLUE}Database type: ${DB_TYPE}${NC}"
echo -e "${BLUE}Namespace: ${NAMESPACE}${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Validate/generate required variables
missing_vars=()

# Always required: S3
if [ -z "${S3_ACCESS_KEY:-}" ]; then
    missing_vars+=("S3_ACCESS_KEY")
fi
if [ -z "${S3_SECRET_KEY:-}" ]; then
    missing_vars+=("S3_SECRET_KEY")
fi

# Generate or validate passwords based on DB type
if [ "$GENERATE_PASSWORDS" = true ]; then
    echo -e "${GREEN}Generating random passwords...${NC}"
    ADMIN_PASSWORD="${ADMIN_PASSWORD:-$(generate_password 20)}"
    NEXTCLOUD_SECRET="$(generate_password 64)"
    
    if [ "$DB_TYPE" = "mariadb" ]; then
        MARIADB_ROOT_PASSWORD="${MARIADB_ROOT_PASSWORD:-$(generate_password 24)}"
        MARIADB_PASSWORD="${MARIADB_PASSWORD:-$(generate_password 24)}"
    else
        POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-$(generate_password 24)}"
        DB_PASSWORD="${DB_PASSWORD:-$(generate_password 24)}"
        REDIS_PASSWORD="${REDIS_PASSWORD:-$(generate_password 24)}"
    fi
else
    # Validate required passwords exist
    if [ -z "${ADMIN_PASSWORD:-}" ]; then
        missing_vars+=("ADMIN_PASSWORD")
    fi
    
    if [ "$DB_TYPE" = "mariadb" ]; then
        if [ -z "${MARIADB_ROOT_PASSWORD:-}" ]; then
            missing_vars+=("MARIADB_ROOT_PASSWORD")
        fi
        if [ -z "${MARIADB_PASSWORD:-}" ]; then
            missing_vars+=("MARIADB_PASSWORD")
        fi
    else
        if [ -z "${POSTGRES_PASSWORD:-}" ]; then
            missing_vars+=("POSTGRES_PASSWORD")
        fi
        if [ -z "${DB_PASSWORD:-}" ]; then
            missing_vars+=("DB_PASSWORD")
        fi
        if [ -z "${REDIS_PASSWORD:-}" ]; then
            missing_vars+=("REDIS_PASSWORD")
        fi
    fi
    
    NEXTCLOUD_SECRET="${NEXTCLOUD_SECRET:-$(generate_password 64)}"
fi

# Check for missing variables
if [ ${#missing_vars[@]} -gt 0 ]; then
    echo -e "${RED}Error: Missing required variables:${NC}"
    for var in "${missing_vars[@]}"; do
        echo "  - $var"
    done
    echo ""
    echo "Either set them in .env or use --generate-passwords"
    exit 1
fi

# Set defaults
ADMIN_USERNAME="${ADMIN_USERNAME:-admin}"
DB_USERNAME="${DB_USERNAME:-nextcloud}"

echo "Configuration:"
echo "  Tenant:        $TENANT"
echo "  Namespace:     $NAMESPACE"
echo "  DB Type:       $DB_TYPE"
echo "  Admin User:    $ADMIN_USERNAME"
echo "  DB Username:   $DB_USERNAME"
echo "  S3 Access Key: ${S3_ACCESS_KEY:0:8}..."
echo ""

# Create namespace if it doesn't exist
if [ "$DRY_RUN" = false ]; then
    kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
fi

# Build secret based on DB type
if [ "$DB_TYPE" = "mariadb" ]; then
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
  # Nextcloud admin
  nextcloud-username: "${ADMIN_USERNAME}"
  nextcloud-password: "${ADMIN_PASSWORD}"
  nextcloud-secret: "${NEXTCLOUD_SECRET}"
  # S3 storage
  s3-access-key: "${S3_ACCESS_KEY}"
  s3-secret-key: "${S3_SECRET_KEY}"
  # MariaDB
  mariadb-root-password: "${MARIADB_ROOT_PASSWORD}"
  mariadb-password: "${MARIADB_PASSWORD}"
EOF
)
else
    # PostgreSQL with Redis
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
  # Nextcloud admin
  nextcloud-username: "${ADMIN_USERNAME}"
  nextcloud-password: "${ADMIN_PASSWORD}"
  nextcloud-secret: "${NEXTCLOUD_SECRET}"
  # S3 storage
  s3-access-key: "${S3_ACCESS_KEY}"
  s3-secret-key: "${S3_SECRET_KEY}"
  # PostgreSQL
  postgres-password: "${POSTGRES_PASSWORD}"
  db-username: "${DB_USERNAME}"
  db-password: "${DB_PASSWORD}"
  # Redis
  redis-password: "${REDIS_PASSWORD}"
EOF
)
fi

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
    echo "  Tenant:           $TENANT"
    echo "  Namespace:        $NAMESPACE"
    echo "  Admin Username:   $ADMIN_USERNAME"
    echo -e "  Admin Password:   ${GREEN}${ADMIN_PASSWORD}${NC}"
    echo ""
    if [ "$DB_TYPE" = "postgres" ]; then
        echo "  PostgreSQL:"
        echo -e "    Admin Password: ${GREEN}${POSTGRES_PASSWORD}${NC}"
        echo -e "    User Password:  ${GREEN}${DB_PASSWORD}${NC}"
        echo ""
        echo "  Redis:"
        echo -e "    Password:       ${GREEN}${REDIS_PASSWORD}${NC}"
    else
        echo "  MariaDB:"
        echo -e "    Root Password:  ${GREEN}${MARIADB_ROOT_PASSWORD}${NC}"
        echo -e "    User Password:  ${GREEN}${MARIADB_PASSWORD}${NC}"
    fi
    echo ""
    echo "Verify with:"
    echo "  kubectl get secret nextcloud-secrets -n $NAMESPACE"
    echo ""
fi
