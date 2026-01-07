#!/usr/bin/env bash
#
# create-platform-secrets.sh - Create secrets for platform components
#
# Creates:
# - pgbouncer-credentials: PostgreSQL connection details for PgBouncer
#
# Usage:
#   ./scripts/create-platform-secrets.sh
#
# Required environment variables:
#   POSTGRES_HOST     - PostgreSQL hostname
#   POSTGRES_PORT     - PostgreSQL port (default: 5432)
#   POSTGRES_USER     - PostgreSQL username
#   POSTGRES_PASSWORD - PostgreSQL password

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

NAMESPACE="nextcloud-platform"

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Creating Platform Secrets${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Create namespace if not exists
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Validate required variables
missing_vars=()

if [ -z "${POSTGRES_HOST:-}" ]; then
    missing_vars+=("POSTGRES_HOST")
fi

if [ -z "${POSTGRES_USER:-}" ]; then
    missing_vars+=("POSTGRES_USER")
fi

if [ -z "${POSTGRES_PASSWORD:-}" ]; then
    missing_vars+=("POSTGRES_PASSWORD")
fi

if [ ${#missing_vars[@]} -gt 0 ]; then
    echo -e "${RED}Error: Missing required environment variables:${NC}"
    for var in "${missing_vars[@]}"; do
        echo "  - $var"
    done
    echo ""
    echo "Set them with:"
    echo "  export POSTGRES_HOST='your-postgresql-host'"
    echo "  export POSTGRES_USER='nextcloud'"
    echo "  export POSTGRES_PASSWORD='your-password'"
    exit 1
fi

POSTGRES_PORT="${POSTGRES_PORT:-5432}"

echo "Creating PgBouncer credentials secret..."
echo "  Host: $POSTGRES_HOST"
echo "  Port: $POSTGRES_PORT"
echo "  User: $POSTGRES_USER"
echo ""

kubectl create secret generic pgbouncer-credentials \
  --namespace="$NAMESPACE" \
  --from-literal=host="$POSTGRES_HOST" \
  --from-literal=port="$POSTGRES_PORT" \
  --from-literal=username="$POSTGRES_USER" \
  --from-literal=password="$POSTGRES_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

echo ""
echo -e "${GREEN}✓ Platform secrets created successfully${NC}"
echo ""
echo "Verify with:"
echo "  kubectl get secrets -n $NAMESPACE"

