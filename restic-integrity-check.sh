#!/bin/bash

# Generic Restic Repository Integrity Check Script
# Usage: ./restic-integrity-check.sh [OPTIONS] <repository>

set -euo pipefail

# Default values
RESTIC_PASSWORD_FILE="$HOME/.restic-password"
LOG_FILE=""
HEALTHCHECK_URL=""
READ_DATA=true
VERBOSE=false
DRY_RUN=false

# Restic exit code for "failed to lock repository" (restic >= 0.17.0)
RESTIC_EXIT_LOCK_FAILED=11

# Function to display usage
usage() {
    cat << EOF
Usage: $0 [OPTIONS] <repository>

Generic integrity check script for Restic repositories.

REQUIRED ARGUMENTS:
    repository              Restic repository URL (e.g., sftp:user@host:/path)

OPTIONS:
    -p, --password-file FILE    Password file path (default: ~/.restic-password)
    -l, --log-file FILE         Log file path (default: no logging)
    -h, --healthcheck URL       Healthchecks.io ping URL for monitoring
    
    CHECK OPTIONS:
    --no-read-data             Skip reading and verifying data blobs (faster)
    --read-data                Verify data blobs (default, more thorough)
    
    OTHER OPTIONS:
    --dry-run                  Show what would be checked without doing it
    -v, --verbose             Enable verbose output
    --help                    Show this help message

EXAMPLES:
    # Basic integrity check
    $0 sftp:user@host:/backups/music
    
    # With healthcheck monitoring and custom log
    $0 --healthcheck https://hc-ping.com/uuid \\
       --log-file /var/log/integrity-check.log \\
       sftp:user@host:/backups/documents
    
    # Quick check without reading data (faster)
    $0 --no-read-data --verbose \\
       local:/path/to/repo
    
    # Multiple repositories check (run separately)
    for repo in repo1 repo2 repo3; do
        $0 --verbose "sftp:user@host:/backups/\$repo"
    done

ENVIRONMENT VARIABLES:
    RESTIC_PASSWORD_FILE    Alternative to --password-file
    RESTIC_PASSWORD         Direct password (not recommended)
    RESTIC_REPOSITORY       Alternative to repository argument

NOTES:
    - The --read-data option (default) performs a thorough check by reading
      and verifying all data blobs. This is slower but more comprehensive.
    - Use --no-read-data for faster checks that only verify repository
      structure and metadata.
    - If the repository is locked, only stale locks (from dead processes or
      not refreshed for 30 minutes) are removed before retrying once. Locks
      held by running restic processes are never removed.
    - Exit codes: 0 = success, 1 = check failed or error occurred,
      11 = check could not run because the repository is locked

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
        "FAILED")
            curl -fsS -m 10 --retry 3 --data-raw "$message" "$HEALTHCHECK_URL/fail" >/dev/null 2>&1 || true
            ;;
    esac
    
    [ "$VERBOSE" = true ] && echo "Healthcheck sent: $status - $message"
}

# Function to remove stale repository locks
# Plain `restic unlock` (never --remove-all) only removes locks that restic
# considers stale: created on this host by a process that no longer exists, or
# not refreshed for 30 minutes. Running restic processes refresh their locks
# every 5 minutes, so locks held by live operations are never removed.
remove_stale_locks() {
    log_message "Repository is locked, removing stale locks (if any)..."
    local unlock_output=""
    if unlock_output=$(eval "$RESTIC_CMD unlock" 2>&1); then
        log_message "Unlock output: $unlock_output"
    else
        log_message "WARNING: Failed to remove stale locks: $unlock_output"
    fi
}

# Function to run a command, retrying once after removing stale locks if it
# failed only because the repository was locked
with_stale_lock_retry() {
    local status=0
    "$@" || status=$?
    if [ "$status" -eq "$RESTIC_EXIT_LOCK_FAILED" ]; then
        remove_stale_locks
        status=0
        "$@" || status=$?
    fi
    return "$status"
}

# Parse command line arguments
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
        --no-read-data)
            READ_DATA=false
            shift
            ;;
        --read-data)
            READ_DATA=true
            shift
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
if [ $# -lt 1 ]; then
    echo "Error: Missing required repository argument"
    echo
    usage
    exit 1
fi

REPOSITORY="$1"

# Use environment variable as fallback for repository
if [ -n "${RESTIC_REPOSITORY:-}" ] && [ "$REPOSITORY" = "${RESTIC_REPOSITORY}" ]; then
    REPOSITORY="$RESTIC_REPOSITORY"
fi

# Use environment variable as fallback for password file
if [ -n "${RESTIC_PASSWORD_FILE:-}" ]; then
    RESTIC_PASSWORD_FILE="${RESTIC_PASSWORD_FILE}"
fi

# Validation
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

# Generate repository name for logging/monitoring
REPO_NAME=$(echo "$REPOSITORY" | sed 's|.*/||' | sed 's|:.*||')
if [ -z "$REPO_NAME" ]; then
    REPO_NAME="repository"
fi

log_message "Starting integrity check for repository: $REPOSITORY"
send_healthcheck "START" "Starting integrity check for $REPO_NAME"

# Build check command arguments
CHECK_ARGS=()
if [ "$READ_DATA" = true ]; then
    CHECK_ARGS+=("--read-data")
    log_message "Performing thorough check with data verification (this may take a while)"
else
    log_message "Performing quick check without data verification"
fi

# Test repository connectivity first
log_message "Testing repository connectivity..."
CONNECTIVITY_OUTPUT=""
if ! CONNECTIVITY_OUTPUT=$(eval "$RESTIC_CMD snapshots --no-lock --latest 1" 2>&1); then
    log_message "ERROR: Cannot connect to repository or repository is empty"
    if [ "$VERBOSE" = true ]; then
        log_message "Connectivity error: $CONNECTIVITY_OUTPUT"
    fi
    send_healthcheck "FAILED" "Cannot connect to repository $REPO_NAME"
    exit 1
fi

# Perform integrity check
if [ "$DRY_RUN" = true ]; then
    log_message "DRY RUN: Would check repository $REPOSITORY"
    echo "Would run: $RESTIC_CMD check ${CHECK_ARGS[*]}"
    exit 0
fi

log_message "Running repository integrity check..."
START_TIME=$(date +%s)

CHECK_OUTPUT=""
CHECK_EXIT=0

run_check() {
    if [ "$VERBOSE" = true ]; then
        # Show progress in verbose mode
        eval "$RESTIC_CMD check ${CHECK_ARGS[*]}"
    else
        # Capture output for logging
        CHECK_OUTPUT=$(eval "$RESTIC_CMD check ${CHECK_ARGS[*]}" 2>&1)
    fi
}

with_stale_lock_retry run_check || CHECK_EXIT=$?

if [ "$CHECK_EXIT" -eq 0 ]; then
    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))
    
    log_message "Repository integrity check completed successfully in ${DURATION} seconds"
    
    # Get repository stats for the success message
    REPO_STATS=""
    if STATS_OUTPUT=$(eval "$RESTIC_CMD stats" 2>/dev/null); then
        REPO_STATS=$(echo "$STATS_OUTPUT" | grep -E "(Total Size|Total File Count)" | head -2 | tr '\n' ', ' | sed 's/, $//' || echo "Repository stats available")
        if [ -z "$REPO_STATS" ]; then
            REPO_STATS="Repository stats available"
        fi
    else
        REPO_STATS="Repository stats unavailable"
    fi
    
    SUCCESS_MSG="Integrity check passed for $REPO_NAME in ${DURATION}s. $REPO_STATS"
    send_healthcheck "SUCCESS" "$SUCCESS_MSG"
    
    # Additional verbose output
    if [ "$VERBOSE" = true ]; then
        echo "=== Check Summary ==="
        echo "Repository: $REPOSITORY"
        echo "Duration: ${DURATION} seconds"
        echo "Data verification: $([ "$READ_DATA" = true ] && echo "enabled" || echo "disabled")"
        echo "Result: PASSED"
        if [ -n "$REPO_STATS" ] && [ "$REPO_STATS" != "Repository stats unavailable" ]; then
            echo "Stats: $REPO_STATS"
        fi
        [ -n "$CHECK_OUTPUT" ] && echo -e "\nDetailed output:\n$CHECK_OUTPUT"
    fi
elif [ "$CHECK_EXIT" -eq "$RESTIC_EXIT_LOCK_FAILED" ]; then
    # The check never ran, so this says nothing about repository integrity
    ERROR_MSG="Integrity check for $REPO_NAME could not run: repository is locked by another active restic process (not a corruption issue). Re-run once it finishes."
    log_message "$ERROR_MSG"
    send_healthcheck "FAILED" "$ERROR_MSG"

    if [ "$VERBOSE" = true ]; then
        echo "=== Check Summary ==="
        echo "Repository: $REPOSITORY"
        echo "Result: NOT RUN (repository locked)"
        echo "Check active locks with: restic -r $REPOSITORY list locks --no-lock"
        [ -n "$CHECK_OUTPUT" ] && echo -e "\nError output:\n$CHECK_OUTPUT"
    fi

    exit "$RESTIC_EXIT_LOCK_FAILED"
else
    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))
    
    ERROR_MSG="CRITICAL: Repository integrity check failed for $REPO_NAME after ${DURATION}s - backup repository may be corrupted!"
    log_message "$ERROR_MSG"
    send_healthcheck "FAILED" "$ERROR_MSG"
    
    if [ "$VERBOSE" = true ]; then
        echo "=== Check Summary ==="
        echo "Repository: $REPOSITORY"
        echo "Duration: ${DURATION} seconds"
        echo "Data verification: $([ "$READ_DATA" = true ] && echo "enabled" || echo "disabled")"
        echo "Result: FAILED"
        echo "WARNING: Repository may be corrupted! Check logs and consider running 'restic repair' if needed."
        [ -n "$CHECK_OUTPUT" ] && echo -e "\nError output:\n$CHECK_OUTPUT"
    fi
    
    exit 1
fi

log_message "Integrity check process completed successfully"
