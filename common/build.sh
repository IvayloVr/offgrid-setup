#!/usr/bin/env bash
# =============================================================================
# build.sh — OffGrid one-command build (lean or full)
#
# Usage:
#   ./build.sh              # build current version
#   ./build.sh 0.2.0        # bump to new version and build
#
# Auto-detects latest Kali ISO — no manual URL/checksum updates needed.
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log()  { echo -e "${GREEN}[+]${RESET} $*"; }
warn() { echo -e "${YELLOW}[!]${RESET} $*"; }
err()  { echo -e "${RED}[✗]${RESET} $*"; exit 1; }
info() { echo -e "${CYAN}[i]${RESET} $*"; }
step() { echo -e "\n${BOLD}━━━ $* ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"; }

# ── Paths ─────────────────────────────────────────────────────────────────────
HTTP_PORT="8100"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
COMMON_DIR="${REPO_ROOT}/common"
OUTPUT_DIR="${SCRIPT_DIR}/output"
PACKER_FILE="${SCRIPT_DIR}/offgrid.pkr.hcl"
BOOTSTRAP_FILE="${SCRIPT_DIR}/../bootstrap.sh"
PRESEED_FILE="${SCRIPT_DIR}/http/preseed.cfg"
VALIDATE_FILE="${COMMON_DIR}/validate.sh"
ISO_SCRIPT="${COMMON_DIR}/get-latest-kali-iso.sh"
VARS_FILE="${SCRIPT_DIR}/build.auto.pkrvars.hcl"
FIREWALL_OPENED=false

# Detect variant from bootstrap.sh version stamp
VARIANT="netinst"
grep -q "full-gui" "${BOOTSTRAP_FILE}" 2>/dev/null && VARIANT="full" || true

# ── STEP 0 — Detect IP and write vars file IMMEDIATELY ───────────────────────
step "Detecting host IP"

DEFAULT_IFACE=$(ip route | awk '/^default/{print $5; exit}')
HOST_IP=$(ip addr show "${DEFAULT_IFACE}" 2>/dev/null \
    | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)

[[ -n "${HOST_IP}" ]] || err "Could not detect host IP"

log "Interface : ${DEFAULT_IFACE}"
log "Host IP   : ${HOST_IP}"

cat > "${VARS_FILE}" << VARS
host_ip   = "${HOST_IP}"
http_port = ${HTTP_PORT}
VARS

log "Vars file written"

# ── Cleanup trap ──────────────────────────────────────────────────────────────
cleanup() {
    local exit_code=$?
    if [[ ${exit_code} -eq 0 ]]; then
        rm -f "${VARS_FILE}"
    else
        warn "Build failed — ${VARS_FILE} kept for debugging"
        warn "Retry: packer build ${PACKER_FILE}"
    fi
    if [[ "${FIREWALL_OPENED}" == "true" ]]; then
        info "Closing firewall port ${HTTP_PORT}..."
        sudo firewall-cmd --remove-port="${HTTP_PORT}/tcp" --quiet 2>/dev/null || \
        sudo ufw delete allow "${HTTP_PORT}/tcp" &>/dev/null 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

# ── Step 1 — Version ─────────────────────────────────────────────────────────
step "Version"

CURRENT_VERSION=$(grep '^VERSION=' "${BOOTSTRAP_FILE}" | cut -d'"' -f2)

if [[ -n "${1:-}" ]]; then
    NEW_VERSION="$1"
    if ! [[ "${NEW_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        err "Invalid version: ${NEW_VERSION} — use x.y.z"
    fi
    if [[ "${NEW_VERSION}" != "${CURRENT_VERSION}" ]]; then
        log "Bumping ${CURRENT_VERSION} → ${NEW_VERSION}"
        sed -i "s/^VERSION=\"${CURRENT_VERSION}\"/VERSION=\"${NEW_VERSION}\"/" "${BOOTSTRAP_FILE}"
        sed -i "s/default = \"${CURRENT_VERSION}\"/default = \"${NEW_VERSION}\"/" "${PACKER_FILE}"
        log "bootstrap.sh and offgrid.pkr.hcl updated"
    else
        warn "Already at ${NEW_VERSION} — rebuilding"
    fi
    VERSION="${NEW_VERSION}"
else
    VERSION="${CURRENT_VERSION}"
    log "Using current version: ${VERSION}"
fi

echo "version = \"${VERSION}\"" >> "${VARS_FILE}"

# ── Step 2 — Auto-detect latest Kali ISO ─────────────────────────────────────
step "Checking latest Kali ISO"

if [[ -f "${ISO_SCRIPT}" ]]; then
    # Source the script — sets KALI_ISO_URL, KALI_ISO_CHECKSUM, KALI_VERSION
    source "${ISO_SCRIPT}" "${VARIANT}" && {
        log "Kali ${KALI_VERSION} — updating packer config..."

        # Update the ISO URL in pkr.hcl
        sed -i "s|default = \"https://cdimage.kali.org/current/kali-linux-.*\.iso\"|default = \"${KALI_ISO_URL}\"|" "${PACKER_FILE}"

        # Update the checksum
        sed -i "s|default = \"sha256:[a-f0-9]*\"|default = \"${KALI_ISO_CHECKSUM}\"|" "${PACKER_FILE}"

        log "Packer config updated to Kali ${KALI_VERSION}"
    } || {
        warn "Could not fetch latest ISO info — using values already in offgrid.pkr.hcl"
    }
else
    warn "get-latest-kali-iso.sh not found at ${ISO_SCRIPT} — using hardcoded ISO values"
fi

# ── Step 3 — Preflight ────────────────────────────────────────────────────────
step "Preflight checks"

[[ -f "${PACKER_FILE}"    ]] || err "offgrid.pkr.hcl not found"
[[ -f "${BOOTSTRAP_FILE}" ]] || err "bootstrap.sh not found"
[[ -f "${PRESEED_FILE}"   ]] || err "preseed.cfg not found"

for cmd in packer qemu-system-x86_64 qemu-img curl; do
    command -v "$cmd" &>/dev/null && log "✓ $cmd" || \
        err "$cmd not found"
done

if [[ ! -e /dev/kvm ]]; then
    info "Loading KVM module..."
    sudo modprobe kvm_intel 2>/dev/null || \
    sudo modprobe kvm_amd  2>/dev/null || \
    err "/dev/kvm not available — enable VT-x in BIOS"
fi
log "✓ KVM"

if [[ -d "${OUTPUT_DIR}" ]]; then
    warn "Removing existing output/ directory..."
    rm -rf "${OUTPUT_DIR}"
fi

# ── Step 4 — Firewall ─────────────────────────────────────────────────────────
step "Firewall"

if command -v firewall-cmd &>/dev/null && sudo firewall-cmd --state &>/dev/null 2>&1; then
    # Fedora / RHEL — firewalld
    sudo firewall-cmd --add-port="${HTTP_PORT}/tcp" --quiet
    FIREWALL_OPENED=true
    log "firewalld: port ${HTTP_PORT} opened"
elif command -v ufw &>/dev/null && sudo ufw status | grep -q "Status: active"; then
    # Debian / Ubuntu — ufw
    sudo ufw allow "${HTTP_PORT}/tcp" comment "OffGrid Packer preseed" &>/dev/null
    FIREWALL_OPENED=true
    log "ufw: port ${HTTP_PORT} opened"
else
    warn "No active firewall detected — skipping (port ${HTTP_PORT} should be reachable)"
fi

# ── Step 5 — Packer init ──────────────────────────────────────────────────────
step "Packer init"

cd "${SCRIPT_DIR}"
QEMU_PLUGIN="${HOME}/.config/packer/plugins/github.com/hashicorp/qemu"
if [[ ! -d "${QEMU_PLUGIN}" ]]; then
    log "Installing QEMU plugin..."
    packer init "${PACKER_FILE}"
else
    log "QEMU plugin already installed"
fi

# ── Step 6 — Build ────────────────────────────────────────────────────────────
step "Building OffGrid v${VERSION}"

info "This takes 45-180 minutes depending on variant."
echo ""

START_TIME=$(date +%s)
export PACKER_HTTP_TIMEOUT=7200
packer build "${PACKER_FILE}"

END_TIME=$(date +%s)
ELAPSED=$(( END_TIME - START_TIME ))
MINUTES=$(( ELAPSED / 60 ))
SECS=$(( ELAPSED % 60 ))

# ── Step 7 — Rename output ────────────────────────────────────────────────────
step "Finalising"

# Determine output name prefix based on variant
if [[ "${VARIANT}" == "full" ]]; then
    RAW="${OUTPUT_DIR}/OffGrid-Full-v${VERSION}"
    QCOW2="${OUTPUT_DIR}/OffGrid-Full-v${VERSION}.qcow2"
    VMDK="${OUTPUT_DIR}/OffGrid-Full-v${VERSION}.vmdk"
else
    RAW="${OUTPUT_DIR}/OffGrid-v${VERSION}"
    QCOW2="${OUTPUT_DIR}/OffGrid-v${VERSION}.qcow2"
    VMDK="${OUTPUT_DIR}/OffGrid-v${VERSION}.vmdk"
fi

[[ -f "${RAW}" ]] && mv "${RAW}" "${QCOW2}" && log "Renamed → $(basename ${QCOW2})"
[[ -f "${QCOW2}" ]] || warn "qcow2 not found at ${QCOW2}"

# ── Step 8 — Convert to VMDK ─────────────────────────────────────────────────
step "Converting to VMDK"

if [[ -f "${QCOW2}" ]]; then
    log "Converting qcow2 → vmdk..."
    qemu-img convert \
        -f qcow2 \
        -O vmdk \
        "${QCOW2}" \
        "${VMDK}"
    log "VMDK ready → $(basename ${VMDK})  ($(du -sh "${VMDK}" | cut -f1))"
else
    warn "qcow2 not found — skipping VMDK conversion"
fi

# ── Step 9 — Summary ─────────────────────────────────────────────────────────
step "Done"

echo ""
echo -e "  ${BOLD}OffGrid v${VERSION} — Build complete${RESET}"
echo -e "  ─────────────────────────────────────────────────────"
[[ -f "${QCOW2}" ]] && echo -e "  qcow2  ${CYAN}${QCOW2}${RESET}  ($(du -sh "${QCOW2}" | cut -f1))"
[[ -f "${VMDK}"  ]] && echo -e "  vmdk   ${CYAN}${VMDK}${RESET}  ($(du -sh "${VMDK}" | cut -f1))"
echo -e "  Time   ${MINUTES}m ${SECS}s"
echo ""
echo -e "  ${YELLOW}Next:${RESET}"
echo -e "  Test:      ${CYAN}qemu-system-x86_64 -m 4096 -enable-kvm -hda ${QCOW2} -boot c -vga virtio -display gtk${RESET}"
echo -e "  Package:   ${CYAN}make package-lean${RESET}  or  ${CYAN}make package-full${RESET}"
echo ""
