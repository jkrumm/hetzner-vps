#!/usr/bin/env bash
# =============================================================================
# Hetzner VPS — Initial Server Provisioning & Hardening
# Run as root on a fresh Ubuntu 24.04 server.
# Idempotent: safe to re-run.
# Supports IPv6-only hosts (CX33 without IPv4).
# =============================================================================
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

DEPLOY_USER="jkrumm"
GITHUB_USERNAME="jkrumm"
REPO_DIR="/home/${DEPLOY_USER}/hetzner-vps"

log()  { echo "[$(date +%H:%M:%S)] $*"; }
skip() { echo "[$(date +%H:%M:%S)] SKIP: $*"; }
warn() { echo "[$(date +%H:%M:%S)] WARN: $*"; }

# Must run as root
[[ $EUID -ne 0 ]] && echo "Run as root." && exit 1

# =============================================================================
# 1. System update
# =============================================================================
log "Updating system packages..."
apt-get update -qq && apt-get upgrade -y -qq

# =============================================================================
# 2. Create deploy user
# =============================================================================
if id "${DEPLOY_USER}" &>/dev/null; then
  skip "User ${DEPLOY_USER} already exists"
else
  log "Creating user ${DEPLOY_USER}..."
  adduser --disabled-password --gecos "" "${DEPLOY_USER}"
  usermod -aG sudo "${DEPLOY_USER}"
fi

# Add SSH keys — try GitHub first, fall back to root's authorized_keys
log "Fetching SSH keys..."
mkdir -p "/home/${DEPLOY_USER}/.ssh"
chmod 700 "/home/${DEPLOY_USER}/.ssh"
touch "/home/${DEPLOY_USER}/.ssh/authorized_keys"
if curl -fsSL --max-time 10 "https://github.com/${GITHUB_USERNAME}.keys" \
    >> "/home/${DEPLOY_USER}/.ssh/authorized_keys" 2>/dev/null; then
  log "SSH keys fetched from GitHub"
elif [[ -s /root/.ssh/authorized_keys ]]; then
  warn "GitHub unreachable (IPv6-only host?) — copying root authorized_keys as fallback"
  cat /root/.ssh/authorized_keys >> "/home/${DEPLOY_USER}/.ssh/authorized_keys"
else
  warn "Could not fetch SSH keys from GitHub and no root keys found. Add keys manually to /home/${DEPLOY_USER}/.ssh/authorized_keys"
fi
sort -u "/home/${DEPLOY_USER}/.ssh/authorized_keys" -o "/home/${DEPLOY_USER}/.ssh/authorized_keys"
chmod 600 "/home/${DEPLOY_USER}/.ssh/authorized_keys"
chown -R "${DEPLOY_USER}:${DEPLOY_USER}" "/home/${DEPLOY_USER}/.ssh"

# =============================================================================
# 3. SSH hardening
# NOTE: SSH binds to Tailscale IP only — run 'tailscale up' BEFORE restarting sshd.
# =============================================================================
log "Hardening SSH..."
cat > /etc/ssh/sshd_config.d/99-hardening.conf << 'EOF'
# Hardened SSH config — key authentication only, Tailscale interface only.
PermitRootLogin no
PasswordAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
AllowUsers jkrumm
MaxAuthTries 3
LoginGraceTime 30
X11Forwarding no
PrintLastLog yes
TCPKeepAlive yes
ClientAliveInterval 300
ClientAliveCountMax 2
# Bind to Tailscale interface only (set ListenAddress after tailscale up)
# ListenAddress <tailscale-ip>   <- Uncomment and set after Tailscale is connected
EOF
# Do NOT restart sshd here — do it manually after Tailscale is connected.
log "SSH config written. Restart sshd AFTER Tailscale is up: systemctl restart sshd"

# =============================================================================
# 4. Kernel hardening (sysctl)
# =============================================================================
log "Applying sysctl hardening..."
cat > /etc/sysctl.d/99-hardening.conf << 'EOF'
# Required for Valkey / Redis
vm.overcommit_memory = 1

# Network hardening
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1

# Kernel hardening
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
kernel.unprivileged_bpf_disabled = 1
net.core.bpf_jit_harden = 2
EOF
sysctl -p /etc/sysctl.d/99-hardening.conf

# =============================================================================
# 5. UFW firewall
# =============================================================================
log "Configuring UFW..."
apt-get install -y -qq ufw
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
# No inbound 80/443 — Traefik has no host ports; all public traffic enters via
# Cloudflare Tunnel (outbound-only). Hetzner Firewall enforces zero inbound too.
# Tailscale interface: allow everything (SSH, monitoring agents, OTel)
ufw allow in on tailscale0 comment "Tailscale"
ufw --force enable
log "UFW enabled. SSH only accessible via Tailscale."

# =============================================================================
# 6. Unattended upgrades (OS security patches only)
# =============================================================================
log "Configuring unattended-upgrades..."
apt-get install -y -qq unattended-upgrades
cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
};

// Never auto-upgrade Docker or container tooling — Watchtower handles container updates.
Unattended-Upgrade::Package-Blacklist {
    "docker-ce";
    "docker-ce-cli";
    "containerd.io";
    "docker-compose-plugin";
    "docker-buildx-plugin";
};

Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF

cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
EOF

systemctl enable unattended-upgrades

# =============================================================================
# 7. Install Docker
# =============================================================================
if command -v docker &>/dev/null; then
  skip "Docker already installed ($(docker --version))"
else
  log "Installing Docker..."
  apt-get install -y -qq ca-certificates curl
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
    https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  usermod -aG docker "${DEPLOY_USER}"
fi

# =============================================================================
# 8. Install tooling
# =============================================================================

# AWS CLI v2 (for S3 backup uploads) — official installer from awscli.amazonaws.com
if command -v aws &>/dev/null; then
  skip "AWS CLI already installed ($(aws --version 2>&1 | cut -d' ' -f1))"
else
  log "Installing AWS CLI v2..."
  apt-get install -y -qq unzip
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
  unzip -q /tmp/awscliv2.zip -d /tmp
  /tmp/aws/install
  rm -rf /tmp/aws /tmp/awscliv2.zip
fi

# Tailscale
if command -v tailscale &>/dev/null; then
  skip "Tailscale already installed"
else
  log "Installing Tailscale..."
  curl -fsSL https://tailscale.com/install.sh | sh
fi

# Doppler CLI — installer downloads from packages.doppler.com (IPv4 only on some CDNs)
if command -v doppler &>/dev/null; then
  skip "Doppler already installed ($(doppler --version 2>&1))"
else
  log "Installing Doppler CLI..."
  apt-get install -y -qq apt-transport-https
  if curl -Ls --max-time 15 https://cli.doppler.com/install.sh | sh; then
    log "Doppler CLI installed"
  else
    warn "Doppler CLI install failed (IPv4-only CDN unreachable from IPv6 host)."
    warn "Install via apt repo manually, or copy binary from another host:"
    warn "  scp <other-host>:/usr/bin/doppler /usr/local/bin/doppler"
  fi
fi

# hcloud CLI — downloads from GitHub; may be unavailable on IPv6-only hosts
if command -v hcloud &>/dev/null; then
  skip "hcloud CLI already installed"
else
  log "Installing hcloud CLI..."
  HCLOUD_VERSION=$(curl -s --max-time 10 https://api.github.com/repos/hetznercloud/cli/releases/latest 2>/dev/null \
    | grep '"tag_name"' | cut -d'"' -f4 || true)
  if [[ -n "${HCLOUD_VERSION}" ]]; then
    curl -fsSL "https://github.com/hetznercloud/cli/releases/download/${HCLOUD_VERSION}/hcloud-linux-amd64.tar.gz" \
      | tar -xz -C /usr/local/bin hcloud
    log "hcloud CLI installed: ${HCLOUD_VERSION}"
  else
    warn "Could not install hcloud CLI (GitHub unreachable on IPv6-only host)."
    warn "Install manually from: https://github.com/hetznercloud/cli/releases/latest"
    warn "Or run from your local machine: make firewall (via SSH)"
  fi
fi

# =============================================================================
# 9. Create Docker external networks
# =============================================================================
log "Creating Docker networks..."
for network in proxy postgres-net valkey-net monitoring-net; do
  if docker network inspect "${network}" &>/dev/null; then
    skip "Network ${network} already exists"
  else
    docker network create "${network}"
    log "Created network: ${network}"
  fi
done

# =============================================================================
# 10. Set up repo directory + acme.json
# =============================================================================
# Ensure repo dir exists and is owned by deploy user
mkdir -p "${REPO_DIR}/traefik"
chown -R "${DEPLOY_USER}:${DEPLOY_USER}" "${REPO_DIR}"

ACME_JSON="${REPO_DIR}/traefik/acme.json"
if [[ ! -f "${ACME_JSON}" ]]; then
  log "Creating traefik/acme.json..."
  touch "${ACME_JSON}"
fi
chmod 600 "${ACME_JSON}"
chown "${DEPLOY_USER}:${DEPLOY_USER}" "${ACME_JSON}"

# =============================================================================
# 11. Install cron job for pg_dump backup
# =============================================================================
log "Installing pg_backup cron job..."
cp "${REPO_DIR}/cron/pg-backup" /etc/cron.d/pg-backup
chmod 644 /etc/cron.d/pg-backup
chown root:root /etc/cron.d/pg-backup

# =============================================================================
# Done
# =============================================================================
log ""
log "============================================================"
log " Setup complete! Next steps:"
log "============================================================"
log " 1. Connect Tailscale:    tailscale up  (already done if you see a TS IP)"
log " 2. Lock down SSH:        Edit /etc/ssh/sshd_config.d/99-hardening.conf"
log "                          Uncomment: ListenAddress <tailscale-ip>"
log "                          Verify Tailscale SSH works, then: systemctl restart sshd"
log " 3. Login to Doppler:     su - ${DEPLOY_USER}"
log "                          doppler login && doppler setup"
log "                          (project: vps, config: prod)"
log " 4. Cloudflare Tunnel:    Create tunnel in Cloudflare dashboard → Zero Trust → Tunnels"
log "                          Copy token → Doppler as CLOUDFLARE_TUNNEL_TOKEN"
log " 5. Apply firewall:       cd ${REPO_DIR} && make firewall"
log "                          Then assign firewall to server in hcloud dashboard"
log " 6. Start all stacks:     make up"
log "                          (networking → infra → monitoring in order)"
log "============================================================"
