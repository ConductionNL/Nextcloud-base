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

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

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
  [[ "$f" =~ ^values/tenants/tenant-.*\.yaml$ ]]
}

is_platform_file() {
  local f="$1"
  [[ "$f" =~ ^values/common\.yaml$ ]] \
    || [[ "$f" =~ ^values/env/.*\.yaml$ ]] \
    || [[ "$f" =~ ^values/db/.*\.yaml$ ]] \
    || [[ "$f" =~ ^values/templates/.*$ ]] \
    || [[ "$f" =~ ^argo/applicationsets/.*$ ]] \
    || [[ "$f" =~ ^argo/projects/.*$ ]] \
    || [[ "$f" =~ ^platform/.*$ ]] \
    || [[ "$f" =~ ^\.github/workflows/.*$ ]] \
    || [[ "$f" =~ ^scripts/.*$ ]] \
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
IFS=$'\n' TENANTS_SORTED=($(sort <<<"${TENANTS_SORTED[*]}"))
unset IFS

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
