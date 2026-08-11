#!/usr/bin/env bash
# SPDX-License-Identifier: EUPL-1.2
# role: tool
#
# nextcloud-platform/tests/run-tests.sh — fixture-tests voor validate-values.sh.
#
# Elke test is een paar bestanden in `cases/`:
#
#   <naam>.yaml    een compleet tenant-bestand dat precies één ding fout (of
#                  goed) doet — al het overige is geldig, zodat een fout
#                  ondubbelzinnig aan het geteste veld toe te schrijven is.
#   <naam>.expect  óf de regel `PASS`, óf één of meer deelstrings die in de
#                  foutuitvoer moeten voorkomen (één per regel, allemaal
#                  vereist).
#
# Waarom deelstrings en geen exacte uitvoer: de foutmeldingen bevatten paden en
# allowlists die legitiem meebewegen. Vastpinnen op de exacte tekst maakt de
# suite broos zonder iets extra's te vangen. Vastpinnen op de kern van de
# melding vangt wél dat de juiste check aansloeg.
#
# Een fixture die per ongeluk op een ANDERE check faalt dan bedoeld wordt zo
# ook gevangen: de verwachte deelstring komt dan niet voor.
#
# Writes: read-only (schrijft alleen in een eigen mktemp-map)
# Idempotent: ja
# Requires: bash, yq (via validate-values.sh)
#
# Usage:
#   ./run-tests.sh                      # alle cases
#   ./run-tests.sh frontend-tag         # alleen cases waarvan de naam dit bevat
#   VERBOSE=1 ./run-tests.sh            # toon de volledige uitvoer per case

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly CASES_DIR="${SCRIPT_DIR}/cases"
readonly VALIDATOR="${SCRIPT_DIR}/../scripts/validate-values.sh"

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly NC='\033[0m'

PASSED=0
FAILED=0

log_pass() { printf "${GREEN}PASS${NC} %s\n" "$1"; }
log_fail() { printf "${RED}FAIL${NC} %s\n" "$1" >&2; }

# Draai de validator op één fixture en toets de uitvoer aan .expect
run_case() {
    local yaml="$1"
    local name expect output rc
    name="$(basename "$yaml" .yaml)"
    expect="${CASES_DIR}/${name}.expect"

    if [[ ! -f "$expect" ]]; then
        log_fail "$name — geen .expect-bestand"
        FAILED=$((FAILED + 1))
        return
    fi

    # validate-values.sh geeft non-zero bij fouten; dat is hier data, geen crash.
    set +e
    output="$(bash "$VALIDATOR" "$yaml" 2>&1)"
    rc=$?
    set -e
    # ANSI-kleuren eruit, anders matchen de deelstrings niet
    output="$(printf '%s' "$output" | sed 's/\x1b\[[0-9;]*m//g')"

    [[ -n "${VERBOSE:-}" ]] && printf -- '--- %s (rc=%s)\n%s\n' "$name" "$rc" "$output"

    if [[ "$(head -1 "$expect")" == "PASS" ]]; then
        if [[ $rc -eq 0 ]]; then
            log_pass "$name"
            PASSED=$((PASSED + 1))
        else
            log_fail "$name — verwachtte geldig, kreeg fouten:"
            printf '%s\n' "$output" | grep -E '^ERROR' >&2 || true
            FAILED=$((FAILED + 1))
        fi
        return
    fi

    if [[ $rc -eq 0 ]]; then
        log_fail "$name — verwachtte een fout, maar de validatie slaagde"
        FAILED=$((FAILED + 1))
        return
    fi

    local missing=()
    local needle
    while IFS= read -r needle; do
        [[ -z "$needle" ]] && continue
        grep -qF -- "$needle" <<<"$output" || missing+=("$needle")
    done <"$expect"

    if [[ ${#missing[@]} -eq 0 ]]; then
        log_pass "$name"
        PASSED=$((PASSED + 1))
    else
        log_fail "$name — foutmelding mist:"
        printf '    %s\n' "${missing[@]}" >&2
        printf '  werkelijke uitvoer:\n' >&2
        printf '%s\n' "$output" | grep -E '^ERROR' | sed 's/^/    /' >&2 || true
        FAILED=$((FAILED + 1))
    fi
}

main() {
    local filter="${1:-}"

    if [[ ! -x "$VALIDATOR" ]] && [[ ! -f "$VALIDATOR" ]]; then
        echo "error: validator niet gevonden op $VALIDATOR" >&2
        exit 1
    fi

    local yaml
    for yaml in "${CASES_DIR}"/*.yaml; do
        [[ -e "$yaml" ]] || continue
        if [[ -n "$filter" ]] && [[ "$(basename "$yaml")" != *"$filter"* ]]; then
            continue
        fi
        run_case "$yaml"
    done

    echo
    echo "tests: ${PASSED} geslaagd, ${FAILED} gefaald"
    [[ $FAILED -eq 0 ]]
}

main "$@"
