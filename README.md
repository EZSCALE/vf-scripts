# vf-scripts

Community tools for [VirtFusion](https://virtfusion.com) hosting providers.

**License:** MIT | **Maintained by:** [EZSCALE](https://github.com/EZSCALE)

---

## Tools

### vf-storage-migrate.sh

**Version 1.1.0**

Zero-downtime VM disk migration between any VirtFusion storage backends. Migrate disk images between NFS, ZFS, local storage, or any combination -- without powering off running VMs. Uses `virsh blockcopy` for live migration with automatic polling, pivot, and retry logic. Battle-tested across 60+ production VM migrations.

Supports both VirtFusion storage types:
- **Datastores** (`type=storage`) -- storage backends linked through VirtFusion's storage table
- **Mountpoints** (`type=mountpoint`) -- local/NFS mount paths configured directly on hypervisor_storage

#### Features

- **Zero downtime** -- live `virsh blockcopy` + pivot for running VMs (no guest restart required)
- **Any storage to any storage** -- NFS, ZFS, local, or any libvirt-compatible backend
- **Datastore and mountpoint support** -- works with both VirtFusion storage configuration types
- **Format conversion** -- convert between qcow2 and raw during migration, or preserve the original format
- **Interactive setup wizard** -- auto-discovers VirtFusion database, hypervisors, and storage backends
- **Per-hypervisor destination mapping** -- different destination storage per hypervisor
- **Network speed auto-tuning** -- automatically sizes blockcopy buffers for 1G/10G/25G/40G/100G links
- **Batch mode** -- migrate all VMs on a storage backend in one command, sorted smallest-first, with ETA tracking
- **Hypervisor filtering** -- migrate VMs on a single hypervisor with `--hypervisor=<id>`
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
- **VirtFusion DB updates** -- correctly updates `server_disks`, `server_disks_storage`, and `hypervisor_storage` records for both storage types
- **Persistent XML updates** -- updates VirtFusion's `server.xml` so VMs survive reboots on the new storage
- **Color output with TTY auto-detection** -- clean output when piped, colored when interactive
- **Concurrent run protection** -- flock-based locking prevents two migrations from running simultaneously
- **Single self-contained script** -- no dependencies beyond standard Linux tools

#### Requirements

- **VirtFusion** control panel (any version -- the script validates the DB schema at runtime)
- **Bash 4.0+** (for associative arrays)
- **mariadb** or **mysql** CLI client on the VirtFusion control panel server
- **Root SSH access** (key-based, no password) from the VFCP server to all hypervisors
- The following tools available on each hypervisor: `virsh`, `qemu-img`, `rsync`

The script is designed to run on the **VirtFusion control panel server** where the MariaDB database is locally accessible. It connects to hypervisors over SSH to perform the actual disk operations.

#### Quick Start

```bash
# Run setup wizard
bash <(curl -fsSL https://raw.githubusercontent.com/EZSCALE/vf-scripts/main/vf-storage-migrate.sh) --setup

# Preview migrations
bash <(curl -fsSL https://raw.githubusercontent.com/EZSCALE/vf-scripts/main/vf-storage-migrate.sh) --all --dry-run
```

#### Installation

```bash
curl -fsSL https://raw.githubusercontent.com/EZSCALE/vf-scripts/main/vf-storage-migrate.sh \
  -o /usr/local/bin/vf-storage-migrate && chmod +x /usr/local/bin/vf-storage-migrate
```

#### Usage

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

#### Examples

```bash
# First-time setup
./vf-storage-migrate.sh --setup

# Preview what would happen
./vf-storage-migrate.sh --all --dry-run

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

#### Storage Type Selection

During setup, the wizard shows both datastores and mountpoints with prefixed IDs:

```
Available storage backends:
  ID     Name                           Path                           Type         VMs
  S7     R720XD_NFS                     /mnt/vms                       datastore    35
  S10    ATL-01 ZFS                     /tank/vms                      datastore    0
  M28    Local ZFS v2                   /tank/vms                      mountpoint   39
  M29    Local ZFS NFS v2               /mnt/atl01-zfs                 mountpoint   26

Select SOURCE storage ID to migrate FROM (e.g. S7 for datastore, M28 for mountpoint): M28
```

Use `S<id>` to select a datastore or `M<id>` to select a mountpoint. The same notation applies when selecting destinations.

**Important:** When migrating to a mountpoint destination, the script automatically sets `disk_storage_id=NULL` in VirtFusion's database. This is required for VirtFusion to correctly manage disks on mountpoint storage (including OS reinstalls and disk creation).

#### How It Works

The migration strategy depends on the VM's current state:

**Running VMs (zero downtime):**
1. `virsh blockcopy` begins copying the disk to the destination while the VM continues running
2. Progress is polled every 5 seconds with percentage and ETA display
3. At 100%, `virsh blockjob --pivot` atomically switches the VM to the new disk
4. The script verifies the VM's active disk path points to the destination

**Shut-off VMs:** Uses `qemu-img convert` to copy and optionally convert the disk image.

**Undefined/Orphaned VMs:** Uses `rsync` to copy files directly.

**After disk copy (all methods):**
- Updates VirtFusion's persistent `server.xml` with new disk paths and format
- Updates VirtFusion database (`server_disks`, `server_disks_storage`) for the new storage
- Records migration state for verification, reporting, and rollback

#### Configuration

The setup wizard generates `~/.vf-storage-migrate.conf`:

```bash
# Source storage
SRC_STORAGE_ID=           # Set for datastores (S-type)
SRC_HV_STORAGE_ID=28      # Set for mountpoints (M-type)
SRC_IS_MOUNTPOINT=true
SRC_STORAGE_NAME="Local ZFS v2"
SRC_PATH="/tank/vms"

# Destination format (raw, qcow2, preserve)
DEST_FORMAT="raw"

# Per-hypervisor destination mapping
HV_9_NAME="atl-01"
HV_9_IP="66.186.37.253"
HV_9_DST_STORAGE_ID=
HV_9_DST_HV_STORAGE_ID=28
HV_9_DST_PATH="/tank/vms"
HV_9_DST_IS_MOUNTPOINT=true

# Network & Tuning
BLOCKCOPY_TIMEOUT=43200    # 12 hours
BLOCKCOPY_BUF_SIZE=134217728  # 128 MB (10G link)
MAX_RETRIES=2
POLL_INTERVAL=5
```

| Option | Default | Description |
|--------|---------|-------------|
| `SRC_STORAGE_ID` | -- | VirtFusion storage ID (datastores only) |
| `SRC_HV_STORAGE_ID` | -- | VirtFusion hypervisor_storage ID (mountpoints only) |
| `SRC_IS_MOUNTPOINT` | `false` | Whether source is a mountpoint type |
| `DEST_FORMAT` | `raw` | Target format: `raw`, `qcow2`, or `preserve` |
| `HV_<id>_DST_HV_STORAGE_ID` | -- | Destination hypervisor_storage ID |
| `HV_<id>_DST_PATH` | -- | Filesystem path on the hypervisor |
| `HV_<id>_DST_IS_MOUNTPOINT` | `false` | Whether destination is a mountpoint type |
| `BLOCKCOPY_TIMEOUT` | `43200` | Maximum seconds for a single disk blockcopy (12 hours) |
| `BLOCKCOPY_BUF_SIZE` | `134217728` | Blockcopy buffer size in bytes (128 MB for 10G) |
| `MAX_RETRIES` | `2` | Number of retry attempts per disk |
| `POLL_INTERVAL` | `5` | Seconds between blockjob progress polls |

#### Common Scenarios

**NFS to ZFS (raw format recommended):**
```bash
./vf-storage-migrate.sh --setup    # Select NFS source, ZFS mountpoint destination, raw format
./vf-storage-migrate.sh --all --dry-run
./vf-storage-migrate.sh --all --yes --hypervisor=9
./vf-storage-migrate.sh --verify
./vf-storage-migrate.sh --cleanup
```

**ZFS to ZFS (cross-node migration):**
```bash
./vf-storage-migrate.sh --setup    # Select local ZFS mountpoint as source, remote NFS-backed ZFS as dest
./vf-storage-migrate.sh --all --yes --hypervisor=8
```

**Local storage to NFS (qcow2 format recommended):**
```bash
./vf-storage-migrate.sh --setup    # Select local source, NFS destination, qcow2 format
./vf-storage-migrate.sh --all --yes
```

#### Safety

**What the script modifies:**
- Disk files -- copies (not moves) to destination. Source files left intact until `--cleanup`.
- VirtFusion database -- updates `server_disks.hypervisor_storage_id`, `server_disks.disk_storage_id`, and `server_disks_storage.storage_id`
- VirtFusion server XML -- updates persistent disk paths and format
- Libvirt active config -- `virsh blockcopy --pivot` atomically switches running VMs

**What it does NOT modify:**
- VM memory, CPU, or network configuration
- VirtFusion application code or settings
- Source disk files (never deleted automatically)
- Other VMs (each migration is fully isolated)

**Rollback:** Every migration can be fully reverted with `--rollback <uuid>`.

**Dry run:** Always preview with `--dry-run` before executing.

#### Troubleshooting

| Problem | Solution |
|---------|----------|
| "Another migration is already running" | `rm -f /var/run/vf-storage-migrate.lock` |
| "blockcopy did not start" | Check for lingering blockjobs: `virsh blockjob <uuid> <target> --abort` |
| "Pivot failed after 10 attempts" | Heavy I/O preventing sync -- script will offer to suspend VM |
| "Not enough space" | Free space on destination or use `--hypervisor=<id>` for smaller batches |
| "SSH connection refused" | Set up key auth: `ssh-copy-id root@<hypervisor-ip>` |
| "Failed to install operating system" after migration | Disk type in VF DB may need `disk_storage_id=NULL` for mountpoint storage -- re-run migration or update manually |
| VM shows wrong storage in panel | Run `--verify` to check DB consistency |

---

## Contributing

Contributions welcome. This tool is maintained by [EZSCALE](https://github.com/EZSCALE) and used in production.

1. Fork at [github.com/EZSCALE/vf-scripts](https://github.com/EZSCALE/vf-scripts)
2. Create a feature branch
3. Test with `--dry-run` against a VirtFusion installation
4. Submit a PR with a clear description

**Guidelines:**
- Keep scripts as single self-contained files
- Maintain backward compatibility with existing config files
- Use `shellcheck` to validate
- Update version numbers for functional changes

## License

MIT License. Copyright (c) 2026 EZSCALE Hosting, LLC. See [LICENSE](LICENSE).
