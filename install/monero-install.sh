#!/usr/bin/env bash

# Copyright (c) 2021-2025 community-scripts ORG
# Author: hundehausen
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://www.getmonero.org/

APP="Monero Node" # Define app name consistently
source /dev/stdin <<< "$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

msg_info "Installing Dependencies"
$STD apt-get install -y \
    curl \
    sudo \
    mc \
    wget \
    bzip2
msg_ok "Installed Dependencies"

msg_info "Installing Monero"
cd /tmp
msg_info "Fetching latest Monero release info..."
RELEASE=$(curl -s https://api.github.com/repos/monero-project/monero/releases/latest | grep "tag_name" | awk '{print substr($2, 3, length($2)-4) }')

if [ -z "$RELEASE" ]; then
    msg_error "Failed to fetch latest Monero release version."
    exit 1
fi
msg_ok "Fetched latest Monero release: v${RELEASE}"

# Download binaries and hash file
wget -q https://downloads.getmonero.org/cli/monero-linux-x64-v${RELEASE}.tar.bz2
wget -q https://www.getmonero.org/downloads/hashes.txt

# Verify hashes
EXPECTED_HASH=$(grep "monero-linux-x64-v${RELEASE}.tar.bz2" hashes.txt | awk '{print $1}')
CALCULATED_HASH=$(sha256sum monero-linux-x64-v${RELEASE}.tar.bz2 | awk '{print $1}')

if [ "$EXPECTED_HASH" != "$CALCULATED_HASH" ]; then
    msg_error "Hash verification failed!"
    rm monero-linux-x64-v${RELEASE}.tar.bz2 hashes.txt
    exit 1
fi

# Extract and install
tar xjf monero-linux-x64-v${RELEASE}.tar.bz2
cp monero-x86_64-linux-gnu-v${RELEASE}/monerod /usr/local/bin/
cp monero-x86_64-linux-gnu-v${RELEASE}/monero-wallet-rpc /usr/local/bin/

# Create data directory
mkdir -p /var/lib/monero
chmod 755 /var/lib/monero

# Ask user about node type (private/public)
msg_info "Node Access Configuration"
echo -e "${YW}Choose the type of node access:${CL}"
echo -e "${YW}1) Private Node - For home use behind NAT, exposes full potential RPC ports${CL}"
echo -e "${YW}2) Public Node  - For VPS/public hosting, only exposes P2P and restricted RPC${CL}"
read -p "Enter your choice (1-2) [1]: " access_choice
echo
access_choice=${access_choice:-1}

# Ask user about pruning
msg_info "Node Type Selection"
echo -e "${YW}Choose the type of Monero node to run:${CL}"
echo -e "${YW}1) Pruned Node  - Requires ~100GB of storage${CL}"
echo -e "${YW}2) Full Node    - Requires ~250GB of storage (recommended)${CL}"
read -p "Enter your choice (1-2) [2]: " node_choice
echo
node_choice=${node_choice:-2}

# Create config directory and configuration file
msg_info "Creating Configuration File"
mkdir -p /etc/monero

# Set RPC configuration based on node type
if [ "$access_choice" == "1" ]; then
    rpc_config="# RPC Connection Settings (Private Node)
rpc-bind-ip=0.0.0.0            # Bind to all interfaces (unrestricted RPC)
rpc-bind-port=18081            # Default unrestricted RPC port
rpc-restricted-bind-ip=0.0.0.0 # Bind to all interfaces (restricted RPC)
rpc-restricted-bind-port=18089 # Restricted RPC port"
else
    rpc_config="# RPC Connection Settings (Public Node)
rpc-restricted-bind-ip=0.0.0.0 # Bind to all interfaces (restricted RPC)
rpc-restricted-bind-port=18089 # Restricted RPC port
public-node=1                  # Advertise node for wallet connections"
fi

cat <<EOF >/etc/monero/monerod.conf
# Configuration file for monerod. For all available options see the MoneroDocs:
# https://docs.getmonero.org/interacting/monerod-reference/

# Data directory (blockchain db and indices)
data-dir=/var/lib/monero

# P2P Connection Settings
p2p-bind-ip=0.0.0.0            # Bind to all interfaces (the default)
p2p-bind-port=18080            # Bind to default port

# Centralized services
check-updates=disabled          # Do not check DNS TXT records for a new version
enable-dns-blocklist=1         # Block known malicious nodes

${rpc_config}

# Connection limits
out-peers=32                   # Maximum number of outbound connections
in-peers=32                    # Maximum number of inbound connections
limit-rate-up=1048576         # 1048576 kB/s == 1GB/s; a raise from default 2048 kB/s
limit-rate-down=1048576       # 1048576 kB/s == 1GB/s; a raise from default 8192 kB/s

# Logs
log-level=0                   # Log level (0-4)
max-log-file-size=104850000   # 100MB per log file
max-log-files=1               # Rotate only one log file

# Safety features
confirm-external-bind=1       # Require confirmation for binding to external IPs
no-igd=1                      # Disable UPnP port mapping

# Pruning configuration
prune-blockchain=$([ "$node_choice" == "1" ] && echo "1" || echo "0")
sync-pruned-blocks=$([ "$node_choice" == "1" ] && echo "1" || echo "0")
EOF

# Add warning about node type based on choice
if [ "$access_choice" == "1" ]; then
    echo -e "${INFO}${YW}Running as private node - RPC ports 18081 (unrestricted) and 18089 (restricted) will be exposed${CL}"
else
    echo -e "${INFO}${YW}Running as public node - Only P2P port 18080 and restricted RPC port 18089 will be exposed${CL}"
fi

# Add warning about disk space based on choice
if [ "$node_choice" == "1" ]; then
    echo -e "${INFO}${YW}Running as pruned node - This will store a smaller version of the blockchain${CL}"
else
    echo -e "${INFO}${YW}Running as full node - This will store the complete blockchain${CL}"
fi

msg_ok "Created Configuration File"

echo "${RELEASE}" > /opt/${APP}_version.txt
msg_ok "Installed Monero"

msg_info "Creating Service"
cat <<EOF >/etc/systemd/system/monero.service
[Unit]
Description=Monero Daemon
After=network-online.target

[Service]
User=root
Group=root

ExecStart=/usr/local/bin/monerod --detach --config-file=/etc/monero/monerod.conf --pidfile /run/monero/monerod.pid
ExecStartPost=/bin/sleep 0.1
PIDFile=/run/monero/monerod.pid
Type=forking

Restart=on-failure
RestartSec=20

RuntimeDirectory=monero

StandardOutput=null
StandardError=null

[Install]
WantedBy=multi-user.target
EOF

systemctl enable -q --now monero
msg_ok "Created Service"

motd_ssh
customize

msg_info "Cleaning up"
rm -rf /tmp/monero-linux-x64-v${RELEASE}.tar.bz2 /tmp/monero-x86_64-linux-gnu-v${RELEASE} /tmp/hashes.txt
$STD apt-get -y autoremove
$STD apt-get -y autoclean
msg_ok "Cleaned"