#!/usr/bin/env bash
#
# classify-change.sh - classify a Git diff as platform vs tenant-additive
#
# Usage:
#   ./scripts/classify-change.sh <base-sha> <head-sha>
#
# Output:
#   - Human-readable summary to stdout
#   - Machine-readable key=value lines suitable for GITHUB_OUTPUT:
#       classification=platform|tenant-additive|mixed
#       changed_tenant_count=<n>
#       changed_tenants=<comma-separated tenant names>
#       changed_files_count=<n>
#

set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <base-sha> <head-sha>" >&2
  exit 1
fi

BASE_SHA="$1"
HEAD_SHA="$2"

# Work from the git root: `git diff --name-only` reports paths relative to the
# git root regardless of the current directory. Until 2026-08-04 this used the
# platform subdirectory as the root, so every pattern below missed and every
# change classified as "platform" with zero changed tenants — fail-safe, but it
# made the tenant-additive path dead and changed_tenants permanently empty.
REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

# Platform values/manifests live in a subdirectory; docs/, scripts/ and
# .github/ sit at the git root. Both shapes appear in the patterns below.
readonly PLATFORM_DIR="nextcloud-platform"

mapfile -t CHANGED_FILES < <(git diff --name-only "$BASE_SHA" "$HEAD_SHA" --)

if [[ ${#CHANGED_FILES[@]} -eq 0 ]]; then
  echo "classification=tenant-additive"
  echo "changed_tenant_count=0"
  echo "changed_tenants="
  echo "changed_files_count=0"
  exit 0
fi

is_tenant_file() {
  local f="$1"
  [[ "$f" =~ ^${PLATFORM_DIR}/values/tenants/tenant-.*\.yaml$ ]]
}

is_platform_file() {
  local f="$1"
  # Inside the platform subdirectory: shared values, Argo wiring, policy, scripts.
  [[ "$f" =~ ^${PLATFORM_DIR}/values/common\.yaml$ ]] \
    || [[ "$f" =~ ^${PLATFORM_DIR}/values/env/.*\.yaml$ ]] \
    || [[ "$f" =~ ^${PLATFORM_DIR}/values/db/.*\.yaml$ ]] \
    || [[ "$f" =~ ^${PLATFORM_DIR}/values/templates/.*$ ]] \
    || [[ "$f" =~ ^${PLATFORM_DIR}/values/canary-overrides.*\.yaml$ ]] \
    || [[ "$f" =~ ^${PLATFORM_DIR}/argo/.*$ ]] \
    || [[ "$f" =~ ^${PLATFORM_DIR}/platform/.*$ ]] \
    || [[ "$f" =~ ^${PLATFORM_DIR}/policy/.*$ ]] \
    || [[ "$f" =~ ^${PLATFORM_DIR}/scripts/.*$ ]] \
    || [[ "$f" =~ ^${PLATFORM_DIR}/bootstrap/.*$ ]] \
    || [[ "$f" =~ ^${PLATFORM_DIR}/CHANGELOG\.md$ ]] \
    || [[ "$f" =~ ^\.github/workflows/.*$ ]] \
    || [[ "$f" =~ ^scripts/.*$ ]] \
    || [[ "$f" =~ ^\.pre-commit-config\.yaml$ ]] \
    || [[ "$f" =~ ^docs/ROLLOUTS\.md$ ]]
}

TENANT_FILES=()
HAS_PLATFORM=false
HAS_OTHER=false

for f in "${CHANGED_FILES[@]}"; do
  if is_tenant_file "$f"; then
    TENANT_FILES+=("$f")
  elif is_platform_file "$f"; then
    HAS_PLATFORM=true
  else
    # Unknown path defaults to safer classification behavior.
    HAS_OTHER=true
  fi
done

# Deduplicate tenant names
declare -A TENANT_SET=()
for tf in "${TENANT_FILES[@]}"; do
  name="${tf##*/tenant-}"
  name="${name%.yaml}"
  TENANT_SET["$name"]=1
done

TENANTS_SORTED=()
for k in "${!TENANT_SET[@]}"; do
  TENANTS_SORTED+=("$k")
done
# Guarded: on an empty array `printf '%s\n'` would emit one blank line and
# mapfile would read it as a single empty tenant, making TENANT_COUNT 1.
if ((${#TENANTS_SORTED[@]} > 0)); then
  mapfile -t TENANTS_SORTED < <(printf '%s\n' "${TENANTS_SORTED[@]}" | sort)
fi

TENANT_COUNT="${#TENANTS_SORTED[@]}"
CHANGED_FILES_COUNT="${#CHANGED_FILES[@]}"
TENANTS_CSV="$(IFS=,; echo "${TENANTS_SORTED[*]}")"

CLASSIFICATION="tenant-additive"
if [[ "$HAS_PLATFORM" == true && "$TENANT_COUNT" -gt 0 ]]; then
  CLASSIFICATION="mixed"
elif [[ "$HAS_PLATFORM" == true || "$HAS_OTHER" == true ]]; then
  CLASSIFICATION="platform"
fi

echo "Changed files (${CHANGED_FILES_COUNT}):"
for f in "${CHANGED_FILES[@]}"; do
  echo " - $f"
done
echo ""
echo "classification=${CLASSIFICATION}"
echo "changed_tenant_count=${TENANT_COUNT}"
echo "changed_tenants=${TENANTS_CSV}"
echo "changed_files_count=${CHANGED_FILES_COUNT}"
