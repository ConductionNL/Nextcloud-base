#!/usr/bin/env bash
# SPDX-License-Identifier: EUPL-1.2
# role: tool
#
# nextcloud-platform/tests/render-extra-hosts.sh — render-check voor
# tenant.extraHostnames.
#
# De fixture-suite (run-tests.sh) toetst de validator; deze check toetst wat de
# ApplicationSet er daarna van maakt. Hij rendert twee fixtures zoals Argo het
# doet: eerst het inline values-blok van de ApplicationSet met het tenantbestand
# als parameters, daarna `helm template` met chart 8.9.0 en dezelfde
# valueFiles-volgorde. Daarna moet gelden:
#
#   tenant-extra-hostnames-apex-met-optin (voorbeeld.nl + www.voorbeeld.nl)
#     - Ingress nextcloud-extra-hosts-apex bestaat, met alleen voorbeeld.nl en
#       hsts-include-subdomains "false";
#     - Ingress nextcloud-extra-hosts heeft alleen www.voorbeeld.nl en dezelfde
#       hsts-include-subdomains als de hoofd-Ingress;
#     - de hoofd-Ingress houdt de waarde uit values/common.yaml (de apex-merge
#       mag de gedeelde values niet muteren);
#     - beide extra Ingresses houden de cert-manager-issuer van de hoofd-Ingress.
#   tenant-extra-hostnames-geldig (geen apex)
#     - geen Ingress nextcloud-extra-hosts-apex.
#
# Argo rendert het values-blok met Go text/template en sprig. Helm doet dat
# ook, dus deze check gebruikt helm als template-engine: het blok gaat als
# template in een wegwerp-chart, met het tenantbestand als values. Twee
# verschillen met Argo, en hoe die gedekt zijn:
#   - Argo draait met missingkey=default, helm met missingkey=zero. Daardoor
#     breekt `.tenant.features.appapi` in helm als `features` ontbreekt, en in
#     Argo niet. De check zet daarom elke tussenliggende map die het blok leest
#     (afgeleid uit de `.tenant.a.b`-paden in het blok zelf) op `{}` als hij
#     ontbreekt; een ontbrekende sleutel in een lege map geeft in beide engines
#     dezelfde lege waarde.
#   - Helm heeft een paar functies meer (include, tpl, required); het blok
#     gebruikt die niet.
# Gemeten 2026-10-14: voor alle 89 tenantbestanden en de extraHostnames-fixtures
# gaf deze engine hetzelfde values-blok als een Go-emulatie van Argo, byte voor
# byte op de afsluitende lege regel na (text/template + sprig, missingkey=default).
#
# Writes: read-only (schrijft alleen in een eigen mktemp-map)
# Idempotent: ja
# Requires: bash, helm, yq; netwerk naar https://nextcloud.github.io/helm/,
#           tenzij NEXTCLOUD_CHART naar een uitgepakte chart wijst
#
# Usage:
#   nextcloud-platform/tests/render-extra-hosts.sh
#   NEXTCLOUD_CHART=/pad/naar/nextcloud nextcloud-platform/tests/render-extra-hosts.sh

set -euo pipefail
shopt -s inherit_errexit

HERE="$(cd "$(dirname "$0")" && pwd)"
PLATFORM="$(cd "${HERE}/.." && pwd)"
VALUES="${PLATFORM}/values"
APPSET="${PLATFORM}/argo/applicationsets/nextcloud-tenants.yaml"
CASES="${HERE}/cases"
CHART_VERSION="8.9.0"
HSTS_SUB="nginx.ingress.kubernetes.io/hsts-include-subdomains"
ISSUER="cert-manager.io/cluster-issuer"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fails=0
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }

chart="${NEXTCLOUD_CHART:-}"
if [[ -z "$chart" ]]; then
    helm pull nextcloud --repo https://nextcloud.github.io/helm/ \
        --version "$CHART_VERSION" --untar --untardir "$TMP_DIR/chart" >/dev/null
    chart="$TMP_DIR/chart/nextcloud"
fi

# Wegwerp-chart met het values-blok van de ApplicationSet als enige template.
engine="$TMP_DIR/engine"
mkdir -p "$engine/templates"
printf 'apiVersion: v2\nname: appset-values\nversion: 0.0.0\n' >"$engine/Chart.yaml"
{
    echo '{{- with .Values }}'
    yq -r '.spec.template.spec.sources[0].helm.values' "$APPSET"
    echo '{{- end }}'
} >"$engine/templates/values.yaml"

# Tussenliggende maps die het blok leest, zoals `.tenant.apps.versions` uit
# `.tenant.apps.versions.opencatalogi`. Elk wordt `{}` als hij ontbreekt.
fill_expr="$(grep -oE '\.tenant(\.[A-Za-z0-9_]+){2,}' "$engine/templates/values.yaml" \
    | sed -E 's/\.[A-Za-z0-9_]+$//' \
    | awk -F. '{p=".tenant"; for (i=3; i<=NF; i++) {p=p"."$i; print p}}' \
    | sort -u | awk '{printf "%s%s |= (. // {})", (NR>1 ? " | " : ""), $0}')"

# Usage: appset_values <tenantbestand> <uitvoer>
appset_values() {
    yq "${fill_expr:-.}" "$1" >"$2.params.yaml"
    helm template x "$engine" -f "$2.params.yaml" --show-only templates/values.yaml \
        | sed '1,2d' >"$2"
}

# Usage: render <fixture-naam>  → pad naar de gerenderde manifests
render() {
    local name="$1" tenant="${CASES}/$1.yaml" out="$TMP_DIR/$1"
    local env db
    appset_values "$tenant" "$out.values.yaml"
    env="$(yq -r '.tenant.environment' "$tenant")"
    db="$(yq -r '.tenant.dbType // "postgres"' "$tenant")"
    helm template nextcloud "$chart" \
        -f "${VALUES}/common.yaml" -f "${VALUES}/env/${env}.yaml" -f "${VALUES}/db/${db}.yaml" \
        -f "$tenant" -f "$out.values.yaml" \
        --namespace "$(yq -r '.tenant.name' "$tenant")" >"$out.manifests.yaml"
    echo "$out.manifests.yaml"
}

# Usage: ingress <manifests> <naam> <yq-expressie op die Ingress>
ingress() {
    # yq geeft per niet-passend document een lege regel; die weg.
    yq -r "select(.kind == \"Ingress\" and .metadata.name == \"$2\") | $3" "$1" | sed '/^$/d'
}

expected_main="$(yq -r ".ingress.annotations.\"${HSTS_SUB}\"" "${VALUES}/common.yaml")"
expected_issuer="$(yq -r ".ingress.annotations.\"${ISSUER}\"" "${VALUES}/common.yaml")"

# Alleen voor het meten van de engine tegen Argo: print het values-blok van
# één tenantbestand en stop.
if [[ "${1:-}" == "--values" ]]; then
    appset_values "$2" "$TMP_DIR/one"
    cat "$TMP_DIR/one"
    exit 0
fi

m="$(render tenant-extra-hostnames-apex-met-optin)"

got="$(ingress "$m" nextcloud-extra-hosts-apex '[.spec.rules[].host] | join(",")')"
[[ "$got" == "voorbeeld.nl" ]] || fail "apex-Ingress hosts: verwacht 'voorbeeld.nl', kreeg '$got'"
got="$(ingress "$m" nextcloud-extra-hosts-apex "[.spec.tls[].hosts[]] | join(\",\")")"
[[ "$got" == "voorbeeld.nl" ]] || fail "apex-Ingress tls-hosts: verwacht 'voorbeeld.nl', kreeg '$got'"
got="$(ingress "$m" nextcloud-extra-hosts-apex ".metadata.annotations.\"${HSTS_SUB}\"")"
[[ "$got" == "false" ]] || fail "apex-Ingress ${HSTS_SUB}: verwacht 'false', kreeg '$got'"
got="$(ingress "$m" nextcloud-extra-hosts-apex ".metadata.annotations.\"${ISSUER}\"")"
[[ "$got" == "$expected_issuer" ]] || fail "apex-Ingress ${ISSUER}: verwacht '$expected_issuer', kreeg '$got'"

got="$(ingress "$m" nextcloud-extra-hosts '[.spec.rules[].host] | join(",")')"
[[ "$got" == "www.voorbeeld.nl" ]] || fail "extra Ingress hosts: verwacht 'www.voorbeeld.nl', kreeg '$got'"
got="$(ingress "$m" nextcloud-extra-hosts ".metadata.annotations.\"${HSTS_SUB}\"")"
[[ "$got" == "$expected_main" ]] || fail "extra Ingress ${HSTS_SUB}: verwacht '$expected_main', kreeg '$got'"
got="$(ingress "$m" nextcloud-extra-hosts ".metadata.annotations.\"${ISSUER}\"")"
[[ "$got" == "$expected_issuer" ]] || fail "extra Ingress ${ISSUER}: verwacht '$expected_issuer', kreeg '$got'"

got="$(ingress "$m" nextcloud ".metadata.annotations.\"${HSTS_SUB}\"")"
[[ "$got" == "$expected_main" ]] || fail "hoofd-Ingress ${HSTS_SUB}: verwacht '$expected_main', kreeg '$got'"

m="$(render tenant-extra-hostnames-geldig)"
got="$(ingress "$m" nextcloud-extra-hosts-apex '.metadata.name')"
[[ -z "$got" ]] || fail "geen apex-host, toch een Ingress nextcloud-extra-hosts-apex"
got="$(ingress "$m" nextcloud-extra-hosts '[.spec.rules[].host] | join(",")')"
[[ "$got" == "portaal.voorbeeld.nl,www.voorbeeld.nl" ]] \
    || fail "extra Ingress hosts (geldig): verwacht 'portaal.voorbeeld.nl,www.voorbeeld.nl', kreeg '$got'"

if [[ $fails -gt 0 ]]; then
    echo "render-extra-hosts: $fails fout(en)" >&2
    exit 1
fi
echo "render-extra-hosts OK"
