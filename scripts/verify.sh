#!/usr/bin/env bash
# SPDX-License-Identifier: EUPL-1.2
# role: tool
#
# scripts/verify.sh — snelle functionele verificatie (pre-push gate).
#
# Draait de bestaande platform-checks: tenant-values-validatie (vereiste
# velden, verboden velden, patronen) en de smoke-checks (chart-renders), plus
# twee doc-asserties: elke probe-host hoort bij een tenantbestand, en elk
# script in nextcloud-platform/scripts/ staat in docs/index.md.
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

# ---------------------------------------------------------------------------
# Doc-assertion 1 (docs-claims): elke host in de probe-lijsten hoort bij een
# bestaand tenantbestand.
#
# Waarom bewaakt: promote-tenant-changes.yaml leest beide lijsten en eist dat
# ALLE hosts erin gezond zijn. Faalt er één, dan draait de workflow de promotie
# terug met --force-with-lease op `release` en `release-accept`. Een tenant
# verwijderen zonder zijn host uit de lijst te halen breekt de promotieketen
# dus voor de hele vloot, niet alleen voor die tenant. docs/REMOVING-TENANT.md
# stap 2 belooft dat je dit eerst doet; deze assertie is de tanden onder die
# belofte.
#
# De host is NIET de tenantnaam. Deze afleiding spiegelt de ingress-host uit
# nextcloud-platform/argo/applicationsets/nextcloud-tenants.yaml (het `values:`-
# blok): omgeving is het achtervoegsel van tenant.name (accept|test|prod), en
# valt daarop terug naar tenant.environment; prod krijgt geen omgevingslabel in
# de host; tenant.hostname overschrijft het geheel. Wijzigt die template, dan
# moet deze functie mee.
# ---------------------------------------------------------------------------
tenant_hosts() {
  local name environment override org omgeving
  while IFS=$'\t' read -r name environment override; do
    [[ -n "${name}" ]] || continue
    if [[ -n "${override}" && "${override}" != "null" ]]; then
      printf '%s\n' "${override}"
      continue
    fi
    case "${name}" in
      *-accept) omgeving="accept" ;;
      *-test) omgeving="test" ;;
      *-prod) omgeving="prod" ;;
      *) omgeving="${environment}" ;;
    esac
    org="${name%"-${omgeving}"}"
    if [[ "${omgeving}" == "prod" ]]; then
      printf '%s.commonground.nu\n' "${org}"
    else
      printf '%s.%s.commonground.nu\n' "${org}" "${omgeving}"
    fi
  done < <(yq -r '[.tenant.name, .tenant.environment, (.tenant.hostname // "")] | @tsv' \
    nextcloud-platform/values/tenants/tenant-*.yaml)
}

readonly PROBE_LISTS=(
  .github/probe-hosts-accept.txt
  .github/probe-hosts-live.txt
)

mapfile -t claimed_hosts < <(tenant_hosts | sort -u)
if [[ "${#claimed_hosts[@]}" -eq 0 ]]; then
  echo "doc-assertion FAALT: geen enkele tenant-host afgeleid — is yq stuk?" >&2
  exit 1
fi

orphan_hosts=()
probe_count=0
for probe_list in "${PROBE_LISTS[@]}"; do
  while IFS= read -r line; do
    line="${line%%#*}"
    line="${line//[[:space:]]/}"
    [[ -n "${line}" ]] || continue
    probe_count=$((probe_count + 1))
    if ! printf '%s\n' "${claimed_hosts[@]}" | grep -qxF "${line}"; then
      orphan_hosts+=("${line} (${probe_list})")
    fi
  done <"${probe_list}"
done

if [[ "${#orphan_hosts[@]}" -gt 0 ]]; then
  echo "doc-assertion FAALT: probe-host zonder tenantbestand:" >&2
  printf '  %s\n' "${orphan_hosts[@]}" >&2
  echo "  De promotie in .github/workflows/promote-tenant-changes.yaml eist dat" >&2
  echo "  ELKE host in deze lijsten 200 + \"installed\":true geeft en draait" >&2
  echo "  anders release en release-accept terug. Een host zonder tenant blijft" >&2
  echo "  dus eeuwig falen en blokkeert de keten voor de hele vloot." >&2
  echo "  Haal de host uit de lijst (docs/REMOVING-TENANT.md stap 2) of zet het" >&2
  echo "  tenantbestand terug." >&2
  exit 1
fi
echo "doc-assertion OK (${probe_count} probe-hosts gedekt door een tenantbestand)"

# ---------------------------------------------------------------------------
# Doc-assertion 2 (docs-claims): elk script in nextcloud-platform/scripts/ heeft
# een regel in docs/index.md.
#
# Waarom bewaakt: docs/index.md is de enige ingang tot deze repo. Een script dat
# er niet in staat, bestaat voor een lezer niet — en wordt dan naast de
# procedure om opnieuw uitgevonden. Patroon gelijk aan cluster-config.
# ---------------------------------------------------------------------------
undocumented_scripts=()
script_count=0
for script_path in nextcloud-platform/scripts/*.sh; do
  script_name="$(basename "${script_path}")"
  script_count=$((script_count + 1))
  grep -qF "${script_name}" docs/index.md || undocumented_scripts+=("${script_name}")
done

if [[ "${#undocumented_scripts[@]}" -gt 0 ]]; then
  echo "doc-assertion FAALT: scripts zonder rij in docs/index.md: ${undocumented_scripts[*]}" >&2
  exit 1
fi
echo "doc-assertion OK (${script_count} scripts gedekt in de index)"

# Fixture-tests voor validate-values.sh. De validator draait hierboven al over de
# echte vloot, maar dat bewijst alleen dat de hUIDIGE bestanden schoon zijn — niet
# dat een check nog aanslaat op een fout die niemand meer maakt. Deze suite houdt
# elke check aan een goed- én een foutgeval.
nextcloud-platform/tests/run-tests.sh >/dev/null
echo "validator-tests OK"

echo "verify: OK"
