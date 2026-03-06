#!/usr/bin/env bash
#
# install-dev-tools.sh - Install local validation tooling for Nextcloud platform development
#
# Installs:
#   - yamllint    (via dnf/pip)
#   - kubeconform (GitHub release binary)
#   - kube-score  (GitHub release binary)
#   - conftest    (GitHub release binary)
#   - gitleaks    (GitHub release binary)
#
# Usage:
#   sudo ./scripts/install-dev-tools.sh            # install to /usr/local/bin (system-wide)
#   ./scripts/install-dev-tools.sh --user          # install to ~/.local/bin (user only)
#
# Pinned versions — update here when bumping:
KUBECONFORM_VERSION="v0.7.0"
KUBE_SCORE_VERSION="v1.20.0"
CONFTEST_VERSION="v0.66.0"
GITLEAKS_VERSION="v8.30.0"

set -euo pipefail

ARCH="$(uname -m)"
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
INSTALL_DIR="/usr/local/bin"
USER_INSTALL=false
TMPDIR="$(mktemp -d)"

# Map arch names to what GitHub releases use
case "$ARCH" in
  x86_64)  ARCH_AMD="amd64" ; ARCH_X86="x86_64" ;;
  aarch64) ARCH_AMD="arm64" ; ARCH_X86="arm64"   ;;
  *)
    echo "Unsupported architecture: $ARCH" >&2
    exit 1
    ;;
esac

cleanup() {
  rm -rf "$TMPDIR"
}
trap cleanup EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)
      USER_INSTALL=true
      INSTALL_DIR="${HOME}/.local/bin"
      shift
      ;;
    -h|--help)
      grep '^#' "$0" | head -20 | sed 's/^# \?//'
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

mkdir -p "$INSTALL_DIR"

if [[ "$USER_INSTALL" == "false" && "$EUID" -ne 0 ]]; then
  echo "ERROR: Run with sudo for system-wide install, or use --user for ~/.local/bin" >&2
  exit 1
fi

echo "Installing dev tools to $INSTALL_DIR"
echo ""

# ── yamllint ──────────────────────────────────────────────────────────────────
install_yamllint() {
  echo "Installing yamllint..."
  if command -v dnf &>/dev/null && [[ "$USER_INSTALL" == "false" ]]; then
    dnf install -y yamllint
  else
    pip3 install --user yamllint
  fi
  echo "  yamllint: $(yamllint --version 2>&1)"
}

# ── kubeconform ───────────────────────────────────────────────────────────────
install_kubeconform() {
  echo "Installing kubeconform ${KUBECONFORM_VERSION}..."
  local url="https://github.com/yannh/kubeconform/releases/download/${KUBECONFORM_VERSION}/kubeconform-${OS}-${ARCH_AMD}.tar.gz"
  curl -fsSL "$url" -o "${TMPDIR}/kubeconform.tar.gz"
  tar -xzf "${TMPDIR}/kubeconform.tar.gz" -C "${TMPDIR}"
  install -m 0755 "${TMPDIR}/kubeconform" "${INSTALL_DIR}/kubeconform"
  echo "  kubeconform: $(kubeconform -v 2>&1)"
}

# ── kube-score ────────────────────────────────────────────────────────────────
install_kube_score() {
  echo "Installing kube-score ${KUBE_SCORE_VERSION}..."
  local url="https://github.com/zegl/kube-score/releases/download/${KUBE_SCORE_VERSION}/kube-score_${KUBE_SCORE_VERSION#v}_${OS}_${ARCH_AMD}.tar.gz"
  curl -fsSL "$url" -o "${TMPDIR}/kube-score.tar.gz"
  tar -xzf "${TMPDIR}/kube-score.tar.gz" -C "${TMPDIR}"
  install -m 0755 "${TMPDIR}/kube-score" "${INSTALL_DIR}/kube-score"
  echo "  kube-score: $(kube-score version 2>&1)"
}

# ── conftest ──────────────────────────────────────────────────────────────────
install_conftest() {
  echo "Installing conftest ${CONFTEST_VERSION}..."
  local url="https://github.com/open-policy-agent/conftest/releases/download/${CONFTEST_VERSION}/conftest_${CONFTEST_VERSION#v}_Linux_${ARCH_X86}.tar.gz"
  curl -fsSL "$url" -o "${TMPDIR}/conftest.tar.gz"
  tar -xzf "${TMPDIR}/conftest.tar.gz" -C "${TMPDIR}"
  install -m 0755 "${TMPDIR}/conftest" "${INSTALL_DIR}/conftest"
  echo "  conftest: $(conftest --version 2>&1)"
}

# ── gitleaks ──────────────────────────────────────────────────────────────────
install_gitleaks() {
  echo "Installing gitleaks ${GITLEAKS_VERSION}..."
  local url="https://github.com/gitleaks/gitleaks/releases/download/${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION#v}_${OS}_${ARCH_X86}.tar.gz"
  curl -fsSL "$url" -o "${TMPDIR}/gitleaks.tar.gz"
  tar -xzf "${TMPDIR}/gitleaks.tar.gz" -C "${TMPDIR}"
  install -m 0755 "${TMPDIR}/gitleaks" "${INSTALL_DIR}/gitleaks"
  echo "  gitleaks: $(gitleaks version 2>&1)"
}

install_yamllint
echo ""
install_kubeconform
echo ""
install_kube_score
echo ""
install_conftest
echo ""
install_gitleaks

echo ""
echo "All tools installed to ${INSTALL_DIR}"
echo "Verify with: yamllint --version && kubeconform -v && kube-score version && conftest --version && gitleaks version"
