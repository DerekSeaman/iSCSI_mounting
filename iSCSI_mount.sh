#!/usr/bin/env bash
# Version 1.4, Sept 8, 2025
# iSCSI LUN mounting script for Proxmox Backup Server (PBS)
# PBS must be running as a VM or bare metal. LXCs are NOT supported.
# Derek Seaman
#

set -euo pipefail

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root" >&2
   exit 1
fi

# Color codes for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
ORANGE='\033[0;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Combined iSCSI Connect and Mount Script ===${NC}"
echo "This script will:"
echo "1. Connect to an iSCSI target with CHAP authentication"
echo "2. Set up automatic mounting with systemd"
echo "3. Configure monitoring and auto-reconnection"
echo

# Check and setup open-iscsi service first
echo -e "${YELLOW}Checking open-iscsi service status...${NC}"

# Check for iscsid service using systemctl list-unit-files (checks if service exists, regardless of state)
if systemctl list-unit-files iscsid.service >/dev/null 2>&1; then
    ISCSI_SERVICE="iscsid.service"
elif systemctl list-unit-files open-iscsi.service >/dev/null 2>&1; then
    ISCSI_SERVICE="open-iscsi.service"
else
    echo -e "${RED}Error: Neither iscsid nor open-iscsi service found or accessible.${NC}" >&2
    echo "Please check if open-iscsi is properly installed:"
    echo "  systemctl status iscsid"
    echo "  systemctl status open-iscsi"
    exit 1
fi

echo "Found iSCSI service: $ISCSI_SERVICE"

# Check if the service is enabled
if ! systemctl is-enabled "$ISCSI_SERVICE" >/dev/null 2>&1; then
    echo -e "${YELLOW}$ISCSI_SERVICE is not enabled. Enabling it now...${NC}"
    systemctl enable "$ISCSI_SERVICE"
    echo -e "${GREEN}✓ $ISCSI_SERVICE enabled${NC}"
else
    echo -e "${GREEN}✓ $ISCSI_SERVICE is already enabled${NC}"
fi

# Check if the service is running
if ! systemctl is-active "$ISCSI_SERVICE" >/dev/null 2>&1; then
    echo -e "${YELLOW}$ISCSI_SERVICE is not running. Starting it now...${NC}"
    systemctl start "$ISCSI_SERVICE"
    
    # Wait a moment for the service to fully start
    sleep 2
    
    # Verify it started successfully
    if systemctl is-active "$ISCSI_SERVICE" >/dev/null 2>&1; then
        echo -e "${GREEN}✓ $ISCSI_SERVICE started successfully${NC}"
    else
        echo -e "${RED}Error: Failed to start $ISCSI_SERVICE${NC}" >&2
        systemctl status "$ISCSI_SERVICE" --no-pager --lines=5
        exit 1
    fi
else
    echo -e "${GREEN}✓ $ISCSI_SERVICE is already running${NC}"
fi

# Check if iscsiadm is available
if ! command -v iscsiadm >/dev/null 2>&1; then
    echo -e "${RED}Error: iscsiadm not found. Please ensure open-iscsi is installed.${NC}" >&2
    exit 1
fi

echo

# Gather ALL user input upfront
echo -e "${YELLOW}=== User Input Required ===${NC}"
read -rp "Enter target IQN (e.g., iqn.2000-01.com.synology:DS923.Target-1.2c0d1f17e14): " TARGET_IQN
read -rp "Enter CHAP username: " CHAP_USER
read -rsp "Enter CHAP password (not displayed): " CHAP_PASS
echo
read -rp "Enter portal IP address (e.g., 192.168.2.100): " PORTAL_IP
read -rp "Enter mount path (e.g., /mnt/synology): " MOUNT_PATH

# Basic validation
if [[ -z "$TARGET_IQN" || -z "$CHAP_USER" || -z "$CHAP_PASS" || -z "$PORTAL_IP" || -z "$MOUNT_PATH" ]]; then
    echo -e "${RED}Error: All fields are required.${NC}" >&2
    exit 1
fi

# Quick IP format check (not exhaustive)
if ! [[ "$PORTAL_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(:[0-9]+)?$ ]]; then
    echo -e "${YELLOW}Warning: '$PORTAL_IP' does not look like a typical IPv4 address with optional port.${NC}"
fi

echo
echo -e "${GREEN}=== Phase 1: iSCSI Connection Setup ===${NC}"
echo -e "${BLUE}Configuring iSCSI node for target: $TARGET_IQN at portal $PORTAL_IP${NC}"

# Discover the target (helps create the node record if missing)
echo -e "${YELLOW}Discovering target...${NC}"
iscsiadm -m discovery -t sendtargets -p "$PORTAL_IP" || true

# Set CHAP auth method, username, and password
echo -e "${YELLOW}Configuring CHAP authentication...${NC}"
iscsiadm -m node --targetname="$TARGET_IQN" \
  --op=update --name node.session.auth.authmethod --value=CHAP
iscsiadm -m node --targetname="$TARGET_IQN" \
  --op=update --name node.session.auth.username --value="$CHAP_USER"
iscsiadm -m node --targetname="$TARGET_IQN" \
  --op=update --name node.session.auth.password --value="$CHAP_PASS"

# Configure node for automatic startup
echo -e "${YELLOW}Configuring node for automatic startup...${NC}"
iscsiadm -m node --targetname="$TARGET_IQN" --portal="$PORTAL_IP" \
  --op=update --name node.startup --value=automatic

# Verify the node configuration was saved
echo -e "${YELLOW}Verifying node configuration...${NC}"
if ! iscsiadm -m node --targetname="$TARGET_IQN" --portal="$PORTAL_IP" --show >/dev/null 2>&1; then
    echo -e "${RED}Error: Node configuration not saved properly${NC}" >&2
    exit 1
fi

# Check if session already exists before attempting login
echo -e "${YELLOW}Checking for existing iSCSI sessions...${NC}"
EXISTING_SESSION=$(iscsiadm -m session 2>/dev/null | grep "$TARGET_IQN" || true)

if [[ -n "$EXISTING_SESSION" ]]; then
    echo -e "${BLUE}ℹ Session already exists for target $TARGET_IQN${NC}"
    echo "$EXISTING_SESSION"
    
    # Check if this target is already mounted
    echo -e "${YELLOW}Checking if target is already mounted...${NC}"
    
    # Get device for this target
    TARGET_DEVICE=""
    in_target_section=false
    while IFS= read -r line; do
        if [[ "$line" =~ Target:.*"$TARGET_IQN" ]]; then
            in_target_section=true
            continue
        fi
        if [[ "$line" =~ ^[[:space:]]*Target: ]] && [[ ! "$line" =~ "$TARGET_IQN" ]]; then
            in_target_section=false
            continue
        fi
        if [[ "$in_target_section" == true ]] && [[ "$line" =~ Attached\ scsi\ disk\ ([a-z]+).*State:\ running ]]; then
            device_name="${BASH_REMATCH[1]}"
            if [[ -n "$device_name" ]]; then
                TARGET_DEVICE="/dev/$device_name"
                break
            fi
        fi
    done <<< "$(iscsiadm -m session -P 3 2>/dev/null)"
    
    # Check if any partition of this device is mounted
    if [[ -n "$TARGET_DEVICE" ]]; then
        MOUNT_INFO=$(mount | grep "^$TARGET_DEVICE" || true)
        if [[ -n "$MOUNT_INFO" ]]; then
            # Extract mount point from mount output
            CURRENT_MOUNT=$(echo "$MOUNT_INFO" | awk '{print $3}' | head -1)
            echo -e "${GREEN}✓ Target $TARGET_IQN is already connected and mounted${NC}"
            echo -e "${BLUE}Device: $TARGET_DEVICE${NC}"
            echo -e "${BLUE}Mount point: $CURRENT_MOUNT${NC}"
            echo
            echo -e "${ORANGE}The iSCSI LUN is already properly configured and mounted.${NC}"
            echo -e "${ORANGE}No additional action required.${NC}"
            exit 0
        fi
    fi
    
    echo -e "${BLUE}Target is connected but not mounted. Continuing with mount setup...${NC}"
    LOGIN_EXIT_CODE=0  # Skip login since session exists
else
    # Login to the target via the specified portal
    echo -e "${YELLOW}Logging into iSCSI target...${NC}"
    # Add timeout to prevent hanging
    timeout 30 iscsiadm -m node --targetname="$TARGET_IQN" --portal="$PORTAL_IP" --login
    LOGIN_EXIT_CODE=$?
fi

# Handle login result
if [[ $LOGIN_EXIT_CODE -eq 124 ]]; then
    echo -e "${RED}Error: iSCSI login timed out after 30 seconds${NC}" >&2
    exit 1
elif [[ $LOGIN_EXIT_CODE -ne 0 ]]; then
    echo -e "${RED}Error: Failed to login to iSCSI target (exit code: $LOGIN_EXIT_CODE)${NC}" >&2
    exit 1
elif [[ $LOGIN_EXIT_CODE -eq 0 ]] && [[ -z "$EXISTING_SESSION" ]]; then
    echo -e "${GREEN}✓ iSCSI login successful${NC}"
fi
echo -e "${BLUE}Active sessions:${NC}"
iscsiadm -m session || true

echo -e "${BLUE}Attached devices on active sessions (initial scan):${NC}"
INITIAL_ATTACHED="$(iscsiadm -m session -P 3 | grep -E 'Attached' || true)"
echo "${INITIAL_ATTACHED}"

# Check for "running" status on any attached device
if ! echo "${INITIAL_ATTACHED}" | grep -qi 'running'; then
    echo -e "${YELLOW}No 'running' status found on attached devices. Triggering a one-time rescan...${NC}"
    iscsiadm -m session --rescan || true
    sleep 5
    echo -e "${BLUE}Attached devices after rescan:${NC}"
    FINAL_ATTACHED="$(iscsiadm -m session -P 3 | grep -E 'Attached' || true)"
    echo "${FINAL_ATTACHED}"
else
    FINAL_ATTACHED="$INITIAL_ATTACHED"
fi

# Extract the device path from the attached devices output
echo -e "${YELLOW}Detecting new iSCSI device for target $TARGET_IQN...${NC}"
DEVICE_PATH=""

# Get list of currently mounted iSCSI devices to avoid them
MOUNTED_ISCSI_DEVICES=()
while IFS= read -r mount_line; do
    if [[ "$mount_line" =~ ^/dev/([a-z]+[0-9]*) ]]; then
        device="${BASH_REMATCH[1]}"
        # Remove partition number to get base device
        base_device=$(echo "$device" | sed 's/[0-9]*$//')
        # Check if it's an iSCSI device by looking at its path
        if [[ -e "/sys/block/$base_device/device" ]]; then
            device_path=$(readlink -f "/sys/block/$base_device/device" 2>/dev/null || true)
            if echo "$device_path" | grep -q "session"; then
                MOUNTED_ISCSI_DEVICES+=("/dev/$base_device")
            fi
        fi
    fi
done <<< "$(mount)"

echo "Currently mounted iSCSI devices: ${MOUNTED_ISCSI_DEVICES[*]:-none}"

# Get session-specific attached devices for our target
# Use a simpler approach - find devices attached to sessions with our target
TARGET_SESSION_INFO=""
in_target_section=false

while IFS= read -r line; do
    # Check if this line contains our target IQN
    if [[ "$line" =~ Target:.*"$TARGET_IQN" ]]; then
        in_target_section=true
        continue
    fi
    
    # If we hit another Target: line that's not ours, we're out of our section
    if [[ "$line" =~ ^[[:space:]]*Target: ]] && [[ ! "$line" =~ "$TARGET_IQN" ]]; then
        in_target_section=false
        continue
    fi
    
    # If we're in our target's section and find an attached disk in running state
    if [[ "$in_target_section" == true ]] && [[ "$line" =~ Attached\ scsi\ disk\ ([a-z]+).*State:\ running ]]; then
        device_name="${BASH_REMATCH[1]}"
        if [[ -n "$device_name" ]]; then
            TARGET_SESSION_INFO="/dev/$device_name"
            break  # Take the first running device for this target
        fi
    fi
done <<< "$(iscsiadm -m session -P 3 2>/dev/null)"

# Check if the target device is already mounted
if [[ -n "$TARGET_SESSION_INFO" && -b "$TARGET_SESSION_INFO" ]]; then
    is_mounted=false
    for mounted_device in "${MOUNTED_ISCSI_DEVICES[@]}"; do
        if [[ "$TARGET_SESSION_INFO" == "$mounted_device" ]]; then
            echo "Device for target is already mounted: $TARGET_SESSION_INFO"
            is_mounted=true
            break
        fi
    done
    
    # If not mounted, use this device
    if [[ "$is_mounted" == false ]]; then
        DEVICE_PATH="$TARGET_SESSION_INFO"
    fi
fi

if [[ -z "$DEVICE_PATH" ]]; then
    echo -e "${RED}Error: Could not detect an available iSCSI device for target $TARGET_IQN.${NC}" >&2
    echo "This could mean:"
    echo "  - The target connection failed"
    echo "  - All devices for this target are already mounted"
    echo "  - The device is not in 'running' state"
    echo
    echo "Devices found for target $TARGET_IQN:"
    echo "$TARGET_SESSION_INFO"
    echo
    echo "Currently mounted iSCSI devices: ${MOUNTED_ISCSI_DEVICES[*]:-none}"
    exit 1
fi

echo -e "${GREEN}✓ Detected iSCSI device: $DEVICE_PATH${NC}"

# Ensure device exists
if [[ ! -b "$DEVICE_PATH" ]]; then
    echo -e "${RED}Error: Device $DEVICE_PATH does not exist or is not a block device.${NC}" >&2
    exit 1
fi

echo
echo -e "${GREEN}=== Phase 2: Storage Setup and Mounting ===${NC}"

# Create systemd unit name by converting mount path to systemd format
# systemd requires mount unit names to match the mount path with specific transformations:
# - Remove leading slash
# - Replace slashes with dashes
# - Escape special characters
SYSTEMD_MOUNT_NAME=$(systemd-escape --path --suffix=mount "$MOUNT_PATH")
SYSTEMD_AUTOMOUNT_NAME=$(systemd-escape --path --suffix=automount "$MOUNT_PATH")

echo -e "\n${YELLOW}Generated systemd unit names:${NC}"
echo "  Mount path: $MOUNT_PATH"
echo "  Mount unit: $SYSTEMD_MOUNT_NAME"
echo "  Automount unit: $SYSTEMD_AUTOMOUNT_NAME"

# Extract service name from mount path (e.g., /mnt/synology923 -> synology923)
SERVICE_NAME=$(basename "$MOUNT_PATH")

echo -e "\n${YELLOW}Step 1: Partitioning disk${NC}"
# Check if device already has partitions
EXISTING_PARTITIONS=$(lsblk -n -o NAME "$DEVICE_PATH" | tail -n +2 || true)
SKIP_PARTITIONING=false

if [[ -n "$EXISTING_PARTITIONS" ]]; then
    echo -e "${YELLOW}Warning: Device $DEVICE_PATH already has partitions:${NC}"
    lsblk "$DEVICE_PATH"
    read -rp "Continue and create new partition table? This will destroy existing data! (y/N): " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo -e "${BLUE}Skipping partitioning - using existing partition table${NC}"
        SKIP_PARTITIONING=true
        # Use the first existing partition - extract just the device name without tree characters
        PARTITION=$(lsblk -n -o NAME "$DEVICE_PATH" | tail -n +2 | head -1 | sed 's/[^a-zA-Z0-9]//g')
        PARTITION="/dev/$PARTITION"
    fi
fi

if [[ "$SKIP_PARTITIONING" == false ]]; then
    # Create partition using parted (GPT)
    parted "$DEVICE_PATH" --script mklabel gpt
    parted "$DEVICE_PATH" --script mkpart primary ext4 0% 100%

    # Wait for partition to appear
    sleep 3
    PARTITION="${DEVICE_PATH}1"

    # Verify partition was created
    if [[ ! -b "$PARTITION" ]]; then
        echo -e "${RED}Error: Partition $PARTITION was not created successfully.${NC}" >&2
        exit 1
    fi
    echo -e "${GREEN}✓ New partition created: $PARTITION${NC}"
else
    echo -e "${GREEN}✓ Using existing partition: $PARTITION${NC}"
    # Verify the existing partition exists
    if [[ ! -b "$PARTITION" ]]; then
        echo -e "${RED}Error: Existing partition $PARTITION does not exist.${NC}" >&2
        exit 1
    fi
fi

echo -e "\n${YELLOW}Step 2: Formatting partition with ext4${NC}"
# Check if partition already has a filesystem
EXISTING_FILESYSTEM=$(blkid -s TYPE -o value "$PARTITION" 2>/dev/null || true)
SKIP_FORMATTING=false

if [[ -n "$EXISTING_FILESYSTEM" ]]; then
    echo -e "${YELLOW}Warning: Partition $PARTITION already has a filesystem ($EXISTING_FILESYSTEM):${NC}"
    blkid "$PARTITION" 2>/dev/null || true
    read -rp "Continue and format partition? This will destroy existing filesystem! (y/N): " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo -e "${BLUE}Skipping formatting - using existing filesystem${NC}"
        SKIP_FORMATTING=true
    fi
fi

if [[ "$SKIP_FORMATTING" == false ]]; then
    mkfs.ext4 "$PARTITION"
    echo -e "${GREEN}✓ Partition formatted with ext4${NC}"
else
    echo -e "${GREEN}✓ Using existing filesystem on $PARTITION${NC}"
    # Verify the existing filesystem is ext4 or compatible
    if [[ "$EXISTING_FILESYSTEM" != "ext4" && "$EXISTING_FILESYSTEM" != "ext3" && "$EXISTING_FILESYSTEM" != "ext2" ]]; then
        echo -e "${YELLOW}Warning: Existing filesystem is $EXISTING_FILESYSTEM, not ext4. This may cause issues.${NC}"
        read -rp "Continue anyway? (y/N): " CONFIRM
        if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
            echo "Aborted by user."
            exit 0
        fi
    fi
fi

echo -e "\n${YELLOW}Step 3: Creating mount directory${NC}"
mkdir -p "$MOUNT_PATH"

echo -e "\n${YELLOW}Step 4: Mounting the partition${NC}"
# Don't mount manually since systemd will handle it
# mount "$PARTITION" "$MOUNT_PATH"
echo "Skipping manual mount - systemd will handle mounting"

# Get UUID of the partition
UUID=$(blkid -s UUID -o value "$PARTITION")

if [[ -z "$UUID" ]]; then
    echo -e "${RED}Error: Cannot determine UUID for partition $PARTITION${NC}" >&2
    exit 1
fi

echo "Partition UUID: $UUID"

echo -e "\n${YELLOW}Step 5: Adding mount to /etc/fstab${NC}"

# Clean up any existing conflicting unit files
echo "Cleaning up any existing systemd unit files..."
LEGACY_MOUNT_UNIT="/etc/systemd/system/mnt-datastore-${SERVICE_NAME}.mount"
LEGACY_AUTOMOUNT_UNIT="/etc/systemd/system/mnt-datastore-${SERVICE_NAME}.automount"
MOUNT_UNIT_FILE="/etc/systemd/system/${SYSTEMD_MOUNT_NAME}"
AUTOMOUNT_UNIT_FILE="/etc/systemd/system/${SYSTEMD_AUTOMOUNT_NAME}"

# Stop and disable any existing services
for unit in "$LEGACY_MOUNT_UNIT" "$LEGACY_AUTOMOUNT_UNIT" "$MOUNT_UNIT_FILE" "$AUTOMOUNT_UNIT_FILE"; do
    unit_name=$(basename "$unit")
    if [[ -f "$unit" ]]; then
        echo "Stopping and disabling unit: $unit_name"
        systemctl stop "$unit_name" 2>/dev/null || true
        systemctl disable "$unit_name" 2>/dev/null || true
        rm -f "$unit"
    fi
done

# Also check for any mount points that might be active
if mountpoint -q "$MOUNT_PATH"; then
    echo "Unmounting existing mount at $MOUNT_PATH"
    umount "$MOUNT_PATH" || true
fi

# Backup fstab
cp /etc/fstab /etc/fstab.backup.$(date +%Y%m%d-%H%M%S)

# Remove any existing entries for this mount point
sed -i "\|${MOUNT_PATH}|d" /etc/fstab

# Add the new fstab entry with systemd-specific options
FSTAB_ENTRY="UUID=${UUID} ${MOUNT_PATH} ext4 defaults,nofail,x-systemd.device-timeout=30 0 2"
echo "$FSTAB_ENTRY" >> /etc/fstab

echo "Added to /etc/fstab: $FSTAB_ENTRY"

echo -e "\n${YELLOW}Step 6: Mounting the filesystem${NC}"
# Test mount the filesystem
mount "$MOUNT_PATH"

# Verify it mounted correctly
if mountpoint -q "$MOUNT_PATH"; then
    echo -e "${GREEN}✓ Mount successful${NC}"
else
    echo -e "${RED}Error: Mount failed${NC}" >&2
    exit 1
fi

echo -e "\n${YELLOW}Step 7: Verifying mount${NC}"
echo "Checking current mount status:"
df -h "$MOUNT_PATH" || echo "Mount not found in df output"
echo
echo "Mount point status:"
if mountpoint -q "$MOUNT_PATH"; then
    echo -e "${GREEN}✓ $MOUNT_PATH is mounted${NC}"
else
    echo -e "${RED}✗ $MOUNT_PATH is not mounted${NC}"
fi

echo
echo "fstab entry verification:"
grep "$MOUNT_PATH" /etc/fstab || echo "No fstab entry found"

echo -e "\n${YELLOW}Step 8: Adding iSCSI session monitoring${NC}"
# Create check-iscsi-session script with auto-detected values
CHECK_ISCSI_SCRIPT="/usr/local/bin/check-iscsi-session-${SERVICE_NAME}.sh"
tee "$CHECK_ISCSI_SCRIPT" > /dev/null << EOF
#!/bin/bash
# Auto-generated iSCSI session and mount monitor for $SERVICE_NAME
TARGET="$TARGET_IQN"
PORTAL="$PORTAL_IP"
MOUNT_PATH="$MOUNT_PATH"
LOG_FILE="/var/log/iscsi-monitor.log"

# Function to log with timestamp
log_message() {
    echo "\$(date '+%Y-%m-%d %H:%M:%S'): \$1" >> "\$LOG_FILE"
}

# Function to check and restore mount
check_and_restore_mount() {
    if ! mountpoint -q "\$MOUNT_PATH" 2>/dev/null; then
        log_message "Mount point \$MOUNT_PATH not mounted. Attempting to mount..."
        if mount "\$MOUNT_PATH" 2>/dev/null; then
            log_message "Successfully mounted \$MOUNT_PATH"
        else
            log_message "Failed to mount \$MOUNT_PATH"
        fi
    fi
}

# Check if session exists
if ! iscsiadm -m session 2>/dev/null | grep -q "\$TARGET"; then
    log_message "iSCSI session for \$TARGET not found. Attempting to reconnect..."
    if iscsiadm -m node -T "\$TARGET" -p "\$PORTAL" --login 2>/dev/null; then
        log_message "Successfully reconnected to \$TARGET"
        # Wait a moment for device to be available
        sleep 2
        # Try to restore mount
        check_and_restore_mount
    else
        log_message "Failed to reconnect to \$TARGET"
    fi
else
    # Session exists, verify it's healthy by checking for running state
    session_health=\$(iscsiadm -m session -P 3 2>/dev/null | awk -v target="\$TARGET" '
        /Target:/ { current_target = \$2 }
        current_target == target && /State:/ { 
            if (\$2 == "running") print "healthy"
            else print "unhealthy"
        }
    ')
    
    if [[ "\$session_health" == "unhealthy" ]]; then
        log_message "iSCSI session for \$TARGET exists but is not in running state"
    fi
    
    # Always check if mount is available, even if session is healthy
    check_and_restore_mount
fi
EOF
chmod +x "$CHECK_ISCSI_SCRIPT"

echo -e "\n${YELLOW}Step 9: Adding cron job for iSCSI monitoring${NC}"
# Add cron job with unique comment to avoid duplicates
CRON_JOB="*/1 * * * * $CHECK_ISCSI_SCRIPT # iSCSI monitor for $SERVICE_NAME"
TEMP_CRON=$(mktemp)

# Get existing crontab and add new job if it doesn't exist
crontab -l 2>/dev/null | grep -v "# iSCSI monitor for $SERVICE_NAME" > "$TEMP_CRON" || true
echo "$CRON_JOB" >> "$TEMP_CRON"
crontab "$TEMP_CRON"
rm "$TEMP_CRON"

echo -e "\n${GREEN}=== Setup Complete ===${NC}"
echo -e "\n${YELLOW}iSCSI Configuration:${NC}"
echo "  Target IQN: $TARGET_IQN"
echo "  Portal:     $PORTAL_IP"
echo "  Device:     $DEVICE_PATH"

echo -e "\n${YELLOW}Created files:${NC}"
echo "  $CHECK_ISCSI_SCRIPT"
echo "  /var/spool/cron/crontabs/root (cron entry added)"
echo "  /etc/fstab.backup.* (fstab backup)"

echo -e "\n${YELLOW}Configuration:${NC}"
echo "  Mount method:   fstab (UUID-based)"
echo "  fstab entry:    UUID=${UUID} ${MOUNT_PATH} ext4 defaults,nofail,x-systemd.device-timeout=30 0 2"
echo "  iSCSI service:  ${ISCSI_SERVICE}"

echo -e "\n${YELLOW}Mount information:${NC}"
if mountpoint -q "$MOUNT_PATH" 2>/dev/null; then
    echo -e "${ORANGE}Current mount status:${NC}"
    df -h "$MOUNT_PATH"
    echo -e "${GREEN}✓ Mount is currently active${NC}"
else
    echo -e "${RED}✗ Mount is not currently active${NC}"
    echo "Try running: mount $MOUNT_PATH"
fi

echo
echo -e "${GREEN}The iSCSI storage is configured for automatic mounting on boot via fstab.${NC}"
echo -e "${GREEN}The system will check the iSCSI connection every 5 minutes via cron.${NC}"

# Final test: Show final df output
echo -e "\n${ORANGE}=== Final Mount Test ===${NC}"
if mountpoint -q "$MOUNT_PATH"; then
    echo -e "${GREEN}✓ Mount is active${NC}"
    echo -e "\n${ORANGE}Final disk usage for $MOUNT_PATH:${NC}"
    df -h "$MOUNT_PATH" | head -1  # Header
    df -h "$MOUNT_PATH" | tail -1 | while read -r line; do
        echo -e "${ORANGE}$line${NC}"
    done
else
    echo -e "${YELLOW}Mount not active. After reboot, the mount should be available automatically.${NC}"
    echo -e "${BLUE}To test now: mount $MOUNT_PATH${NC}"
fi