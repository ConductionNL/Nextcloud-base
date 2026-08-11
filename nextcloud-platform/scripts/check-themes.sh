#!/usr/bin/env bash
# SPDX-License-Identifier: EUPL-1.2
# role: tool
#
# nextcloud-platform/scripts/check-themes.sh — toetst tenant-thema's aan de
# twee bronnen die er werkelijk toe doen.
#
# `themeClassname` in een tenant-bestand gaat ongewijzigd door naar
# GATSBY_NL_DESIGN_THEME_CLASSNAME. Een klasse die niet bestaat levert
# stilzwijgend geen thema op — geen foutmelding, geen degraded pod, alleen een
# site zonder huisstijl. Er zijn twee onafhankelijke bronnen:
#
#   1. ConductionNL/conduction-theme — de thema's die Conduction onderhoudt
#      (map `<naam>-design-tokens` → klasse `<naam>-theme`). Leidend, maar het
#      image loopt erop achter: een nieuw thema werkt pas na een image-bump.
#   2. De CSS-bundle in het draaiende image — wat vandaag écht rendert. Bevat
#      ook NL Design System-thema's die niet uit conduction-theme komen.
#
# Geen van beide is op zichzelf de waarheid, daarom rapporteert dit script ze
# naast elkaar in plaats van één verdict te vellen. Daarom is dit ook een
# handmatige audit en geen CI-check: `validate-values.sh` toetst alleen de VORM
# (`<naam>-theme`), want een lijst in CI slaat rood op een thema dat net is
# toegevoegd of nog niet gebundeld.
#
# Writes: read-only
# Idempotent: ja
# Requires: yq, gh (geauthenticeerd), kubectl met clustertoegang
# Style-afwijking: geen
#
# Usage:
#   ./check-themes.sh                          # beide bronnen, hele vloot
#   ./check-themes.sh --namespace epe-accept   # bundle uit die namespace halen
#   ./check-themes.sh --no-cluster             # alleen conduction-theme, geen pod nodig

set -euo pipefail

readonly THEME_REPO="ConductionNL/conduction-theme"
readonly THEME_DIRS=("municipalities" "other" "partnerships" "water-authorities")
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly TENANT_DIR="${SCRIPT_DIR}/../values/tenants"

NAMESPACE="canary-accept"
USE_CLUSTER=1

usage() {
    sed -n '3,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# Thema-klassen uit conduction-theme (map per thema + het conduction-thema zelf)
fetch_repo_themes() {
    local d
    for d in "${THEME_DIRS[@]}"; do
        gh api "repos/${THEME_REPO}/contents/${d}" \
            --jq '.[] | select(.type=="dir") | .name' 2>/dev/null || true
    done
    echo "conduction-design-tokens"
}

# Thema-klassen uit de CSS-bundle van een draaiend frontend-pod
fetch_bundle_themes() {
    local ns="$1"
    local pod
    pod=$(kubectl -n "$ns" get pods -o name 2>/dev/null | grep woo-website | head -1)
    if [[ -z "$pod" ]]; then
        echo "error: geen woo-website-pod in namespace '$ns'" >&2
        return 1
    fi
    kubectl -n "$ns" exec "$pod" -- sh -c \
        "grep -rhoE '[a-z0-9][a-z0-9-]*-theme' /usr/share/nginx/html --include='*.css' 2>/dev/null" \
        | sort -u
}

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --namespace) NAMESPACE="$2"; shift 2 ;;
            --no-cluster) USE_CLUSTER=0; shift ;;
            -h|--help) usage; exit 0 ;;
            *) echo "error: onbekend argument '$1'" >&2; usage >&2; exit 2 ;;
        esac
    done

    local tmp
    tmp=$(mktemp -d)
    # shellcheck disable=SC2064  # tmp nu uitvouwen, niet bij trap-uitvoering
    trap "rm -rf '$tmp'" EXIT

    fetch_repo_themes | sed 's/-design-tokens$/-theme/' | sort -u > "$tmp/repo.txt"
    echo "conduction-theme: $(wc -l < "$tmp/repo.txt") thema's"

    : > "$tmp/bundle.txt"
    if [[ "$USE_CLUSTER" -eq 1 ]]; then
        fetch_bundle_themes "$NAMESPACE" > "$tmp/bundle.txt"
        echo "image-bundle ($NAMESPACE): $(wc -l < "$tmp/bundle.txt") thema's"
        echo
        echo "In conduction-theme maar nog niet gebundeld (werkt pas na image-bump):"
        comm -23 "$tmp/repo.txt" "$tmp/bundle.txt" | sed 's/^/  /'
    fi

    echo
    echo "Tenants met een thema dat in geen van beide bronnen voorkomt:"
    local found=0 f theme in_repo in_bundle
    for f in "$TENANT_DIR"/tenant-*.yaml; do
        theme=$(yq eval '.tenant.frontend.branding.themeClassname // ""' "$f" 2>/dev/null)
        [[ -z "$theme" ]] && continue
        in_repo=$(grep -qxF "$theme" "$tmp/repo.txt" && echo ja || echo nee)
        in_bundle=$(grep -qxF "$theme" "$tmp/bundle.txt" && echo ja || echo nee)
        if [[ "$in_repo" == "nee" && "$in_bundle" == "nee" ]]; then
            printf '  %-40s %s\n' "$(basename "$f")" "$theme"
            found=1
        fi
    done
    [[ "$found" -eq 0 ]] && echo "  (geen)"

    echo
    echo "Tenants met een gebundeld thema dat niet uit conduction-theme komt:"
    found=0
    for f in "$TENANT_DIR"/tenant-*.yaml; do
        theme=$(yq eval '.tenant.frontend.branding.themeClassname // ""' "$f" 2>/dev/null)
        [[ -z "$theme" ]] && continue
        if ! grep -qxF "$theme" "$tmp/repo.txt" && grep -qxF "$theme" "$tmp/bundle.txt"; then
            printf '  %-40s %s\n' "$(basename "$f")" "$theme"
            found=1
        fi
    done
    [[ "$found" -eq 0 ]] && echo "  (geen)"
}

main "$@"
