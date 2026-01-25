# iSCSI LUN Mounting Scripts for Proxmox Backup Server

A comprehensive set of Bash scripts for automated iSCSI LUN connection, mounting, and cleanup on Debian 13 systems, specifically designed for Proxmox Backup Server (PBS) datastore configuration. These scripts provide enterprise-grade iSCSI storage management with systemd integration, automatic reconnection monitoring, and complete cleanup capabilities.

For a complete tutorial on configuring Synology iSCSI LUNs with Proxmox Backup Server, see: [How to: Synology iSCSI LUN for Proxmox Backup Server Datastore](https://www.derekseaman.com/2025/08/how-to-synology-iscsi-lun-for-proxmox-backup-server-datastore.html)

For guidance on how to install PBS as a VM, see:

- Proxmox VE: [How to: Proxmox Backup Server 4 VM Installation](https://www.derekseaman.com/2025/08/how-to-proxmox-backup-server-4-vm-installation.html)
- Synology NAS: [How to: Proxmox Backup Server 4 as a Synology VM](https://www.derekseaman.com/2025/08/how-to-proxmox-backup-server-4-as-a-synology-vm.html)

## Summary

This repository contains two complementary scripts designed to simplify iSCSI storage management for Proxmox Backup Server environments:

- **`iSCSI_mount.sh`** - Combined connection and mounting script that connects to iSCSI targets with CHAP authentication, automatically detects the new storage device, partitions and formats it, then configures automatic mounting via fstab as a PBS datastore
- **`iSCSI_cleanup.sh`** - Comprehensive cleanup script that safely disconnects all iSCSI sessions, unmounts storage, removes fstab entries, and cleans up all traces

Both scripts are optimized specifically for Debian 13 with open-iscsi (the base OS for Proxmox Backup Server) and include robust error handling, colored output for better user experience, and detailed logging. The scripts use a simplified fstab-based approach for reliable automatic mounting. The mounted iSCSI LUNs can be directly configured as backup datastores in the Proxmox Backup Server web interface. This script is NOT compatible with Proxmox Backup Servers running as a LXC. You must run PBS as a full VM or baremetal to easily mount iSCSI LUNs.

## Features

### iSCSI Mounting Script

- **Automatic iSCSI Service Management** - Detects, enables, and starts the appropriate iSCSI service (iscsid)
- **CHAP Authentication Support** - Secure connection with username/password authentication
- **Automatic Device Detection** - Identifies the newly connected iSCSI device without manual specification
- **Complete Storage Setup** - Creates GPT partition tables, formats (ext4), and mounts the storage automatically
- **Existing Storage Protection** - Detects existing partition tables and filesystems, prompts user before destruction, can reuse existing storage
- **fstab Integration** - Uses traditional fstab approach with systemd-optimized options for reliable boot mounting
- **Session and Mount Monitoring** - Configures automatic reconnection and mount restoration monitoring via cron (every minute)
- **UUID-based Mounting** - Uses partition UUIDs for reliable mounting across reboots
- **PBS Datastore Ready** - Mounted storage is immediately ready for configuration as a PBS datastore
- **Comprehensive Error Handling** - Validates each step with detailed error reporting

### Cleanup Script

- **Complete Session Cleanup** - Logs out from all active iSCSI sessions safely
- **Device Removal** - Forces removal of iSCSI block devices and SCSI entries
- **fstab Cleanup** - Removes iSCSI entries from /etc/fstab with backup creation
- **Monitoring Cleanup** - Removes monitoring scripts, helper scripts, log files, and cron jobs
- **Database Cleanup** - Clears iSCSI node configurations and database entries
- **Verification** - Confirms complete removal of all iSCSI traces

### General Features

- **Debian 13 Optimized** - Specifically designed for Debian 13 with open-iscsi
- **Root Privilege Management** - Automatic root privilege checking
- **Colored Output** - Consistent color coding for status messages and errors
- **Input Validation** - Comprehensive validation of user inputs and system state
- **Safe Execution** - Uses `set -euo pipefail` for robust error handling

## Prerequisites

- Debian 13 (Trixie) - base OS for Proxmox Backup Server 4.0
- Root privileges
- open-iscsi package installed
- Target iSCSI server with CHAP authentication configured
- Proxmox Backup Server installation (for datastore configuration)

## Installation

1. Clone the repository:

   ```bash
   apt update
   apt install -y git
   git clone https://github.com/DerekSeaman/iSCSI_mounting.git
   cd iSCSI_mounting
   ```

2. Make scripts executable:

   ```bash
   chmod +x iSCSI_mount.sh iSCSI_cleanup.sh
   ```

3. Install and configure open-iscsi:

   ```bash
   # Install open-iscsi and parted
   apt install open-iscsi parted -y

   # Load iSCSI kernel modules
   modprobe iscsi_tcp
   modprobe scsi_transport_iscsi

   # Verify modules are loaded
   lsmod | grep iscsi_tcp
   modinfo iscsi_tcp

   # Configure modules to load at boot
   echo "iscsi_tcp" >> /etc/modules
   echo "scsi_transport_iscsi" >> /etc/modules

   # Configure automatic node startup
   sed -i 's/node.startup = manual/node.startup = automatic/g' /etc/iscsi/iscsid.conf
   ```

4. Reboot the system:

   ```bash
   reboot
   ```

## Usage

### Mounting iSCSI Storage

Run the mounting script as root:

```bash
./iSCSI_mounting/iSCSI_mount.sh
```

The script will prompt for:

- **Target IQN** (e.g., `iqn.2000-01.com.synology:DS923.Target-1.2c0d1f17e14`)
- **CHAP Username**
- **CHAP Password** (hidden input)
- **iSCSI Portal IP Address** (e.g., `192.168.2.100`)
- **Mount Path** (e.g., `/mnt/synology`)

### Example Session

```text
=== Combined iSCSI Connect and Mount Script ===
Enter target IQN: iqn.2000-01.com.synology:DS923.Target-1.2c0d1f17e14
Enter CHAP username: myuser
Enter CHAP password: [hidden]
Enter portal IP address: 192.168.2.100
Enter mount path: /mnt/synology

✓ iSCSI connection established
✓ Device /dev/sde detected and configured

Step 1: Partitioning disk
Warning: Device /dev/sde already has partitions:
NAME   MAJ:MIN RM  SIZE RO TYPE MOUNTPOINT
sde      8:64   0  300G  0 disk 
└─sde1   8:65   0  300G  0 part 
Continue and create new partition table? This will destroy existing data! (y/N): n
Skipping partitioning - using existing partition table
✓ Using existing partition: /dev/sde1

Step 2: Formatting partition with ext4
Warning: Partition /dev/sde1 already has a filesystem (ext4):
/dev/sde1: UUID="12345678-1234-1234-1234-123456789abc" TYPE="ext4"
Continue and format partition? This will destroy existing filesystem! (y/N): n
Skipping formatting - using existing filesystem
✓ Using existing filesystem on /dev/sde1

✓ Mount configured for immediate availability on boot
✓ Monitoring setup complete

Final disk usage for /mnt/synology:
Filesystem      Size  Used Avail Use% Mounted on
/dev/sde1       2.0T   24K  1.9T   1% /mnt/synology
```

**Next Steps**: After successful mounting, configure the mounted path (`/mnt/synology`) as a datastore in the Proxmox Backup Server web interface under **Datastores** → **Add Datastore**.

### Cleaning Up iSCSI Storage

To remove all iSCSI configurations and disconnect storage:

```bash
./iSCSI_cleanup.sh
```

**Warning**: This will disconnect ALL iSCSI sessions and may cause data loss. Ensure all data is saved before running.

## Script Workflow

### Mounting Process

1. **Service Verification** - Checks and starts iscsid service
2. **iSCSI Connection** - Connects to target with CHAP authentication and configures automatic startup
3. **Device Detection** - Automatically finds the new storage device
4. **Storage Preparation** - Intelligently handles GPT partitioning and formatting:
   - Detects existing partition tables (both MBR and GPT) and prompts user before destruction
   - Creates a new GPT partition table, supporting disks >2TB
   - Can reuse existing partitions if user declines to overwrite
   - Detects existing filesystems and prompts user before formatting
   - Can reuse existing ext2/ext3/ext4 filesystems if user declines to format
   - Creates new GPT partition and ext4 filesystem only when needed or requested
5. **fstab Configuration** - Adds UUID-based entry to /etc/fstab with systemd-optimized options
6. **Mount Activation** - Immediately mounts the filesystem and verifies operation
7. **Monitoring Setup** - Configures automatic session reconnection and mount restoration monitoring via cron

### Cleanup Process

1. **Discovery** - Identifies all active iSCSI sessions and devices
2. **fstab Cleanup** - Removes iSCSI entries from /etc/fstab with backup creation
3. **Storage Unmounting** - Safely unmounts all iSCSI filesystems
4. **Session Logout** - Disconnects from all iSCSI targets
5. **Configuration Removal** - Cleans up node configurations and databases
6. **Device Cleanup** - Forces removal of device entries
7. **File Cleanup** - Removes monitoring scripts, helper scripts, and logs
8. **Verification** - Confirms complete cleanup

## Generated Files

The mounting script creates several files for persistent configuration:

### fstab Configuration

- `/etc/fstab` - UUID-based mount entry with systemd-optimized options
- `/etc/fstab.backup.*` - Timestamped backup of original fstab

### Monitoring

- `/usr/local/bin/check-iscsi-session-[mountname].sh` - Session and mount monitoring script
- `/var/log/iscsi-monitor.log` - Monitoring log file
- Cron job entry for automated monitoring (every minute)

### Mount Configuration

- GPT partition table with single partition mounted at specified path with UUID-based configuration
- ext4 filesystem optimized for backup storage
- Automatic mounting on boot via fstab with timeout protection
- Ready for Proxmox Backup Server datastore configuration

## Configuration Options

### Mount Behavior

The script configures **automatic mounting** via fstab with systemd enhancements:

- Storage is mounted automatically during system startup
- Uses `nofail` option to prevent boot failure if storage unavailable
- 30-second device timeout prevents boot hangs
- No manual intervention required after reboot

### Monitoring Frequency

- Session and mount monitoring runs every minute via cron
- Failed connections trigger automatic reconnection attempts
- Failed mounts trigger automatic mount restoration attempts
- All monitoring activity is logged for troubleshooting

## Proxmox Backup Server Integration

After successfully mounting the iSCSI storage using these scripts:

1. **Access PBS Web Interface** - Navigate to your Proxmox Backup Server web interface
2. **Add Datastore** - Go to **Datastores** → **Add Datastore**
3. **Configure Datastore**:
   - **Name**: Choose a descriptive name (e.g., "synology-backup")
   - **Backing Path**: Use the mount path from the script (e.g., `/mnt/synology`)
   - **GC Schedule**: Configure garbage collection as needed
4. **Verify Setup** - The datastore should show available space and be ready for backup jobs

The ext4 filesystem and fstab-based mount configuration are optimized for backup storage workloads and provide reliable, battle-tested performance for Proxmox Backup Server operations.

## Troubleshooting

### Common Issues

#### Device not detected after connection

- Verify iSCSI target is accessible and running
- Check CHAP credentials are correct
- Ensure no firewall blocking the connection
- Verify `node.startup=automatic` is configured

#### Mount not available after reboot

- Check fstab entry: `more /etc/fstab`
- Verify iSCSI session is active: `iscsiadm -m session`
- Check boot logs: `journalctl -b | grep -i iscsi`
- Test manual mount: `mount [mountpath]`
- Check monitoring logs: `tail /var/log/iscsi-monitor.log`
- Wait 1-2 minutes for automatic restoration (monitoring runs every minute)

#### Permission denied errors

- Ensure script is run as root
- Check mount point permissions after setup
- Verify filesystem is accessible: `ls -la [mountpath]`

### Log Locations

- **Boot logs**: `journalctl -b | grep -i iscsi`
- **Monitoring logs**: `/var/log/iscsi-monitor.log`
- **iSCSI service logs**: `journalctl -u iscsid`
- **fstab backups**: `/etc/fstab.backup.*`

### Manual Commands

Check mount status:

```bash
df -h | grep [mountpath]
```

```bash
lsblk -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINT
```

Check fstab entry:

```bash
more /etc/fstab
```

Check iSCSI sessions:

```bash
iscsiadm -m session
```

Test connectivity:

```bash
iscsiadm -m discovery -t sendtargets -p [portal-ip]
```

## Security Considerations

- **CHAP Passwords** - Stored in iSCSI node configuration files (readable by root only)
- **Authentication** - Scripts require root privileges for system modifications
- **Data Protection** - Always backup data before running cleanup script

## Compatibility

- **Operating System**: Debian 13 (Trixie) - Proxmox Backup Server 4.0 ISO
- **iSCSI Implementation**: open-iscsi
- **Init System**: systemd

The scripts are specifically optimized for this environment and may require modifications for other distributions.

## Contributing

Contributions are welcome! Please ensure:

- Maintain compatibility with Debian 13
- Follow existing code style and error handling patterns
- Test thoroughly before submitting pull requests
- Update documentation for new features

## License

This project is released under the MIT License. See LICENSE file for details.

## Author

### Derek Seaman

Built as a companion for iSCSI LUN management for Proxmox Backup Server (PBS).
