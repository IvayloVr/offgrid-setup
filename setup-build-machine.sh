#!/usr/bin/env bash
# =============================================================================
# setup-build-machine.sh
# One-time setup for the OffGrid build machine.
# Detects the OS and installs Packer + QEMU/KVM correctly.
#
# Supported:
#   Fedora 38+
#   Ubuntu 20.04, 22.04, 24.04
#   Debian 11, 12
#
# Usage:
#   sudo bash setup-build-machine.sh
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log()  { echo -e "${GREEN}[+]${RESET} $*"; }
warn() { echo -e "${YELLOW}[!]${RESET} $*"; }
err()  { echo -e "${RED}[✗]${RESET} $*"; exit 1; }
info() { echo -e "${CYAN}[i]${RESET} $*"; }
step() { echo -e "\n${BOLD}━━━ $* ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"; }

# ── Preflight ─────────────────────────────────────────────────────────────────
[[ "$(id -u)" -eq 0 ]] || err "Run as root: sudo bash setup-build-machine.sh"

# ── Detect OS ─────────────────────────────────────────────────────────────────
step "Detecting OS"

OS_ID=$(grep '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"')
OS_VERSION=$(grep '^VERSION_ID=' /etc/os-release | cut -d= -f2 | tr -d '"')
OS_PRETTY=$(grep '^PRETTY_NAME=' /etc/os-release | cut -d= -f2 | tr -d '"')

log "Detected: ${OS_PRETTY}"

case "${OS_ID}" in
    fedora)
        DISTRO="fedora"
        ;;
    ubuntu|debian|linuxmint|pop|kali)
        DISTRO="debian"
        ;;
    *)
        warn "Unknown OS: ${OS_ID}"
        warn "Attempting Debian-style install — may need manual adjustments"
        DISTRO="debian"
        ;;
esac

log "Install mode: ${DISTRO}"

# ── Get the actual user (not root) ────────────────────────────────────────────
# When run with sudo, SUDO_USER is the real user
REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || echo $USER)}"
REAL_HOME=$(getent passwd "${REAL_USER}" | cut -d: -f6)
log "Configuring for user: ${REAL_USER}"

# ═══════════════════════════════════════════════════════════════════════════════
# FEDORA
# ═══════════════════════════════════════════════════════════════════════════════
install_fedora() {

    step "Updating system"
    dnf update -y -q
    log "System updated"

    step "Installing QEMU/KVM"
    dnf install -y -q \
        qemu-kvm \
        libvirt \
        libvirt-daemon-kvm \
        virt-install \
        bridge-utils \
        qemu-img
    log "QEMU/KVM installed"

    step "Starting libvirtd"
    systemctl enable --now libvirtd
    log "libvirtd enabled and started"

    step "Installing Packer"
    # Add HashiCorp repo if not already present
    if ! dnf repolist | grep -q hashicorp; then
        dnf config-manager addrepo \
            --from-repofile=https://rpm.releases.hashicorp.com/fedora/hashicorp.repo \
            2>/dev/null || \
        dnf install -y -q dnf-plugins-core && \
        dnf config-manager --add-repo \
            https://rpm.releases.hashicorp.com/fedora/hashicorp.repo
    fi
    dnf install -y -q packer
    log "Packer installed"

    step "Installing utilities"
    dnf install -y -q \
        curl \
        wget \
        git \
        jq \
        python3 \
        exfatprogs \
        virt-manager \
        tigervnc
    log "Utilities installed"

    step "Configuring user groups"
    usermod -aG libvirt "${REAL_USER}"
    usermod -aG kvm     "${REAL_USER}"
    log "User ${REAL_USER} added to libvirt and kvm groups"

    step "Loading KVM module"
    modprobe kvm_intel 2>/dev/null || modprobe kvm_amd 2>/dev/null || \
        warn "KVM module not loaded — enable VT-x in BIOS if not already done"

}

# ═══════════════════════════════════════════════════════════════════════════════
# DEBIAN / UBUNTU
# ═══════════════════════════════════════════════════════════════════════════════
install_debian() {

    step "Updating system"
    apt-get update -qq
    apt-get upgrade -y -qq
    log "System updated"

    step "Installing prerequisites"
    apt-get install -y -qq \
        curl \
        wget \
        git \
        jq \
        python3 \
        gnupg \
        software-properties-common \
        apt-transport-https \
        ca-certificates \
        lsb-release
    log "Prerequisites installed"

    step "Installing QEMU/KVM"
    apt-get install -y -qq \
        qemu-system \
        qemu-kvm \
        qemu-utils \
        libvirt-daemon-system \
        libvirt-clients \
        virtinst \
        bridge-utils \
        cpu-checker
    log "QEMU/KVM installed"

    step "Starting libvirtd"
    systemctl enable --now libvirtd
    log "libvirtd enabled and started"

    step "Installing Packer"
    # Add HashiCorp GPG key
    curl -fsSL https://apt.releases.hashicorp.com/gpg \
        | gpg --dearmor \
        | tee /usr/share/keyrings/hashicorp-archive-keyring.gpg > /dev/null

    # Add HashiCorp repo
    echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
        | tee /etc/apt/sources.list.d/hashicorp.list

    apt-get update -qq
    apt-get install -y -qq packer
    log "Packer installed"

    step "Installing utilities"
    apt-get install -y -qq \
        exfatprogs \
        virt-manager \
        tigervnc-viewer \
        python3-pip 2>/dev/null || true
    log "Utilities installed"

    step "Configuring user groups"
    usermod -aG libvirt "${REAL_USER}"
    usermod -aG kvm     "${REAL_USER}"
    log "User ${REAL_USER} added to libvirt and kvm groups"

    step "Loading KVM module"
    modprobe kvm_intel 2>/dev/null || modprobe kvm_amd 2>/dev/null || \
        warn "KVM module not loaded — enable VT-x in BIOS if not already done"

    step "Configuring UFW"
    if command -v ufw &>/dev/null; then
        ufw allow 8100/tcp comment "OffGrid Packer preseed" 2>/dev/null || true
        log "UFW: port 8100 allowed for Packer preseed server"
    else
        warn "UFW not found — skipping firewall rule"
    fi

}

# ── Run the right installer ───────────────────────────────────────────────────
case "${DISTRO}" in
    fedora) install_fedora ;;
    debian) install_debian ;;
esac

# ── Verify installation ───────────────────────────────────────────────────────
step "Verifying installation"

FAILED=()

command -v packer             &>/dev/null && log "✓ packer $(packer --version)" || FAILED+=("packer")
command -v qemu-system-x86_64 &>/dev/null || command -v qemu-system &>/dev/null && log "✓ qemu" || FAILED+=("qemu")
command -v qemu-img           &>/dev/null && log "✓ qemu-img"                   || FAILED+=("qemu-img")
command -v curl               &>/dev/null && log "✓ curl"                       || FAILED+=("curl")
command -v git                &>/dev/null && log "✓ git"                        || FAILED+=("git")

if [[ -e /dev/kvm ]]; then
    log "✓ /dev/kvm exists"
else
    warn "✗ /dev/kvm not found — enable VT-x/AMD-V in BIOS and reboot"
    FAILED+=("kvm")
fi

# ── Summary ───────────────────────────────────────────────────────────────────
step "Setup complete"

echo ""
echo -e "  ${BOLD}Build machine setup — ${OS_PRETTY}${RESET}"
echo -e "  ─────────────────────────────────────────────────────"
echo -e "  OS:      ${CYAN}${OS_PRETTY}${RESET}"
echo -e "  User:    ${CYAN}${REAL_USER}${RESET}"
echo -e "  Packer:  ${CYAN}$(packer --version 2>/dev/null || echo 'check manually')${RESET}"
echo -e "  QEMU:    ${CYAN}$(qemu-system-x86_64 --version 2>/dev/null | head -1 || echo 'check manually')${RESET}"
echo ""

if [[ ${#FAILED[@]} -gt 0 ]]; then
    echo -e "  ${RED}Failed checks: ${FAILED[*]}${RESET}"
    echo -e "  Resolve the above before running build.sh"
    echo ""
else
    echo -e "  ${GREEN}All checks passed.${RESET}"
    echo ""
    echo -e "  ${YELLOW}IMPORTANT: Log out and back in for group changes to take effect${RESET}"
    echo -e "  Groups added: libvirt, kvm"
    echo ""
    echo -e "  Then build:"
    echo -e "  ${CYAN}cd offgrid/build && ./build.sh 1.0.0${RESET}"
    echo ""
fi
