#!/usr/bin/env bash
# =============================================================================
# install-template.sh
# Generic Packer install script template for Azure Marketplace VM images.
#
# This script is executed by Packer during VM image build on Ubuntu 24.04 LTS.
# After completion, Packer deprovisions the VM and saves it as a Managed Image.
#
# AI should replace the following placeholders:
#   {{SERVICE_NAME}}          - short kebab-case name (e.g., "my-app")
#   {{SERVICE_DESCRIPTION}}   - human-readable description
#   {{LANGUAGE_INSTALL}}      - language runtime installation commands
#   {{PROJECT_INSTALL}}       - project-specific build/install commands
#   {{RUN_COMMAND}}           - ExecStart command for systemd (absolute path)
#   {{EXPOSED_PORT}}          - application port (e.g., 3000)
#   {{ENV_VARS}}              - Environment= lines for systemd unit
#   {{CONFIG_SETUP}}          - config directory/file creation commands
#   {{EXTRA_DEPENDENCIES}}    - additional apt packages (space-separated)
# =============================================================================

set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------------------
# Logging utilities
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()    { echo -e "\n${GREEN}==>${NC} $*\n"; }

# ---------------------------------------------------------------------------
# 1. System update and base dependencies
# ---------------------------------------------------------------------------
log_step "Step 1: Updating system packages"

apt-get update -y
apt-get upgrade -y \
  -o Dpkg::Options::="--force-confdef" \
  -o Dpkg::Options::="--force-confold"

apt-get install -y \
  curl \
  wget \
  git \
  unzip \
  build-essential \
  ca-certificates \
  gnupg \
  lsb-release \
  software-properties-common \
  systemd \
  jq \
  {{EXTRA_DEPENDENCIES}}

log_info "System packages updated"

# ---------------------------------------------------------------------------
# 2. Install language runtime
# ---------------------------------------------------------------------------
log_step "Step 2: Installing language runtime"

{{LANGUAGE_INSTALL}}

log_info "Language runtime installed"

# ---------------------------------------------------------------------------
# 3. Install the project
# ---------------------------------------------------------------------------
log_step "Step 3: Installing {{SERVICE_NAME}}"

{{PROJECT_INSTALL}}

log_info "{{SERVICE_NAME}} installed"

# ---------------------------------------------------------------------------
# 4. Create system user
# ---------------------------------------------------------------------------
log_step "Step 4: Creating {{SERVICE_NAME}} system user"

if ! id "{{SERVICE_NAME}}" &>/dev/null; then
  useradd \
    --system \
    --create-home \
    --home-dir /var/lib/{{SERVICE_NAME}} \
    --shell /bin/bash \
    --comment "{{SERVICE_DESCRIPTION}}" \
    {{SERVICE_NAME}}
  log_info "User '{{SERVICE_NAME}}' created"
else
  log_warn "User '{{SERVICE_NAME}}' already exists, skipping"
fi

# ---------------------------------------------------------------------------
# 5. Create directory structure and config
# ---------------------------------------------------------------------------
log_step "Step 5: Creating directory structure"

SERVICE_HOME="/var/lib/{{SERVICE_NAME}}"
SERVICE_LOG_DIR="/var/log/{{SERVICE_NAME}}"

mkdir -p \
  "${SERVICE_HOME}/.config" \
  "${SERVICE_LOG_DIR}"

{{CONFIG_SETUP}}

chown -R {{SERVICE_NAME}}:{{SERVICE_NAME}} "${SERVICE_HOME}" "${SERVICE_LOG_DIR}"

# If the project was cloned to /opt, also fix permissions
if [ -d "/opt/{{SERVICE_NAME}}" ]; then
  chown -R {{SERVICE_NAME}}:{{SERVICE_NAME}} /opt/{{SERVICE_NAME}}
fi

log_info "Directory structure created"

# ---------------------------------------------------------------------------
# 6. Create systemd service unit
# ---------------------------------------------------------------------------
log_step "Step 6: Creating systemd service"

cat > /etc/systemd/system/{{SERVICE_NAME}}.service << 'EOF'
[Unit]
Description={{SERVICE_DESCRIPTION}}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User={{SERVICE_NAME}}
Group={{SERVICE_NAME}}
WorkingDirectory=/opt/{{SERVICE_NAME}}
{{ENV_VARS}}
ExecStart={{RUN_COMMAND}}
ExecReload=/bin/kill -HUP $MAINPID

Restart=on-failure
RestartSec=10s
StartLimitIntervalSec=60s
StartLimitBurst=3

StandardOutput=append:/var/log/{{SERVICE_NAME}}/app.log
StandardError=append:/var/log/{{SERVICE_NAME}}/error.log

NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ReadWritePaths=/var/lib/{{SERVICE_NAME}} /var/log/{{SERVICE_NAME}} /opt/{{SERVICE_NAME}}

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable {{SERVICE_NAME}}.service

log_info "systemd service '{{SERVICE_NAME}}' enabled (will start on first boot)"

# ---------------------------------------------------------------------------
# 7. Azure Linux Agent
# ---------------------------------------------------------------------------
log_step "Step 7: Ensuring Azure Linux Agent is installed"

apt-get install -y walinuxagent
systemctl enable walinuxagent

log_info "Azure Linux Agent (walinuxagent) installed and enabled"

# ---------------------------------------------------------------------------
# 8. Firewall configuration
# ---------------------------------------------------------------------------
log_step "Step 8: Configuring UFW firewall"

apt-get install -y ufw

ufw --force reset
ufw default deny incoming
ufw default allow outgoing

ufw allow 22/tcp comment 'SSH'

# Uncomment and adjust if the application port should be publicly accessible:
# ufw allow {{EXPOSED_PORT}}/tcp comment '{{SERVICE_NAME}}'

ufw --force enable

log_info "Firewall configured"

# ---------------------------------------------------------------------------
# 9. System optimizations
# ---------------------------------------------------------------------------
log_step "Step 9: Applying system optimizations"

cat >> /etc/security/limits.conf << 'EOF'
{{SERVICE_NAME}} soft nofile 65536
{{SERVICE_NAME}} hard nofile 65536
EOF

cat >> /etc/sysctl.d/99-{{SERVICE_NAME}}.conf << 'EOF'
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 4096
EOF

sysctl -p /etc/sysctl.d/99-{{SERVICE_NAME}}.conf 2>/dev/null || true

log_info "System optimizations applied"

# ---------------------------------------------------------------------------
# 10. Complete
# ---------------------------------------------------------------------------
log_step "Installation complete"

echo ""
log_info "{{SERVICE_NAME}} has been installed successfully."
log_info ""
log_info "After deploying a VM from this image:"
log_info "  1. Configure environment variables in /etc/systemd/system/{{SERVICE_NAME}}.service"
log_info "  2. Run: sudo systemctl start {{SERVICE_NAME}}"
log_info "  3. Check status: sudo systemctl status {{SERVICE_NAME}}"
log_info "  4. View logs: sudo journalctl -u {{SERVICE_NAME}} -f"
echo ""
