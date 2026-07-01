#!/usr/bin/env bash
# =============================================================================
# validate.sh
# Runs inside the VM after bootstrap.sh to verify the build is good.
# If anything critical is missing the build fails before exporting —
# you never get a broken VMDK.
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BOLD='\033[1m'; RESET='\033[0m'

PASS=0
FAIL=0
WARN=0

ok()   { echo -e "${GREEN}  ✓${RESET}  $*"; ((PASS++)); }
fail() { echo -e "${RED}  ✗${RESET}  $*"; ((FAIL++)); }
warn() { echo -e "${YELLOW}  !${RESET}  $*"; ((WARN++)); }

echo ""
echo -e "${BOLD}━━━ OffGrid Build Validation ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""

# ── Core tools ────────────────────────────────────────────────────────────────
echo -e "${BOLD}Core tools:${RESET}"
for tool in nmap rustscan masscan netexec ffuf gobuster feroxbuster \
            nuclei sqlmap john hashcat hydra responder tcpdump \
            impacket-smbclient certipy tmux jq git curl wget autossh; do
    command -v "$tool" &>/dev/null && ok "$tool" || fail "$tool not found"
done

# ── Python tools ──────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Python tools:${RESET}"
for pkg in impacket bloodhound pywhisker; do
    python3 -c "import ${pkg//-/_}" 2>/dev/null && ok "python: $pkg" || warn "python: $pkg (non-critical)"
done

# ── Docker ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Docker:${RESET}"
if command -v docker &>/dev/null; then
    ok "docker installed"
    if docker info &>/dev/null 2>&1; then
        ok "docker daemon running"
    else
        fail "docker daemon not running"
    fi
else
    fail "docker not found"
fi

# ── BloodHound CE ─────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}BloodHound CE:${RESET}"
if [[ -f /opt/bloodhound-ce/docker-compose.yml ]]; then
    ok "docker-compose.yml present"
    # Check images are pulled
    if docker images | grep -q "specterops/bloodhound"; then
        ok "bloodhound image pulled"
    else
        warn "bloodhound image not pulled — will need internet on first use"
    fi
else
    fail "BloodHound CE docker-compose.yml missing"
fi

# ── Wordlists ─────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Wordlists:${RESET}"
[[ -d /opt/wordlists ]]                    && ok "/opt/wordlists exists"  || fail "/opt/wordlists missing"
[[ -L /opt/wordlists/seclists ]] || [[ -d /opt/wordlists/seclists ]] \
                                           && ok "seclists present"       || fail "seclists missing"
[[ -f /opt/wordlists/passwords/rockyou.txt ]] \
                                           && ok "rockyou.txt present"    || warn "rockyou.txt missing"
[[ -f /opt/wordlists/ad/common-usernames.txt ]] \
                                           && ok "AD username list present" || fail "AD username list missing"

# ── Directory structure ───────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Engagement structure:${RESET}"
for dir in /engagements /engagements/recon /engagements/web \
           /engagements/ad /engagements/evidence /engagements/reports; do
    [[ -d "$dir" ]] && ok "$dir" || fail "$dir missing"
done

# ── Shell environment ─────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Shell environment:${RESET}"
[[ -f /home/kali/.zshrc ]]   && ok "~/.zshrc exists"    || fail "~/.zshrc missing"
[[ -f /home/kali/.tmux.conf ]] && ok "~/.tmux.conf exists" || fail "~/.tmux.conf missing"
grep -q "ENGAGEMENTS" /home/kali/.zshrc && ok "ENGAGEMENTS alias set" || fail "ENGAGEMENTS not in .zshrc"
grep -q "bhound" /home/kali/.zshrc      && ok "bhound alias set"      || fail "bhound not in .zshrc"

# ── Tunnel ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Reverse tunnel:${RESET}"
[[ -f /etc/systemd/system/offgrid-tunnel.service ]] \
    && ok "tunnel service installed" || fail "tunnel service missing"
systemctl is-enabled offgrid-tunnel &>/dev/null \
    && ok "tunnel service enabled"   || fail "tunnel service not enabled"
[[ -f /home/kali/.ssh/offgrid_tunnel ]] \
    && ok "tunnel key present"       || fail "tunnel key missing"
[[ -f /usr/local/bin/offgrid-setup-tunnel ]] \
    && ok "offgrid-setup-tunnel installed" || fail "offgrid-setup-tunnel missing"

# ── Version stamp ─────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Version:${RESET}"
[[ -f /etc/offgrid-release ]] && ok "$(cat /etc/offgrid-release | tr '\n' '  ')" || fail "version stamp missing"

# ── Full variant extras ───────────────────────────────────────────────────────
if [[ -f /etc/offgrid-release ]] && grep -q "full-gui" /etc/offgrid-release 2>/dev/null; then
    echo ""
    echo -e "${BOLD}Full variant extras:${RESET}"
    command -v msfconsole  &>/dev/null && ok "metasploit"  || fail "metasploit missing"
    command -v burpsuite   &>/dev/null && ok "burpsuite"   || warn "burpsuite missing (non-critical)"
    command -v wireshark   &>/dev/null && ok "wireshark"   || warn "wireshark missing"
    [[ -f /home/kali/Desktop/BloodHound.desktop ]] \
        && ok "desktop shortcuts" || warn "desktop shortcuts missing"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "  Passed:   ${GREEN}${PASS}${RESET}"
echo -e "  Warnings: ${YELLOW}${WARN}${RESET}"
echo -e "  Failed:   ${RED}${FAIL}${RESET}"
echo ""

if [[ ${FAIL} -gt 0 ]]; then
    echo -e "${RED}BUILD VALIDATION FAILED — ${FAIL} critical check(s) failed${RESET}"
    echo -e "Fix bootstrap.sh and rebuild. Do not distribute this VM."
    echo ""
    exit 1
else
    echo -e "${GREEN}BUILD VALIDATION PASSED${RESET}"
    [[ ${WARN} -gt 0 ]] && echo -e "${YELLOW}${WARN} warning(s) — review above${RESET}"
    echo ""
    exit 0
fi
