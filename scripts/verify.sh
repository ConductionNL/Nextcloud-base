#!/usr/bin/env bash
# SPDX-License-Identifier: EUPL-1.2
# role: tool
#
# scripts/verify.sh — snelle functionele verificatie (pre-push gate).
#
# Draait de bestaande platform-checks: tenant-values-validatie (vereiste
# velden, verboden velden, patronen) en de smoke-checks (chart-renders).
# Dry-run only, geen cluster-toegang.
#
# Writes: read-only
# Idempotent: yes
# Requires: bash, yq, yamllint (via validate-values), helm
#
# Usage:
#   ./scripts/verify.sh

set -euo pipefail

cd "$(dirname "$0")/.."

bash nextcloud-platform/scripts/validate-values.sh >/dev/null
echo "validate-values OK (alle tenants)"

bash nextcloud-platform/scripts/smoke-checks.sh >/dev/null
echo "smoke-checks OK"

echo "verify: OK"
