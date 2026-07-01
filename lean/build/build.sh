#!/usr/bin/env bash
# =============================================================================
# build.sh — OffGrid one-command build
#
# Usage:
#   ./build.sh              # build using current version in bootstrap.sh
#   ./build.sh 0.2.0        # bump to new version and build
#
# What it does:
#   1. Reads or sets version — syncs bootstrap.sh and offgrid.pkr.hcl
#   2. Checks all dependencies
#   3. Detects host IP automatically
#   4. Opens firewall port temporarily
#   5. Runs packer build
#   6. Renames output to OffGrid-v<version>.qcow2
#   7. Converts to VMDK automatically
#   8. Closes firewall, cleans up
#   9. Prints summary
#
# Output:
#   output/OffGrid-v<version>.qcow2
#   output/OffGrid-v<version>.vmdk
# =============================================================================

set -euo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
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
OUTPUT_DIR="${SCRIPT_DIR}/output"
PACKER_FILE="${SCRIPT_DIR}/offgrid.pkr.hcl"
BOOTSTRAP_FILE="${SCRIPT_DIR}/../bootstrap.sh"
PRESEED_FILE="${SCRIPT_DIR}/http/preseed.cfg"
VARS_FILE="${SCRIPT_DIR}/build.auto.pkrvars.hcl"
FIREWALL_OPENED=false

# ── Cleanup on exit ───────────────────────────────────────────────────────────
cleanup() {
    rm -f "${VARS_FILE}"
    if [[ "${FIREWALL_OPENED}" == "true" ]]; then
        info "Closing firewall port ${HTTP_PORT}..."
        sudo firewall-cmd --remove-port="${HTTP_PORT}/tcp" --quiet 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

# ── Step 1 — Version handling ─────────────────────────────────────────────────
step "Version"

# Read current version from bootstrap.sh
CURRENT_VERSION=$(grep '^VERSION=' "${BOOTSTRAP_FILE}" | cut -d'"' -f2)

if [[ -n "${1:-}" ]]; then
    NEW_VERSION="$1"

    # Validate format x.y.z
    if ! [[ "${NEW_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        err "Invalid version format: ${NEW_VERSION} — use x.y.z e.g. 0.2.0"
    fi

    if [[ "${NEW_VERSION}" == "${CURRENT_VERSION}" ]]; then
        warn "Version ${NEW_VERSION} is already set — rebuilding same version"
        VERSION="${NEW_VERSION}"
    else
        log "Bumping version ${CURRENT_VERSION} → ${NEW_VERSION}"

        # Update bootstrap.sh
        sed -i "s/^VERSION=\"${CURRENT_VERSION}\"/VERSION=\"${NEW_VERSION}\"/" "${BOOTSTRAP_FILE}"

        # Update offgrid.pkr.hcl
        sed -i "s/default = \"${CURRENT_VERSION}\"/default = \"${NEW_VERSION}\"/" "${PACKER_FILE}"

        VERSION="${NEW_VERSION}"
        log "bootstrap.sh updated → VERSION=\"${VERSION}\""
        log "offgrid.pkr.hcl updated → version = \"${VERSION}\""
    fi
else
    # No argument — use whatever is currently in bootstrap.sh
    VERSION="${CURRENT_VERSION}"
    log "Using current version: ${VERSION}"
fi

# ── Step 2 — Preflight ────────────────────────────────────────────────────────
step "Preflight checks"

[[ -f "${PACKER_FILE}"    ]] || err "offgrid.pkr.hcl not found at ${PACKER_FILE}"
[[ -f "${BOOTSTRAP_FILE}" ]] || err "bootstrap.sh not found at ${BOOTSTRAP_FILE}"
[[ -f "${PRESEED_FILE}"   ]] || err "preseed.cfg not found at ${PRESEED_FILE}"

for cmd in packer qemu-system-x86_64 qemu-img curl; do
    command -v "$cmd" &>/dev/null && log "✓ $cmd" || \
        err "$cmd not found — install with: sudo dnf install -y $cmd"
done

if [[ ! -e /dev/kvm ]]; then
    info "Loading KVM module..."
    sudo modprobe kvm_intel 2>/dev/null || \
    sudo modprobe kvm_amd  2>/dev/null || \
    err "/dev/kvm not available — enable VT-x/AMD-V in BIOS"
fi
log "✓ KVM"

# Clean output dir — Packer refuses to overwrite
if [[ -d "${OUTPUT_DIR}" ]]; then
    warn "Removing existing output/ directory..."
    rm -rf "${OUTPUT_DIR}"
fi

# ── Step 3 — Detect host IP ───────────────────────────────────────────────────
step "Detecting host IP"

DEFAULT_IFACE=$(ip route | awk '/^default/{print $5; exit}')
HOST_IP=$(ip addr show "${DEFAULT_IFACE}" 2>/dev/null \
    | awk '/inet /{print $2}' \
    | cut -d/ -f1 \
    | head -1)

[[ -n "${HOST_IP}" ]] || err "Could not detect host IP on interface ${DEFAULT_IFACE}"

log "Interface : ${DEFAULT_IFACE}"
log "Host IP   : ${HOST_IP}"

# ── Step 4 — Firewall ─────────────────────────────────────────────────────────
step "Firewall"

if command -v firewall-cmd &>/dev/null && sudo firewall-cmd --state &>/dev/null 2>&1; then
    sudo firewall-cmd --add-port="${HTTP_PORT}/tcp" --quiet
    FIREWALL_OPENED=true
    log "Port ${HTTP_PORT} opened (closes when build finishes)"
else
    warn "firewalld not active — skipping"
fi

# ── Step 5 — Write vars file ──────────────────────────────────────────────────
step "Configuring build"

cat > "${VARS_FILE}" << VARS
host_ip   = "${HOST_IP}"
http_port = ${HTTP_PORT}
version   = "${VERSION}"
VARS

log "Vars written → host_ip=${HOST_IP}, version=${VERSION}"

# ── Step 6 — Packer init ──────────────────────────────────────────────────────
step "Packer init"

cd "${SCRIPT_DIR}"

QEMU_PLUGIN="${HOME}/.config/packer/plugins/github.com/hashicorp/qemu"
if [[ ! -d "${QEMU_PLUGIN}" ]]; then
    log "Installing QEMU plugin (first time only)..."
    packer init "${PACKER_FILE}"
else
    log "QEMU plugin already installed"
fi

# ── Step 7 — Build ────────────────────────────────────────────────────────────
step "Building OffGrid v${VERSION}"

info "This takes 45-90 minutes."
info "Headless build — connect via VNC if you want to watch:"
info "  vncviewer 127.0.0.1:<port shown in packer output>"
echo ""

START_TIME=$(date +%s)

packer build "${PACKER_FILE}"

END_TIME=$(date +%s)
ELAPSED=$(( END_TIME - START_TIME ))
MINUTES=$(( ELAPSED / 60 ))
SECS=$(( ELAPSED % 60 ))

# ── Step 8 — Rename output ────────────────────────────────────────────────────
step "Finalising"

RAW="${OUTPUT_DIR}/OffGrid-v${VERSION}"
QCOW2="${OUTPUT_DIR}/OffGrid-v${VERSION}.qcow2"
VMDK="${OUTPUT_DIR}/OffGrid-v${VERSION}.vmdk"

if [[ -f "${RAW}" ]]; then
    mv "${RAW}" "${QCOW2}"
    log "Renamed → OffGrid-v${VERSION}.qcow2"
elif [[ -f "${QCOW2}" ]]; then
    log "qcow2 already named correctly"
else
    warn "Expected output not found — check ${OUTPUT_DIR}/ manually"
fi

# ── Step 9 — Convert to VMDK ─────────────────────────────────────────────────
step "Converting to VMDK"

if [[ -f "${QCOW2}" ]]; then
    log "Converting qcow2 → vmdk (this takes a few minutes)..."
    qemu-img convert \
        -f qcow2 \
        -O vmdk \
        -o subformat=streamOptimized \
        "${QCOW2}" \
        "${VMDK}"
    VMDK_SIZE=$(du -sh "${VMDK}" | cut -f1)
    log "VMDK ready → OffGrid-v${VERSION}.vmdk (${VMDK_SIZE})"
else
    warn "qcow2 not found — skipping VMDK conversion"
fi

# ── Step 10 — Summary ─────────────────────────────────────────────────────────
step "Done"

echo ""
echo -e "  ${BOLD}OffGrid v${VERSION} — Build complete${RESET}"
echo -e "  ─────────────────────────────────────────────────────"

if [[ -f "${QCOW2}" ]]; then
    echo -e "  qcow2    ${CYAN}${QCOW2}${RESET}  ($(du -sh "${QCOW2}" | cut -f1))"
fi
if [[ -f "${VMDK}" ]]; then
    echo -e "  vmdk     ${CYAN}${VMDK}${RESET}  ($(du -sh "${VMDK}" | cut -f1))"
fi

echo -e "  Time     ${MINUTES}m ${SECS}s"
echo ""
echo -e "  ${YELLOW}Distribute:${RESET}"
echo -e "  Send ${CYAN}OffGrid-v${VERSION}.vmdk${RESET} to client"
echo -e "  They import into VMware Player and start the VM"
echo ""
echo -e "  ${YELLOW}Test locally:${RESET}"
echo -e "  ${CYAN}virt-manager${RESET} → New VM → Import existing disk → select qcow2"
echo -e "  SSH: ${CYAN}ssh kali@<vm-ip>${RESET}  password: kali"
echo ""
echo -e "  ${YELLOW}Next build:${RESET}"
echo -e "  ${CYAN}./build.sh 0.$(( ${VERSION##*.} + 1 )).0${RESET}  or  ${CYAN}./build.sh$(RESET)"
echo ""
