#!/usr/bin/env bash
# SPDX-License-Identifier: EUPL-1.2
# role: tool
#
# nextcloud-platform/scripts/collect-changelog.sh — voegt de fragmenten uit
# changelog.d/ samen onder `## [Unreleased]` in CHANGELOG.md.
#
# Het fragment-patroon bestaat omdat elke PR anders op dezelfde regel van
# CHANGELOG.md schrijft, waardoor iedere merge alle andere openstaande PR's brak.
# Dit script zet die wachtruimte weer om in de canonieke historie. Draai het als
# losse commit, niet in een PR die ook code wijzigt — dan is er niets om over te
# conflicteren.
#
# Sorteert op bestandsnaam, dus het PR-nummer voorin bepaalt de volgorde.
#
# Writes: CHANGELOG.md, en verwijdert changelog.d/*.md (behalve README.md)
# Idempotent: ja in de zin dat een tweede run zonder fragmenten niets doet
# Requires: bash, git (alleen voor --check)
#
# Usage:
#   ./collect-changelog.sh                 # voeg samen en verwijder de fragmenten
#   ./collect-changelog.sh --dry-run       # toon wat er zou gebeuren
#   ./collect-changelog.sh --check         # exit 1 als er fragmenten open staan

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly REPO_ROOT
readonly FRAGMENT_DIR="${REPO_ROOT}/changelog.d"
readonly CHANGELOG="${REPO_ROOT}/CHANGELOG.md"
readonly ANCHOR="## [Unreleased]"

usage() {
  echo "usage: $0 [--dry-run|--check]" >&2
  exit 2
}

list_fragments() {
  # README.md is de uitleg, geen fragment.
  find "${FRAGMENT_DIR}" -maxdepth 1 -name '*.md' ! -name 'README.md' \
    -type f | sort
}

main() {
  local mode="collect"
  case "${1:-}" in
    "") ;;
    --dry-run) mode="dry-run" ;;
    --check) mode="check" ;;
    *) usage ;;
  esac

  [[ -f "${CHANGELOG}" ]] || {
    echo "error: ${CHANGELOG} bestaat niet" >&2
    exit 1
  }
  grep -qF "${ANCHOR}" "${CHANGELOG}" || {
    echo "error: anker '${ANCHOR}' niet gevonden in CHANGELOG.md" >&2
    exit 1
  }

  local -a fragments=()
  mapfile -t fragments < <(list_fragments)

  if [[ "${#fragments[@]}" -eq 0 ]]; then
    echo "Geen fragmenten in changelog.d/."
    exit 0
  fi

  echo "Fragmenten (${#fragments[@]}):"
  local f
  for f in "${fragments[@]}"; do
    echo "  $(basename "${f}")"
  done

  if [[ "${mode}" == "check" ]]; then
    echo "check: er staan ${#fragments[@]} fragmenten open" >&2
    exit 1
  fi
  if [[ "${mode}" == "dry-run" ]]; then
    echo "dry-run: CHANGELOG.md niet gewijzigd, fragmenten niet verwijderd."
    exit 0
  fi

  local tmp
  tmp="$(mktemp)"
  # Alles t/m het anker, dan de fragmenten, dan de rest.
  local inserted=false
  while IFS= read -r line; do
    printf '%s\n' "${line}" >>"${tmp}"
    if [[ "${inserted}" == false && "${line}" == "${ANCHOR}" ]]; then
      for f in "${fragments[@]}"; do
        printf '\n' >>"${tmp}"
        cat "${f}" >>"${tmp}"
      done
      inserted=true
    fi
  done <"${CHANGELOG}"

  mv "${tmp}" "${CHANGELOG}"
  rm -f "${fragments[@]}"

  echo
  echo "Samengevoegd in CHANGELOG.md en fragmenten verwijderd."
  echo "Commit dit als losse wijziging, zonder code erbij."
}

main "$@"
