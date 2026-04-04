# vf-storage-migrate

**Version 1.0.0** | **MIT License** | **VirtFusion Community Tool**

Zero-downtime VM disk migration for [VirtFusion](https://virtfusion.com) hosting providers. Migrate disk images between any storage backends -- NFS to ZFS, local to NFS, NFS to local, or any combination -- without powering off running VMs. Uses `virsh blockcopy` for live migration with automatic polling, pivot, and retry logic. Battle-tested across 60+ production VM migrations.

---

## Features

- **Zero downtime** -- live `virsh blockcopy` + pivot for running VMs (no guest restart required)
- **Any storage to any storage** -- NFS, ZFS, local, or any libvirt-compatible backend
- **Format conversion** -- convert between qcow2 and raw during migration, or preserve the original format
- **Interactive setup wizard** -- auto-discovers VirtFusion database, hypervisors, and storage backends
- **Per-hypervisor destination mapping** -- different destination storage per hypervisor
- **Network speed auto-tuning** -- automatically sizes blockcopy buffers for 1G/10G/25G/40G/100G links
- **Batch mode** -- migrate all VMs on a storage backend in one command, with ETA tracking
- **Optional parallel migrations** -- run N concurrent migrations with `--parallel=N`
- **Dry-run mode** -- preview exactly what will happen before committing
- **Full rollback** -- revert any migration back to the original storage, DB state, and XML config
- **Post-migration verification** -- confirm all migrated VMs are healthy, paths correct, DB consistent
- **Migration reporting** -- summary with source/dest sizes, compression ratios, and time per VM
- **Cleanup mode** -- safely list and remove old source disk images after verification
- **Offline fallback** -- uses `qemu-img convert` for shut-off VMs, `rsync` for undefined/orphaned disks
- **Retry with --reuse-external** -- resumes partial copies instead of starting from scratch
- **Interactive suspend prompt** -- option to pause a VM if live blockcopy fails (never auto-suspends)
- **Signal-safe** -- catches SIGINT/SIGTERM, aborts active blockjobs, resumes suspended VMs
- **VirtFusion DB updates** -- automatically updates `server_disks_storage` and `server_disks` records
- **Persistent XML updates** -- updates VirtFusion's `server.xml` so VMs survive reboots on the new storage
- **Color output with TTY auto-detection** -- clean output when piped, colored when interactive
- **Concurrent run protection** -- flock-based locking prevents two migrations from running simultaneously
- **Single self-contained script** -- no dependencies beyond standard Linux tools

## Requirements

- **VirtFusion** control panel (any version -- the script validates the DB schema at runtime)
- **Bash 4.0+** (for associative arrays)
- **mariadb** or **mysql** CLI client on the VirtFusion control panel server
- **Root SSH access** (key-based, no password) from the VFCP server to all hypervisors
- The following tools available on each hypervisor: `virsh`, `qemu-img`, `rsync`

The script is designed to run on the **VirtFusion control panel server** where the MariaDB database is locally accessible. It connects to hypervisors over SSH to perform the actual disk operations.

## Quick Start

Run the setup wizard on your VirtFusion control panel server:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/EZSCALE/vf-scripts/main/vf-storage-migrate.sh) --setup
```

The wizard will auto-discover your VirtFusion database, list all hypervisors and storage backends, and walk you through selecting source and destination storage. Once complete, preview your migration:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/EZSCALE/vf-scripts/main/vf-storage-migrate.sh) --all --dry-run
```

## One-Liner Commands

Every operation can be run directly from GitHub without installing anything. Each command pulls the latest version automatically.

```bash
# Setup wizard (run first)
bash <(curl -fsSL https://raw.githubusercontent.com/EZSCALE/vf-scripts/main/vf-storage-migrate.sh) --setup

# Preview all migrations (dry run)
bash <(curl -fsSL https://raw.githubusercontent.com/EZSCALE/vf-scripts/main/vf-storage-migrate.sh) --all --dry-run

# Migrate all VMs (with confirmations per VM)
bash <(curl -fsSL https://raw.githubusercontent.com/EZSCALE/vf-scripts/main/vf-storage-migrate.sh) --all

# Migrate all VMs without prompts
bash <(curl -fsSL https://raw.githubusercontent.com/EZSCALE/vf-scripts/main/vf-storage-migrate.sh) --all --yes

# Migrate a single VM
bash <(curl -fsSL https://raw.githubusercontent.com/EZSCALE/vf-scripts/main/vf-storage-migrate.sh) <uuid>

# Rollback a migration
bash <(curl -fsSL https://raw.githubusercontent.com/EZSCALE/vf-scripts/main/vf-storage-migrate.sh) --rollback <uuid>

# Verify all migrated VMs are healthy
bash <(curl -fsSL https://raw.githubusercontent.com/EZSCALE/vf-scripts/main/vf-storage-migrate.sh) --verify

# View migration report
bash <(curl -fsSL https://raw.githubusercontent.com/EZSCALE/vf-scripts/main/vf-storage-migrate.sh) --report

# Clean up old source images
bash <(curl -fsSL https://raw.githubusercontent.com/EZSCALE/vf-scripts/main/vf-storage-migrate.sh) --cleanup
```

## Installation

For frequent use, install the script permanently to avoid re-downloading each time:

```bash
curl -fsSL https://raw.githubusercontent.com/EZSCALE/vf-scripts/main/vf-storage-migrate.sh \
  -o /usr/local/bin/vf-storage-migrate && chmod +x /usr/local/bin/vf-storage-migrate
```

Then use the shorter command name:

```bash
vf-storage-migrate --setup
vf-storage-migrate --all --dry-run
vf-storage-migrate <uuid>
```

## Usage

```
vf-storage-migrate.sh [command] [options]

Commands:
  --setup                Interactive setup wizard (run first)
  <uuid>                 Migrate single VM by UUID
  --all                  Migrate all VMs on source storage
  --rollback <uuid>      Revert a migrated VM to original storage
  --verify               Check all migrated VMs are healthy
  --report               Show migration summary with compression stats
  --cleanup              List/remove old source disk images

Options:
  --yes, -y              Skip confirmation prompts (except suspend)
  --dry-run              Show what would happen without doing anything
  --no-color             Disable colored output
  --keep-qcow2           Override config: don't convert format
  --hypervisor=<id>      Filter batch to specific hypervisor
  --parallel=N           Run N migrations concurrently (default: 1)
  --config=<path>        Use alternate config file
  --log=<path>           Use alternate log file
  --version              Show version
  --help, -h             Show this help
```

### Examples

```bash
# First-time setup
./vf-storage-migrate.sh --setup

# Preview what would happen
./vf-storage-migrate.sh --all --dry-run

# Migrate all VMs (with per-VM confirmation)
./vf-storage-migrate.sh --all

# Migrate all VMs on hypervisor 9 without prompts
./vf-storage-migrate.sh --all --yes --hypervisor=9

# Migrate a single VM
./vf-storage-migrate.sh a1b2c3d4-e5f6-7890-abcd-ef1234567890

# Run 2 migrations in parallel (requires --yes)
./vf-storage-migrate.sh --all --parallel=2 --yes

# Rollback a migration
./vf-storage-migrate.sh --rollback a1b2c3d4-e5f6-7890-abcd-ef1234567890

# Verify and report
./vf-storage-migrate.sh --verify
./vf-storage-migrate.sh --report

# Clean up source images from completed migrations
./vf-storage-migrate.sh --cleanup
```

## Setup Wizard Walkthrough

Run `--setup` before your first migration. The wizard has six steps:

### Step 1: VirtFusion Detection

The wizard locates your VirtFusion installation at `/opt/virtfusion/app/control/.env`, extracts database credentials, and validates connectivity. If VirtFusion is installed in a non-standard location, the wizard will prompt you.

### Step 2: Storage Backend Discovery

All storage backends configured in VirtFusion are listed with their IDs, names, types, and paths. You select the **source storage** -- the one you want to migrate VMs away from.

```
Available storage backends:
  ID  Name                Type       Path
  1   Shared NFS          storage    /mnt/vms
  2   Local ZFS           storage    /tank/vms
  3   NFS-to-ZFS Bridge   storage    /mnt/zfs-nfs

Select SOURCE storage ID to migrate FROM: 1
```

### Step 3: Per-Hypervisor Destination Mapping

The wizard shows all hypervisors that have VMs on the source storage, then asks you to pick a destination storage for each one. This allows different hypervisors to use different destination paths (for example, one hypervisor might use local ZFS while another uses a remote NFS mount to that same ZFS pool).

For each hypervisor, the wizard also validates SSH connectivity and confirms the destination path is accessible.

### Step 4: Format Conversion

Choose how disk images should be converted during migration:

| Option | Best For | Notes |
|--------|----------|-------|
| **raw** | ZFS destinations | Eliminates double copy-on-write overhead. Recommended for ZFS. |
| **qcow2** | Non-ZFS destinations | Retains thin provisioning and snapshot capabilities. |
| **preserve** | Mixed environments | Keeps whatever format each disk currently uses. |

### Step 5: Network Speed Tuning

Select the link speed between your hypervisors and storage to auto-tune blockcopy buffer sizes and poll intervals:

| Link Speed | Buffer Size | Recommended Parallel |
|------------|-------------|---------------------|
| 1 Gbps     | 16 MB       | 1                   |
| 10 Gbps    | 128 MB      | 1                   |
| 25 Gbps    | 256 MB      | 2                   |
| 40 Gbps    | 512 MB      | 2                   |
| 100 Gbps   | 1 GB        | 4                   |

### Step 6: Pre-flight Validation

The wizard runs comprehensive checks before saving your config:

- SSH connectivity to every hypervisor
- `virsh`, `qemu-img`, and `rsync` available on each hypervisor
- Source and destination paths accessible on each hypervisor
- Configuration saved to `~/.vf-storage-migrate.conf`

## How It Works

The migration strategy depends on the VM's current state:

### Running VMs (zero downtime)

1. **Start blockcopy** -- `virsh blockcopy` begins copying the disk to the destination in the background while the VM continues running. All guest writes are mirrored to both source and destination.
2. **Poll progress** -- The script polls `virsh blockjob --info` every 10 seconds, displaying percentage complete and an ETA.
3. **Handle lock contention** -- If libvirt reports lock contention during polling, the script retries the poll (this is normal during heavy I/O).
4. **Pivot at 100%** -- Once the copy is fully synchronized, the script issues `virsh blockjob --pivot` which atomically switches the VM to the new disk. The VM never stops. Pivot is retried up to 10 times to handle transient lock contention.
5. **Verify** -- The script confirms the VM's active disk path now points to the destination.

### Shut-off VMs

Uses `qemu-img convert` to copy (and optionally convert) the disk image. No blockcopy needed since no QEMU process is running.

### Undefined/Orphaned VMs

For VMs that exist as disk files but have no libvirt domain (destroyed in VirtFusion but files remain), the script uses `rsync` to copy the files directly.

### After Disk Copy (all methods)

6. **Update persistent XML** -- The VirtFusion server XML (`/home/vf-data/server/<uuid>/server.xml`) is updated with the new disk path and format so the VM boots from the correct location on next restart.
7. **Update VirtFusion database** -- The `server_disks` and `server_disks_storage` tables are updated so VirtFusion knows the disk's new storage location. This ensures VirtFusion's panel, API, and any future operations reference the correct storage.
8. **Record migration state** -- Migration metadata (source/dest paths, sizes, timestamps) is saved locally for verification, reporting, and rollback.

### Retry Logic

If blockcopy fails on the first attempt:

1. The script retries with `--reuse-external`, which picks up from where the previous copy left off instead of starting over.
2. If the retry also fails, the script offers to **suspend the VM** (pause it) and retry. This is the only time the VM experiences downtime, and it only happens interactively with your explicit approval. The script will never auto-suspend.
3. If all retries fail, the VM is left in its original state and the next VM in the batch continues.

## Configuration

The setup wizard generates `~/.vf-storage-migrate.conf`. You can also edit it manually.

```bash
# vf-storage-migrate configuration
# Generated by: vf-storage-migrate.sh --setup

# Source storage (what we're migrating FROM)
SRC_STORAGE_ID=1
SRC_STORAGE_NAME="Shared NFS"

# Destination format (raw, qcow2, preserve)
DEST_FORMAT="raw"

# Per-hypervisor destination mapping
# Format: HV_<id>_DST_STORAGE_ID, HV_<id>_DST_HV_STORAGE_ID, HV_<id>_DST_PATH
HV_1_NAME="hv-node-01"
HV_1_IP="10.0.0.11"
HV_1_DST_STORAGE_ID=2
HV_1_DST_HV_STORAGE_ID=5
HV_1_DST_PATH="/tank/vms"

HV_2_NAME="hv-node-02"
HV_2_IP="10.0.0.12"
HV_2_DST_STORAGE_ID=3
HV_2_DST_HV_STORAGE_ID=6
HV_2_DST_PATH="/mnt/zfs-nfs"

# Network & Tuning
LINK_SPEED_GBPS=10
BLOCKCOPY_TIMEOUT=10800
BLOCKCOPY_BUF_SIZE=134217728
MAX_RETRIES=2
POLL_INTERVAL=10
```

### Configuration Options

| Option | Default | Description |
|--------|---------|-------------|
| `SRC_STORAGE_ID` | -- | VirtFusion storage ID to migrate FROM |
| `DEST_FORMAT` | `raw` | Target format: `raw`, `qcow2`, or `preserve` |
| `HV_<id>_DST_STORAGE_ID` | -- | Destination VirtFusion storage ID for this hypervisor |
| `HV_<id>_DST_HV_STORAGE_ID` | -- | Destination hypervisor_storage ID (VF join table) |
| `HV_<id>_DST_PATH` | -- | Filesystem path on the hypervisor for destination storage |
| `HV_<id>_IP` | -- | SSH IP address for the hypervisor |
| `BLOCKCOPY_TIMEOUT` | `10800` | Maximum seconds for a single disk blockcopy (3 hours) |
| `BLOCKCOPY_BUF_SIZE` | `134217728` | Blockcopy buffer size in bytes (128 MB for 10G) |
| `MAX_RETRIES` | `2` | Number of retry attempts per disk |
| `POLL_INTERVAL` | `10` | Seconds between blockjob progress polls |
| `LINK_SPEED_GBPS` | `10` | Network speed for auto-tuning (informational) |

### Using an Alternate Config File

```bash
./vf-storage-migrate.sh --config=/path/to/other.conf --all --dry-run
```

## Common Scenarios

### NFS to ZFS (Recommended: raw format)

The most common migration. Moving from shared NFS storage to local or remote ZFS pools. Use `raw` format to avoid double copy-on-write (qcow2 CoW on top of ZFS CoW wastes CPU and IOPS).

```bash
# Setup: select NFS as source, ZFS pool as destination, raw format
./vf-storage-migrate.sh --setup

# Preview
./vf-storage-migrate.sh --all --dry-run

# Migrate one hypervisor at a time
./vf-storage-migrate.sh --all --yes --hypervisor=9
./vf-storage-migrate.sh --all --yes --hypervisor=8

# Verify everything is healthy
./vf-storage-migrate.sh --verify

# Clean up old NFS images
./vf-storage-migrate.sh --cleanup
```

### Local Storage to NFS (Recommended: qcow2 format)

Centralizing scattered local disks onto shared NFS storage. Use `qcow2` to retain thin provisioning over NFS.

```bash
# Setup: select local storage as source, NFS as destination, qcow2 format
./vf-storage-migrate.sh --setup

# Migrate all
./vf-storage-migrate.sh --all --yes
```

### Storage Restructuring (Same Backend Type)

Reorganizing paths within the same storage type -- for example, moving VMs from one ZFS dataset to another, or consolidating multiple NFS mounts.

```bash
# Setup: select old storage ID as source, new storage ID as destination, preserve format
./vf-storage-migrate.sh --setup

# Migrate
./vf-storage-migrate.sh --all --yes
```

### Migrating a Single Problem VM

If a specific VM has I/O issues on its current storage:

```bash
# Get the VM UUID from VirtFusion panel or database
./vf-storage-migrate.sh a1b2c3d4-e5f6-7890-abcd-ef1234567890

# If something goes wrong, roll it back
./vf-storage-migrate.sh --rollback a1b2c3d4-e5f6-7890-abcd-ef1234567890
```

### Large Batch with Parallel Migrations

For large fleets where sequential migration would take too long. Parallel mode requires `--yes` since interactive prompts are disabled.

```bash
# Run 2 concurrent migrations
./vf-storage-migrate.sh --all --parallel=2 --yes

# Run 4 concurrent migrations (only on fast storage links)
./vf-storage-migrate.sh --all --parallel=4 --yes
```

**Note:** Parallel migrations share the same storage bandwidth. Start with `--parallel=2` and monitor I/O before increasing. High parallelism on slower links can degrade guest VM performance.

## Troubleshooting

### "Another migration is already running"

The script uses a lock file at `/var/run/vf-storage-migrate.lock` to prevent concurrent runs. If a previous run was killed unexpectedly:

```bash
rm -f /var/run/vf-storage-migrate.lock
```

### "blockcopy did not start"

Common causes:

- **Active blockjob from a previous run** -- The script tries to abort lingering jobs automatically. If it persists, manually abort: `ssh <hypervisor> "virsh blockjob <uuid> <target> --abort"`
- **Destination path does not exist** -- Ensure the destination directory exists and is writable on the hypervisor.
- **QEMU version mismatch** -- Some older QEMU versions have blockcopy limitations. Check `qemu-img --version` on the hypervisor.

### "Pivot failed after 10 attempts"

This usually means heavy I/O on the VM is preventing the copy from fully synchronizing. The script will offer to suspend the VM so the copy can complete. If you decline, the blockjob is aborted and the VM stays on the original storage.

### "Not enough space"

The script checks destination free space before each VM. If you see this error, free space on the destination or migrate VMs in smaller batches using `--hypervisor=<id>`.

### "SSH connection refused" or "Permission denied"

The script requires passwordless root SSH from the VFCP server to all hypervisors. Verify:

```bash
ssh root@<hypervisor-ip> "hostname"
```

If this fails, set up SSH key authentication:

```bash
ssh-copy-id root@<hypervisor-ip>
```

### "Table 'X' not found" during schema validation

The VirtFusion database schema does not match what the script expects. This could mean:

- VirtFusion is not fully installed
- The database name is incorrect (check `DB_DATABASE` in VirtFusion's `.env`)
- A VirtFusion update changed the schema (please open an issue)

### VM shows wrong storage in VirtFusion panel after migration

Run `--verify` to check if the database was updated correctly:

```bash
./vf-storage-migrate.sh --verify
```

If verification shows a DB mismatch, you may need to manually update the `server_disks_storage` table or roll back and re-migrate.

### Migrated VM fails to boot after hypervisor reboot

The persistent XML may not have been updated. Check `/home/vf-data/server/<uuid>/server.xml` on the hypervisor and verify the disk source paths point to the new location. If not, roll back and re-migrate:

```bash
./vf-storage-migrate.sh --rollback <uuid>
./vf-storage-migrate.sh <uuid>
```

## Safety

### What the script modifies

- **Disk files** -- Copies (not moves) disk images to the destination path. Source files are left intact until you explicitly run `--cleanup`.
- **VirtFusion database** -- Updates `server_disks.hypervisor_storage_id` and `server_disks_storage.storage_id` to reflect the new storage backend.
- **VirtFusion server XML** -- Updates the persistent domain XML at `/home/vf-data/server/<uuid>/server.xml` with new disk paths and format.
- **Libvirt active config** -- The `virsh blockcopy --pivot` operation atomically switches the running VM's disk path.
- **Log file** -- Writes to `/var/log/vf-storage-migrate.log`.
- **State files** -- Saves migration metadata to `/var/lib/vf-storage-migrate/` for verification, reporting, and rollback.
- **Rollback data** -- Saves original XML and config to `/var/lib/vf-migrate-rollback/<uuid>/` on each hypervisor.

### What the script does NOT modify

- **VM memory, CPU, or network configuration** -- Only disk paths are changed.
- **VirtFusion application code or settings** -- Only the database records related to disk storage are updated.
- **Source disk files** -- Never deleted automatically. Only `--cleanup` removes them, and only after confirmation.
- **Other VMs** -- Each migration is fully isolated. A failure on one VM does not affect others.

### Rollback

Every migration can be fully reverted with `--rollback <uuid>`:

1. If the VM is running, a reverse blockcopy moves the disk back to the original path.
2. If the VM is shut off, `qemu-img convert` copies the disk back.
3. The VirtFusion database is restored to the original storage IDs.
4. The persistent XML is restored from the backup taken before migration.
5. If the VM was suspended during migration, it is resumed.

Rollback data is stored on the hypervisor at `/var/lib/vf-migrate-rollback/<uuid>/` and is preserved until you manually remove it.

### Dry Run

Always preview with `--dry-run` before executing. It performs all the same lookups and validation but makes no changes:

```bash
./vf-storage-migrate.sh --all --dry-run
```

## Logging

All output is logged to `/var/log/vf-storage-migrate.log` with timestamps. Use an alternate log path:

```bash
./vf-storage-migrate.sh --all --log=/path/to/custom.log
```

## License

MIT License. Copyright (c) 2026 EZSCALE Hosting, LLC.

See [LICENSE](LICENSE) for the full text.

## Contributing

Contributions are welcome. This tool is maintained by [EZSCALE](https://github.com/EZSCALE) and used in production.

### How to contribute

1. Fork the repository at [github.com/EZSCALE/vf-scripts](https://github.com/EZSCALE/vf-scripts)
2. Create a feature branch (`git checkout -b my-feature`)
3. Make your changes to `vf-storage-migrate.sh`
4. Test with `--dry-run` against a VirtFusion installation
5. Submit a pull request with a clear description of what the change does and why

### Guidelines

- Keep the script as a single self-contained file (no external dependencies beyond standard Linux tools)
- Maintain backward compatibility with existing config files
- Test both the live (blockcopy) and offline (qemu-img) code paths
- Use `shellcheck` to validate -- the script should pass with no warnings
- Update the version number in the script header for any functional changes

### Reporting Issues

Open an issue at [github.com/EZSCALE/vf-scripts/issues](https://github.com/EZSCALE/vf-scripts/issues) with:

- Your VirtFusion version
- The full command you ran
- The relevant section of `/var/log/vf-storage-migrate.log`
- Your hypervisor OS and QEMU/libvirt versions
