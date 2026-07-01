#!/usr/bin/env bash
# =============================================================================
# vps-setup.sh — OffGrid VPS tunnel server setup
# Run this ONCE on your VPS before distributing any VM
#
# Usage:
#   chmod +x vps-setup.sh
#   sudo ./vps-setup.sh
#
# What it does:
#   1. Creates a dedicated 'tunnel' user (no shell, no login)
#   2. Configures SSH to listen on port 443 (bypasses most firewalls)
#   3. Enables GatewayPorts for reverse tunnel forwarding
#   4. Adds your public key for managing the VPS
#   5. Creates authorized_keys for VM tunnel connections
#   6. Sets up UFW/firewalld rules
#   7. Prints connection instructions
#
# Requirements:
#   - Debian/Ubuntu or RHEL/Fedora VPS
#   - Root access
#   - Port 443 available (no web server on this VPS, or use a different port)
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
step "Preflight"

[[ "$(id -u)" -eq 0 ]] || err "Run as root: sudo ./vps-setup.sh"

# Detect OS
if command -v apt-get &>/dev/null; then
    OS="debian"
    log "Detected: Debian/Ubuntu"
elif command -v dnf &>/dev/null; then
    OS="rhel"
    log "Detected: RHEL/Fedora"
else
    err "Unsupported OS — needs apt or dnf"
fi

# Get VPS public IP
VPS_IP=$(curl -s https://ipinfo.io/ip 2>/dev/null || \
         curl -s https://api.ipify.org 2>/dev/null || \
         hostname -I | awk '{print $1}')
log "VPS IP: ${VPS_IP}"

# ── Install autossh if not present ────────────────────────────────────────────
step "Dependencies"

if [[ "$OS" == "debian" ]]; then
    apt-get update -qq
    apt-get install -y -qq openssh-server
else
    dnf install -y -q openssh-server
fi
log "SSH server verified"

# ── Create tunnel user ────────────────────────────────────────────────────────
step "Tunnel user"

if id tunnel &>/dev/null; then
    log "User 'tunnel' already exists"
else
    useradd -m -s /bin/false -c "OffGrid tunnel user" tunnel
    log "User 'tunnel' created (no shell, no login)"
fi

# SSH directory for tunnel user
mkdir -p /home/tunnel/.ssh
chmod 700 /home/tunnel/.ssh
touch /home/tunnel/.ssh/authorized_keys
chmod 600 /home/tunnel/.ssh/authorized_keys
chown -R tunnel:tunnel /home/tunnel/.ssh

log "Tunnel user SSH directory ready"
info "Add VM public keys to: /home/tunnel/.ssh/authorized_keys"

# ── Configure SSH ─────────────────────────────────────────────────────────────
step "SSH configuration"

SSHD_CONFIG="/etc/ssh/sshd_config"
SSHD_BACKUP="${SSHD_CONFIG}.backup.$(date +%Y%m%d%H%M%S)"

# Backup original
cp "${SSHD_CONFIG}" "${SSHD_BACKUP}"
log "Original sshd_config backed up → ${SSHD_BACKUP}"

# Remove any existing OffGrid config block to avoid duplicates
sed -i '/# ── OffGrid tunnel config/,/# ── End OffGrid/d' "${SSHD_CONFIG}"

# Append OffGrid config
cat >> "${SSHD_CONFIG}" << 'EOF'

# ── OffGrid tunnel config ─────────────────────────────────────────────────────
# Listen on 443 as well as 22
# 443 is almost always allowed outbound from client networks
Port 22
Port 443

# Allow reverse tunnel forwarding
GatewayPorts yes
AllowTcpForwarding yes

# Tunnel user restrictions — no shell, no X11, no agent forwarding
Match User tunnel
    AllowTcpForwarding yes
    X11Forwarding no
    AllowAgentForwarding no
    ForceCommand /bin/false
    PermitOpen any
# ── End OffGrid ───────────────────────────────────────────────────────────────
EOF

log "SSH configured to listen on ports 22 and 443"
log "GatewayPorts and AllowTcpForwarding enabled"

# Validate config before restarting
sshd -t && log "sshd config valid" || err "sshd config invalid — check ${SSHD_CONFIG}"

systemctl restart sshd
log "sshd restarted"

# ── Firewall ──────────────────────────────────────────────────────────────────
step "Firewall"

if command -v ufw &>/dev/null; then
    ufw allow 22/tcp   comment "SSH" 2>/dev/null || true
    ufw allow 443/tcp  comment "OffGrid tunnel" 2>/dev/null || true
    log "UFW: ports 22 and 443 allowed"

elif command -v firewall-cmd &>/dev/null && firewall-cmd --state &>/dev/null; then
    firewall-cmd --permanent --add-port=22/tcp
    firewall-cmd --permanent --add-port=443/tcp
    firewall-cmd --reload
    log "firewalld: ports 22 and 443 allowed"

else
    warn "No firewall detected — ensure ports 22 and 443 are open in your cloud provider's security group"
fi

# ── Connection helper script ──────────────────────────────────────────────────
step "Installing connection helper"

cat > /usr/local/bin/offgrid-connect << 'CONNECT'
#!/usr/bin/env bash
# offgrid-connect — jump from VPS into a connected OffGrid VM
# Usage: offgrid-connect [tunnel-port]

TUNNEL_PORT="${1:-2222}"

echo -e "\033[0;36m[i]\033[0m Connecting to OffGrid VM on tunnel port ${TUNNEL_PORT}..."
echo -e "\033[0;33m[!]\033[0m Password: kali (change it after first login)"
echo ""

# Check if the tunnel port is actually listening
if ! ss -tlnp | grep -q ":${TUNNEL_PORT}"; then
    echo -e "\033[0;31m[✗]\033[0m No VM connected on port ${TUNNEL_PORT}"
    echo -e "    Ports currently forwarded:"
    ss -tlnp | grep -E ':[2-9][0-9]{3}' | awk '{print "    " $4}'
    exit 1
fi

ssh kali@localhost -p "${TUNNEL_PORT}" \
    -o "StrictHostKeyChecking=no" \
    -o "UserKnownHostsFile=/dev/null"
CONNECT

chmod +x /usr/local/bin/offgrid-connect
log "offgrid-connect installed"

# ── Show connected VMs ────────────────────────────────────────────────────────
cat > /usr/local/bin/offgrid-status << 'STATUS'
#!/usr/bin/env bash
# offgrid-status — show which OffGrid VMs are currently connected

echo ""
echo "Connected OffGrid VMs:"
echo "────────────────────────────────────"

TUNNELS=$(ss -tlnp | grep -E ':2[0-9]{3}\b' | awk '{print $4}' | sort)

if [[ -z "$TUNNELS" ]]; then
    echo "  No VMs connected"
else
    while IFS= read -r tunnel; do
        PORT=$(echo "$tunnel" | cut -d: -f2)
        echo "  VM on port ${PORT} → ssh kali@localhost -p ${PORT}"
    done <<< "$TUNNELS"
fi

echo ""
STATUS

chmod +x /usr/local/bin/offgrid-status
log "offgrid-status installed"

# ── Summary ───────────────────────────────────────────────────────────────────
step "VPS setup complete"

echo ""
echo -e "  ${BOLD}OffGrid VPS — Setup Summary${RESET}"
echo -e "  ──────────────────────────────────────────────────"
echo -e "  VPS IP:          ${CYAN}${VPS_IP}${RESET}"
echo -e "  SSH ports:       ${CYAN}22, 443${RESET}"
echo -e "  Tunnel user:     ${CYAN}tunnel${RESET} (no shell)"
echo -e "  Authorized keys: ${CYAN}/home/tunnel/.ssh/authorized_keys${RESET}"
echo ""
echo -e "  ${YELLOW}After building a VM:${RESET}"
echo -e "  1. Boot the VM"
echo -e "  2. Run: ${CYAN}sudo offgrid-setup-tunnel ${VPS_IP}${RESET}"
echo -e "  3. Copy the displayed public key"
echo -e "  4. On this VPS: ${CYAN}echo 'PUBLIC_KEY' >> /home/tunnel/.ssh/authorized_keys${RESET}"
echo ""
echo -e "  ${YELLOW}To connect to a VM from here:${RESET}"
echo -e "  ${CYAN}offgrid-connect${RESET}         # connect to VM on default port 2222"
echo -e "  ${CYAN}offgrid-connect 2223${RESET}    # if running multiple VMs"
echo -e "  ${CYAN}offgrid-status${RESET}          # see which VMs are connected"
echo ""
echo -e "  ${YELLOW}From your laptop (one command, no VPS login needed):${RESET}"
echo -e "  ${CYAN}ssh -J tunnel@${VPS_IP}:443 kali@localhost -p 2222${RESET}"
echo ""
