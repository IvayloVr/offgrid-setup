#!/usr/bin/env bash
# =============================================================================
# build.sh — OffGrid Full one-command build
#
# Usage:
#   ./build.sh              # build using current version in bootstrap.sh
#   ./build.sh 1.1.0        # bump to new version and build
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
OUTPUT_DIR="${SCRIPT_DIR}/output"
PACKER_FILE="${SCRIPT_DIR}/offgrid.pkr.hcl"
BOOTSTRAP_FILE="${SCRIPT_DIR}/../bootstrap.sh"
PRESEED_FILE="${SCRIPT_DIR}/http/preseed.cfg"
VARS_FILE="${SCRIPT_DIR}/build.auto.pkrvars.hcl"
FIREWALL_OPENED=false

# ── STEP 0 — Detect IP and write vars file IMMEDIATELY ───────────────────────
# This must happen before the cleanup trap is registered
# so it survives even if later steps fail
step "Detecting host IP"

DEFAULT_IFACE=$(ip route | awk '/^default/{print $5; exit}')
HOST_IP=$(ip addr show "${DEFAULT_IFACE}" 2>/dev/null \
    | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)

[[ -n "${HOST_IP}" ]] || err "Could not detect host IP on interface ${DEFAULT_IFACE}"

log "Interface : ${DEFAULT_IFACE}"
log "Host IP   : ${HOST_IP}"

# Write vars file NOW — before anything can go wrong
cat > "${VARS_FILE}" << VARS
host_ip   = "${HOST_IP}"
http_port = ${HTTP_PORT}
VARS

log "Vars file written with IP ${HOST_IP}"

# ── Now register cleanup trap ─────────────────────────────────────────────────
cleanup() {
    local exit_code=$?
    if [[ ${exit_code} -eq 0 ]]; then
        rm -f "${VARS_FILE}"
        info "Vars file cleaned up"
    else
        warn "Build failed — ${VARS_FILE} kept for debugging"
        warn "Retry: packer build ${PACKER_FILE}"
    fi
    if [[ "${FIREWALL_OPENED}" == "true" ]]; then
        info "Closing firewall port ${HTTP_PORT}..."
        sudo firewall-cmd --remove-port="${HTTP_PORT}/tcp" --quiet 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

# ── Step 1 — Version ─────────────────────────────────────────────────────────
step "Version"

CURRENT_VERSION=$(grep '^VERSION=' "${BOOTSTRAP_FILE}" | cut -d'"' -f2)

if [[ -n "${1:-}" ]]; then
    NEW_VERSION="$1"
    if ! [[ "${NEW_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        err "Invalid version: ${NEW_VERSION} — use x.y.z e.g. 1.1.0"
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

# Add version to vars file
echo "version   = \"${VERSION}\"" >> "${VARS_FILE}"
log "Vars file: host_ip=${HOST_IP}, version=${VERSION}"

# ── Step 2 — Preflight ────────────────────────────────────────────────────────
step "Preflight checks"

[[ -f "${PACKER_FILE}"    ]] || err "offgrid.pkr.hcl not found"
[[ -f "${BOOTSTRAP_FILE}" ]] || err "bootstrap.sh not found"
[[ -f "${PRESEED_FILE}"   ]] || err "preseed.cfg not found"

for cmd in packer qemu-system-x86_64 qemu-img curl; do
    command -v "$cmd" &>/dev/null && log "✓ $cmd" || \
        err "$cmd not found — sudo apt/dnf install $cmd"
done

if [[ ! -e /dev/kvm ]]; then
    info "Loading KVM module..."
    sudo modprobe kvm_intel 2>/dev/null || \
    sudo modprobe kvm_amd  2>/dev/null || \
    err "/dev/kvm not available — enable VT-x in BIOS"
fi
log "✓ KVM"

AVAILABLE_GB=$(df -BG "${SCRIPT_DIR}" | awk 'NR==2{print $4}' | tr -d 'G')
if [[ "${AVAILABLE_GB}" -lt 150 ]]; then
    warn "Low disk space: ${AVAILABLE_GB}GB available, 150GB recommended"
fi

if [[ -d "${OUTPUT_DIR}" ]]; then
    warn "Removing existing output/ directory..."
    rm -rf "${OUTPUT_DIR}"
fi

# ── Step 3 — Firewall ─────────────────────────────────────────────────────────
step "Firewall"

if command -v firewall-cmd &>/dev/null && sudo firewall-cmd --state &>/dev/null 2>&1; then
    sudo firewall-cmd --add-port="${HTTP_PORT}/tcp" --quiet
    FIREWALL_OPENED=true
    log "Port ${HTTP_PORT} opened"
else
    warn "firewalld not active — skipping"
fi

# Verify preseed is reachable (test after Packer starts HTTP server)
info "Preseed will be served at http://${HOST_IP}:${HTTP_PORT}/preseed.cfg"

# ── Step 4 — Packer init ──────────────────────────────────────────────────────
step "Packer init"

cd "${SCRIPT_DIR}"

QEMU_PLUGIN="${HOME}/.config/packer/plugins/github.com/hashicorp/qemu"
if [[ ! -d "${QEMU_PLUGIN}" ]]; then
    log "Installing QEMU plugin..."
    packer init "${PACKER_FILE}"
else
    log "QEMU plugin already installed"
fi

# ── Step 5 — Build ────────────────────────────────────────────────────────────
step "Building OffGrid Full v${VERSION}"

info "This is a FULL build — expect 90-180 minutes."
info "Full Kali desktop + all tools + Docker images downloaded during build."
info "Output VMDK requires zero internet after deployment."
echo ""

START_TIME=$(date +%s)

export PACKER_HTTP_TIMEOUT=7200

packer build "${PACKER_FILE}"

END_TIME=$(date +%s)
ELAPSED=$(( END_TIME - START_TIME ))
MINUTES=$(( ELAPSED / 60 ))
SECS=$(( ELAPSED % 60 ))

# ── Step 6 — Rename output ────────────────────────────────────────────────────
step "Finalising"

RAW="${OUTPUT_DIR}/OffGrid-Full-v${VERSION}"
QCOW2="${OUTPUT_DIR}/OffGrid-Full-v${VERSION}.qcow2"
VMDK="${OUTPUT_DIR}/OffGrid-Full-v${VERSION}.vmdk"

if [[ -f "${RAW}" ]]; then
    mv "${RAW}" "${QCOW2}"
    log "Renamed → OffGrid-Full-v${VERSION}.qcow2"
elif [[ -f "${QCOW2}" ]]; then
    log "qcow2 already named correctly"
else
    warn "Expected output not found — check ${OUTPUT_DIR}/"
fi

# ── Step 7 — Convert to VMDK ─────────────────────────────────────────────────
step "Converting to VMDK"

if [[ -f "${QCOW2}" ]]; then
    log "Converting qcow2 → vmdk (10-15 min for large image)..."
    qemu-img convert \
        -f qcow2 \
        -O vmdk \
        -o subformat=streamOptimized \
        "${QCOW2}" \
        "${VMDK}"
    log "VMDK ready → OffGrid-Full-v${VERSION}.vmdk ($(du -sh "${VMDK}" | cut -f1))"
else
    warn "qcow2 not found — skipping VMDK conversion"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
step "Done"

echo ""
echo -e "  ${BOLD}OffGrid Full v${VERSION} — Build complete${RESET}"
echo -e "  ─────────────────────────────────────────────────────"
[[ -f "${QCOW2}" ]] && echo -e "  qcow2  ${CYAN}${QCOW2}${RESET}  ($(du -sh "${QCOW2}" | cut -f1))"
[[ -f "${VMDK}"  ]] && echo -e "  vmdk   ${CYAN}${VMDK}${RESET}  ($(du -sh "${VMDK}" | cut -f1))"
echo -e "  Time   ${MINUTES}m ${SECS}s"
echo ""
echo -e "  ${YELLOW}Test locally:${RESET}"
echo -e "  ${CYAN}virt-manager${RESET} → New VM → Import → select qcow2"
echo -e "  Login: kali / kali"
echo ""
echo -e "  ${YELLOW}Distribute:${RESET}"
echo -e "  Send ${CYAN}OffGrid-Full-v${VERSION}.vmdk${RESET} to client"
echo ""
