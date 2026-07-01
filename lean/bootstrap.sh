#!/usr/bin/env bash
# =============================================================================
# OffGrid Bootstrap — lean edition
# Provisions a fresh Kali netinst into a ready-to-use pentest environment
# No internet required after this runs
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
VERSION="0.3.0"
WORDLISTS="/opt/wordlists"
ENGAGEMENTS="/engagements"
SHELL_RC="/home/kali/.zshrc"
USER="kali"

# ── Preflight ─────────────────────────────────────────────────────────────────
step "Preflight"

[[ "$(id -u)" -eq 0 ]] || err "Run as root: sudo bash bootstrap.sh"
grep -qi kali /etc/os-release 2>/dev/null || warn "Not Kali — some packages may differ"

log "Starting OffGrid bootstrap v${VERSION}"
log "$(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '\"')"

# ── System update ─────────────────────────────────────────────────────────────
step "System update"

apt-get update -qq
apt-get upgrade -y -qq
apt-get autoremove -y -qq
log "System updated"

# ── Tool installation ─────────────────────────────────────────────────────────
step "Installing tools"

# Single apt call — faster and cleaner than looping
apt-get install -y -qq \
    \
    `# ── Recon ──────────────────────────────────────` \
    nmap rustscan masscan \
    \
    `# ── Active Directory ────────────────────────────` \
    netexec crackmapexec impacket-scripts \
    certipy-ad ldapdomaindump \
    \
    `# ── Web ─────────────────────────────────────────` \
    ffuf gobuster feroxbuster nuclei \
    sqlmap whatweb wfuzz \
    \
    `# ── Password ────────────────────────────────────` \
    john hashcat hydra \
    \
    `# ── Network ─────────────────────────────────────` \
    wireshark-common tcpdump responder \
    \
    `# ── Wordlists ───────────────────────────────────` \
    seclists wordlists \
    \
    `# ── Utilities ───────────────────────────────────` \
    tmux jq git curl wget \
    python3-pip python3-venv \
    net-tools dnsutils whois \
    2>/dev/null || warn "One or more packages failed — check output above"

log "Tools installed"

# ── Python tools (latest versions not in apt) ─────────────────────────────────
step "Python tools"

pip3 install --break-system-packages -q \
    impacket \
    bloodhound \
    certipy-ad \
    pywhisker \
    pywerview \
    netexec \
    2>/dev/null || warn "Some pip packages failed"

log "Python tools installed"

# ── BloodHound CE ─────────────────────────────────────────────────────────────
step "BloodHound CE"

if command -v docker &>/dev/null; then
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

    # Pull images now while we have internet — so it works offline later
    log "Pulling BloodHound CE images (this takes a few minutes)..."
    cd /opt/bloodhound-ce
    docker-compose pull 2>/dev/null || warn "Docker pull failed — run manually when connected"
    cd - > /dev/null

    log "BloodHound CE ready → start with: bhound"
    log "Access at: http://localhost:8080  (admin / OffGrid2024!)"
else
    warn "Docker not found — BloodHound CE skipped"
    warn "Install Docker: curl -fsSL https://get.docker.com | sh"
fi

# ── Wordlists ─────────────────────────────────────────────────────────────────
step "Staging wordlists"

mkdir -p "${WORDLISTS}"/{passwords,usernames,web,dns,ad}

# SecLists — symlink, never copy (saves ~1GB)
if   [[ -d /usr/share/seclists ]]; then
    ln -sfn /usr/share/seclists "${WORDLISTS}/seclists"
elif [[ -d /usr/share/wordlists/seclists ]]; then
    ln -sfn /usr/share/wordlists/seclists "${WORDLISTS}/seclists"
else
    warn "SecLists not found — run: apt install seclists"
fi

# rockyou — decompress if needed
[[ -f /usr/share/wordlists/rockyou.txt.gz ]] && \
    gunzip -kf /usr/share/wordlists/rockyou.txt.gz 2>/dev/null || true
[[ -f /usr/share/wordlists/rockyou.txt ]] && \
    ln -sfn /usr/share/wordlists/rockyou.txt "${WORDLISTS}/passwords/rockyou.txt"

# Common AD usernames
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

# Common service passwords for spraying
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
        warn "Nuclei template update failed — run manually: nuclei -update-templates"
else
    warn "Nuclei not found"
fi

# ── Engagement directory ──────────────────────────────────────────────────────
step "Engagement structure"

mkdir -p "${ENGAGEMENTS}"/{recon,web,ad,network,evidence,loot,notes,reports}
chown -R ${USER}:${USER} "${ENGAGEMENTS}"
chmod 700 "${ENGAGEMENTS}"
log "Engagement root: ${ENGAGEMENTS}"

# ── tmux ─────────────────────────────────────────────────────────────────────
step "tmux config"

cat > /home/${USER}/.tmux.conf << 'EOF'
set -g default-terminal "screen-256color"
set -g history-limit 50000
set -g mouse on

# Prefix: Ctrl+a
unbind C-b
set-option -g prefix C-a
bind-key C-a send-prefix

# Splits
bind | split-window -h -c "#{pane_current_path}"
bind - split-window -v -c "#{pane_current_path}"
unbind '"'
unbind %

# Pane navigation — Alt+arrow, no prefix
bind -n M-Left  select-pane -L
bind -n M-Right select-pane -R
bind -n M-Up    select-pane -U
bind -n M-Down  select-pane -D

# Reload config
bind r source-file ~/.tmux.conf \; display "Reloaded"

# Status bar
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
# OffGrid environment
# ══════════════════════════════════════════════════════

export ENGAGEMENTS="/engagements"
export WORDLISTS="/opt/wordlists"
export SECLISTS="/opt/wordlists/seclists"

# ── Navigation ────────────────────────────────────────
alias eng="cd /engagements"
alias wl="cd /opt/wordlists"

# ── BloodHound CE ─────────────────────────────────────
alias bhound="cd /opt/bloodhound-ce && docker-compose up -d && echo 'BloodHound → http://localhost:8080'"
alias bhound-stop="cd /opt/bloodhound-ce && docker-compose down"
alias bhound-status="cd /opt/bloodhound-ce && docker-compose ps"

# ── Nmap — always saves output ────────────────────────
nmap-quick() {
    # Fast — open ports + service versions
    nmap -sV --open -oA "${PWD}/nmap-quick-${1/\//-}" "$1"
}
nmap-full() {
    # All ports — service versions + default scripts
    nmap -sV -sC -p- --open -oA "${PWD}/nmap-full-${1/\//-}" "$1"
}
nmap-udp() {
    # Top 200 UDP
    nmap -sU --top-ports 200 -oA "${PWD}/nmap-udp-${1/\//-}" "$1"
}
nmap-smb() {
    # SMB vuln check
    nmap -p 445 --script smb-vuln* -oA "${PWD}/nmap-smb-${1/\//-}" "$1"
}
nmap-web() {
    # Web ports with http scripts
    nmap -p 80,443,8080,8443,8000,8888 --script http-* -oA "${PWD}/nmap-web-${1/\//-}" "$1"
}

# ── netexec shortcuts ─────────────────────────────────
alias nxc="netexec"
smb-null()   { netexec smb "$1" -u '' -p '' --shares 2>/dev/null; }
smb-guest()  { netexec smb "$1" -u 'guest' -p '' --shares 2>/dev/null; }
smb-spray()  { netexec smb "$1" -u "$2" -p "$3" --continue-on-success; }
winrm-spray(){ netexec winrm "$1" -u "$2" -p "$3" --continue-on-success; }
ldap-enum()  { netexec ldap "$1" -u "$2" -p "$3" --users --groups; }

# ── Web fuzzing ───────────────────────────────────────
ffuf-dir() {
    ffuf -u "http://$1/FUZZ" \
         -w "${SECLISTS}/Discovery/Web-Content/directory-list-2.3-medium.txt" \
         -fc 404 -t 50
}
ffuf-dir-ssl() {
    ffuf -u "https://$1/FUZZ" \
         -w "${SECLISTS}/Discovery/Web-Content/directory-list-2.3-medium.txt" \
         -fc 404 -t 50
}
ffuf-vhost() {
    ffuf -u "http://$2" \
         -H "Host: FUZZ.$1" \
         -w "${SECLISTS}/Discovery/DNS/subdomains-top1million-5000.txt" \
         -fc 302,404
}
ffuf-params() {
    ffuf -u "http://$1?FUZZ=test" \
         -w "${SECLISTS}/Discovery/Web-Content/burp-parameter-names.txt" \
         -fc 404
}

# ── Utils ──────────────────────────────────────────────
alias myip="ip -br addr"
alias listening="ss -tlnp"
alias routes="ip route"
alias timestamp="date +%Y%m%d-%H%M%S"
alias hex="xxd"
alias urlencode='python3 -c "import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1]))"'
alias urldecode='python3 -c "import sys,urllib.parse; print(urllib.parse.unquote(sys.argv[1]))"'
alias b64e='python3 -c "import sys,base64; print(base64.b64encode(sys.argv[1].encode()).decode())"'
alias b64d='python3 -c "import sys,base64; print(base64.b64decode(sys.argv[1]).decode())"'

EOF

chown ${USER}:${USER} "${SHELL_RC}"
log "Shell environment configured"

# ── Permissions ───────────────────────────────────────────────────────────────
chown -R ${USER}:${USER} "${WORDLISTS}" 2>/dev/null || true

# ── Done ──────────────────────────────────────────────────────────────────────
step "Done"

echo ""
echo -e "  ${BOLD}OffGrid v${VERSION}${RESET}"
echo -e "  ─────────────────────────────────────────────────"
echo -e "  Engagements  ${CYAN}${ENGAGEMENTS}${RESET}"
echo -e "  Wordlists    ${CYAN}${WORDLISTS}${RESET}"
echo -e "  BloodHound   ${CYAN}http://localhost:8080${RESET}  (bhound to start)"
echo ""
echo -e "  ${YELLOW}Next:${RESET}"
echo -e "  1. source ~/.zshrc"
echo -e "  2. bhound           # start BloodHound CE"
echo -e "  3. cd /engagements  # start working"
echo ""
