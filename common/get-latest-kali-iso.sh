#!/usr/bin/env bash
# =============================================================================
# get-latest-kali-iso.sh
# Fetches the latest Kali ISO URL and SHA256 checksum automatically.
# Called by build.sh before every build — no manual ISO updates needed.
#
# Usage:
#   source get-latest-kali-iso.sh <variant>
#   variant: netinst (lean) or full
#
# Sets:
#   KALI_ISO_URL
#   KALI_ISO_CHECKSUM
#   KALI_VERSION
# =============================================================================

set -euo pipefail

VARIANT="${1:-netinst}"   # netinst or full
KALI_MIRROR="https://cdimage.kali.org/current"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; RESET='\033[0m'
log()  { echo -e "${GREEN}[+]${RESET} $*"; }
warn() { echo -e "${YELLOW}[!]${RESET} $*"; }

# ── Fetch the SHA256SUMS file ─────────────────────────────────────────────────
SUMS_URL="${KALI_MIRROR}/SHA256SUMS"

log "Fetching Kali ISO list from ${SUMS_URL}..."

SUMS=$(curl -fsSL "${SUMS_URL}" 2>/dev/null) || {
    warn "Could not fetch SHA256SUMS — using cached values if available"
    return 1 2>/dev/null || exit 1
}

# ── Find the right ISO ────────────────────────────────────────────────────────
if [[ "${VARIANT}" == "netinst" ]]; then
    # Lean build — netinst AMD64
    ISO_LINE=$(echo "${SUMS}" | grep "installer-netinst-amd64.iso$" | grep -v torrent | head -1)
elif [[ "${VARIANT}" == "full" ]]; then
    # Full build — full installer AMD64 (not everything, not live)
    ISO_LINE=$(echo "${SUMS}" | grep "installer-amd64.iso$" | grep -v torrent | grep -v everything | grep -v netinst | head -1)
else
    echo "Unknown variant: ${VARIANT}. Use 'netinst' or 'full'"
    exit 1
fi

[[ -n "${ISO_LINE}" ]] || { echo "Could not find ISO in SHA256SUMS"; exit 1; }

# ── Extract checksum and filename ─────────────────────────────────────────────
KALI_ISO_CHECKSUM="sha256:$(echo "${ISO_LINE}" | awk '{print $1}')"
ISO_FILENAME=$(echo "${ISO_LINE}" | awk '{print $2}')
KALI_ISO_URL="${KALI_MIRROR}/${ISO_FILENAME}"

# ── Extract version from filename ─────────────────────────────────────────────
# Filename format: kali-linux-2026.1-installer-netinst-amd64.iso
KALI_VERSION=$(echo "${ISO_FILENAME}" | grep -oP '\d{4}\.\d+')

log "Kali version : ${KALI_VERSION}"
log "ISO filename : ${ISO_FILENAME}"
log "Checksum     : ${KALI_ISO_CHECKSUM:0:20}..."
log "URL          : ${KALI_ISO_URL}"

export KALI_ISO_URL
export KALI_ISO_CHECKSUM
export KALI_VERSION
