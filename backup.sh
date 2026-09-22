#!/bin/bash

# Generic Restic Backup Script
# Usage: ./backup.sh [OPTIONS] <source_path> <repository>

set -euo pipefail

# Default values
RESTIC_PASSWORD_FILE="$HOME/.restic-password"
LOG_FILE=""
HEALTHCHECK_URL=""
KEEP_DAILY=7
KEEP_WEEKLY=4
KEEP_MONTHLY=6
KEEP_YEARLY=2
TAG_PREFIX=""
DRY_RUN=false
VERBOSE=false
EXCLUDE_CACHES=true
ONE_FILE_SYSTEM=true
COMPRESSION="auto"

# Function to display usage
usage() {
    cat << EOF
Usage: $0 [OPTIONS] <source_path> <repository>

Generic backup script using Restic for any folder and repository.

REQUIRED ARGUMENTS:
    source_path         Path to backup (e.g., /home/user/documents)
    repository          Restic repository URL (e.g., sftp:user@host:/path)

OPTIONS:
    -p, --password-file FILE    Password file path (default: ~/.restic-password)
    -l, --log-file FILE         Log file path (default: no logging)
    -h, --healthcheck URL       Healthchecks.io ping URL
    -t, --tag TAG               Additional tag for backup (can be used multiple times)
    --tag-prefix PREFIX         Prefix for auto-generated tags (default: none)
    
    RETENTION POLICY:
    --keep-daily N              Keep N daily snapshots (default: 7)
    --keep-weekly N             Keep N weekly snapshots (default: 4)
    --keep-monthly N            Keep N monthly snapshots (default: 6)
    --keep-yearly N             Keep N yearly snapshots (default: 2)
    
    BACKUP OPTIONS:
    -e, --exclude PATTERN       Exclude files/dirs matching PATTERN (can be used multiple times,
                                same syntax as restic --exclude)
    --no-exclude-caches         Don't exclude cache directories
    --no-one-file-system        Allow crossing filesystem boundaries
    --compression LEVEL         Compression level: auto|max|off|fastest|better (default: auto)
    
    OTHER OPTIONS:
    --dry-run                   Show what would be backed up without doing it
    -v, --verbose              Enable verbose output
    --help                     Show this help message

EXAMPLES:
    # Basic backup
    $0 /home/user/music sftp:user@host:/backups/music
    
    # With custom retention and healthcheck
    $0 --keep-daily 14 --healthcheck https://hc-ping.com/uuid \\
       /var/www sftp:user@host:/backups/www
    
    # Multiple tags and custom log file
    $0 -t production -t database --tag-prefix server1 \\
       --log-file /var/log/backup.log \\
       /var/lib/mysql sftp:user@host:/backups/mysql

    # Exclude subdirectories from the backup
    $0 --exclude /srv/app/data/postgres --exclude "/srv/app/data/app/tmp" \\
       /srv/app sftp:user@host:/backups/app

ENVIRONMENT VARIABLES:
    RESTIC_PASSWORD_FILE    Alternative to --password-file
    RESTIC_PASSWORD         Direct password (not recommended)
    RESTIC_REPOSITORY       Alternative to repository argument

EOF
}

# Function to log messages
log_message() {
    local message="$(date '+%Y-%m-%d %H:%M:%S') - $1"
    
    if [ "$VERBOSE" = true ]; then
        echo "$message"
    fi
    
    if [ -n "$LOG_FILE" ]; then
        echo "$message" >> "$LOG_FILE"
    fi
}

# Function to send healthcheck ping
send_healthcheck() {
    local status="$1"
    local message="$2"
    
    if [ -z "$HEALTHCHECK_URL" ]; then
        [ "$VERBOSE" = true ] && echo "Healthcheck: $status - $message (no URL configured)"
        return
    fi
    
    case "$status" in
        "START")
            curl -fsS -m 10 --retry 3 "$HEALTHCHECK_URL/start" >/dev/null 2>&1 || true
            ;;
        "SUCCESS")
            curl -fsS -m 10 --retry 3 --data-raw "$message" "$HEALTHCHECK_URL" >/dev/null 2>&1 || true
            ;;
        "FAILED"|"WARNING")
            curl -fsS -m 10 --retry 3 --data-raw "$message" "$HEALTHCHECK_URL/fail" >/dev/null 2>&1 || true
            ;;
    esac
    
    [ "$VERBOSE" = true ] && echo "Healthcheck sent: $status - $message"
}

# Parse command line arguments
CUSTOM_TAGS=()
EXCLUDE_PATTERNS=()
POSITIONAL_ARGS=()

while [[ $# -gt 0 ]]; do
    case $1 in
        -p|--password-file)
            RESTIC_PASSWORD_FILE="$2"
            shift 2
            ;;
        -l|--log-file)
            LOG_FILE="$2"
            shift 2
            ;;
        -h|--healthcheck)
            HEALTHCHECK_URL="$2"
            shift 2
            ;;
        -t|--tag)
            CUSTOM_TAGS+=("$2")
            shift 2
            ;;
        --tag-prefix)
            TAG_PREFIX="$2"
            shift 2
            ;;
        --keep-daily)
            KEEP_DAILY="$2"
            shift 2
            ;;
        --keep-weekly)
            KEEP_WEEKLY="$2"
            shift 2
            ;;
        --keep-monthly)
            KEEP_MONTHLY="$2"
            shift 2
            ;;
        --keep-yearly)
            KEEP_YEARLY="$2"
            shift 2
            ;;
        -e|--exclude)
            EXCLUDE_PATTERNS+=("$2")
            shift 2
            ;;
        --no-exclude-caches)
            EXCLUDE_CACHES=false
            shift
            ;;
        --no-one-file-system)
            ONE_FILE_SYSTEM=false
            shift
            ;;
        --compression)
            case "$2" in
                auto|max|off|fastest|better)
                    COMPRESSION="$2"
                    ;;
                *)
                    echo "Error: Invalid compression value '$2'. Valid values: auto, max, off, fastest, better"
                    exit 1
                    ;;
            esac
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        --help)
            usage
            exit 0
            ;;
        -*)
            echo "Unknown option $1"
            usage
            exit 1
            ;;
        *)
            POSITIONAL_ARGS+=("$1")
            shift
            ;;
    esac
done

# Restore positional parameters
set -- "${POSITIONAL_ARGS[@]}"

# Check required arguments
if [ $# -lt 2 ]; then
    echo "Error: Missing required arguments"
    echo
    usage
    exit 1
fi

SOURCE_PATH="$1"
REPOSITORY="$2"

# Use environment variable as fallback for repository
if [ -n "${RESTIC_REPOSITORY:-}" ] && [ "$REPOSITORY" = "${RESTIC_REPOSITORY}" ]; then
    REPOSITORY="$RESTIC_REPOSITORY"
fi

# Use environment variable as fallback for password file
if [ -n "${RESTIC_PASSWORD_FILE:-}" ]; then
    RESTIC_PASSWORD_FILE="${RESTIC_PASSWORD_FILE}"
fi

# Validation
if [ ! -d "$SOURCE_PATH" ]; then
    echo "ERROR: Source path does not exist: $SOURCE_PATH"
    send_healthcheck "FAILED" "Source path not found: $SOURCE_PATH"
    exit 1
fi

if [ ! -f "$RESTIC_PASSWORD_FILE" ] && [ -z "${RESTIC_PASSWORD:-}" ]; then
    echo "ERROR: Restic password file not found: $RESTIC_PASSWORD_FILE"
    echo "       Set RESTIC_PASSWORD environment variable or provide valid password file"
    send_healthcheck "FAILED" "Restic password file not found: $RESTIC_PASSWORD_FILE"
    exit 1
fi

# Build restic command base
RESTIC_CMD="restic -r $REPOSITORY"
if [ -f "$RESTIC_PASSWORD_FILE" ]; then
    RESTIC_CMD="$RESTIC_CMD --password-file $RESTIC_PASSWORD_FILE"
fi
# Add compression as a global flag
RESTIC_CMD="$RESTIC_CMD --compression $COMPRESSION"

# Generate backup name from source path for tagging
BACKUP_NAME=$(basename "$SOURCE_PATH")
if [ -n "$TAG_PREFIX" ]; then
    BACKUP_NAME="${TAG_PREFIX}-${BACKUP_NAME}"
fi

# Build tag arguments
TAG_ARGS=()
TAG_ARGS+=("--tag" "$BACKUP_NAME")
TAG_ARGS+=("--tag" "$(date +%Y-%m)")

# Add custom tags
for tag in "${CUSTOM_TAGS[@]}"; do
    if [ -n "$TAG_PREFIX" ]; then
        TAG_ARGS+=("--tag" "${TAG_PREFIX}-${tag}")
    else
        TAG_ARGS+=("--tag" "$tag")
    fi
done

# Build backup command arguments
BACKUP_ARGS=()
if [ "$EXCLUDE_CACHES" = true ]; then
    BACKUP_ARGS+=("--exclude-caches")
fi
if [ "$ONE_FILE_SYSTEM" = true ]; then
    BACKUP_ARGS+=("--one-file-system")
fi
for pattern in "${EXCLUDE_PATTERNS[@]}"; do
    BACKUP_ARGS+=("--exclude" "$(printf '%q' "$pattern")")
done

log_message "Starting backup of $SOURCE_PATH to $REPOSITORY"
send_healthcheck "START" "Starting backup of $BACKUP_NAME"

# Pre-backup: Check repository connectivity
log_message "Checking repository connectivity..."
CONNECTIVITY_OUTPUT=""
if ! CONNECTIVITY_OUTPUT=$(eval "$RESTIC_CMD snapshots --last" 2>&1); then
    log_message "WARNING: Could not connect to repository or no snapshots exist yet"
    if [ "$VERBOSE" = true ]; then
        log_message "Connectivity check output: $CONNECTIVITY_OUTPUT"
    fi
fi

# Perform backup
if [ "$DRY_RUN" = true ]; then
    log_message "DRY RUN: Would backup $SOURCE_PATH"
    echo "Would run: $RESTIC_CMD backup \"$SOURCE_PATH\" ${TAG_ARGS[*]} ${BACKUP_ARGS[*]}"
    exit 0
fi

log_message "Creating backup snapshot..."
log_message "Running command: $RESTIC_CMD backup \"$SOURCE_PATH\" ${TAG_ARGS[*]} ${BACKUP_ARGS[*]}"

BACKUP_OUTPUT=""
BACKUP_SUCCESS=false

if [ "$VERBOSE" = true ]; then
    # Show progress in verbose mode
    if eval "$RESTIC_CMD backup \"$SOURCE_PATH\" ${TAG_ARGS[*]} ${BACKUP_ARGS[*]}"; then
        BACKUP_SUCCESS=true
    fi
else
    # Capture output for logging
    if BACKUP_OUTPUT=$(eval "$RESTIC_CMD backup \"$SOURCE_PATH\" ${TAG_ARGS[*]} ${BACKUP_ARGS[*]}" 2>&1); then
        BACKUP_SUCCESS=true
    fi
fi

if [ "$BACKUP_SUCCESS" = true ]; then
    log_message "Backup completed successfully"
    if [ "$VERBOSE" = true ] && [ -n "${BACKUP_OUTPUT:-}" ]; then
        echo "$BACKUP_OUTPUT"
    fi
    
    # Clean up old snapshots according to retention policy
    log_message "Applying retention policy..."
    FORGET_OUTPUT=""
    if FORGET_OUTPUT=$(eval "$RESTIC_CMD forget --tag $BACKUP_NAME --keep-daily $KEEP_DAILY --keep-weekly $KEEP_WEEKLY --keep-monthly $KEEP_MONTHLY --keep-yearly $KEEP_YEARLY --prune" 2>&1); then
        log_message "Retention policy applied successfully"
        
        # Get backup stats for healthcheck message
        BACKUP_STATS=""
        BACKUP_STATS=$(eval "$RESTIC_CMD stats --mode raw-data" 2>/dev/null | tail -n 3 | head -n 1 2>/dev/null || echo "Stats unavailable")
        send_healthcheck "SUCCESS" "Backup of $BACKUP_NAME completed successfully. Repository: $BACKUP_STATS"
    else
        log_message "WARNING: Backup succeeded but retention cleanup failed"
        if [ "$VERBOSE" = true ] && [ -n "$FORGET_OUTPUT" ]; then
            log_message "Retention error output: $FORGET_OUTPUT"
        fi
        send_healthcheck "WARNING" "Backup of $BACKUP_NAME succeeded but retention cleanup failed"
    fi
else
    log_message "ERROR: Backup failed"
    if [ -n "${BACKUP_OUTPUT:-}" ]; then
        log_message "Backup error output: $BACKUP_OUTPUT"
    fi
    send_healthcheck "FAILED" "Backup of $BACKUP_NAME failed - check logs for details"
    exit 1
fi

log_message "Backup process completed"
