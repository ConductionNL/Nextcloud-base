#!/usr/bin/env bash
#
# argocd-sync.sh - Trigger Argo CD refresh + sync using kubectl (no argocd CLI)
#
# Why:
#   Waiting for Argo to notice Git changes can be annoying. This script forces a
#   hard refresh and starts a sync for one (or many) Argo CD Applications.
#
# Requirements:
#   - kubectl configured to talk to the cluster that runs Argo CD
#   - Argo CD Application CRD installed (applications.argoproj.io)
#
# Usage:
#   ./scripts/argocd-sync.sh <tenant|app> [--wait] [--timeout 600]
#   ./scripts/argocd-sync.sh <tenant|app> --prune
#   ./scripts/argocd-sync.sh --pattern "nc-*-prod" --wait
#
# Notes:
#   - If you pass a tenant name (e.g. "zuiddrecht-accept"), app name is assumed
#     to be "nc-<tenant>".
#   - This does NOT force delete resources; prune is opt-in via --prune.
#

set -euo pipefail

ARGOCD_NS="argocd"
PATTERN=""
TARGET=""
PRUNE=false
WAIT=false
TIMEOUT_SECONDS=600
REFRESH_APPSET=false
APPSET_NAME="nextcloud-tenants"
WAIT_FOR_APP_SECONDS=120

usage() {
  echo "Usage:"
  echo "  $0 <tenant|app> [--wait] [--timeout <seconds>] [--prune] [--argocd-ns <ns>]"
  echo "     [--refresh-appset] [--appset-name <name>] [--wait-for-app <seconds>]"
  echo "  $0 --pattern \"nc-*-prod\" [--wait] [--timeout <seconds>] [--prune] [--argocd-ns <ns>]"
  echo "     [--refresh-appset] [--appset-name <name>] [--wait-for-app <seconds>]"
  echo ""
  echo "Examples:"
  echo "  $0 zuiddrecht-accept --wait"
  echo "  $0 nc-zuiddrecht-accept"
  echo "  $0 noordwijk-accept --refresh-appset --wait-for-app 180 --wait"
  echo "  $0 --pattern \"nc-*-test\" --wait"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --argocd-ns)
      ARGOCD_NS="$2"
      shift 2
      ;;
    --pattern)
      PATTERN="$2"
      shift 2
      ;;
    --refresh-appset)
      REFRESH_APPSET=true
      shift
      ;;
    --appset-name)
      APPSET_NAME="$2"
      shift 2
      ;;
    --wait-for-app)
      WAIT_FOR_APP_SECONDS="$2"
      shift 2
      ;;
    --prune)
      PRUNE=true
      shift
      ;;
    --wait)
      WAIT=true
      shift
      ;;
    --timeout)
      TIMEOUT_SECONDS="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      if [[ -z "$TARGET" ]]; then
        TARGET="$1"
        shift
      else
        echo "Unknown arg: $1" >&2
        usage >&2
        exit 1
      fi
      ;;
  esac
done

if [[ -z "$PATTERN" && -z "$TARGET" ]]; then
  usage >&2
  exit 1
fi

require_kubectl() {
  if ! command -v kubectl >/dev/null 2>&1; then
    echo "kubectl not found in PATH" >&2
    exit 1
  fi
}

app_exists() {
  local app="$1"
  kubectl -n "$ARGOCD_NS" get application "$app" >/dev/null 2>&1
}

resolve_app_name() {
  local input="$1"
  if [[ "$input" == nc-* ]]; then
    echo "$input"
    return 0
  fi
  echo "nc-$input"
}

list_apps_by_pattern() {
  local pattern="$1"
  # Output application names (no "application/" prefix)
  kubectl -n "$ARGOCD_NS" get applications -o name 2>/dev/null \
    | sed 's#^application\.argoproj\.io/##' \
    | while read -r app; do
        [[ -z "$app" ]] && continue
        if [[ "$app" == $pattern ]]; then
          echo "$app"
        fi
      done
}

refresh_applicationset() {
  local appset="$1"
  echo "Refreshing ApplicationSet $appset..."
  kubectl -n "$ARGOCD_NS" annotate applicationset "$appset" \
    argocd.argoproj.io/application-set-refresh=true \
    --overwrite >/dev/null
}

wait_for_app_exists() {
  local app="$1"
  local timeout="$2"
  local start
  start="$(date +%s)"

  while true; do
    if app_exists "$app"; then
      return 0
    fi

    local now elapsed
    now="$(date +%s)"
    elapsed=$((now - start))
    if [[ "$timeout" -gt 0 && "$elapsed" -ge "$timeout" ]]; then
      return 1
    fi

    sleep 3
  done
}

wait_for_pattern_matches() {
  local pattern="$1"
  local timeout="$2"
  local start
  start="$(date +%s)"

  while true; do
    local matches
    matches="$(list_apps_by_pattern "$pattern" || true)"
    if [[ -n "$matches" ]]; then
      echo "$matches"
      return 0
    fi

    local now elapsed
    now="$(date +%s)"
    elapsed=$((now - start))
    if [[ "$timeout" -gt 0 && "$elapsed" -ge "$timeout" ]]; then
      return 1
    fi

    sleep 3
  done
}

hard_refresh() {
  local app="$1"
  kubectl -n "$ARGOCD_NS" annotate application "$app" \
    argocd.argoproj.io/refresh=hard \
    --overwrite >/dev/null
}

trigger_sync() {
  local app="$1"
  local prune_json="false"
  if [[ "$PRUNE" == "true" ]]; then
    prune_json="true"
  fi

  # Setting .operation.sync is enough to trigger a sync. We intentionally do NOT
  # set revision(s) here; Argo will use the application's configured sources.
  kubectl -n "$ARGOCD_NS" patch application "$app" --type merge \
    -p "{\"operation\":{\"sync\":{\"prune\":${prune_json}}}}" >/dev/null
}

wait_for_sync() {
  local app="$1"
  local timeout="$2"
  local start
  start="$(date +%s)"

  while true; do
    local now elapsed phase sync health
    now="$(date +%s)"
    elapsed=$((now - start))

    phase="$(kubectl -n "$ARGOCD_NS" get application "$app" -o jsonpath='{.status.operationState.phase}' 2>/dev/null || true)"
    sync="$(kubectl -n "$ARGOCD_NS" get application "$app" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
    health="$(kubectl -n "$ARGOCD_NS" get application "$app" -o jsonpath='{.status.health.status}' 2>/dev/null || true)"

    echo "[$app] phase=${phase:-?} sync=${sync:-?} health=${health:-?} (${elapsed}s)"

    if [[ "$sync" == "Synced" && "$health" == "Healthy" ]]; then
      return 0
    fi

    if [[ "$timeout" -gt 0 && "$elapsed" -ge "$timeout" ]]; then
      echo "Timed out waiting for $app after ${timeout}s" >&2
      return 1
    fi

    sleep 5
  done
}

require_kubectl

if [[ "$REFRESH_APPSET" == "true" ]]; then
  refresh_applicationset "$APPSET_NAME"
fi

APPS=()
if [[ -n "$PATTERN" ]]; then
  MATCHES=""
  if [[ "$REFRESH_APPSET" == "true" ]]; then
    if ! MATCHES="$(wait_for_pattern_matches "$PATTERN" "$WAIT_FOR_APP_SECONDS")"; then
      echo "No applications match pattern after waiting ${WAIT_FOR_APP_SECONDS}s: $PATTERN (namespace: $ARGOCD_NS)" >&2
      exit 1
    fi
  else
    MATCHES="$(list_apps_by_pattern "$PATTERN" || true)"
  fi

  while read -r app; do
    [[ -n "$app" ]] && APPS+=("$app")
  done <<< "$MATCHES"

  if [[ ${#APPS[@]} -eq 0 ]]; then
    echo "No applications match pattern: $PATTERN (namespace: $ARGOCD_NS)" >&2
    exit 1
  fi
else
  APP="$(resolve_app_name "$TARGET")"
  if ! app_exists "$APP"; then
    if [[ "$REFRESH_APPSET" == "true" ]]; then
      echo "Waiting for application to appear: $APP (${WAIT_FOR_APP_SECONDS}s max)..."
      if ! wait_for_app_exists "$APP" "$WAIT_FOR_APP_SECONDS"; then
        echo "Application not found after waiting ${WAIT_FOR_APP_SECONDS}s: $APP (namespace: $ARGOCD_NS)" >&2
        exit 1
      fi
    else
      echo "Application not found: $APP (namespace: $ARGOCD_NS)" >&2
      echo "Tip: add --refresh-appset to force generation for newly added tenants." >&2
      exit 1
    fi
  fi
  APPS+=("$APP")
fi

for app in "${APPS[@]}"; do
  echo "Refreshing $app..."
  hard_refresh "$app"
  echo "Syncing $app (prune=$PRUNE)..."
  trigger_sync "$app"
done

if [[ "$WAIT" == "true" ]]; then
  for app in "${APPS[@]}"; do
    wait_for_sync "$app" "$TIMEOUT_SECONDS"
  done
fi

