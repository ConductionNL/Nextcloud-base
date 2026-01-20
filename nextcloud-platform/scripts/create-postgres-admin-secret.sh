#!/usr/bin/env bash
#
# create-postgres-admin-secret.sh - Create PostgreSQL admin secret for database provisioning
#
# This secret is used by the database provisioning Job to create tenant databases.
# It needs admin-level access to PostgreSQL to CREATE DATABASE and CREATE USER.
#
# Usage:
#   export POSTGRES_HOST='your-postgres-host'
#   export POSTGRES_PORT='5432'
#   export POSTGRES_ADMIN_USER='postgres'
#   export POSTGRES_ADMIN_PASSWORD='your-admin-password'
#   ./scripts/create-postgres-admin-secret.sh

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Creating PostgreSQL Admin Secret${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Validate required variables
missing_vars=()

if [ -z "${POSTGRES_HOST:-}" ]; then
    missing_vars+=("POSTGRES_HOST")
fi

if [ -z "${POSTGRES_ADMIN_USER:-}" ]; then
    missing_vars+=("POSTGRES_ADMIN_USER")
fi

if [ -z "${POSTGRES_ADMIN_PASSWORD:-}" ]; then
    missing_vars+=("POSTGRES_ADMIN_PASSWORD")
fi

if [ ${#missing_vars[@]} -gt 0 ]; then
    echo -e "${RED}Error: Missing required environment variables:${NC}"
    for var in "${missing_vars[@]}"; do
        echo "  - $var"
    done
    echo ""
    echo "Set them with:"
    echo "  export POSTGRES_HOST='your-postgres-host'"
    echo "  export POSTGRES_PORT='5432'  # optional, default 5432"
    echo "  export POSTGRES_ADMIN_USER='postgres'"
    echo "  export POSTGRES_ADMIN_PASSWORD='your-admin-password'"
    exit 1
fi

POSTGRES_PORT="${POSTGRES_PORT:-5432}"

echo "Configuration:"
echo "  Host: $POSTGRES_HOST"
echo "  Port: $POSTGRES_PORT"
echo "  Admin User: $POSTGRES_ADMIN_USER"
echo ""

# Create namespace if not exists
kubectl create namespace nextcloud-platform --dry-run=client -o yaml | kubectl apply -f -

# Create secret
kubectl create secret generic postgres-admin \
  --namespace=nextcloud-platform \
  --from-literal=host="$POSTGRES_HOST" \
  --from-literal=port="$POSTGRES_PORT" \
  --from-literal=username="$POSTGRES_ADMIN_USER" \
  --from-literal=password="$POSTGRES_ADMIN_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

# Label it
kubectl label secret postgres-admin \
  --namespace=nextcloud-platform \
  --overwrite \
  app.kubernetes.io/part-of=nextcloud-platform \
  app.kubernetes.io/component=database

echo ""
echo -e "${GREEN}✓ PostgreSQL admin secret created${NC}"
echo ""
echo "This secret will be used to automatically provision databases for each tenant."
echo ""
echo "Verify with:"
echo "  kubectl get secret postgres-admin -n nextcloud-platform"

