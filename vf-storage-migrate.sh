#!/usr/bin/env bash
#
# vf-storage-migrate.sh — VirtFusion Storage Migration Tool
# https://github.com/EZSCALE/vf-scripts
#
# VERSION: 1.0.0
#
# Live-migrates VM disk images between VirtFusion storage backends using
# virsh blockcopy for zero-downtime migration of running VMs. Supports any
# storage-to-storage migration (NFS->ZFS, local->NFS, NFS->local, etc.).
#
# Designed to run from the VirtFusion control panel server where the MariaDB
# database is accessible locally. Hypervisors are accessed via SSH.
#
# Features:
#   - Zero downtime via virsh blockcopy + pivot (running VMs)
#   - Offline qemu-img convert for shut-off VMs
#   - rsync fallback for undefined VMs with orphaned disk files
#   - Format conversion (qcow2->raw, raw->qcow2, or preserve)
#   - Interactive setup wizard auto-discovers hypervisors and storage
#   - Per-hypervisor destination storage mapping
#   - Network speed auto-tuning (1G/10G/25G/40G/100G)
#   - Retry with --reuse-external on failure
#   - Interactive suspend prompt after first failure
#   - Full rollback support (blockcopy back + DB + XML restore)
#   - Batch mode with ETA and progress tracking
#   - Optional parallel migrations (--parallel=N)
#   - Post-migration verify and reporting
#   - Cleanup mode to remove old source images
#   - SIGINT/SIGTERM safe — aborts active blockjobs, resumes suspended VMs
#
# Requirements:
#   - Bash 4.0+
#   - VirtFusion control panel server (local mariadb access)
#   - Root SSH access to all hypervisors (key-based, no password)
#   - virsh, qemu-img, rsync available on hypervisors
#   - mariadb (or mysql) client on this server
#
# Usage:
#   ./vf-storage-migrate.sh --setup                   # First-time setup wizard
#   ./vf-storage-migrate.sh <uuid>                    # Migrate single VM
#   ./vf-storage-migrate.sh --all                     # Migrate all VMs on source storage
#   ./vf-storage-migrate.sh --all --dry-run           # Preview batch migration
#   ./vf-storage-migrate.sh --all --yes               # Batch without confirmations
#   ./vf-storage-migrate.sh --all --hypervisor=9      # Batch for one hypervisor
#   ./vf-storage-migrate.sh --all --parallel=2 --yes  # Parallel batch
#   ./vf-storage-migrate.sh --rollback <uuid>         # Revert migrated VM
#   ./vf-storage-migrate.sh --verify                  # Check all migrated VMs
#   ./vf-storage-migrate.sh --report                  # Migration summary
#   ./vf-storage-migrate.sh --cleanup                 # List/remove old source images
#
# Configuration:
#   Run --setup first. Config saved to ~/.vf-storage-migrate.conf
#   Override with --config=<path>
#
# License: MIT (see LICENSE file)
#
# Copyright (c) 2026 EZSCALE Hosting
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
#

set -euo pipefail

VERSION="1.0.0"

# =====================================================================
# Color & Output Setup
# =====================================================================

# Auto-detect TTY — disable colors when piped or redirected
if [ -t 1 ] && [ -t 2 ]; then
    USE_COLOR=true
else
    USE_COLOR=false
fi

# Color codes — set to empty strings if colors are disabled
setup_colors() {
    if $USE_COLOR; then
        RED='\033[0;31m'
        GREEN='\033[0;32m'
        YELLOW='\033[1;33m'
        CYAN='\033[0;36m'
        BOLD='\033[1m'
        DIM='\033[2m'
        NC='\033[0m'
    else
        RED=''
        GREEN=''
        YELLOW=''
        CYAN=''
        BOLD=''
        DIM=''
        NC=''
    fi
}
setup_colors

# =====================================================================
# Logging — dual output to console and log file
# =====================================================================

LOG_FILE="/var/log/vf-storage-migrate.log"

# Strip ANSI escape codes for log file output
strip_ansi() {
    sed 's/\x1b\[[0-9;]*m//g'
}

_log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo -e "$msg"
    echo -e "$msg" | strip_ansi >> "$LOG_FILE" 2>/dev/null || true
}

log()  { _log "${GREEN}$*${NC}"; }
warn() { _log "${YELLOW}WARN: $*${NC}"; }
err()  { _log "${RED}ERROR: $*${NC}"; }
info() { _log "${CYAN}$*${NC}"; }
dim()  { _log "${DIM}$*${NC}"; }

# Confirmation prompt — respects AUTO_YES but never auto-confirms suspend
confirm() {
    if ${AUTO_YES:-false}; then return 0; fi
    echo -en "${YELLOW}$1 [y/N]: ${NC}"
    read -r response
    [[ "$response" =~ ^[Yy]$ ]] || { echo "Skipped."; return 1; }
}

# =====================================================================
# Defaults — overridden by config and CLI flags
# =====================================================================

# VirtFusion .env location (standard install path)
VF_ENV_PATH="/opt/virtfusion/app/control/.env"

# Config file location
CONFIG_FILE="${HOME}/.vf-storage-migrate.conf"

# VirtFusion data directory (where server XMLs live)
VFDATA="/home/vf-data/server"

# Rollback data directory on hypervisors
ROLLBACK_DIR="/var/lib/vf-migrate-rollback"

# Migration state directory (local, on VFCP)
STATE_DIR="/var/lib/vf-storage-migrate"

# DB credentials (auto-discovered or from config)
DB_USER=""
DB_PASS=""
DB_HOST="127.0.0.1"
DB_NAME=""

# Source storage
SRC_STORAGE_ID=""
SRC_STORAGE_NAME=""

# Destination format
DEST_FORMAT="raw"

# Blockcopy tuning defaults
BLOCKCOPY_TIMEOUT=10800         # 3 hours
BLOCKCOPY_BUF_SIZE=134217728    # 128MB (tuned for 10G)
MAX_RETRIES=2
POLL_INTERVAL=10

# CLI flags
AUTO_YES=false
DRY_RUN=false
DO_ROLLBACK=false
DO_SETUP=false
DO_VERIFY=false
DO_REPORT=false
DO_CLEANUP=false
KEEP_QCOW2=false
BATCH_ALL=false
PARALLEL=1
FILTER_HV_ID=""
UUID=""
ROLLBACK_UUID=""

# Hypervisor arrays — populated from config
declare -A HV_NAMES=()          # HV_NAMES[id]=name
declare -A HV_IPS=()            # HV_IPS[id]=ip
declare -A HV_DST_STORAGE=()    # HV_DST_STORAGE[id]=storage_id
declare -A HV_DST_HV_STORAGE=() # HV_DST_HV_STORAGE[id]=hv_storage_id
declare -A HV_DST_PATHS=()      # HV_DST_PATHS[id]=path
declare -a HV_IDS=()            # Ordered list of configured hypervisor IDs

# Interrupt tracking — for safe cleanup on SIGINT/SIGTERM
CURRENT_MIGRATE_UUID=""
CURRENT_MIGRATE_HV=""
CURRENT_MIGRATE_TARGETS=()
CURRENT_MIGRATE_SUSPENDED=false

# =====================================================================
# CLI Argument Parsing
# =====================================================================

show_help() {
    cat <<'HELPEOF'
vf-storage-migrate.sh — VirtFusion Storage Migration Tool

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

Examples:
  # First-time setup
  ./vf-storage-migrate.sh --setup

  # Preview what would happen
  ./vf-storage-migrate.sh --all --dry-run

  # Migrate all VMs (with confirmations)
  ./vf-storage-migrate.sh --all

  # Migrate all VMs on hypervisor 9 without prompts
  ./vf-storage-migrate.sh --all --yes --hypervisor=9

  # Migrate a single VM
  ./vf-storage-migrate.sh a1b2c3d4-e5f6-7890-abcd-ef1234567890

  # Rollback a migration
  ./vf-storage-migrate.sh --rollback a1b2c3d4-e5f6-7890-abcd-ef1234567890

  # Verify and report
  ./vf-storage-migrate.sh --verify
  ./vf-storage-migrate.sh --report
HELPEOF
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --setup)        DO_SETUP=true ;;
            --yes|-y)       AUTO_YES=true ;;
            --dry-run)      DRY_RUN=true ;;
            --rollback)
                DO_ROLLBACK=true
                # Next arg is the UUID if present and not a flag
                if [ $# -gt 1 ] && [[ ! "$2" =~ ^-- ]]; then
                    ROLLBACK_UUID="$2"
                    shift
                fi
                ;;
            --keep-qcow2)   KEEP_QCOW2=true ;;
            --all)          BATCH_ALL=true ;;
            --verify)       DO_VERIFY=true ;;
            --report)       DO_REPORT=true ;;
            --cleanup)      DO_CLEANUP=true ;;
            --no-color)     USE_COLOR=false; setup_colors ;;
            --parallel=*)   PARALLEL="${1#*=}" ;;
            --hypervisor=*) FILTER_HV_ID="${1#*=}" ;;
            --config=*)     CONFIG_FILE="${1#*=}" ;;
            --log=*)        LOG_FILE="${1#*=}" ;;
            --version)      echo "vf-storage-migrate $VERSION"; exit 0 ;;
            --help|-h)      show_help; exit 0 ;;
            -*)             err "Unknown flag: $1"; echo "Use --help for usage."; exit 1 ;;
            *)
                # Positional argument — UUID
                if [ -z "$UUID" ]; then
                    UUID="$1"
                else
                    err "Unexpected argument: $1"
                    exit 1
                fi
                ;;
        esac
        shift
    done

    # --keep-qcow2 overrides config
    if $KEEP_QCOW2; then
        DEST_FORMAT="qcow2"
    fi

    # Validate --hypervisor is an integer if provided (prevents SQL injection)
    if [ -n "$FILTER_HV_ID" ] && ! [[ "$FILTER_HV_ID" =~ ^[0-9]+$ ]]; then
        err "--hypervisor must be a numeric hypervisor ID, got: $FILTER_HV_ID"
        exit 1
    fi

    # Validate --parallel is a positive integer
    if ! [[ "$PARALLEL" =~ ^[1-9][0-9]*$ ]]; then
        err "--parallel must be a positive integer, got: $PARALLEL"
        exit 1
    fi

    # Parallel mode requires --yes (no interactive prompts possible)
    if [ "$PARALLEL" -gt 1 ] && ! $AUTO_YES; then
        err "--parallel=N requires --yes (no interactive prompts in parallel mode)"
        exit 1
    fi
}

# =====================================================================
# VirtFusion DB Credential Discovery
# =====================================================================

# Auto-discover DB credentials from VirtFusion's .env file.
# Falls back to config file overrides if .env is not readable.
discover_db_credentials() {
    local env_file="${VF_ENV_PATH}"

    if [ -f "$env_file" ] && [ -r "$env_file" ]; then
        # Extract credentials from VirtFusion's Laravel .env
        DB_USER=$(grep -E '^DB_USERNAME=' "$env_file" | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'")
        DB_PASS=$(grep -E '^DB_PASSWORD=' "$env_file" | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'")
        DB_HOST=$(grep -E '^DB_HOST=' "$env_file" | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'")
        DB_NAME=$(grep -E '^DB_DATABASE=' "$env_file" | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'")

        # Default host to localhost if empty
        [ -z "$DB_HOST" ] && DB_HOST="127.0.0.1"
        return 0
    fi

    return 1
}

# =====================================================================
# Database Query Wrapper
# =====================================================================

# Execute a SQL query against the VirtFusion database.
# Returns tab-separated rows with no headers (-N).
# Uses local mariadb client — no SSH needed since we run on VFCP.
vfdb() {
    local query="$1"
    mariadb -u "$DB_USER" -p"$DB_PASS" -h "$DB_HOST" "$DB_NAME" -N -B -e "$query" 2>>"$LOG_FILE"
}

# Same as vfdb but suppresses all output — for schema validation
vfdb_quiet() {
    local query="$1"
    mariadb -u "$DB_USER" -p"$DB_PASS" -h "$DB_HOST" "$DB_NAME" -N -B -e "$query" &>/dev/null
}

# =====================================================================
# SSH Wrapper
# =====================================================================

# Execute a command on a hypervisor via SSH.
# Always uses -n to prevent stdin consumption in loops.
# Timeout of 30s for connectivity checks, no limit for migrations.
hv_ssh() {
    local ip="$1"
    shift
    ssh -n -o ConnectTimeout=10 -o BatchMode=yes "$ip" "$@"
}

# SSH with a custom timeout (for long-running operations)
hv_ssh_long() {
    local ip="$1"
    shift
    ssh -n -o ConnectTimeout=10 -o BatchMode=yes -o ServerAliveInterval=30 "$ip" "$@"
}

# =====================================================================
# UUID Validation
# =====================================================================

# Validate UUID format to prevent SQL injection.
# VirtFusion uses standard RFC 4122 UUIDs.
validate_uuid() {
    local uuid="$1"
    if ! [[ "$uuid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
        err "Invalid UUID format: $uuid"
        return 1
    fi
}

# =====================================================================
# Config File Management
# =====================================================================

# Load config file into environment variables and populate HV arrays.
load_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        return 1
    fi

    # Source the config file (bash env format)
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"

    # Populate hypervisor arrays from HV_*_* variables in config
    # Config format: HV_<id>_NAME, HV_<id>_IP, HV_<id>_DST_STORAGE_ID, etc.
    HV_IDS=()
    local var
    for var in $(compgen -v | grep -E '^HV_[0-9]+_NAME$' | sort -t_ -k2 -n); do
        local hv_id
        hv_id=$(echo "$var" | sed 's/HV_\([0-9]*\)_NAME/\1/')
        HV_IDS+=("$hv_id")

        local name_var="HV_${hv_id}_NAME"
        local ip_var="HV_${hv_id}_IP"
        local dst_storage_var="HV_${hv_id}_DST_STORAGE_ID"
        local dst_hv_storage_var="HV_${hv_id}_DST_HV_STORAGE_ID"
        local dst_path_var="HV_${hv_id}_DST_PATH"

        HV_NAMES[$hv_id]="${!name_var}"
        HV_IPS[$hv_id]="${!ip_var}"
        HV_DST_STORAGE[$hv_id]="${!dst_storage_var}"
        HV_DST_HV_STORAGE[$hv_id]="${!dst_hv_storage_var}"
        HV_DST_PATHS[$hv_id]="${!dst_path_var}"
    done

    return 0
}

# Save current configuration to config file.
save_config() {
    local config_path="$1"

    mkdir -p "$(dirname "$config_path")"

    cat > "$config_path" <<CONFIGEOF
# vf-storage-migrate configuration
# Generated by: vf-storage-migrate.sh --setup
# Date: $(date '+%Y-%m-%d %H:%M:%S')
# Version: $VERSION

# VirtFusion .env path (for DB credential auto-discovery)
# Uncomment to override:
# VF_ENV_PATH="/opt/virtfusion/app/control/.env"

# DB credential overrides (only needed if .env auto-discovery fails)
# DB_USER=""
# DB_PASS=""
# DB_HOST="127.0.0.1"
# DB_NAME=""

# VirtFusion data directory (where server XMLs live)
VFDATA="$VFDATA"

# Source storage (what we're migrating FROM)
SRC_STORAGE_ID=$SRC_STORAGE_ID
SRC_STORAGE_NAME="$SRC_STORAGE_NAME"

# Destination format (raw, qcow2, preserve)
DEST_FORMAT="$DEST_FORMAT"

# Per-hypervisor destination mapping
# Format: HV_<id>_NAME, HV_<id>_IP, HV_<id>_DST_STORAGE_ID, HV_<id>_DST_HV_STORAGE_ID, HV_<id>_DST_PATH
CONFIGEOF

    # Write each hypervisor's config block
    for hv_id in "${HV_IDS[@]}"; do
        cat >> "$config_path" <<HVEOF

HV_${hv_id}_NAME="${HV_NAMES[$hv_id]}"
HV_${hv_id}_IP="${HV_IPS[$hv_id]}"
HV_${hv_id}_DST_STORAGE_ID=${HV_DST_STORAGE[$hv_id]}
HV_${hv_id}_DST_HV_STORAGE_ID=${HV_DST_HV_STORAGE[$hv_id]}
HV_${hv_id}_DST_PATH="${HV_DST_PATHS[$hv_id]}"
HVEOF
    done

    # Write tuning section
    cat >> "$config_path" <<TUNEEOF

# Network & Tuning
BLOCKCOPY_TIMEOUT=$BLOCKCOPY_TIMEOUT
BLOCKCOPY_BUF_SIZE=$BLOCKCOPY_BUF_SIZE
MAX_RETRIES=$MAX_RETRIES
POLL_INTERVAL=$POLL_INTERVAL

# Buffer size reference (auto-tuned by link speed during setup):
#   1G  →  16 MB  (16777216)
#   10G → 128 MB  (134217728)
#   25G → 256 MB  (268435456)
#   40G → 512 MB  (536870912)
#  100G →   1 GB  (1073741824)
TUNEEOF

    log "Config saved to $config_path"
}

# =====================================================================
# Schema Validation
# =====================================================================

# Validate that the VirtFusion DB has the tables and columns we need.
# This makes the script version-agnostic — it checks structure, not version.
validate_schema() {
    local errors=0

    # Required tables
    for table in servers server_disks server_disks_storage storage hypervisor_storage; do
        if ! vfdb_quiet "SELECT 1 FROM $table LIMIT 1"; then
            err "Required table '$table' not found in database"
            ((errors++))
        fi
    done

    # Required columns on servers
    if ! vfdb_quiet "SELECT uuid, hypervisor_id, name FROM servers LIMIT 1"; then
        err "Missing columns on 'servers' table (need: uuid, hypervisor_id, name)"
        ((errors++))
    fi

    # Required columns on server_disks
    if ! vfdb_quiet "SELECT id, server_id, hypervisor_storage_id, disk_storage_id, type, deleted_at FROM server_disks LIMIT 1"; then
        err "Missing columns on 'server_disks' table (need: id, server_id, hypervisor_storage_id, disk_storage_id, type, deleted_at)"
        ((errors++))
    fi

    # Required columns on server_disks_storage
    if ! vfdb_quiet "SELECT id, storage_id FROM server_disks_storage LIMIT 1"; then
        err "Missing columns on 'server_disks_storage' table (need: id, storage_id)"
        ((errors++))
    fi

    # Required columns on storage
    if ! vfdb_quiet "SELECT id, name, path FROM storage LIMIT 1"; then
        err "Missing columns on 'storage' table (need: id, name, path)"
        ((errors++))
    fi

    # Required columns on hypervisor_storage
    if ! vfdb_quiet "SELECT id, hypervisor_id, storage_id FROM hypervisor_storage LIMIT 1"; then
        err "Missing columns on 'hypervisor_storage' table (need: id, hypervisor_id, storage_id)"
        ((errors++))
    fi

    return "$errors"
}

# =====================================================================
# Pre-flight Validation
# =====================================================================

# Run comprehensive checks before any migration.
preflight() {
    local errors=0

    info "Pre-flight validation..."

    # Check DB connectivity and schema
    if ! vfdb_quiet "SELECT 1"; then
        err "Cannot connect to VirtFusion database"
        return 1
    fi
    log "  [OK] Database connection"

    if ! validate_schema; then
        err "Schema validation failed — is this a supported VirtFusion version?"
        return 1
    fi
    log "  [OK] Schema validated"

    # Check each configured hypervisor
    for hv_id in "${HV_IDS[@]}"; do
        local hv_name="${HV_NAMES[$hv_id]}"
        local hv_ip="${HV_IPS[$hv_id]}"
        local dst_path="${HV_DST_PATHS[$hv_id]}"

        # SSH connectivity
        if ! hv_ssh "$hv_ip" "true" 2>/dev/null; then
            err "  [FAIL] SSH to $hv_name ($hv_ip)"
            ((errors++))
            continue
        fi
        log "  [OK] SSH to $hv_name ($hv_ip)"

        # Required tools
        for tool in virsh qemu-img rsync; do
            if ! hv_ssh "$hv_ip" "command -v $tool" &>/dev/null; then
                err "  [FAIL] $tool not found on $hv_name"
                ((errors++))
            else
                log "  [OK] $tool available on $hv_name"
            fi
        done

        # Source path accessible
        local src_path
        src_path=$(vfdb "SELECT path FROM storage WHERE id = $SRC_STORAGE_ID" | head -1)
        if [ -n "$src_path" ]; then
            if hv_ssh "$hv_ip" "test -d '$src_path'" 2>/dev/null; then
                log "  [OK] Source path $src_path accessible on $hv_name"
            else
                warn "  [WARN] Source path $src_path not accessible on $hv_name (may not have VMs here)"
            fi
        fi

        # Destination path accessible
        if hv_ssh "$hv_ip" "test -d '$dst_path'" 2>/dev/null; then
            log "  [OK] Dest path $dst_path accessible on $hv_name"
        else
            err "  [FAIL] Dest path $dst_path not accessible on $hv_name"
            ((errors++))
        fi
    done

    if [ "$errors" -gt 0 ]; then
        err "Pre-flight failed with $errors error(s)"
        return 1
    fi

    log "  Pre-flight passed"
    return 0
}

# =====================================================================
# Setup Wizard
# =====================================================================

do_setup() {
    echo -e "${BOLD}VirtFusion Storage Migration - Setup Wizard${NC}"
    echo -e "${BOLD}============================================${NC}"
    echo

    # --- Step 1: Check VirtFusion installation ---
    echo -e "${BOLD}[1/6] Checking VirtFusion installation...${NC}"

    # Try auto-discovery first
    if [ -f "$VF_ENV_PATH" ] && [ -r "$VF_ENV_PATH" ]; then
        info "  Found: $VF_ENV_PATH"
        discover_db_credentials
    else
        warn "  VirtFusion .env not found at $VF_ENV_PATH"
        echo -en "  Enter path to VirtFusion .env (or press Enter to enter credentials manually): "
        read -r custom_env_path
        if [ -n "$custom_env_path" ] && [ -f "$custom_env_path" ]; then
            VF_ENV_PATH="$custom_env_path"
            discover_db_credentials
        else
            echo -en "  DB username: "
            read -r DB_USER
            echo -en "  DB password: "
            read -rs DB_PASS
            echo
            echo -en "  DB host [127.0.0.1]: "
            read -r DB_HOST
            [ -z "$DB_HOST" ] && DB_HOST="127.0.0.1"
            echo -en "  DB name: "
            read -r DB_NAME
        fi
    fi

    # Test DB connection
    if ! vfdb_quiet "SELECT 1"; then
        err "  Cannot connect to database. Check credentials."
        exit 1
    fi
    info "  Database: connected ($DB_NAME)"

    # Validate schema
    if ! validate_schema; then
        err "  Schema validation failed."
        exit 1
    fi
    info "  Schema: validated"
    echo

    # --- Step 2: Show available storage backends ---
    echo -e "${BOLD}[2/6] Available storage backends:${NC}"

    local storage_list
    storage_list=$(vfdb "
        SELECT s.id, s.name, s.path,
               COUNT(DISTINCT sd.server_id) AS vm_count
        FROM storage s
        LEFT JOIN hypervisor_storage hs ON hs.storage_id = s.id
        LEFT JOIN server_disks sd ON sd.hypervisor_storage_id = hs.id AND sd.deleted_at IS NULL
        GROUP BY s.id, s.name, s.path
        ORDER BY s.id
    ")

    if [ -z "$storage_list" ]; then
        err "  No storage backends found in database."
        exit 1
    fi

    printf "  ${BOLD}%-4s %-30s %-40s %s${NC}\n" "ID" "Name" "Path" "VMs"
    while IFS=$'\t' read -r s_id s_name s_path s_vms; do
        [ -z "$s_id" ] && continue
        printf "  %-4s %-30s %-40s %s\n" "$s_id" "$s_name" "$s_path" "$s_vms"
    done <<< "$storage_list"
    echo

    echo -en "  Select ${BOLD}SOURCE${NC} storage ID to migrate FROM: "
    read -r SRC_STORAGE_ID

    # Validate input is an integer (prevents SQL injection)
    if ! [[ "$SRC_STORAGE_ID" =~ ^[0-9]+$ ]]; then
        err "  Invalid input — must be a numeric storage ID."
        exit 1
    fi

    # Validate source storage exists
    SRC_STORAGE_NAME=$(vfdb "SELECT name FROM storage WHERE id = $SRC_STORAGE_ID" | head -1)
    if [ -z "$SRC_STORAGE_NAME" ]; then
        err "  Storage ID $SRC_STORAGE_ID not found."
        exit 1
    fi
    info "  Source: $SRC_STORAGE_NAME (ID: $SRC_STORAGE_ID)"
    echo

    # --- Step 3: Show hypervisors using this storage ---
    echo -e "${BOLD}[3/6] Hypervisors using storage $SRC_STORAGE_ID ($SRC_STORAGE_NAME):${NC}"

    # Find hypervisors that have VMs with disks on the source storage
    local hv_list
    hv_list=$(vfdb "
        SELECT DISTINCT h.id, h.name, h.ip_address,
               COUNT(DISTINCT s.id) AS vm_count
        FROM hypervisors h
        JOIN servers s ON s.hypervisor_id = h.id
        JOIN server_disks sd ON sd.server_id = s.id AND sd.deleted_at IS NULL
        JOIN server_disks_storage sds ON sds.id = sd.disk_storage_id
        WHERE sds.storage_id = $SRC_STORAGE_ID
        GROUP BY h.id, h.name, h.ip_address
        ORDER BY h.id
    ")

    if [ -z "$hv_list" ]; then
        # Maybe no VMs yet, but still show hypervisors with this storage configured
        hv_list=$(vfdb "
            SELECT DISTINCT h.id, h.name, h.ip_address, 0 AS vm_count
            FROM hypervisors h
            JOIN hypervisor_storage hs ON hs.hypervisor_id = h.id
            WHERE hs.storage_id = $SRC_STORAGE_ID
            ORDER BY h.id
        ")
    fi

    if [ -z "$hv_list" ]; then
        err "  No hypervisors found using storage $SRC_STORAGE_ID."
        exit 1
    fi

    printf "  ${BOLD}%-4s %-20s %-18s %s${NC}\n" "ID" "Name" "IP" "VMs on storage"
    while IFS=$'\t' read -r h_id h_name h_ip h_vms; do
        [ -z "$h_id" ] && continue
        printf "  %-4s %-20s %-18s %s\n" "$h_id" "$h_name" "$h_ip" "$h_vms"
    done <<< "$hv_list"
    echo

    # --- Step 3b: Configure destination for each hypervisor ---
    HV_IDS=()
    while IFS=$'\t' read -r h_id h_name h_ip h_vms; do
        [ -z "$h_id" ] && continue

        echo -e "  ${BOLD}Configure destination for hypervisor $h_id ($h_name):${NC}"

        # Show available destination storages for this hypervisor (excluding source)
        local dest_storages
        dest_storages=$(vfdb "
            SELECT hs.id AS hv_storage_id, s.id AS storage_id, s.name, s.path
            FROM hypervisor_storage hs
            JOIN storage s ON s.id = hs.storage_id
            WHERE hs.hypervisor_id = $h_id
            AND s.id != $SRC_STORAGE_ID
            ORDER BY s.id
        ")

        if [ -z "$dest_storages" ]; then
            warn "    No other storage backends configured for $h_name — skipping"
            echo
            continue
        fi

        echo "    Available destination storages:"
        while IFS=$'\t' read -r hs_id s_id s_name s_path; do
            [ -z "$hs_id" ] && continue
            printf "      %-4s %-30s %s\n" "$s_id" "$s_name" "$s_path"
        done <<< "$dest_storages"

        echo -en "    Select destination storage ID: "
        read -r dst_storage_id

        # Validate input is an integer (prevents SQL injection)
        if ! [[ "$dst_storage_id" =~ ^[0-9]+$ ]]; then
            err "    Invalid input — must be a numeric storage ID."
            exit 1
        fi

        # Resolve the hypervisor_storage ID and path for the chosen destination
        local dst_info
        dst_info=$(vfdb "
            SELECT hs.id, s.path
            FROM hypervisor_storage hs
            JOIN storage s ON s.id = hs.storage_id
            WHERE hs.hypervisor_id = $h_id
            AND s.id = $dst_storage_id
            LIMIT 1
        ")

        if [ -z "$dst_info" ]; then
            err "    Storage $dst_storage_id is not configured for hypervisor $h_name"
            exit 1
        fi

        local dst_hv_storage_id dst_path
        dst_hv_storage_id=$(echo "$dst_info" | awk '{print $1}')
        dst_path=$(echo "$dst_info" | awk '{print $2}')

        # SSH connectivity check
        echo -n "    SSH check to $h_ip... "
        if hv_ssh "$h_ip" "true" 2>/dev/null; then
            echo -e "${GREEN}OK${NC}"
        else
            echo -e "${RED}FAILED${NC}"
            err "    Cannot SSH to $h_ip. Ensure root key-based SSH is configured."
            exit 1
        fi

        # Path accessibility check
        echo -n "    Path $dst_path accessible... "
        if hv_ssh "$h_ip" "test -d '$dst_path'" 2>/dev/null; then
            echo -e "${GREEN}OK${NC}"
        else
            echo -e "${RED}FAILED${NC}"
            err "    Path $dst_path does not exist on $h_name"
            exit 1
        fi

        # Store in arrays
        HV_IDS+=("$h_id")
        HV_NAMES[$h_id]="$h_name"
        HV_IPS[$h_id]="$h_ip"
        HV_DST_STORAGE[$h_id]="$dst_storage_id"
        HV_DST_HV_STORAGE[$h_id]="$dst_hv_storage_id"
        HV_DST_PATHS[$h_id]="$dst_path"
        echo
    done <<< "$hv_list"

    if [ ${#HV_IDS[@]} -eq 0 ]; then
        err "No hypervisors configured. Cannot continue."
        exit 1
    fi

    # --- Step 4: Format conversion ---
    echo -e "${BOLD}[4/6] Format conversion:${NC}"
    echo "  Convert disk images during migration?"
    echo "  [1] raw  (Recommended for ZFS — eliminates double copy-on-write)"
    echo "  [2] qcow2 (Standard format — supports snapshots, thin provisioning)"
    echo "  [3] preserve (Keep whatever format each disk currently uses)"
    echo -en "  Select [1]: "
    read -r fmt_choice
    case "${fmt_choice:-1}" in
        1) DEST_FORMAT="raw" ;;
        2) DEST_FORMAT="qcow2" ;;
        3) DEST_FORMAT="preserve" ;;
        *) DEST_FORMAT="raw" ;;
    esac
    info "  Format: $DEST_FORMAT"
    echo

    # --- Step 5: Network speed tuning ---
    echo -e "${BOLD}[5/6] Network link speed:${NC}"
    echo "  What is the link speed used for VM storage traffic?"
    echo "  [1] 1 Gbps"
    echo "  [2] 10 Gbps"
    echo "  [3] 25 Gbps"
    echo "  [4] 40 Gbps"
    echo "  [5] 100 Gbps"
    echo "  [6] Custom (enter buffer size in MB)"
    echo -en "  Select [2]: "
    read -r speed_choice
    local speed_label=""
    case "${speed_choice:-2}" in
        1) BLOCKCOPY_BUF_SIZE=16777216;    speed_label="1 Gbps" ;;
        2) BLOCKCOPY_BUF_SIZE=134217728;   speed_label="10 Gbps" ;;
        3) BLOCKCOPY_BUF_SIZE=268435456;   speed_label="25 Gbps" ;;
        4) BLOCKCOPY_BUF_SIZE=536870912;   speed_label="40 Gbps" ;;
        5) BLOCKCOPY_BUF_SIZE=1073741824;  speed_label="100 Gbps" ;;
        6)
            echo -en "  Buffer size in MB: "
            read -r custom_mb
            BLOCKCOPY_BUF_SIZE=$((custom_mb * 1048576))
            speed_label="Custom (${custom_mb} MB buffer)"
            ;;
        *) BLOCKCOPY_BUF_SIZE=134217728;   speed_label="10 Gbps" ;;
    esac

    local buf_mb=$((BLOCKCOPY_BUF_SIZE / 1048576))
    info "  Tuning for $speed_label:"
    info "    Blockcopy buffer: ${buf_mb} MB"
    info "    Poll interval: ${POLL_INTERVAL}s"
    info "    Max retries: $MAX_RETRIES"
    echo

    # --- Step 6: Save config ---
    echo -e "${BOLD}[6/6] Saving configuration...${NC}"
    save_config "$CONFIG_FILE"
    echo

    # --- Run pre-flight ---
    preflight
    echo

    log "Setup complete! Run migrations with:"
    info "  $0 --all --dry-run    # Preview"
    info "  $0 --all --yes        # Execute all"
    info "  $0 <uuid>             # Single VM"
}

# =====================================================================
# Interrupt Handler
# =====================================================================

# On SIGINT/SIGTERM: abort active blockjobs and resume any suspended VM.
# This prevents leaving VMs in a bad state if the operator hits Ctrl-C.
cleanup_on_interrupt() {
    echo -e "\n${YELLOW}[$(date '+%H:%M:%S')] Interrupted — cleaning up...${NC}"

    if [ -n "$CURRENT_MIGRATE_UUID" ] && [ -n "$CURRENT_MIGRATE_HV" ]; then
        # Abort any active blockjobs for the current VM
        for tgt in "${CURRENT_MIGRATE_TARGETS[@]}"; do
            echo "[$(date '+%H:%M:%S')] Aborting blockjob $tgt on $CURRENT_MIGRATE_UUID..."
            hv_ssh "$CURRENT_MIGRATE_HV" "virsh blockjob $CURRENT_MIGRATE_UUID $tgt --abort" 2>/dev/null || true
        done

        # Wait for blockjobs to clear (up to 30s)
        for tgt in "${CURRENT_MIGRATE_TARGETS[@]}"; do
            for _w in $(seq 1 6); do
                local _jstat
                _jstat=$(hv_ssh "$CURRENT_MIGRATE_HV" "virsh blockjob $CURRENT_MIGRATE_UUID $tgt --info 2>&1" 2>/dev/null || true)
                if echo "$_jstat" | grep -qi "no current\|error"; then break; fi
                sleep 5
            done
        done

        # Resume VM if we suspended it
        if $CURRENT_MIGRATE_SUSPENDED; then
            echo "[$(date '+%H:%M:%S')] Resuming suspended VM $CURRENT_MIGRATE_UUID..."
            hv_ssh "$CURRENT_MIGRATE_HV" "virsh resume $CURRENT_MIGRATE_UUID" 2>/dev/null || true
        fi

        echo "[$(date '+%H:%M:%S')] Blockjobs aborted. VM still running on original disks."
        echo "[$(date '+%H:%M:%S')] Re-run to retry: $0 $CURRENT_MIGRATE_UUID --yes"
    fi

    # Clean up lock file
    rm -f "$LOCK_FILE" 2>/dev/null || true

    exit 130
}

trap cleanup_on_interrupt INT TERM

# =====================================================================
# Resolve VM -> Hypervisor -> Paths
# =====================================================================

# Global variables set by resolve_vm (used by migrate_one, rollback, etc.)
SERVER_DB_ID=""
HV_ID=""
HV_IP=""
HV_NAME=""
DST_PATH=""
NEW_STORAGE_ID=""
NEW_HV_STORAGE_ID=""
SRC_PATH=""
VM_NAME=""
DISK_DB_IDS=""
DISK_STORAGE_DB_IDS=""
OLD_HV_STORAGE_ID=""

# Resolve a VM UUID to its hypervisor, paths, and storage IDs.
# Sets global variables for use by the caller.
resolve_vm() {
    local uuid="$1"

    validate_uuid "$uuid" || return 1

    # Look up server in VirtFusion DB
    SERVER_DB_ID=$(vfdb "SELECT id FROM servers WHERE uuid = '$uuid'" | head -1)
    if [ -z "$SERVER_DB_ID" ]; then
        err "VM $uuid not found in VirtFusion DB"
        return 1
    fi

    HV_ID=$(vfdb "SELECT hypervisor_id FROM servers WHERE id = $SERVER_DB_ID" | head -1)
    VM_NAME=$(vfdb "SELECT name FROM servers WHERE id = $SERVER_DB_ID" | head -1)

    # Check if this hypervisor is in our config
    if [ -z "${HV_IPS[$HV_ID]+x}" ]; then
        err "VM $uuid is on hypervisor $HV_ID which is not in the migration config"
        err "Run --setup to configure this hypervisor"
        return 1
    fi

    HV_IP="${HV_IPS[$HV_ID]}"
    HV_NAME="${HV_NAMES[$HV_ID]}"
    DST_PATH="${HV_DST_PATHS[$HV_ID]}"
    NEW_STORAGE_ID="${HV_DST_STORAGE[$HV_ID]}"
    NEW_HV_STORAGE_ID="${HV_DST_HV_STORAGE[$HV_ID]}"

    # Get source path from storage table
    SRC_PATH=$(vfdb "SELECT path FROM storage WHERE id = $SRC_STORAGE_ID" | head -1)

    # Get disk IDs for DB updates
    DISK_DB_IDS=$(vfdb "SELECT GROUP_CONCAT(id) FROM server_disks WHERE server_id = $SERVER_DB_ID AND deleted_at IS NULL" | head -1)
    DISK_STORAGE_DB_IDS=$(vfdb "SELECT GROUP_CONCAT(disk_storage_id) FROM server_disks WHERE server_id = $SERVER_DB_ID AND deleted_at IS NULL" | head -1)
    OLD_HV_STORAGE_ID=$(vfdb "SELECT hypervisor_storage_id FROM server_disks WHERE server_id = $SERVER_DB_ID AND deleted_at IS NULL LIMIT 1" | head -1)
}

# =====================================================================
# Migration State Tracking
# =====================================================================

# Record a completed migration in the state directory (local).
# Used by --verify, --report, and --cleanup.
record_migration() {
    local uuid="$1"
    local src_size="$2"
    local dst_size="$3"
    local elapsed="$4"

    mkdir -p "$STATE_DIR"
    cat > "$STATE_DIR/$uuid.conf" <<STATEEOF
UUID=$uuid
VM_NAME=$VM_NAME
HV_ID=$HV_ID
HV_NAME=$HV_NAME
SRC_STORAGE_ID=$SRC_STORAGE_ID
DST_STORAGE_ID=$NEW_STORAGE_ID
SRC_PATH=$SRC_PATH
DST_PATH=$DST_PATH
DEST_FORMAT=$DEST_FORMAT
SRC_SIZE=$src_size
DST_SIZE=$dst_size
ELAPSED=$elapsed
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
STATEEOF
}

# =====================================================================
# Rollback
# =====================================================================

do_rollback() {
    local uuid="$1"

    validate_uuid "$uuid" || exit 1
    resolve_vm "$uuid" || exit 1

    # Load rollback data from the hypervisor
    local rb_dir="$ROLLBACK_DIR/$uuid"
    local rb_data
    rb_data=$(hv_ssh "$HV_IP" "cat $rb_dir/rollback.conf 2>/dev/null") || {
        err "No rollback data for $uuid on $HV_NAME ($rb_dir)"
        exit 1
    }

    # Parse rollback config
    local orig_hv_storage_id orig_storage_id disk_ids disk_storage_ids orig_src_path orig_format
    orig_hv_storage_id=$(echo "$rb_data" | grep "^OLD_HV_STORAGE_ID=" | cut -d= -f2)
    orig_storage_id=$(echo "$rb_data" | grep "^OLD_STORAGE_ID=" | cut -d= -f2)
    disk_ids=$(echo "$rb_data" | grep "^DISK_DB_IDS=" | cut -d= -f2)
    disk_storage_ids=$(echo "$rb_data" | grep "^DISK_STORAGE_DB_IDS=" | cut -d= -f2)
    orig_src_path=$(echo "$rb_data" | grep "^SRC_PATH=" | cut -d= -f2)
    orig_format=$(echo "$rb_data" | grep "^ORIG_FORMAT=" | cut -d= -f2)
    [ -z "$orig_format" ] && orig_format="qcow2"  # Default assumption for old rollback data

    info "Rollback: $VM_NAME ($uuid) on $HV_NAME"
    info "  Reverting disks from $DST_PATH back to $orig_src_path"
    confirm "Proceed with rollback?" || exit 1

    # Get current VM state
    local vm_state
    vm_state=$(hv_ssh "$HV_IP" "virsh domstate $uuid 2>/dev/null" | xargs || echo "not found")

    # Get current disk list
    local disks
    disks=$(hv_ssh "$HV_IP" "virsh domblklist $uuid 2>/dev/null | awk 'NR>2 && \$2 != \"-\" && \$2 ~ /\.img/ {print \$1, \$2}'" || true)

    if [ -z "$disks" ]; then
        err "No disks found for $uuid — VM may not be defined"
        exit 1
    fi

    while read -r target src_file; do
        [ -z "$target" ] && continue
        local fname
        fname=$(basename "$src_file")
        local orig_file="${orig_src_path}/${fname}"

        # Only rollback disks that are on the destination path
        if [[ "$src_file" != *"$DST_PATH"* ]]; then
            info "  $target: $src_file — not on dest path, skipping"
            continue
        fi

        if [ "$vm_state" = "running" ] || [ "$vm_state" = "paused" ]; then
            log "  Reverting $target: $src_file -> $orig_file (format: $orig_format)"
            hv_ssh_long "$HV_IP" "virsh blockcopy $uuid '$src_file' --dest '$orig_file' --format $orig_format \
                --buf-size $BLOCKCOPY_BUF_SIZE --transient-job \
                --wait --verbose --pivot" 2>&1
        else
            log "  Copying $target: $src_file -> $orig_file (offline, format: $orig_format)"
            hv_ssh_long "$HV_IP" "qemu-img convert -f raw -O $orig_format -p '$src_file' '$orig_file'" 2>&1
            hv_ssh "$HV_IP" "chown qemu:qemu 2>/dev/null || chown libvirt-qemu:libvirt-qemu 2>/dev/null || chown 107:107 '$orig_file'" 2>/dev/null
        fi
    done <<< "$disks"

    # Restore DB
    log "Restoring VirtFusion DB..."
    IFS=',' read -ra DIDS <<< "$disk_ids"
    for did in "${DIDS[@]}"; do
        vfdb "UPDATE server_disks SET hypervisor_storage_id = $orig_hv_storage_id, type = '$orig_format' WHERE id = $did"
    done
    IFS=',' read -ra DSIDS <<< "$disk_storage_ids"
    for dsid in "${DSIDS[@]}"; do
        vfdb "UPDATE server_disks_storage SET storage_id = $orig_storage_id WHERE id = $dsid"
    done

    # Restore persistent XML from backup
    log "Restoring persistent XML..."
    hv_ssh "$HV_IP" "cp $rb_dir/server.xml.bak $VFDATA/$uuid/server.xml" 2>/dev/null || true
    hv_ssh "$HV_IP" "virsh define $VFDATA/$uuid/server.xml 2>/dev/null" || true

    # Remove state record
    rm -f "$STATE_DIR/$uuid.conf" 2>/dev/null || true

    log "Rollback complete for $VM_NAME ($uuid)"
}

# =====================================================================
# Migrate Single VM
# =====================================================================

migrate_one() {
    local uuid="$1"
    local migration_start
    migration_start=$(date +%s)

    resolve_vm "$uuid" || return 1

    log "=== Disk Migration: $VM_NAME ($uuid) ==="
    info "  Host: $HV_NAME ($HV_IP)"
    info "  VF Server ID: $SERVER_DB_ID"
    info "  Source: $SRC_PATH/ -> Dest: $DST_PATH/"

    # --- Detect VM state ---
    local VM_STATE
    VM_STATE=$(hv_ssh "$HV_IP" "virsh domstate $uuid 2>/dev/null" | xargs || echo "not found")

    if [[ "$VM_STATE" == *"not found"* ]] || [[ "$VM_STATE" == *"failed to get domain"* ]] || [ -z "$VM_STATE" ]; then
        VM_STATE="not found"
        # VM not in libvirt — check if disk files exist on filesystem
        local orphan_disks
        orphan_disks=$(hv_ssh "$HV_IP" "ls $SRC_PATH/${uuid}*.img 2>/dev/null" || true)
        if [ -z "$orphan_disks" ]; then
            warn "VM $uuid not in libvirt and no disk files found, skipping"
            return 2
        fi
        info "  VM not in libvirt but disk files exist — will use file copy"
        VM_STATE="undefined"
    fi
    info "  VM state: $VM_STATE"

    # --- Check if already migrated ---
    local current_storage
    current_storage=$(vfdb "SELECT storage_id FROM server_disks_storage sds JOIN server_disks sd ON sd.disk_storage_id = sds.id WHERE sd.server_id = $SERVER_DB_ID AND sd.deleted_at IS NULL LIMIT 1" | head -1)
    if [ "$current_storage" != "$SRC_STORAGE_ID" ]; then
        info "  Already migrated (storage_id=$current_storage), skipping"
        return 2  # 2 = skipped
    fi

    # --- Build disk list ---
    local DISK_LIST
    if [ "$VM_STATE" = "undefined" ]; then
        # No libvirt domain — find disk files on filesystem
        DISK_LIST=$(hv_ssh "$HV_IP" "ls -1 $SRC_PATH/${uuid}*.img 2>/dev/null" | while read -r f; do echo "file $f"; done)
    else
        DISK_LIST=$(hv_ssh "$HV_IP" "virsh domblklist $uuid 2>/dev/null" | awk -v src="$SRC_PATH/" 'NR>2 && index($2, src)==1 {print $1, $2}')
    fi

    if [ -z "$DISK_LIST" ]; then
        warn "No disks on $SRC_PATH — already migrated or no disks, skipping"
        return 2
    fi

    # --- Show disk info and calculate total size ---
    info "  Disks:"
    local TOTAL_SIZE=0
    while IFS= read -r line; do
        local target src_file
        target=$(echo "$line" | awk '{print $1}')
        src_file=$(echo "$line" | awk '{print $2}')
        [ -z "$target" ] && continue
        local size_h size_b
        size_h=$(hv_ssh "$HV_IP" "du -h '$src_file' 2>/dev/null | awk '{print \$1}'" || echo "?")
        size_b=$(hv_ssh "$HV_IP" "stat -c%s '$src_file' 2>/dev/null" || echo "0")
        TOTAL_SIZE=$((TOTAL_SIZE + size_b))
        info "    $target: $src_file ($size_h)"
    done <<< "$DISK_LIST"

    local TOTAL_H
    TOTAL_H=$(awk "BEGIN {printf \"%.1f GiB\", $TOTAL_SIZE/1073741824}")

    # Determine effective format for display
    local display_format="$DEST_FORMAT"
    [ "$display_format" = "preserve" ] && display_format="(preserve source)"
    info "  Total: $TOTAL_H | Format: -> $display_format"

    # --- Check destination space ---
    local DST_AVAIL
    DST_AVAIL=$(hv_ssh "$HV_IP" "df -B1 --output=avail '$DST_PATH' 2>/dev/null | tail -1" || echo "0")
    DST_AVAIL=$(echo "$DST_AVAIL" | tr -d ' ')
    local DST_AVAIL_H
    DST_AVAIL_H=$(awk "BEGIN {printf \"%.1f GiB\", $DST_AVAIL/1073741824}")
    info "  Destination available: $DST_AVAIL_H"

    if [ "$TOTAL_SIZE" -gt "$DST_AVAIL" ]; then
        err "Not enough space! Need $TOTAL_H, have $DST_AVAIL_H"
        return 1
    fi

    # --- Dry run exit ---
    if $DRY_RUN; then
        info "  [DRY-RUN] Would migrate $TOTAL_H (DB: storage $SRC_STORAGE_ID->$NEW_STORAGE_ID, hv_storage $OLD_HV_STORAGE_ID->$NEW_HV_STORAGE_ID)"
        return 0
    fi

    confirm "Migrate $VM_NAME ($TOTAL_H)?" || return 2

    # --- Save rollback data on the hypervisor ---
    hv_ssh "$HV_IP" "mkdir -p $ROLLBACK_DIR/$uuid"
    hv_ssh "$HV_IP" "cp $VFDATA/$uuid/server.xml $ROLLBACK_DIR/$uuid/server.xml.bak 2>/dev/null" || true

    # Detect original format of first disk for rollback
    local first_src_file orig_format
    first_src_file=$(echo "$DISK_LIST" | head -1 | awk '{print $2}')
    orig_format=$(hv_ssh "$HV_IP" "qemu-img info '$first_src_file' 2>/dev/null | awk '/^file format:/{print \$3}'" || echo "qcow2")
    [ -z "$orig_format" ] && orig_format="qcow2"

    hv_ssh "$HV_IP" "cat > $ROLLBACK_DIR/$uuid/rollback.conf << 'ROLLBACK_CONF'
UUID=$uuid
SERVER_DB_ID=$SERVER_DB_ID
HV_ID=$HV_ID
HV_IP=$HV_IP
SRC_PATH=$SRC_PATH
DST_PATH=$DST_PATH
OLD_HV_STORAGE_ID=$OLD_HV_STORAGE_ID
OLD_STORAGE_ID=$SRC_STORAGE_ID
DISK_DB_IDS=$DISK_DB_IDS
DISK_STORAGE_DB_IDS=$DISK_STORAGE_DB_IDS
ORIG_FORMAT=$orig_format
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
ROLLBACK_CONF"

    # --- Copy disks based on VM state ---
    # blockcopy works on running/paused/suspended VMs (QEMU process is active)
    # qemu-img convert works on shut-off VMs (no QEMU lock on disk)
    # rsync/cp works for undefined VMs (no libvirt domain at all)
    if [ "$VM_STATE" = "running" ] || [ "$VM_STATE" = "paused" ] || [ "$VM_STATE" = "suspended" ]; then
        # ============================================================
        # LIVE MIGRATION: virsh blockcopy + poll + pivot
        # ============================================================
        log "  Method: live blockcopy (VM is $VM_STATE)"

        # Set interrupt tracking
        CURRENT_MIGRATE_UUID="$uuid"
        CURRENT_MIGRATE_HV="$HV_IP"
        CURRENT_MIGRATE_TARGETS=()
        CURRENT_MIGRATE_SUSPENDED=false

        local MIGRATED_DISKS=()

        while read -r target src_file; do
            [ -z "$target" ] && continue
            local fname dst_file
            fname=$(basename "$src_file")
            dst_file="${DST_PATH}/${fname}"

            # Detect source format for this disk
            local src_fmt
            src_fmt=$(hv_ssh "$HV_IP" "qemu-img info '$src_file' 2>/dev/null | awk '/^file format:/{print \$3}'" || echo "raw")
            [ -z "$src_fmt" ] && src_fmt="raw"

            # Determine effective destination format
            local eff_format="$DEST_FORMAT"
            if [ "$eff_format" = "preserve" ]; then
                eff_format="$src_fmt"
            fi

            local attempt=0
            local success=false
            local was_suspended=false
            CURRENT_MIGRATE_TARGETS+=("$target")

            while [ $attempt -le "$MAX_RETRIES" ]; do
                attempt=$((attempt + 1))
                local reuse_flag=""

                # --- Cancel any lingering blockjob from previous runs ---
                local existing_job
                existing_job=$(hv_ssh "$HV_IP" "virsh blockjob $uuid $target --info 2>&1" || true)
                if ! echo "$existing_job" | grep -qi "no current\|error"; then
                    warn "  Active blockjob found on $target — aborting first"
                    hv_ssh "$HV_IP" "virsh blockjob $uuid $target --abort" 2>/dev/null || true
                    # Wait for the abort to complete (up to 30s)
                    for _w in $(seq 1 6); do
                        local jstat
                        jstat=$(hv_ssh "$HV_IP" "virsh blockjob $uuid $target --info 2>&1" || true)
                        if echo "$jstat" | grep -qi "no current\|error"; then break; fi
                        info "  Waiting for blockjob to clear ($target)..."
                        sleep 5
                    done
                fi

                # --- Check if destination file exists (from previous failed attempt) ---
                local dest_exists
                dest_exists=$(hv_ssh "$HV_IP" "test -f '$dst_file' && echo yes || echo no" 2>/dev/null)
                if [ "$dest_exists" = "yes" ]; then
                    if [ $attempt -eq 1 ]; then
                        info "  Existing dest file found — resuming with --reuse-external"
                    else
                        warn "  Retry $attempt/$((MAX_RETRIES+1)) for $target — resuming with --reuse-external"
                    fi
                    reuse_flag="--reuse-external"
                elif [ $attempt -gt 1 ]; then
                    warn "  Retry $attempt/$((MAX_RETRIES+1)) for $target — fresh copy"
                fi

                info "  blockcopy $target -> $dst_file (attempt $attempt/$((MAX_RETRIES+1)), format: $src_fmt -> $eff_format)"

                # --- Start blockcopy without --wait — we poll ourselves ---
                # This gives us control over progress reporting, ETA, and error handling.
                # --transient-job means the copy doesn't survive VM reboot (safe).
                local bc_cmd="virsh blockcopy $uuid '$src_file' \
                    --dest '$dst_file' \
                    --format $eff_format \
                    --buf-size $BLOCKCOPY_BUF_SIZE \
                    --transient-job"
                [ -n "$reuse_flag" ] && bc_cmd="$bc_cmd --reuse-external"

                hv_ssh "$HV_IP" "$bc_cmd" 2>&1 || true

                # Give libvirt a moment to register the job
                sleep 3

                # --- Verify the blockjob actually started ---
                local job_check
                job_check=$(hv_ssh "$HV_IP" "virsh blockjob $uuid $target --info 2>&1" || true)
                if ! echo "$job_check" | grep -q "Block Copy" && ! echo "$job_check" | grep -qi "Timed out\|cannot acquire"; then
                    warn "  blockcopy did not start for $target: $job_check"
                    continue
                fi

                info "  blockcopy started — polling progress every ${POLL_INTERVAL}s"
                local poll_start
                poll_start=$(date +%s)

                # --- Poll loop: check blockjob progress ---
                while true; do
                    sleep "$POLL_INTERVAL"
                    local poll_elapsed=$(( $(date +%s) - poll_start ))

                    # Safety timeout
                    if [ $poll_elapsed -gt "$BLOCKCOPY_TIMEOUT" ]; then
                        err "  Timeout after ${poll_elapsed}s — aborting blockjob"
                        hv_ssh "$HV_IP" "virsh blockjob $uuid $target --abort" 2>/dev/null || true
                        break
                    fi

                    # Query blockjob status
                    local poll
                    poll=$(hv_ssh "$HV_IP" "virsh blockjob $uuid $target --info 2>&1" || true)

                    if echo "$poll" | grep -q "No current block job"; then
                        # Job ended — check if disk path changed (shouldn't happen without --pivot, but check)
                        local cur_path
                        cur_path=$(hv_ssh "$HV_IP" "virsh domblklist $uuid 2>/dev/null | awk '\$1==\"$target\" {print \$2}'" || true)
                        if [[ "$cur_path" == *"$DST_PATH"* ]]; then
                            info "  $target: completed and pivoted"
                            success=true
                        else
                            warn "  blockjob ended without pivot — disk still on source"
                        fi
                        break
                    elif echo "$poll" | grep -qi "Timed out\|cannot acquire"; then
                        # libvirt lock contention — just retry the poll, don't abort
                        info "  libvirt lock contention, retrying poll... (${poll_elapsed}s)"
                        continue
                    elif ! echo "$poll" | grep -q "Block Copy"; then
                        warn "  Unexpected blockjob status: $poll"
                        break
                    fi

                    # Parse percentage from blockjob output
                    local pct_num
                    pct_num=$(echo "$poll" | sed -n 's/.*\[\s*\([0-9.]*\)\s*%\].*/\1/p')

                    # Calculate ETA for this disk
                    local eta_str=""
                    if [ -n "$pct_num" ] && [ "$pct_num" != "0" ] && [ "$pct_num" != "100.00" ]; then
                        local remaining_pct
                        remaining_pct=$(awk "BEGIN {printf \"%.2f\", 100 - $pct_num}")
                        local rate
                        rate=$(awk "BEGIN {if($poll_elapsed>0) printf \"%.4f\", $pct_num/$poll_elapsed; else print 0}")
                        if [ "$(awk "BEGIN {print ($rate > 0)}")" = "1" ]; then
                            local eta_secs
                            eta_secs=$(awk "BEGIN {printf \"%.0f\", $remaining_pct/$rate}")
                            local eta_m=$((eta_secs / 60))
                            local eta_s=$((eta_secs % 60))
                            eta_str=" | ETA: ${eta_m}m${eta_s}s"
                        fi
                    fi

                    # --- At 100%: issue pivot with retries ---
                    if [[ "$pct_num" == "100.00" ]] || [[ "$pct_num" == "100" ]]; then
                        info "  $target at 100% — pivoting"
                        local pivot_ok=false

                        # Pivot can fail due to lock contention — retry up to 10 times
                        for _p in $(seq 1 10); do
                            hv_ssh "$HV_IP" "virsh blockjob $uuid $target --pivot" 2>/dev/null || true
                            sleep 3
                            local cur_path
                            cur_path=$(hv_ssh "$HV_IP" "virsh domblklist $uuid 2>/dev/null | awk '\$1==\"$target\" {print \$2}'" || true)
                            if [[ "$cur_path" == *"$DST_PATH"* ]]; then
                                info "  $target: pivot successful"
                                success=true
                                pivot_ok=true
                                break
                            fi
                            info "  pivot attempt $_p — retrying..."
                        done

                        if $pivot_ok; then break; fi
                        warn "  pivot failed after 10 attempts"
                        break
                    fi

                    # Progress output
                    info "  $target: ${pct_num}% (${poll_elapsed}s elapsed${eta_str})"
                done

                if $success; then break; fi

                warn "  blockcopy attempt $attempt failed for $target"

                # --- After first failure: offer to suspend VM for faster retry ---
                # Always interactive — never auto-suspend, this could be a customer's VM
                if [ $attempt -eq 1 ] && [ $attempt -le "$MAX_RETRIES" ]; then
                    local do_suspend=false
                    echo -en "${YELLOW}  Suspend VM for faster retry? (freezes VM in memory, resumes after copy) [y/N]: ${NC}"
                    read -r suspend_response
                    [[ "$suspend_response" =~ ^[Yy]$ ]] && do_suspend=true

                    if $do_suspend; then
                        info "  Suspending VM..."
                        if hv_ssh "$HV_IP" "virsh suspend $uuid" 2>/dev/null; then
                            was_suspended=true
                            CURRENT_MIGRATE_SUSPENDED=true
                            info "  VM suspended"
                        else
                            warn "  Failed to suspend VM — retrying live"
                        fi
                    fi
                fi

                # If reuse failed, delete dest and try fresh on next attempt
                if [ -n "$reuse_flag" ] && [ $attempt -le "$MAX_RETRIES" ]; then
                    warn "  Resume failed — will try fresh copy next"
                    hv_ssh "$HV_IP" "rm -f '$dst_file'" 2>/dev/null || true
                fi
            done

            # Resume VM if we suspended it (whether success or failure)
            if $was_suspended; then
                info "  Resuming VM..."
                hv_ssh "$HV_IP" "virsh resume $uuid" 2>/dev/null || true
                was_suspended=false
                CURRENT_MIGRATE_SUSPENDED=false
            fi

            if ! $success; then
                err "blockcopy failed for $target after $((MAX_RETRIES+1)) attempts on $VM_NAME"
                err "Use: $0 --rollback $uuid"
                # Clear interrupt tracking
                CURRENT_MIGRATE_UUID=""
                CURRENT_MIGRATE_HV=""
                CURRENT_MIGRATE_TARGETS=()
                return 1
            fi

            MIGRATED_DISKS+=("$target")
            info "  $target: pivoted successfully"
        done <<< "$DISK_LIST"

        # --- Verify all disks are on new path ---
        local ALL_OK=true
        while read -r target src_file; do
            [ -z "$target" ] && continue
            local current
            current=$(hv_ssh "$HV_IP" "virsh domblklist $uuid 2>/dev/null | awk '\$1==\"$target\" {print \$2}'" || true)
            if [[ "$current" == *"$DST_PATH"* ]]; then
                info "  Verified $target: $current"
            else
                err "  $target: expected $DST_PATH/... got $current"
                ALL_OK=false
            fi
        done <<< "$DISK_LIST"

        if ! $ALL_OK; then
            err "Verification failed for $VM_NAME — use --rollback $uuid"
            CURRENT_MIGRATE_UUID=""
            CURRENT_MIGRATE_HV=""
            CURRENT_MIGRATE_TARGETS=()
            return 1
        fi

    else
        # ============================================================
        # OFFLINE MIGRATION: qemu-img convert or rsync
        # ============================================================
        log "  Method: offline copy (VM is $VM_STATE)"

        while read -r target src_file; do
            [ -z "$target" ] && continue
            local fname dst_file
            fname=$(basename "$src_file")
            dst_file="${DST_PATH}/${fname}"

            # Detect source format via qemu-img info
            local src_fmt
            src_fmt=$(hv_ssh "$HV_IP" "qemu-img info '$src_file' 2>/dev/null | awk '/^file format:/{print \$3}'" || echo "raw")
            [ -z "$src_fmt" ] && src_fmt="raw"

            # Determine effective destination format
            local eff_format="$DEST_FORMAT"
            if [ "$eff_format" = "preserve" ]; then
                eff_format="$src_fmt"
            fi

            local attempt=0
            local max_offline_retries=2
            local success=false

            while [ $attempt -le $max_offline_retries ]; do
                attempt=$((attempt + 1))
                if [ $attempt -gt 1 ]; then
                    warn "  Retry $attempt/$((max_offline_retries+1)) for $target"
                    hv_ssh "$HV_IP" "rm -f '$dst_file'" 2>/dev/null || true
                    sleep 3
                fi

                if [ "$src_fmt" = "$eff_format" ]; then
                    # Same format — straight copy with sparse handling (faster than qemu-img convert)
                    info "  Copying $target: $src_fmt (no conversion, attempt $attempt/$((max_offline_retries+1)))"
                    hv_ssh_long "$HV_IP" "rsync --sparse --info=progress2 '$src_file' '$dst_file'" 2>&1
                    local rc=$?
                else
                    # Different format — use qemu-img convert
                    info "  Converting $target: $src_fmt -> $eff_format (attempt $attempt/$((max_offline_retries+1)))"
                    hv_ssh_long "$HV_IP" "qemu-img convert -f $src_fmt -O $eff_format -p '$src_file' '$dst_file'" 2>&1
                    local rc=$?
                fi

                if [ $rc -eq 0 ]; then
                    success=true
                    break
                fi
                warn "  offline copy attempt $attempt failed for $target (exit $rc)"
            done

            if ! $success; then
                err "offline copy failed for $target after $((max_offline_retries+1)) attempts on $VM_NAME"
                return 1
            fi

            # Fix ownership to qemu user (UID 107 on most systems)
            hv_ssh "$HV_IP" "chown qemu:qemu 2>/dev/null || chown libvirt-qemu:libvirt-qemu 2>/dev/null || chown 107:107 '$dst_file'" 2>/dev/null || true
            info "  $target: copied OK"
        done <<< "$DISK_LIST"
    fi

    # ============================================================
    # Post-copy: Update persistent XML and VirtFusion DB
    # ============================================================

    # Determine effective format for XML/DB updates
    local eff_format="$DEST_FORMAT"
    if [ "$eff_format" = "preserve" ]; then
        eff_format="$orig_format"
    fi

    # --- Update persistent XML ---
    # Replace source path with destination path in the libvirt XML
    hv_ssh "$HV_IP" "sed -i 's|${SRC_PATH}/|${DST_PATH}/|g' $VFDATA/$uuid/server.xml" 2>/dev/null || true

    # Update format in XML if we converted
    if [ "$eff_format" = "raw" ] && [ "$orig_format" != "raw" ]; then
        hv_ssh "$HV_IP" "sed -i -E 's|type=[\"'\'']*qcow2[\"'\'']*( cache=)|type=\"raw\"\1|g' $VFDATA/$uuid/server.xml" 2>/dev/null || true
    elif [ "$eff_format" = "qcow2" ] && [ "$orig_format" != "qcow2" ]; then
        hv_ssh "$HV_IP" "sed -i -E 's|type=[\"'\'']*raw[\"'\'']*( cache=)|type=\"qcow2\"\1|g' $VFDATA/$uuid/server.xml" 2>/dev/null || true
    fi

    # Re-define the domain with the updated XML
    hv_ssh "$HV_IP" "virsh define $VFDATA/$uuid/server.xml 2>/dev/null" || true

    # --- Update VirtFusion DB ---
    # Update server_disks.hypervisor_storage_id to point to the new hypervisor-specific storage
    IFS=',' read -ra DIDS <<< "$DISK_DB_IDS"
    for did in "${DIDS[@]}"; do
        vfdb "UPDATE server_disks SET hypervisor_storage_id = $NEW_HV_STORAGE_ID WHERE id = $did"
        # Update disk type if we converted
        if [ "$eff_format" != "preserve" ]; then
            vfdb "UPDATE server_disks SET type = '$eff_format' WHERE id = $did"
        fi
    done

    # Update server_disks_storage.storage_id to point to the new storage backend
    IFS=',' read -ra DSIDS <<< "$DISK_STORAGE_DB_IDS"
    for dsid in "${DSIDS[@]}"; do
        vfdb "UPDATE server_disks_storage SET storage_id = $NEW_STORAGE_ID WHERE id = $dsid"
    done

    # Show final VM state
    local final_state
    final_state=$(hv_ssh "$HV_IP" "virsh domstate $uuid 2>/dev/null" | xargs || echo "unknown")
    info "  Final state: $final_state"

    # Calculate destination size for reporting
    local dst_total_size=0
    while IFS= read -r line; do
        local tgt sf
        tgt=$(echo "$line" | awk '{print $1}')
        sf=$(echo "$line" | awk '{print $2}')
        [ -z "$tgt" ] && continue
        local fn
        fn=$(basename "$sf")
        local ds
        ds=$(hv_ssh "$HV_IP" "stat -c%s '${DST_PATH}/${fn}' 2>/dev/null" || echo "0")
        dst_total_size=$((dst_total_size + ds))
    done <<< "$DISK_LIST"

    local migration_elapsed=$(( $(date +%s) - migration_start ))

    # Record migration for verify/report/cleanup
    record_migration "$uuid" "$TOTAL_SIZE" "$dst_total_size" "$migration_elapsed"

    # Clear interrupt tracking — this VM is done
    CURRENT_MIGRATE_UUID=""
    CURRENT_MIGRATE_HV=""
    CURRENT_MIGRATE_TARGETS=()
    CURRENT_MIGRATE_SUSPENDED=false

    log "Migrated: $VM_NAME ($uuid) -> $DST_PATH/ (${migration_elapsed}s)"
    echo
}

# =====================================================================
# Batch Migration (--all)
# =====================================================================

do_batch() {
    log "=== Batch Migration: All VMs on source storage (storage_id=$SRC_STORAGE_ID) ==="
    echo

    # Build the hypervisor filter clause
    local hv_filter=""
    if [ -n "$FILTER_HV_ID" ]; then
        hv_filter="AND s.hypervisor_id = $FILTER_HV_ID"
        info "Filtering to hypervisor ID: $FILTER_HV_ID"
    else
        # Build IN clause from all configured hypervisor IDs
        local hv_in
        hv_in=$(IFS=,; echo "${HV_IDS[*]}")
        hv_filter="AND s.hypervisor_id IN ($hv_in)"
    fi

    # Query all VMs with disks still on source storage
    local vm_list
    vm_list=$(vfdb "
        SELECT DISTINCT s.uuid, s.name, s.hypervisor_id
        FROM servers s
        JOIN server_disks sd ON sd.server_id = s.id AND sd.deleted_at IS NULL
        JOIN server_disks_storage sds ON sds.id = sd.disk_storage_id
        WHERE sds.storage_id = $SRC_STORAGE_ID
        $hv_filter
        ORDER BY s.hypervisor_id, s.id
    ")

    if [ -z "$vm_list" ]; then
        log "No VMs found on source storage. All migrated!"
        return 0
    fi

    # Parse into arrays (avoids SSH stdin consumption in while-read loops)
    local -a ALL_UUIDS=()
    local -a ALL_NAMES=()
    local -a ALL_HVS=()
    while IFS=$'\t' read -r vm_uuid vm_name vm_hv; do
        [ -z "$vm_uuid" ] && continue
        ALL_UUIDS+=("$vm_uuid")
        ALL_NAMES+=("$vm_name")
        ALL_HVS+=("$vm_hv")
    done <<< "$vm_list"

    local total_vms=${#ALL_UUIDS[@]}

    # Count per hypervisor
    log "Found $total_vms VMs to migrate:"
    for hv_id in "${HV_IDS[@]}"; do
        local count=0
        for h in "${ALL_HVS[@]}"; do
            [ "$h" = "$hv_id" ] && ((count++))
        done
        [ $count -gt 0 ] && info "  ${HV_NAMES[$hv_id]}: $count VMs"
    done
    echo

    # Show VM list
    info "VM List:"
    for i in "${!ALL_UUIDS[@]}"; do
        local hv_label="${HV_NAMES[${ALL_HVS[$i]}]:-hv-${ALL_HVS[$i]}}"
        info "  $((i+1)). ${ALL_NAMES[$i]} (${ALL_UUIDS[$i]}) on $hv_label"
    done
    echo

    # --- Dry run mode ---
    if $DRY_RUN; then
        log "Running dry-run for each VM..."
        echo
        for i in "${!ALL_UUIDS[@]}"; do
            set +e
            migrate_one "${ALL_UUIDS[$i]}"
            set -e
            echo
        done
        log "[DRY-RUN] Batch complete. $total_vms VMs would be migrated."
        return 0
    fi

    confirm "Start batch migration of $total_vms VMs?" || exit 1

    # --- Sequential or parallel processing ---
    local migrated=0
    local failed=0
    local skipped=0
    local start_time
    start_time=$(date +%s)

    if [ "$PARALLEL" -gt 1 ]; then
        # ============================================================
        # Parallel mode: run N migrations concurrently via background jobs
        # ============================================================
        log "Running with --parallel=$PARALLEL"
        warn "  Note: In parallel mode, Ctrl+C will abort all jobs. Orphaned blockjobs"
        warn "  may remain on hypervisors. Check with: virsh blockjob <uuid> vda --info"
        warn "  Re-running the script will detect and clean up orphaned jobs automatically."
        local running=0
        local pids=()
        local pid_uuids=()

        for i in "${!ALL_UUIDS[@]}"; do
            local vm_uuid="${ALL_UUIDS[$i]}"
            local vm_name="${ALL_NAMES[$i]}"

            # Wait if we're at max parallel jobs
            while [ $running -ge "$PARALLEL" ]; do
                # Wait for any child to finish
                wait -n 2>/dev/null || true
                # Recount running jobs
                local new_running=0
                local new_pids=()
                local new_pid_uuids=()
                for pi in "${!pids[@]}"; do
                    if kill -0 "${pids[$pi]}" 2>/dev/null; then
                        new_pids+=("${pids[$pi]}")
                        new_pid_uuids+=("${pid_uuids[$pi]}")
                        ((new_running++))
                    else
                        # Check exit code
                        wait "${pids[$pi]}" 2>/dev/null || true
                        local rc=$?
                        case $rc in
                            0) ((migrated++)) ;;
                            2) ((skipped++)) ;;
                            *) ((failed++)) ;;
                        esac
                    fi
                done
                pids=("${new_pids[@]}")
                pid_uuids=("${new_pid_uuids[@]}")
                running=$new_running
            done

            info "--- Starting: $vm_name ($vm_uuid)"
            migrate_one "$vm_uuid" &
            pids+=($!)
            pid_uuids+=("$vm_uuid")
            ((running++))
        done

        # Wait for all remaining jobs
        for pi in "${!pids[@]}"; do
            wait "${pids[$pi]}" 2>/dev/null || true
            local rc=$?
            case $rc in
                0) ((migrated++)) ;;
                2) ((skipped++)) ;;
                *) ((failed++)) ;;
            esac
        done

    else
        # ============================================================
        # Sequential mode: one VM at a time
        # ============================================================
        for i in "${!ALL_UUIDS[@]}"; do
            local vm_uuid="${ALL_UUIDS[$i]}"
            local vm_name="${ALL_NAMES[$i]}"
            local remaining=$((total_vms - migrated - failed - skipped))
            log "--- [$((migrated + failed + skipped + 1))/$total_vms] $vm_name ($vm_uuid) --- ($remaining remaining)"

            set +e
            migrate_one "$vm_uuid"
            local rc=$?
            set -e

            case $rc in
                0) ((migrated++)) ;;
                2) ((skipped++)) ;;
                *) ((failed++)); warn "Failed to migrate $vm_name — continuing with next VM" ;;
            esac

            # Batch ETA calculation
            local processed=$((migrated + failed + skipped))
            local batch_elapsed=$(( $(date +%s) - start_time ))
            if [ $processed -gt 0 ] && [ $batch_elapsed -gt 0 ]; then
                local avg_per_vm=$(( batch_elapsed / processed ))
                local batch_remaining=$(( total_vms - processed ))
                local batch_eta_secs=$(( avg_per_vm * batch_remaining ))
                local batch_eta_h=$(( batch_eta_secs / 3600 ))
                local batch_eta_m=$(( (batch_eta_secs % 3600) / 60 ))
                info "  Batch: $processed/$total_vms done (${migrated} migrated, ${skipped} skipped, ${failed} failed) | ETA: ${batch_eta_h}h${batch_eta_m}m"
            fi
        done
    fi

    # --- Summary ---
    local end_time
    end_time=$(date +%s)
    local elapsed=$(( end_time - start_time ))
    local elapsed_h=$(( elapsed / 3600 ))
    local elapsed_m=$(( (elapsed % 3600) / 60 ))
    local elapsed_s=$(( elapsed % 60 ))

    echo
    log "========================================="
    log "  Batch Migration Complete"
    log "========================================="
    info "  Migrated: $migrated"
    info "  Skipped:  $skipped (already done or not found)"
    info "  Failed:   $failed"
    info "  Total:    $total_vms"
    if [ $elapsed_h -gt 0 ]; then
        info "  Duration: ${elapsed_h}h ${elapsed_m}m ${elapsed_s}s"
    else
        info "  Duration: ${elapsed_m}m ${elapsed_s}s"
    fi
    info "  Log:      $LOG_FILE"

    if [ $failed -gt 0 ]; then
        warn "  $failed VMs failed — check log for details"
        echo
        info "  Failed VMs can be retried individually:"
        info "    $0 <uuid> --yes"
        info "  Or rolled back:"
        info "    $0 --rollback <uuid>"
    fi
}

# =====================================================================
# Verify Mode (--verify)
# =====================================================================

do_verify() {
    log "=== Verification: Checking all migrated VMs ==="
    echo

    if [ ! -d "$STATE_DIR" ]; then
        info "No migration state directory found. Nothing to verify."
        return 0
    fi

    local total=0 ok=0 problems=0

    for state_file in "$STATE_DIR"/*.conf; do
        [ -f "$state_file" ] || continue
        ((total++))

        # Load state
        local v_uuid v_name v_hv_id v_hv_name v_dst_path v_dst_storage_id v_format
        # shellcheck source=/dev/null
        source "$state_file"
        v_uuid="$UUID"
        v_name="${VM_NAME:-unknown}"
        v_hv_id="${HV_ID:-}"
        v_hv_name="${HV_NAME:-unknown}"
        v_dst_path="${DST_PATH:-}"
        v_dst_storage_id="${DST_STORAGE_ID:-}"
        v_format="${DEST_FORMAT:-raw}"

        info "Checking $v_name ($v_uuid) on $v_hv_name..."
        local v_ok=true

        # Check hypervisor is configured
        if [ -z "${HV_IPS[$v_hv_id]+x}" ]; then
            err "  Hypervisor $v_hv_id not in config — cannot verify"
            ((problems++))
            continue
        fi

        local hv_ip="${HV_IPS[$v_hv_id]}"

        # Check 1: VM exists in libvirt
        local vm_state
        vm_state=$(hv_ssh "$hv_ip" "virsh domstate $v_uuid 2>/dev/null" | xargs || echo "not found")
        if [[ "$vm_state" == *"not found"* ]]; then
            warn "  VM not found in libvirt (may be destroyed/rebuilt)"
        else
            log "  [OK] VM state: $vm_state"
        fi

        # Check 2: Disks on correct path
        if [[ "$vm_state" != *"not found"* ]]; then
            local disks
            disks=$(hv_ssh "$hv_ip" "virsh domblklist $v_uuid 2>/dev/null | awk 'NR>2 && \$2 != \"-\" && \$2 ~ /\.img/ {print \$1, \$2}'" || true)
            while read -r tgt dpath; do
                [ -z "$tgt" ] && continue
                if [[ "$dpath" == *"$v_dst_path"* ]]; then
                    log "  [OK] $tgt: $dpath"
                else
                    err "  [FAIL] $tgt: expected $v_dst_path/... got $dpath"
                    v_ok=false
                fi
            done <<< "$disks"
        fi

        # Check 3: DB matches
        local db_storage
        db_storage=$(vfdb "
            SELECT sds.storage_id
            FROM servers s
            JOIN server_disks sd ON sd.server_id = s.id AND sd.deleted_at IS NULL
            JOIN server_disks_storage sds ON sds.id = sd.disk_storage_id
            WHERE s.uuid = '$v_uuid'
            LIMIT 1
        " | head -1)

        if [ "$db_storage" = "$v_dst_storage_id" ]; then
            log "  [OK] DB storage_id: $db_storage"
        elif [ -z "$db_storage" ]; then
            warn "  VM not found in DB (may be destroyed)"
        else
            err "  [FAIL] DB storage_id: expected $v_dst_storage_id, got $db_storage"
            v_ok=false
        fi

        if $v_ok; then
            ((ok++))
        else
            ((problems++))
        fi
    done

    echo
    log "========================================="
    log "  Verification Summary"
    log "========================================="
    info "  Total checked: $total"
    info "  Healthy:       $ok"
    info "  Problems:      $problems"

    if [ "$problems" -gt 0 ]; then
        warn "  $problems VMs have issues — review above output"
        return 1
    fi

    log "  All VMs healthy!"
    return 0
}

# =====================================================================
# Report Mode (--report)
# =====================================================================

do_report() {
    log "=== Migration Report ==="
    echo

    if [ ! -d "$STATE_DIR" ]; then
        info "No migration state directory found. Nothing to report."
        return 0
    fi

    local total=0
    local total_src_bytes=0
    local total_dst_bytes=0
    local total_elapsed=0

    printf "  ${BOLD}%-40s %-12s %-12s %-10s %-8s %s${NC}\n" \
        "VM" "Source" "Dest" "Ratio" "Time" "Date"

    for state_file in "$STATE_DIR"/*.conf; do
        [ -f "$state_file" ] || continue
        ((total++))

        # Load state
        # shellcheck source=/dev/null
        source "$state_file"

        local src_h dst_h ratio elapsed_str
        src_h=$(awk "BEGIN {printf \"%.1f GiB\", ${SRC_SIZE:-0}/1073741824}")
        dst_h=$(awk "BEGIN {printf \"%.1f GiB\", ${DST_SIZE:-0}/1073741824}")

        if [ "${SRC_SIZE:-0}" -gt 0 ] && [ "${DST_SIZE:-0}" -gt 0 ]; then
            ratio=$(awk "BEGIN {printf \"%.1f%%\", (${DST_SIZE}/${SRC_SIZE})*100}")
        else
            ratio="N/A"
        fi

        local em=$((${ELAPSED:-0} / 60))
        local es=$((${ELAPSED:-0} % 60))
        elapsed_str="${em}m${es}s"

        local ts_short
        ts_short=$(echo "${TIMESTAMP:-}" | cut -dT -f1)

        printf "  %-40s %-12s %-12s %-10s %-8s %s\n" \
            "${VM_NAME:-$UUID}" "$src_h" "$dst_h" "$ratio" "$elapsed_str" "$ts_short"

        total_src_bytes=$((total_src_bytes + ${SRC_SIZE:-0}))
        total_dst_bytes=$((total_dst_bytes + ${DST_SIZE:-0}))
        total_elapsed=$((total_elapsed + ${ELAPSED:-0}))
    done

    echo
    log "========================================="
    log "  Summary"
    log "========================================="

    local total_src_h total_dst_h total_ratio total_time_h total_time_m
    total_src_h=$(awk "BEGIN {printf \"%.1f GiB\", $total_src_bytes/1073741824}")
    total_dst_h=$(awk "BEGIN {printf \"%.1f GiB\", $total_dst_bytes/1073741824}")

    if [ "$total_src_bytes" -gt 0 ]; then
        total_ratio=$(awk "BEGIN {printf \"%.1f%%\", ($total_dst_bytes/$total_src_bytes)*100}")
    else
        total_ratio="N/A"
    fi

    total_time_h=$((total_elapsed / 3600))
    total_time_m=$(( (total_elapsed % 3600) / 60 ))

    info "  VMs migrated:   $total"
    info "  Source total:    $total_src_h"
    info "  Dest total:      $total_dst_h"
    info "  Size ratio:      $total_ratio"
    info "  Total time:      ${total_time_h}h ${total_time_m}m"

    if [ "$total_src_bytes" -gt "$total_dst_bytes" ] && [ "$total_dst_bytes" -gt 0 ]; then
        local saved
        saved=$(awk "BEGIN {printf \"%.1f GiB\", ($total_src_bytes - $total_dst_bytes)/1073741824}")
        info "  Space saved:     $saved"
    fi
}

# =====================================================================
# Cleanup Mode (--cleanup)
# =====================================================================

do_cleanup() {
    log "=== Cleanup: Source images from completed migrations ==="
    echo

    if [ ! -d "$STATE_DIR" ]; then
        info "No migration state directory found. Nothing to clean up."
        return 0
    fi

    local total_found=0
    local total_bytes=0
    local -a cleanup_files=()
    local -a cleanup_hvs=()

    for state_file in "$STATE_DIR"/*.conf; do
        [ -f "$state_file" ] || continue

        # Load state
        # shellcheck source=/dev/null
        source "$state_file"

        local v_uuid="${UUID}"
        local v_src_path="${SRC_PATH}"
        local v_hv_id="${HV_ID}"
        local v_hv_name="${HV_NAME:-unknown}"

        # Check hypervisor is configured
        if [ -z "${HV_IPS[$v_hv_id]+x}" ]; then
            continue
        fi

        local hv_ip="${HV_IPS[$v_hv_id]}"

        # Find source files that still exist
        local src_files
        src_files=$(hv_ssh "$hv_ip" "ls -1 ${v_src_path}/${v_uuid}*.img 2>/dev/null" || true)

        if [ -z "$src_files" ]; then
            continue
        fi

        while read -r src_file; do
            [ -z "$src_file" ] && continue
            local fsize
            fsize=$(hv_ssh "$hv_ip" "stat -c%s '$src_file' 2>/dev/null" || echo "0")
            local fsize_h
            fsize_h=$(awk "BEGIN {printf \"%.1f GiB\", $fsize/1073741824}")

            info "  $v_hv_name: $src_file ($fsize_h)"
            cleanup_files+=("$src_file")
            cleanup_hvs+=("$hv_ip")
            ((total_found++))
            total_bytes=$((total_bytes + fsize))
        done <<< "$src_files"
    done

    if [ "$total_found" -eq 0 ]; then
        log "No source images found to clean up."
        return 0
    fi

    local total_h
    total_h=$(awk "BEGIN {printf \"%.1f GiB\", $total_bytes/1073741824}")
    echo
    log "Found $total_found source image(s) totaling $total_h"

    if $DRY_RUN; then
        info "[DRY-RUN] Would remove $total_found files ($total_h)"
        return 0
    fi

    confirm "Remove $total_found source image(s) ($total_h)?" || return 0

    local removed=0
    for i in "${!cleanup_files[@]}"; do
        local f="${cleanup_files[$i]}"
        local h="${cleanup_hvs[$i]}"
        info "  Removing: $f"
        if hv_ssh "$h" "rm -f '$f'" 2>/dev/null; then
            ((removed++))
        else
            warn "  Failed to remove: $f"
        fi
    done

    log "Removed $removed of $total_found source images"
}

# =====================================================================
# Main Entry Point
# =====================================================================

main() {
    parse_args "$@"

    # Setup mode runs standalone — no config needed
    if $DO_SETUP; then
        # Ensure log directory exists
        mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
        touch "$LOG_FILE" 2>/dev/null || true

        # Discover DB credentials for setup
        discover_db_credentials || true
        do_setup
        exit 0
    fi

    # All other modes require config
    if ! load_config; then
        err "No config file found at $CONFIG_FILE"
        err "Run '$0 --setup' first to configure migration parameters."
        exit 1
    fi

    # Discover DB credentials (config may override via sourcing)
    if [ -z "$DB_USER" ] || [ -z "$DB_NAME" ]; then
        if ! discover_db_credentials; then
            err "Cannot discover VirtFusion DB credentials."
            err "Ensure VF .env exists at $VF_ENV_PATH or set DB_* in config."
            exit 1
        fi
    fi

    # Ensure log file is writable
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    touch "$LOG_FILE" 2>/dev/null || true

    # Ensure state directory exists
    mkdir -p "$STATE_DIR" 2>/dev/null || true

    # Lock file to prevent concurrent runs (parallel is handled internally)
    local LOCK_FILE="/var/run/vf-storage-migrate.lock"
    exec 200>"$LOCK_FILE"
    if ! flock -n 200; then
        err "Another migration is already running (lock: $LOCK_FILE)"
        exit 1
    fi

    # Route to the requested command
    if $DO_ROLLBACK; then
        local rb_uuid="${ROLLBACK_UUID:-$UUID}"
        if [ -z "$rb_uuid" ]; then
            err "Usage: $0 --rollback <uuid>"
            exit 1
        fi
        do_rollback "$rb_uuid"

    elif $DO_VERIFY; then
        do_verify

    elif $DO_REPORT; then
        do_report

    elif $DO_CLEANUP; then
        do_cleanup

    elif $BATCH_ALL; then
        preflight || exit 1
        echo
        do_batch

    elif [ -n "$UUID" ]; then
        # Single VM migration
        validate_uuid "$UUID" || exit 1

        # Run preflight on first use
        preflight || exit 1
        echo

        migrate_one "$UUID"

    else
        echo "Usage: $0 <uuid|--all|--setup|--verify|--report|--cleanup|--rollback <uuid>>"
        echo "Run '$0 --help' for full usage."
        exit 1
    fi
}

main "$@"
