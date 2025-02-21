#!/usr/bin/env bash
source <(curl -s https://raw.githubusercontent.com/hundehausen/ProxmoxVE/refs/heads/monero/misc/build.func)
# Copyright (c) 2021-2025 community-scripts ORG
# Author: hundehausen
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://www.getmonero.org/

APP="Monero Node"
var_tags="crypto,blockchain,privacy"
var_cpu="4"
var_ram="4096"
var_disk="200"
var_os="debian"
var_version="12"
var_unprivileged="1"

# App Output & Base Settings
header_info "$APP"
base_settings
variables
color
catch_errors

function check_monero_status() {
    header_info
    check_container_storage
    check_container_resources
    if [[ ! -f /usr/local/bin/monerod ]]; then
        msg_error "No ${APP} Installation Found!"
        exit 1
    fi
    
    msg_info "Checking Monero Service Status"
    if systemctl is-active -q monero; then
        msg_ok "Monero Service is Running"
        
        # Check blockchain sync status
        msg_info "Checking Blockchain Sync Status"
        SYNC_INFO=$(curl -s -X POST http://127.0.0.1:18081/json_rpc -d '{"jsonrpc":"2.0","id":"0","method":"get_info"}' -H 'Content-Type: application/json' 2>/dev/null)
        
        if [ $? -eq 0 ] && [ -n "$SYNC_INFO" ]; then
            HEIGHT=$(echo $SYNC_INFO | grep -o '"height":[0-9]*' | cut -d ":" -f2)
            TARGET=$(echo $SYNC_INFO | grep -o '"target_height":[0-9]*' | cut -d ":" -f2)
            SYNC=$(echo $SYNC_INFO | grep -o '"synchronized":[a-z]*' | cut -d ":" -f2)
            
            if [ -n "$HEIGHT" ] && [ -n "$TARGET" ]; then
                PERCENT=$(awk "BEGIN {print int(($HEIGHT/$TARGET)*100)}")
                echo -e "${INFO}${YW}Blockchain Height: ${HEIGHT} / ${TARGET} (${PERCENT}% synchronized)${CL}"
            elif [ "$SYNC" == "true" ]; then
                echo -e "${INFO}${GN}Blockchain is fully synchronized${CL}"
            else
                echo -e "${INFO}${YW}Blockchain is synchronizing${CL}"
            fi
        else
            msg_error "Could not connect to Monero RPC interface"
        fi
        
        # Check disk usage
        msg_info "Checking Disk Usage"
        DISK_USAGE=$(du -sh /var/lib/monero 2>/dev/null | awk '{print $1}')
        if [ -n "$DISK_USAGE" ]; then
            echo -e "${INFO}${YW}Blockchain Size: ${DISK_USAGE}${CL}"
        else
            echo -e "${INFO}${YW}Could not determine blockchain size${CL}"
        fi
    else
        msg_error "Monero Service is Not Running"
    fi
    exit
}

function update_script() {
    header_info
    check_container_storage
    check_container_resources
    if [[ ! -f /usr/local/bin/monerod ]]; then
        msg_error "No ${APP} Installation Found!"
        exit 1
    fi
    
    msg_info "Checking for latest ${APP} version..."
    cd /tmp
    CURRENT_VERSION=$(cat /opt/${APP}_version.txt 2>/dev/null || echo "unknown")
    RELEASE=$(curl -s https://api.github.com/repos/monero-project/monero/releases/latest | grep "tag_name" | awk '{print substr($2, 3, length($2)-4) }')
    
    if [ -z "$RELEASE" ]; then
        msg_error "Failed to fetch latest Monero version"
        exit 1
    fi
    
    echo -e "${INFO}${YW}Current version: ${CURRENT_VERSION}, Latest version: ${RELEASE}${CL}"
    
    if [[ "${RELEASE}" != "${CURRENT_VERSION}" ]]; then
        msg_info "New version available (v${RELEASE}). Stopping Monero Service..."
        systemctl stop monero
        if systemctl is-active -q monero; then
            msg_error "Failed to stop Monero Service. Aborting update."
            exit 1
        fi
        msg_ok "Stopped Monero Service"
        msg_info "Updating ${APP} to v${RELEASE}..."
        
        # Create backup of configuration
        if [ -f /etc/monero/monerod.conf ]; then
            msg_info "Backing up configuration"
            cp /etc/monero/monerod.conf /etc/monero/monerod.conf.bak
            msg_ok "Configuration backed up"
        fi
        
        wget -q https://downloads.getmonero.org/cli/monero-linux-x64-v${RELEASE}.tar.bz2
        wget -q https://www.getmonero.org/downloads/hashes.txt
        
        # Verify hashes
        EXPECTED_HASH=$(grep "monero-linux-x64-v${RELEASE}.tar.bz2" hashes.txt | awk '{print $1}')
        CALCULATED_HASH=$(sha256sum monero-linux-x64-v${RELEASE}.tar.bz2 | awk '{print $1}')
        
        if [ -z "$EXPECTED_HASH" ]; then
            msg_error "Could not find hash for version ${RELEASE}"
            echo -e "${INFO}${YW}Attempting to restart Monero service (previous version)...${CL}"
            systemctl start monero
            exit 1
        fi
        
        if [ "$EXPECTED_HASH" != "$CALCULATED_HASH" ]; then
            msg_error "Hash verification failed!"
            echo -e "${INFO}${RD}Expected: ${EXPECTED_HASH}${CL}"
            echo -e "${INFO}${RD}Calculated: ${CALCULATED_HASH}${CL}"
            rm monero-linux-x64-v${RELEASE}.tar.bz2 hashes.txt
            
            echo -e "${INFO}${YW}Attempting to restart Monero service (previous version)...${CL}"
            systemctl start monero
            exit 1
        fi
        
        tar xjf monero-linux-x64-v${RELEASE}.tar.bz2
        
        # Backup existing binaries
        if [ -f /usr/local/bin/monerod ]; then
            mv /usr/local/bin/monerod /usr/local/bin/monerod.old
        fi
        if [ -f /usr/local/bin/monero-wallet-rpc ]; then
            mv /usr/local/bin/monero-wallet-rpc /usr/local/bin/monero-wallet-rpc.old
        fi
        
        # Install new binaries
        cp monero-x86_64-linux-gnu-v${RELEASE}/monerod /usr/local/bin/
        cp monero-x86_64-linux-gnu-v${RELEASE}/monero-wallet-rpc /usr/local/bin/
        
        # Copy additional binaries if they exist
        if [ -f monero-x86_64-linux-gnu-v${RELEASE}/monero-wallet-cli ]; then
            cp monero-x86_64-linux-gnu-v${RELEASE}/monero-wallet-cli /usr/local/bin/
        fi
        
        # Set proper permissions
        chmod 755 /usr/local/bin/monerod
        chmod 755 /usr/local/bin/monero-wallet-rpc
        if [ -f /usr/local/bin/monero-wallet-cli ]; then
            chmod 755 /usr/local/bin/monero-wallet-cli
        fi
        
        # Update version file
        echo "${RELEASE}" > /opt/${APP}_version.txt
        
        # Cleanup
        rm -rf monero-linux-x64-v${RELEASE}.tar.bz2 monero-x86_64-linux-gnu-v${RELEASE} hashes.txt
        
        msg_ok "Updated ${APP} to v${RELEASE}"
    else
        msg_ok "${APP} is already at the latest version (v${RELEASE}). No update needed."
        exit 0
    fi

    msg_info "Starting Monero Service"
    systemctl start monero
    
    # Verify service started successfully
    sleep 2
    if systemctl is-active -q monero; then
        msg_ok "Started Monero Service"
    else
        msg_error "Failed to start Monero Service"
        echo -e "${INFO}${YW}Check logs with: journalctl -u monero${CL}"
    fi
    exit
}

function backup_blockchain() {
    header_info
    check_container_storage
    check_container_resources
    if [[ ! -f /usr/local/bin/monerod ]]; then
        msg_error "No ${APP} Installation Found!"
        exit 1
    fi
    
    # Check if there's enough space for backup
    BLOCKCHAIN_SIZE=$(du -sm /var/lib/monero 2>/dev/null | awk '{print $1}')
    AVAILABLE_SPACE=$(df -m /tmp | awk 'NR==2 {print $4}')
    
    if [ -z "$BLOCKCHAIN_SIZE" ] || [ -z "$AVAILABLE_SPACE" ]; then
        msg_error "Could not determine blockchain size or available space"
        exit 1
    fi
    
    if [ "$BLOCKCHAIN_SIZE" -gt "$AVAILABLE_SPACE" ]; then
        msg_error "Not enough space for backup"
        echo -e "${INFO}${YW}Blockchain size: ${BLOCKCHAIN_SIZE}MB, Available space: ${AVAILABLE_SPACE}MB${CL}"
        exit 1
    fi
    
    BACKUP_FILE="/tmp/monero_blockchain_$(date +%Y%m%d).tar.gz"
    
    msg_info "Stopping Monero Service"
    systemctl stop monero
    msg_ok "Stopped Monero Service"
    
    msg_info "Creating Blockchain Backup"
    tar -czf "$BACKUP_FILE" -C /var/lib/monero .
    
    if [ $? -eq 0 ]; then
        msg_ok "Created Blockchain Backup: $BACKUP_FILE"
    else
        msg_error "Failed to create blockchain backup"
    fi
    
    msg_info "Starting Monero Service"
    systemctl start monero
    msg_ok "Started Monero Service"
    
    echo -e "${INFO}${GN}Backup completed. File location: ${BACKUP_FILE}${CL}"
    echo -e "${INFO}${YW}Remember to move this backup to a safe location${CL}"
    exit
}

# Check for command line arguments
if [[ "$1" == "update" ]]; then
    update_script
elif [[ "$1" == "status" ]]; then
    check_monero_status
elif [[ "$1" == "backup" ]]; then
    backup_blockchain
elif [[ "$1" == "help" ]]; then
    echo -e "${BOLD}${APP} Management Script${CL}"
    echo -e "${YW}Usage:${CL}"
    echo -e "  $0               - Create new Monero node container"
    echo -e "  $0 update        - Update existing Monero installation"
    echo -e "  $0 status        - Check Monero node status"
    echo -e "  $0 backup        - Backup Monero blockchain data"
    echo -e "  $0 help          - Show this help message"
    exit
fi

start
build_container
description

msg_ok "Completed Successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW}Monero node is running and syncing with the blockchain${CL}"
echo -e "${INFO}${YW}Monitor progress with: monerod status${CL}"
echo -e "${INFO}${YW}Manage your node with: $0 [update|status|backup|help]${CL}"