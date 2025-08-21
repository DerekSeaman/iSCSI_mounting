#!/usr/bin/env bash
# Version 1.1, 8/19/2025
# iSCSI LUN cleanup script which dismounts iSCSI LUNs and cleans up all automounts
# Built as a companion script to my iSCSI_mount.sh script to mount an iSCSI LUN 
# Derek Seaman
#

set -euo pipefail

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root" >&2
   exit 1
fi

# Color codes for output (matching v2 combined script)
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
ORANGE='\033[0;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Complete iSCSI Cleanup Script ===${NC}"
echo "This script will:"
echo "1. Remove iSCSI entries from /etc/fstab"
echo "2. Unmount all iSCSI-related mount points"
echo "3. Logout from all active iSCSI sessions"
echo "4. Remove all iSCSI node configurations"
echo "5. Force removal of device entries"
echo "6. Clean up monitoring scripts and cron jobs"
echo "7. Remove any remaining systemd unit files"
echo

# Check if iscsiadm is available
if ! command -v iscsiadm >/dev/null 2>&1; then
    echo -e "${RED}Warning: iscsiadm not found. Some cleanup may be incomplete.${NC}"
    ISCSI_AVAILABLE=false
else
    ISCSI_AVAILABLE=true
fi

# Confirmation prompt
read -rp "This will disconnect ALL iSCSI sessions and may cause data loss. Continue? (y/N): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Operation cancelled."
    exit 0
fi

echo -e "\n${YELLOW}Step 1: Discovering current iSCSI sessions and mounted devices${NC}"

# Get list of active iSCSI sessions before cleanup
if $ISCSI_AVAILABLE; then
    ACTIVE_SESSIONS=$(iscsiadm -m session 2>/dev/null || true)
    if [[ -n "$ACTIVE_SESSIONS" ]]; then
        echo -e "${BLUE}Active iSCSI sessions:${NC}"
        echo "$ACTIVE_SESSIONS"
    else
        echo "No active iSCSI sessions found."
    fi
else
    ACTIVE_SESSIONS=""
fi

# Find iSCSI-related block devices
echo -e "\n${BLUE}Looking for iSCSI block devices:${NC}"
ISCSI_DEVICES=()
for device in /sys/block/*/device; do
    if [[ -e "$device" ]]; then
        device_path=$(readlink -f "$device")
        if echo "$device_path" | grep -q "session"; then
            block_device="/dev/$(basename "$(dirname "$device")")"
            echo "Found iSCSI device: $block_device"
            ISCSI_DEVICES+=("$block_device")
        fi
    fi
done

if [[ ${#ISCSI_DEVICES[@]} -eq 0 ]]; then
    echo "No iSCSI block devices found in /sys/block/"
fi

echo -e "\n${YELLOW}Step 2: Removing iSCSI entries from /etc/fstab${NC}"

# Backup fstab before making changes
if [[ -f /etc/fstab ]]; then
    cp /etc/fstab /etc/fstab.backup.cleanup.$(date +%Y%m%d-%H%M%S)
    echo "Created fstab backup: /etc/fstab.backup.cleanup.$(date +%Y%m%d-%H%M%S)"
fi

# Find and remove iSCSI-related fstab entries
echo "Scanning /etc/fstab for iSCSI-related entries..."
iscsi_fstab_entries=0

# Check for entries with x-systemd.device-timeout (our signature) or _netdev
while IFS= read -r line; do
    if [[ "$line" =~ ^[[:space:]]*UUID= ]] && [[ "$line" =~ (x-systemd\.device-timeout|_netdev) ]]; then
        mount_point=$(echo "$line" | awk '{print $2}')
        echo "Found iSCSI fstab entry for mount point: $mount_point"
        iscsi_fstab_entries=$((iscsi_fstab_entries + 1))
        
        # Remove this entry from fstab
        sed -i "\|${mount_point}|d" /etc/fstab
        echo "Removed fstab entry for: $mount_point"
    fi
done < /etc/fstab

if [[ $iscsi_fstab_entries -eq 0 ]]; then
    echo "No iSCSI-related fstab entries found"
else
    echo "Removed $iscsi_fstab_entries iSCSI fstab entries"
fi

echo -e "\n${YELLOW}Step 3: Unmounting all iSCSI devices and removing mount points${NC}"

# Collect mount points for later removal
MOUNT_POINTS_TO_REMOVE=()

# Unmount all partitions on iSCSI devices
for device in "${ISCSI_DEVICES[@]}"; do
    echo "Processing device: $device"
    
    # Find all mounted partitions for this device
    mounted_partitions=$(mount | grep "^$device" | awk '{print $1}' || true)
    
    for partition in $mounted_partitions; do
        mount_point=$(mount | grep "^$partition " | awk '{print $3}' || true)
        if [[ -n "$mount_point" ]]; then
            echo "  Unmounting $partition from $mount_point"
            umount "$partition" || umount -f "$partition" || umount -l "$partition" || true
            # Add to removal list if it's in /mnt
            if [[ "$mount_point" == /mnt/* ]]; then
                MOUNT_POINTS_TO_REMOVE+=("$mount_point")
            fi
        fi
    done
    
    # Also check for any remaining mounts using findmnt
    remaining_mounts=$(findmnt -rn -S "$device*" 2>/dev/null | awk '{print $1}' || true)
    for mount_point in $remaining_mounts; do
        echo "  Force unmounting remaining mount: $mount_point"
        umount "$mount_point" || umount -f "$mount_point" || umount -l "$mount_point" || true
        # Add to removal list if it's in /mnt
        if [[ "$mount_point" == /mnt/* ]]; then
            MOUNT_POINTS_TO_REMOVE+=("$mount_point")
        fi
    done
done

# Also check fstab for any mount points that might not be currently mounted
echo "Checking fstab for additional mount points to remove..."
if [[ -f /etc/fstab ]]; then
    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*UUID= ]] && [[ "$line" =~ (x-systemd\.device-timeout|_netdev) ]]; then
            mount_point=$(echo "$line" | awk '{print $2}')
            if [[ "$mount_point" == /mnt/* ]]; then
                MOUNT_POINTS_TO_REMOVE+=("$mount_point")
            fi
        fi
    done < /etc/fstab
fi

# Remove duplicate mount points
IFS=" " read -r -a UNIQUE_MOUNT_POINTS <<< "$(printf '%s\n' "${MOUNT_POINTS_TO_REMOVE[@]}" | sort -u | tr '\n' ' ')"

# Remove mount point directories
if [[ ${#UNIQUE_MOUNT_POINTS[@]} -gt 0 ]]; then
    echo -e "\n${BLUE}Removing mount point directories:${NC}"
    for mount_point in "${UNIQUE_MOUNT_POINTS[@]}"; do
        if [[ -d "$mount_point" ]]; then
            echo "  Attempting to remove directory: $mount_point"
            if rmdir "$mount_point" 2>/dev/null; then
                echo "    ✓ Successfully removed: $mount_point"
            else
                echo "    ⚠ Could not remove: $mount_point (directory not empty or permission denied)"
                echo "    Manual cleanup may be required for: $mount_point"
            fi
        fi
    done
else
    echo "No mount point directories found to remove"
fi

echo -e "\n${YELLOW}Step 4: Logging out from all iSCSI sessions${NC}"

if $ISCSI_AVAILABLE && [[ -n "$ACTIVE_SESSIONS" ]]; then
    # Method 1: Try to logout from each session individually
    while IFS= read -r session_line; do
        if [[ -n "$session_line" ]]; then
            # Extract target and portal from session line
            # Format: tcp: [session_num] portal:port,tag target_iqn
            if [[ "$session_line" =~ tcp:\ \[[0-9]+\]\ ([^,]+),[0-9]+\ (.+) ]]; then
                portal="${BASH_REMATCH[1]}"
                target="${BASH_REMATCH[2]}"
                echo "Logging out from target: $target via portal: $portal"
                iscsiadm -m node -T "$target" -p "$portal" --logout || true
            fi
        fi
    done <<< "$ACTIVE_SESSIONS"
    
    # Method 2: Force logout from all sessions
    echo "Performing global logout from all remaining sessions..."
    iscsiadm -m session --logout || true
    
    # Method 3: Use session IDs for any stubborn sessions
    remaining_sessions=$(iscsiadm -m session 2>/dev/null || true)
    if [[ -n "$remaining_sessions" ]]; then
        echo "Force logging out remaining sessions by session ID..."
        while IFS= read -r session_line; do
            if [[ "$session_line" =~ tcp:\ \[([0-9]+)\] ]]; then
                session_id="${BASH_REMATCH[1]}"
                echo "Force logout session ID: $session_id"
                iscsiadm -m session -r "$session_id" --logout || true
            fi
        done <<< "$remaining_sessions"
    fi
fi

echo -e "\n${YELLOW}Step 5: Removing iSCSI node configurations${NC}"

if $ISCSI_AVAILABLE; then
    # Get list of all configured nodes
    CONFIGURED_NODES=$(iscsiadm -m node 2>/dev/null || true)
    
    if [[ -n "$CONFIGURED_NODES" ]]; then
        echo -e "${BLUE}Removing configured iSCSI nodes:${NC}"
        while IFS= read -r node_line; do
            if [[ -n "$node_line" && "$node_line" =~ ^([^,]+),([^[:space:]]+)[[:space:]]+(.+) ]]; then
                portal="${BASH_REMATCH[1]}"
                tag="${BASH_REMATCH[2]}"
                target="${BASH_REMATCH[3]}"
                echo "Removing node: $target via $portal"
                iscsiadm -m node -T "$target" -p "$portal" --op=delete || true
            fi
        done <<< "$CONFIGURED_NODES"
    else
        echo "No iSCSI node configurations found."
    fi
    
    # Clean up any remaining node database entries
    echo "Cleaning up iSCSI node database..."
    rm -rf /var/lib/iscsi/nodes/* 2>/dev/null || true
    rm -rf /var/lib/iscsi/send_targets/* 2>/dev/null || true
fi

echo -e "\n${YELLOW}Step 6: Forcing removal of device entries${NC}"

# Force remove device entries and rescan SCSI bus
for device in "${ISCSI_DEVICES[@]}"; do
    device_name=$(basename "$device")
    echo "Removing device: $device"
    
    # Remove all partitions first
    for partition in "${device}"*; do
        if [[ -b "$partition" && "$partition" != "$device" ]]; then
            echo "  Removing partition: $partition"
            # Remove from device mapper if present
            dm_name=$(dmsetup info -c --noheadings -o name "$partition" 2>/dev/null || true)
            if [[ -n "$dm_name" ]]; then
                dmsetup remove "$dm_name" || true
            fi
        fi
    done
    
    # Find SCSI device path
    if [[ -e "/sys/block/$device_name/device" ]]; then
        scsi_device_path=$(readlink -f "/sys/block/$device_name/device")
        echo "  SCSI device path: $scsi_device_path"
        
        # Extract host, channel, target, lun
        if [[ "$scsi_device_path" =~ host([0-9]+)/.*target([0-9]+):([0-9]+):([0-9]+)/([0-9]+):([0-9]+):([0-9]+):([0-9]+) ]]; then
            host="${BASH_REMATCH[1]}"
            target_id="${BASH_REMATCH[5]}"
            channel="${BASH_REMATCH[6]}"
            lun="${BASH_REMATCH[8]}"
            
            echo "  Removing SCSI device: host$host channel:$channel target:$target_id lun:$lun"
            
            # Remove the device
            if [[ -f "/sys/class/scsi_device/$target_id:$channel:$target_id:$lun/device/delete" ]]; then
                echo 1 > "/sys/class/scsi_device/$target_id:$channel:$target_id:$lun/device/delete" 2>/dev/null || true
            fi
        fi
    fi
done

# Rescan SCSI buses to clean up
echo "Rescanning SCSI buses to clean up..."
for host in /sys/class/scsi_host/host*; do
    if [[ -f "$host/scan" ]]; then
        echo "- - -" > "$host/scan" 2>/dev/null || true
    fi
done

echo -e "\n${YELLOW}Step 7: Final cleanup${NC}"

# Remove any device mapper entries
echo "Cleaning up device mapper entries..."
for dm_device in /dev/mapper/*; do
    if [[ -e "$dm_device" ]]; then
        dm_name=$(basename "$dm_device")
        # Skip system device mapper entries
        if [[ ! "$dm_name" =~ ^(control|ubuntu--vg-.*)$ ]]; then
            # Check if it might be iSCSI related
            dm_info=$(dmsetup info "$dm_name" 2>/dev/null || true)
            if [[ "$dm_info" =~ (iscsi|session) ]]; then
                echo "Removing device mapper entry: $dm_name"
                dmsetup remove "$dm_name" || true
            fi
        fi
    fi
done

# Clean up any remaining iSCSI-related systemd unit files
echo "Cleaning up any remaining iSCSI-related systemd unit files..."
# Only remove files that might have been created by previous versions of the script
for unit_file in /etc/systemd/system/iscsi-target-*.service /etc/systemd/system/mnt-*.mount /etc/systemd/system/mnt-*.automount; do
    if [[ -f "$unit_file" ]]; then
        unit_name=$(basename "$unit_file")
        echo "Removing systemd unit file: $unit_file"
        systemctl stop "$unit_name" 2>/dev/null || true
        systemctl disable "$unit_name" 2>/dev/null || true
        rm -f "$unit_file"
    fi
done

# Clean up monitoring scripts and helper scripts
echo "Cleaning up iSCSI session and mount monitoring scripts..."
rm -f /usr/local/bin/check-iscsi-session*.sh
rm -f /usr/local/bin/wait-iscsi-target*.sh

# Clean up log files created by monitoring scripts
echo "Cleaning up iSCSI session and mount monitoring log files..."
rm -f /var/log/iscsi-monitor.log

# Enhanced cron job cleanup with service reload (Debian 13 uses cron.service)
echo -e "${YELLOW}Cleaning up iSCSI-related cron jobs and reloading cron service...${NC}"
temp_cron=$(mktemp)

# Get current crontab and remove iSCSI-related entries
echo -e "${BLUE}Removing all iSCSI monitor cron jobs...${NC}"
if crontab -l 2>/dev/null > "$temp_cron"; then
    # Count how many iSCSI cron jobs we're removing
    removed_count=$(grep -c "iSCSI monitor" "$temp_cron" 2>/dev/null || echo "0")
    
    # Remove all lines containing "iSCSI monitor"
    grep -v "iSCSI monitor" "$temp_cron" > "${temp_cron}.new" || touch "${temp_cron}.new"
    
    # Update crontab
    crontab "${temp_cron}.new"
    
    if [[ "$removed_count" -gt 0 ]]; then
        echo -e "${GREEN}✓ Removed $removed_count iSCSI monitor cron job(s)${NC}"
    else
        echo "No iSCSI monitor cron jobs found to remove"
    fi
    
    rm -f "${temp_cron}.new"
else
    echo "No existing crontab found"
fi

rm -f "$temp_cron"

# Restart cron service (Debian 13 - cron.service doesn't support reload)
echo -e "${BLUE}Restarting cron service...${NC}"
systemctl restart cron
echo -e "${GREEN}✓ Cron service restarted${NC}"

# Reload systemd
systemctl daemon-reload

echo -e "\n${YELLOW}Step 8: Verification${NC}"

# Check for remaining sessions
if $ISCSI_AVAILABLE; then
    remaining_sessions=$(iscsiadm -m session 2>/dev/null || true)
    if [[ -n "$remaining_sessions" ]]; then
        echo -e "${RED}Warning: Some iSCSI sessions may still be active:${NC}"
        echo "$remaining_sessions"
    else
        echo -e "${GREEN}✓ No active iSCSI sessions remaining${NC}"
    fi
fi

# Check for remaining devices
echo -e "\n${BLUE}Checking for remaining iSCSI devices:${NC}"
remaining_devices=()
for device in /sys/block/*/device; do
    if [[ -e "$device" ]]; then
        device_path=$(readlink -f "$device")
        if echo "$device_path" | grep -q "session"; then
            block_device="/dev/$(basename "$(dirname "$device")")"
            remaining_devices+=("$block_device")
        fi
    fi
done

if [[ ${#remaining_devices[@]} -eq 0 ]]; then
    echo -e "${GREEN}✓ No iSCSI block devices remaining${NC}"
else
    echo -e "${RED}Warning: Some iSCSI devices may still be present:${NC}"
    printf '%s\n' "${remaining_devices[@]}"
fi

# Check for remaining mounts
echo -e "\n${BLUE}Checking for remaining iSCSI mounts:${NC}"
remaining_mounts=$(mount | grep -E "(iscsi|session)" || true)
if [[ -z "$remaining_mounts" ]]; then
    echo -e "${GREEN}✓ No iSCSI mounts remaining${NC}"
else
    echo -e "${RED}Warning: Some iSCSI mounts may still be active:${NC}"
    echo "$remaining_mounts"
fi

# Check cron cleanup
echo -e "\n${BLUE}Verifying cron cleanup:${NC}"
if crontab -l 2>/dev/null | grep -q "iSCSI monitor"; then
    remaining_cron_jobs=$(crontab -l 2>/dev/null | grep -c "iSCSI monitor")
    echo -e "${RED}Warning: $remaining_cron_jobs iSCSI monitor cron job(s) still present${NC}"
else
    echo -e "${GREEN}✓ No iSCSI monitor cron jobs remaining${NC}"
fi

# Check fstab cleanup
echo -e "\n${BLUE}Verifying fstab cleanup:${NC}"
if grep -q "x-systemd.device-timeout\|_netdev" /etc/fstab 2>/dev/null; then
    remaining_fstab_entries=$(grep -c "x-systemd.device-timeout\|_netdev" /etc/fstab 2>/dev/null || echo "0")
    echo -e "${RED}Warning: $remaining_fstab_entries potential iSCSI fstab entries still present${NC}"
    echo "Remaining entries:"
    grep "x-systemd.device-timeout\|_netdev" /etc/fstab 2>/dev/null || true
else
    echo -e "${GREEN}✓ No iSCSI fstab entries remaining${NC}"
fi

echo -e "\n${GREEN}=== iSCSI Cleanup Complete ===${NC}"
echo
echo -e "${ORANGE}Summary of actions taken:${NC}"
echo "• Removed iSCSI entries from /etc/fstab (with backup)"
echo "• Unmounted all iSCSI-related filesystems"
echo "• Removed iSCSI mount point directories from /mnt"
echo "• Logged out from all iSCSI sessions"
echo "• Removed all iSCSI node configurations"
echo "• Removed device entries and rescanned SCSI buses"
echo "• Cleaned up monitoring scripts and helper scripts"
echo "• Removed all iSCSI-related cron jobs"
echo "• Cleaned up any remaining systemd unit files"
echo
echo -e "${BLUE}Note: A system reboot may be required to ensure all traces are removed.${NC}"