#!/usr/bin/env bash
# =============================================================================
# OffGrid Full — Bootstrap
# Provisions a full Kali desktop VM with all tools, Docker, and reverse tunnel
# Everything is installed during build — zero internet required after deployment
# Run once: sudo bash bootstrap.sh
# =============================================================================

set -euo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log()  { echo -e "${GREEN}[+]${RESET} $*"; }
warn() { echo -e "${YELLOW}[!]${RESET} $*"; }
err()  { echo -e "${RED}[✗]${RESET} $*"; exit 1; }
step() { echo -e "\n${BOLD}━━━ $* ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"; }

# ── Config ────────────────────────────────────────────────────────────────────
VERSION="1.0.0"
WORDLISTS="/opt/wordlists"
ENGAGEMENTS="/engagements"
SHELL_RC="/home/kali/.zshrc"
USER="kali"

# ── Preflight ─────────────────────────────────────────────────────────────────
step "Preflight"

[[ "$(id -u)" -eq 0 ]] || err "Run as root: sudo bash bootstrap.sh"

# Ensure root filesystem is mounted read-write
# Can be read-only if bootstrap runs too early after boot
if ! touch /etc/offgrid-test 2>/dev/null; then
    log "Remounting root filesystem read-write..."
    mount -o remount,rw / || err "Failed to remount filesystem"
fi
rm -f /etc/offgrid-test

grep -qi kali /etc/os-release 2>/dev/null || warn "Not Kali — some packages may differ"

log "Starting OffGrid Full bootstrap v${VERSION}"
log "$(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '\"')"

# ── Repositories ──────────────────────────────────────────────────────────────
step "Configuring repositories"

# Full Kali rolling repos
cat > /etc/apt/sources.list << 'EOF'
deb http://http.kali.org/kali kali-rolling main contrib non-free non-free-firmware
EOF

# Prerequisites for adding Docker repo
apt-get update -qq
apt-get install -y -qq \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    apt-transport-https

# Docker official repo
install -m 0755 -d /usr/share/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg \
    | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
chmod a+r /usr/share/keyrings/docker-archive-keyring.gpg

echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] \
https://download.docker.com/linux/debian bookworm stable" \
    > /etc/apt/sources.list.d/docker.list

apt-get update -qq
log "Repositories configured"

# ── System update ─────────────────────────────────────────────────────────────
step "System update"

# Set apt retries and timeouts — QEMU NAT can be flaky with some mirrors
cat > /etc/apt/apt.conf.d/99offgrid << 'EOF'
Acquire::Retries "5";
Acquire::http::Timeout "60";
Acquire::https::Timeout "60";
EOF

# Use --fix-missing so a single unreachable mirror doesn't abort everything
apt-get upgrade -y -qq --fix-missing || warn "Some packages failed to upgrade — continuing"
apt-get autoremove -y -qq
log "System updated"

# ── Docker ────────────────────────────────────────────────────────────────────
step "Docker"

apt-get install -y -qq \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-compose-plugin

systemctl enable docker
systemctl start docker
usermod -aG docker ${USER}

log "Docker installed and started"

# ── Full Kali toolset ─────────────────────────────────────────────────────────
step "Installing full Kali toolset"

# kali-linux-default is already installed by preseed
# Add the extended toolsets on top
apt-get install -y -qq --fix-missing \ \
    kali-tools-top10 \
    kali-tools-web \
    kali-tools-passwords \
    kali-tools-exploitation \
    kali-tools-post-exploitation \
    kali-tools-sniffing-spoofing \
    kali-tools-wireless \
    kali-tools-forensics \
    kali-tools-reporting \
    \
    `# ── Active Directory (not always in metapackages)` \
    netexec \
    crackmapexec \
    impacket-scripts \
    certipy-ad \
    ldapdomaindump \
    bloodhound \
    \
    `# ── Additional web tools` \
    ffuf \
    feroxbuster \
    nuclei \
    whatweb \
    \
    `# ── Wordlists` \
    seclists \
    wordlists \
    \
    `# ── Utilities` \
    tmux \
    jq \
    git \
    autossh \
    net-tools \
    dnsutils \
    whois \
    python3-pip \
    python3-venv \
    terminator \
    gedit \
    2>/dev/null || warn "One or more packages failed — check output above"

log "Full toolset installed"

# ── Python tools ──────────────────────────────────────────────────────────────
step "Python tools"

pip3 install --break-system-packages -q \
    impacket \
    pywhisker \
    pywerview \
    2>/dev/null || warn "Some pip packages failed"

log "Python tools installed"

# ── Burp Suite — download standalone installer ────────────────────────────────
step "Burp Suite Pro check"

# Burp Community is already in kali-linux-default
# If you have a Pro license, place burpsuite_pro_linux.jar in /opt/burpsuite/
if command -v burpsuite &>/dev/null; then
    log "Burp Suite already installed via Kali packages"
else
    warn "Burp Suite not found — install manually if needed"
fi

# ── BloodHound CE ─────────────────────────────────────────────────────────────
step "BloodHound CE"

mkdir -p /opt/bloodhound-ce

cat > /opt/bloodhound-ce/docker-compose.yml << 'EOF'
version: "3.8"
services:
  bloodhound:
    image: specterops/bloodhound:latest
    environment:
      - bloodhound_auth_initial_admin_password=OffGrid2024!
    ports:
      - "127.0.0.1:8080:8080"
    depends_on:
      - neo4j
      - postgres
    restart: unless-stopped

  neo4j:
    image: neo4j:4.4
    environment:
      - NEO4J_AUTH=neo4j/OffGridNeo4j!
    volumes:
      - neo4j-data:/data
    restart: unless-stopped

  postgres:
    image: postgres:13
    environment:
      - POSTGRES_DB=bloodhound
      - POSTGRES_USER=bloodhound
      - POSTGRES_PASSWORD=OffGridPG!
    volumes:
      - pg-data:/var/lib/postgresql/data
    restart: unless-stopped

volumes:
  neo4j-data:
  pg-data:
EOF

log "Pulling BloodHound CE images..."
cd /opt/bloodhound-ce
docker compose pull 2>/dev/null && \
    log "BloodHound CE images pulled — works offline from now on" || \
    warn "Docker pull failed — run: cd /opt/bloodhound-ce && docker compose pull"
cd - > /dev/null

log "BloodHound CE ready → start with: bhound"

# ── Wordlists ─────────────────────────────────────────────────────────────────
step "Staging wordlists"

mkdir -p "${WORDLISTS}"/{passwords,usernames,web,dns,ad}

# SecLists symlink
if [[ -d /usr/share/seclists ]]; then
    ln -sfn /usr/share/seclists "${WORDLISTS}/seclists"
    log "SecLists symlinked"
elif [[ -d /usr/share/wordlists/seclists ]]; then
    ln -sfn /usr/share/wordlists/seclists "${WORDLISTS}/seclists"
    log "SecLists symlinked"
else
    warn "SecLists not found"
fi

# rockyou
[[ -f /usr/share/wordlists/rockyou.txt.gz ]] && \
    gunzip -kf /usr/share/wordlists/rockyou.txt.gz 2>/dev/null || true
[[ -f /usr/share/wordlists/rockyou.txt ]] && \
    ln -sfn /usr/share/wordlists/rockyou.txt "${WORDLISTS}/passwords/rockyou.txt"

# AD lists
cat > "${WORDLISTS}/ad/common-usernames.txt" << 'EOF'
administrator
admin
svc_admin
svc_backup
svc_sql
svc_scan
service
backup
helpdesk
support
it
sysadmin
netadmin
monitoring
scanner
EOF

cat > "${WORDLISTS}/ad/common-passwords.txt" << 'EOF'
Password1
Password1!
Password123
Password123!
Welcome1
Welcome1!
Welcome123
Summer2024!
Winter2024!
Spring2024!
Autumn2024!
Company2024!
January2024!
January2025!
Changeme1!
EOF

log "Wordlists staged at ${WORDLISTS}"

# ── Nuclei templates ──────────────────────────────────────────────────────────
step "Nuclei templates"

if command -v nuclei &>/dev/null; then
    nuclei -update-templates -silent 2>/dev/null && \
        log "Nuclei templates downloaded" || \
        warn "Nuclei template update failed"
else
    warn "Nuclei not found"
fi

# ── Metasploit DB setup ───────────────────────────────────────────────────────
step "Metasploit database"

# Init the MSF PostgreSQL database so it works on first boot
if command -v msfdb &>/dev/null; then
    msfdb init 2>/dev/null && log "Metasploit DB initialised" || \
        warn "msfdb init failed — run manually: msfdb init"
else
    warn "msfdb not found"
fi

# ── Engagement directory ──────────────────────────────────────────────────────
step "Engagement structure"

mkdir -p "${ENGAGEMENTS}"/{recon,web,ad,network,evidence,loot,notes,reports}
chown -R ${USER}:${USER} "${ENGAGEMENTS}"
chmod 700 "${ENGAGEMENTS}"
log "Engagement root: ${ENGAGEMENTS}"

# ── Desktop shortcuts ─────────────────────────────────────────────────────────
step "Desktop shortcuts"

DESKTOP_DIR="/home/${USER}/Desktop"
mkdir -p "${DESKTOP_DIR}"

# BloodHound CE shortcut
cat > "${DESKTOP_DIR}/BloodHound.desktop" << 'EOF'
[Desktop Entry]
Name=BloodHound CE
Comment=Start BloodHound Community Edition
Exec=bash -c "cd /opt/bloodhound-ce && docker-compose up -d && xdg-open http://localhost:8080"
Icon=bloodhound
Terminal=false
Type=Application
Categories=Security;
EOF

# Engagements folder shortcut
cat > "${DESKTOP_DIR}/Engagements.desktop" << 'EOF'
[Desktop Entry]
Name=Engagements
Comment=Open engagements folder
Exec=thunar /engagements
Icon=folder
Terminal=false
Type=Application
Categories=
EOF

# Terminal shortcut
cat > "${DESKTOP_DIR}/Terminal.desktop" << 'EOF'
[Desktop Entry]
Name=Terminal
Comment=Open terminal
Exec=terminator
Icon=terminator
Terminal=false
Type=Application
Categories=
EOF

chmod +x "${DESKTOP_DIR}"/*.desktop
chown -R ${USER}:${USER} "${DESKTOP_DIR}"
log "Desktop shortcuts created"

# ── tmux ─────────────────────────────────────────────────────────────────────
step "tmux config"

cat > /home/${USER}/.tmux.conf << 'EOF'
set -g default-terminal "screen-256color"
set -g history-limit 50000
set -g mouse on

unbind C-b
set-option -g prefix C-a
bind-key C-a send-prefix

bind | split-window -h -c "#{pane_current_path}"
bind - split-window -v -c "#{pane_current_path}"
unbind '"'
unbind %

bind -n M-Left  select-pane -L
bind -n M-Right select-pane -R
bind -n M-Up    select-pane -U
bind -n M-Down  select-pane -D

bind r source-file ~/.tmux.conf \; display "Reloaded"

set -g status-style bg=colour235,fg=colour136
set -g status-left "#[fg=colour33,bold] OffGrid #[fg=colour240]| "
set -g status-right "#[fg=colour136]%H:%M  #[fg=colour33]%d-%b-%Y "
set -g status-left-length 20
set -g window-status-current-style fg=colour166,bold
set -g base-index 1
EOF

chown ${USER}:${USER} /home/${USER}/.tmux.conf
log "tmux configured"

# ── Shell environment ─────────────────────────────────────────────────────────
step "Shell environment"

cat >> "${SHELL_RC}" << 'EOF'

# ══════════════════════════════════════════════════════
# OffGrid Full environment
# ══════════════════════════════════════════════════════

export ENGAGEMENTS="/engagements"
export WORDLISTS="/opt/wordlists"
export SECLISTS="/opt/wordlists/seclists"

# ── Navigation ────────────────────────────────────────
alias eng="cd /engagements"
alias wl="cd /opt/wordlists"

# ── BloodHound CE ─────────────────────────────────────
alias bhound="cd /opt/bloodhound-ce && docker compose up -d && xdg-open http://localhost:8080 2>/dev/null || echo 'BloodHound → http://localhost:8080'"
alias bhound-stop="cd /opt/bloodhound-ce && docker compose down"
alias bhound-status="cd /opt/bloodhound-ce && docker compose ps"

# ── Nmap ──────────────────────────────────────────────
nmap-quick() { nmap -sV --open -oA "${PWD}/nmap-quick-${1/\//-}" "$1"; }
nmap-full()  { nmap -sV -sC -p- --open -oA "${PWD}/nmap-full-${1/\//-}" "$1"; }
nmap-udp()   { nmap -sU --top-ports 200 -oA "${PWD}/nmap-udp-${1/\//-}" "$1"; }
nmap-smb()   { nmap -p 445 --script smb-vuln* -oA "${PWD}/nmap-smb-${1/\//-}" "$1"; }
nmap-web()   { nmap -p 80,443,8080,8443,8000,8888 --script http-* -oA "${PWD}/nmap-web-${1/\//-}" "$1"; }

# ── netexec ───────────────────────────────────────────
alias nxc="netexec"
smb-null()    { netexec smb "$1" -u '' -p '' --shares 2>/dev/null; }
smb-guest()   { netexec smb "$1" -u 'guest' -p '' --shares 2>/dev/null; }
smb-spray()   { netexec smb "$1" -u "$2" -p "$3" --continue-on-success; }
winrm-spray() { netexec winrm "$1" -u "$2" -p "$3" --continue-on-success; }
ldap-enum()   { netexec ldap "$1" -u "$2" -p "$3" --users --groups; }

# ── Web fuzzing ───────────────────────────────────────
ffuf-dir()     { ffuf -u "http://$1/FUZZ" -w "${SECLISTS}/Discovery/Web-Content/directory-list-2.3-medium.txt" -fc 404 -t 50; }
ffuf-dir-ssl() { ffuf -u "https://$1/FUZZ" -w "${SECLISTS}/Discovery/Web-Content/directory-list-2.3-medium.txt" -fc 404 -t 50; }
ffuf-vhost()   { ffuf -u "http://$2" -H "Host: FUZZ.$1" -w "${SECLISTS}/Discovery/DNS/subdomains-top1million-5000.txt" -fc 302,404; }
ffuf-params()  { ffuf -u "http://$1?FUZZ=test" -w "${SECLISTS}/Discovery/Web-Content/burp-parameter-names.txt" -fc 404; }

# ── Utils ─────────────────────────────────────────────
alias myip="ip -br addr"
alias listening="ss -tlnp"
alias routes="ip route"
alias timestamp="date +%Y%m%d-%H%M%S"
alias urlencode='python3 -c "import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1]))"'
alias urldecode='python3 -c "import sys,urllib.parse; print(urllib.parse.unquote(sys.argv[1]))"'
alias b64e='python3 -c "import sys,base64; print(base64.b64encode(sys.argv[1].encode()).decode())"'
alias b64d='python3 -c "import sys,base64; print(base64.b64decode(sys.argv[1]).decode())"'

EOF

chown ${USER}:${USER} "${SHELL_RC}"
log "Shell environment configured"

# ── Permissions ───────────────────────────────────────────────────────────────
chown -R ${USER}:${USER} "${WORDLISTS}" 2>/dev/null || true

# ── Reverse SSH tunnel ────────────────────────────────────────────────────────
step "Reverse SSH tunnel"

SSH_DIR="/home/${USER}/.ssh"
TUNNEL_KEY="${SSH_DIR}/offgrid_tunnel"

mkdir -p "${SSH_DIR}"
chmod 700 "${SSH_DIR}"

if [[ ! -f "${TUNNEL_KEY}" ]]; then
    ssh-keygen -t ed25519 \
        -f "${TUNNEL_KEY}" \
        -N "" \
        -C "offgrid-full-tunnel-v${VERSION}" \
        -q
    log "Tunnel key pair generated"
fi

chown -R ${USER}:${USER} "${SSH_DIR}"
chmod 600 "${TUNNEL_KEY}"
chmod 644 "${TUNNEL_KEY}.pub"

cat > /etc/systemd/system/offgrid-tunnel.service << 'UNIT'
[Unit]
Description=OffGrid reverse SSH tunnel
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
User=kali
Environment="AUTOSSH_GATETIME=0"
EnvironmentFile=-/etc/offgrid-tunnel.conf
ExecStart=/usr/bin/autossh -M 0 -N \
    -o "ServerAliveInterval=30" \
    -o "ServerAliveCountMax=3" \
    -o "ExitOnForwardFailure=yes" \
    -o "StrictHostKeyChecking=no" \
    -o "UserKnownHostsFile=/dev/null" \
    -o "ConnectTimeout=10" \
    -i /home/kali/.ssh/offgrid_tunnel \
    -R ${TUNNEL_PORT}:localhost:22 \
    tunnel@${VPS_IP} -p ${VPS_SSH_PORT}
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
UNIT

cat > /etc/offgrid-tunnel.conf << 'CONF'
VPS_IP=YOUR_VPS_IP
VPS_SSH_PORT=443
TUNNEL_PORT=2222
CONF

systemctl enable offgrid-tunnel.service
log "Tunnel service enabled"

# Setup helper
cat > /usr/local/bin/offgrid-setup-tunnel << 'SETUP'
#!/usr/bin/env bash
set -euo pipefail
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; RESET='\033[0m'
log()  { echo -e "${GREEN}[+]${RESET} $*"; }
info() { echo -e "${CYAN}[i]${RESET} $*"; }

[[ "$(id -u)" -eq 0 ]] || { echo "Run as root: sudo offgrid-setup-tunnel <vps-ip>"; exit 1; }
[[ -n "${1:-}" ]] || { echo "Usage: sudo offgrid-setup-tunnel <vps-ip> [vps-port] [tunnel-port]"; exit 1; }

VPS_IP="$1"
VPS_SSH_PORT="${2:-443}"
TUNNEL_PORT="${3:-2222}"

cat > /etc/offgrid-tunnel.conf << EOF
VPS_IP=${VPS_IP}
VPS_SSH_PORT=${VPS_SSH_PORT}
TUNNEL_PORT=${TUNNEL_PORT}
EOF

echo ""
echo -e "${YELLOW}━━━ Add this public key to your VPS ━━━━━━━━━━━━━━━━━━━━━${RESET}"
cat /home/kali/.ssh/offgrid_tunnel.pub
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
info "On your VPS:"
info "  echo '$(cat /home/kali/.ssh/offgrid_tunnel.pub)' >> /home/tunnel/.ssh/authorized_keys"
echo ""

systemctl restart offgrid-tunnel.service
sleep 3
systemctl is-active --quiet offgrid-tunnel.service && \
    log "Tunnel running" || \
    echo "Check: journalctl -u offgrid-tunnel -n 20"
SETUP

chmod +x /usr/local/bin/offgrid-setup-tunnel
log "offgrid-setup-tunnel installed"

# ── Version stamp ─────────────────────────────────────────────────────────────
echo "OFFGRID_FULL_VERSION=${VERSION}" > /etc/offgrid-release
echo "BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> /etc/offgrid-release
echo "VARIANT=full-gui" >> /etc/offgrid-release

# ── Done ──────────────────────────────────────────────────────────────────────
step "Done"

echo ""
echo -e "  ${BOLD}OffGrid Full v${VERSION}${RESET}"
echo -e "  ─────────────────────────────────────────────────"
echo -e "  Engagements  ${CYAN}${ENGAGEMENTS}${RESET}"
echo -e "  Wordlists    ${CYAN}${WORDLISTS}${RESET}"
echo -e "  BloodHound   ${CYAN}http://localhost:8080${RESET}  (bhound to start)"
echo -e "  Desktop      ${CYAN}XFCE with shortcuts${RESET}"
echo ""
echo -e "  ${YELLOW}Tunnel public key:${RESET}"
cat /home/${USER}/.ssh/offgrid_tunnel.pub
echo ""
echo -e "  ${YELLOW}Next steps:${RESET}"
echo -e "  1. source ~/.zshrc"
echo -e "  2. sudo offgrid-setup-tunnel <your-vps-ip>"
echo -e "  3. bhound"
echo ""
