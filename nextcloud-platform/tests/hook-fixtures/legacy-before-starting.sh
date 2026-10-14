#!/bin/bash
# Bevroren referentie: de before-starting-hook uit nextcloud-platform/values/common.yaml
# op main 119496b, vóór de generieke app-pins. run-hook-tests.sh draait deze naast
# de huidige hook en eist gelijk gedrag voor tenants die alleen de drie oude pins
# gebruiken. Niet aanpassen: het is het meetpunt, geen code die draait.
set -o pipefail

LOG="/var/www/html/data/conduction-apps.log"
STATE_FILE="/var/www/html/data/.conduction-apps-state"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG" 2>&1; }

if [ "${CONDUCTION_APPS_ENABLED:-true}" != "true" ]; then log "Conduction apps disabled (skipping)"; exit 0; fi
if [ ! -f /var/www/html/config/config.php ]; then exit 0; fi

log "=== Conduction Apps Bootstrap Started (before-starting) ==="

APPS="${CONDUCTION_APPS:-opencatalogi openconnector openregister}"
if [ -z "$APPS" ]; then
  log "CONDUCTION_APPS is empty; skipping"
  exit 0
fi

DESIRED_STATE="APPS=${APPS};OPENCATALOGI_VERSION=${OPENCATALOGI_VERSION-};OPENCONNECTOR_VERSION=${OPENCONNECTOR_VERSION-};OPENREGISTER_VERSION=${OPENREGISTER_VERSION-}"
CURRENT_STATE="$(cat "$STATE_FILE" 2>/dev/null || true)"
if [ "$CURRENT_STATE" = "$DESIRED_STATE" ]; then
  log "Conduction apps already in desired state (skip)"
  exit 0
fi

install_app() {
  APP_NAME=$1
  VERSION_VAR=$2
  VERSION="${!VERSION_VAR-}"

  if [ -n "$VERSION" ]; then
    log "Installing $APP_NAME v$VERSION (pinned)..."

    if [ -d "/var/www/html/apps/$APP_NAME" ]; then
      log "Removing bundled $APP_NAME from /apps/ to use pinned version"
      rm -rf "/var/www/html/apps/$APP_NAME"
    fi

    URL="https://github.com/ConductionNL/$APP_NAME/releases/download/v$VERSION/$APP_NAME-$VERSION.tar.gz"
    mkdir -p /var/www/html/custom_apps

    if curl -fsSL "$URL" -o /tmp/$APP_NAME.tar.gz 2>>"$LOG"; then
      rm -rf "/var/www/html/custom_apps/$APP_NAME" 2>/dev/null
      tar -xzf /tmp/$APP_NAME.tar.gz -C /var/www/html/custom_apps/ 2>>"$LOG"
      rm /tmp/$APP_NAME.tar.gz
      chown -R www-data:www-data "/var/www/html/custom_apps/$APP_NAME"
      log "$APP_NAME v$VERSION installed to custom_apps"
    else
      log "ERROR: GitHub download failed for $URL"
      return 0
    fi
  else
    if php occ app:list 2>/dev/null | grep -q -- "- $APP_NAME:"; then
      return 0
    fi
    log "Installing $APP_NAME (latest from app store)..."
    php occ app:install "$APP_NAME" 2>>"$LOG" || true
  fi

  php occ app:enable "$APP_NAME" 2>>"$LOG" || true

  if [ -n "$VERSION" ] && [ -d "/var/www/html/apps/$APP_NAME" ]; then
    rm -rf "/var/www/html/apps/$APP_NAME"
    php occ app:enable "$APP_NAME" 2>>"$LOG" || true
  fi

  INSTALLED_VER=$(php occ app:list 2>/dev/null | grep -- "- $APP_NAME:" | sed 's/.*: //')
  log "$APP_NAME enabled (version: $INSTALLED_VER)"
}

for app in $APPS; do
  case "$app" in
    opencatalogi)  install_app "opencatalogi"  "OPENCATALOGI_VERSION" ;;
    openconnector) install_app "openconnector" "OPENCONNECTOR_VERSION" ;;
    openregister)  install_app "openregister"  "OPENREGISTER_VERSION" ;;
    *)
      log "Installing $app (app store, no pin support)..."
      php occ app:install "$app" 2>>"$LOG" || true
      php occ app:enable "$app" 2>>"$LOG" || true
      ;;
  esac
done

php occ db:add-missing-indices 2>>"$LOG" || true
php occ maintenance:repair --include-expensive 2>>"$LOG" || true

echo "$DESIRED_STATE" > "$STATE_FILE"
log "=== Conduction Apps Bootstrap Complete ==="

