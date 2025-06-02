#!/bin/bash

# JellyMac/bin/handle_magnet_link.sh
# Handles adding a magnet link to the Transmission torrent client.
# This script is specifically designed for use with 'transmission-remote'.
# Utilizes functions from lib/common_utils.sh.

# --- Strict Mode & Globals ---
set -euo pipefail # Enable strict mode for better error handling

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "${SCRIPT_DIR}/../lib" && pwd)" # Assumes lib is one level up from bin

#==============================================================================
# TEMPORARY FILE MANAGEMENT
#==============================================================================
# Global array to track temporary files created during script execution
_SCRIPT_TEMP_FILES_TO_CLEAN=()

# Function: _cleanup_script_temp_files
# Description: Cleans up temporary files created during script execution
# Parameters: None
# Returns: None
# Side Effects: Removes all tracked temporary files and clears the tracking array
_cleanup_script_temp_files() {
    # shellcheck disable=SC2128 # We want to check array length
    # shellcheck disable=SC2317 
    if [[ ${#_SCRIPT_TEMP_FILES_TO_CLEAN[@]} -gt 0 ]]; then
        log_debug_event "Torrent" "EXIT trap: Cleaning up temporary files (${#_SCRIPT_TEMP_FILES_TO_CLEAN[@]})..."
        local temp_file_to_clean
        for temp_file_to_clean in "${_SCRIPT_TEMP_FILES_TO_CLEAN[@]}"; do
            if [[ -n "$temp_file_to_clean" && -e "$temp_file_to_clean" ]]; then
                rm -f "$temp_file_to_clean"
                log_debug_event "Torrent" "EXIT trap: Removed '$temp_file_to_clean'"
            fi
        done
    fi
    # shellcheck disable=SC2317
    _SCRIPT_TEMP_FILES_TO_CLEAN=()
}
# Trap for this script's specific temp files.
trap _cleanup_script_temp_files EXIT SIGINT SIGTERM

#==============================================================================
# LIBRARY SOURCING AND CONFIGURATION
#==============================================================================

# --- Source Libraries ---
# Source order matters: logging -> config -> common -> others
# shellcheck source=../lib/logging_utils.sh
# shellcheck disable=SC1091
source "${LIB_DIR}/logging_utils.sh"
# shellcheck source=../lib/jellymac_config.sh
# shellcheck disable=SC1091
source "${LIB_DIR}/jellymac_config.sh" # Sources JELLYMAC_PROJECT_ROOT and all other configs

# --- Variable Initialization for set -u compatibility ---
TRANSMISSION_REMOTE_HOST="${TRANSMISSION_REMOTE_HOST:-}" 
TRANSMISSION_REMOTE_AUTH="${TRANSMISSION_REMOTE_AUTH:-}"
TORRENT_CLIENT_CLI_PATH="${TORRENT_CLIENT_CLI_PATH:-}"

# shellcheck source=../lib/common_utils.sh
# shellcheck disable=SC1091
source "${LIB_DIR}/common_utils.sh" # For find_executable, record_transfer_to_history, play_sound_notification

# --- Log Level & Prefix Initialization ---
# SCRIPT_CURRENT_LOG_LEVEL is set by logging_utils.sh based on LOG_LEVEL from config
# Use standard logging functions with "Torrent" module for 🧲 emoji branding

#==============================================================================
# MAGNET LINK PROCESSING FUNCTIONS
#==============================================================================

# Function: main
# Description: Main entry point for magnet link processing - validates magnet URL format,
#              connects to Transmission daemon, and adds magnet link to download queue
# Parameters:
#   $1 - Magnet URL to process (must start with magnet:?xt=urn:btih:)
# Returns: 
#   0 - Success (link added or duplicate handled)
#   1 - Failure (invalid format, connection error, or processing error)
# Side Effects: Adds magnet link to Transmission, records history, sends notifications

# --- Argument Validation ---
if [[ $# -ne 1 ]]; then
    log_error_event "Torrent" "Usage: $SCRIPT_NAME <magnet_url>"
    exit 1
fi
MAGNET_URL="$1" # Script argument, global to this script's execution

log_user_start "Torrent" "🧲 Processing magnet link..."

# Basic magnet link validation
if ! [[ "$MAGNET_URL" =~ ^magnet:\?xt=urn:btih:[a-zA-Z0-9]{32,} ]]; then
    log_error_event "Torrent" "Invalid magnet link format provided: '${MAGNET_URL:0:100}...'"
    exit 1
fi
log_debug_event "Torrent" "Received Magnet link: ${MAGNET_URL:0:70}..."

# --- Pre-flight Checks ---
if [[ -z "$TRANSMISSION_REMOTE_HOST" ]]; then # From combined.conf.sh
    log_error_event "Torrent" "TRANSMISSION_REMOTE_HOST is not set in the configuration. Cannot connect to Transmission."
    exit 1
fi

# Determine Transmission CLI executable path using find_executable from common_utils.sh
# TORRENT_CLIENT_CLI_PATH is from combined.conf.sh
TRANSMISSION_CLI_EXECUTABLE=$(find_executable "transmission-remote" "${TORRENT_CLIENT_CLI_PATH:-}")
# find_executable (from common_utils.sh) will exit the script if transmission-remote is not found.

log_debug_event "Torrent" "Using Transmission CLI: $TRANSMISSION_CLI_EXECUTABLE"

# --- Add Magnet Link to Transmission ---
log_user_progress "Torrent" "📡 Connecting to Transmission..."

# Use an array for transmission-remote arguments for safety with special characters
declare -a transmission_remote_args=() 
transmission_remote_args[${#transmission_remote_args[@]}]="$TRANSMISSION_REMOTE_HOST" # Server address:port

if [[ -n "$TRANSMISSION_REMOTE_AUTH" ]]; then # Expected format: "username:password", from combined.conf.sh
    transmission_remote_args[${#transmission_remote_args[@]}]="--auth"
    transmission_remote_args[${#transmission_remote_args[@]}]="$TRANSMISSION_REMOTE_AUTH"
fi

transmission_remote_args[${#transmission_remote_args[@]}]="--add"
transmission_remote_args[${#transmission_remote_args[@]}]="$MAGNET_URL" # The magnet link itself
# Crucially, ensure Transmission client is configured to download completed files to DROP_FOLDER.
# This script does not specify a download directory, relying on Transmission's global settings.

log_debug_event "Torrent" "Executing command: $TRANSMISSION_CLI_EXECUTABLE ${transmission_remote_args[*]}"

# Capture stdout and stderr for better error reporting and success message parsing
# These temp files are local to this script execution.
TR_STDOUT_LOG_FILE=$(mktemp "${SCRIPT_DIR}/.tr_stdout.XXXXXX") # SCRIPT_DIR is bin/
_SCRIPT_TEMP_FILES_TO_CLEAN[${#_SCRIPT_TEMP_FILES_TO_CLEAN[@]}]="$TR_STDOUT_LOG_FILE"

TR_STDERR_LOG_FILE=$(mktemp "${SCRIPT_DIR}/.tr_stderr.XXXXXX")
_SCRIPT_TEMP_FILES_TO_CLEAN[${#_SCRIPT_TEMP_FILES_TO_CLEAN[@]}]="$TR_STDERR_LOG_FILE"

set +e # Temporarily disable exit on error to capture return code and output
"$TRANSMISSION_CLI_EXECUTABLE" "${transmission_remote_args[@]}" > "$TR_STDOUT_LOG_FILE" 2> "$TR_STDERR_LOG_FILE"
TR_EXIT_CODE=$? # Capture exit code immediately
set -e # Re-enable exit on error

stdout_output=$(cat "$TR_STDOUT_LOG_FILE")
stderr_output=$(cat "$TR_STDERR_LOG_FILE")
# Temp files are cleaned by this script's EXIT trap

if [[ $TR_EXIT_CODE -ne 0 ]]; then
    # Check specifically for connection errors
    if echo "$stdout_output$stderr_output" | grep -qE -i "connection refused|couldn't connect|failed to connect|connection timed out"; then
        log_error_event "Torrent" "Failed to connect to Transmission daemon at ${TRANSMISSION_REMOTE_HOST:-localhost:9091}"
        log_user_info "Torrent" "➡️ To start Transmission daemon: brew services start transmission"
        log_user_info "Torrent" "➡️ To check daemon status: brew services info transmission" 
        
        # Show notification if enabled
        if [[ "${ENABLE_DESKTOP_NOTIFICATIONS:-false}" == "true" && "$(uname)" == "Darwin" ]]; then
            send_desktop_notification "Transmission Connection Error" "Transmission daemon is not running. Magnet link handling failed."
        fi
        
        exit 1
    else
        # Format error message for other types of errors
        error_message="Failed to add magnet link (Exit Code: $TR_EXIT_CODE)."
        [[ -n "$stdout_output" ]] && error_message+=" Stdout: $stdout_output."
        [[ -n "$stderr_output" ]] && error_message+=" Stderr: $stderr_output."

        # Check for "duplicate torrent" or similar messages which we might treat as non-fatal
        if echo "$stdout_output$stderr_output" | grep -qE -i "duplicate torrent|torrent is already there"; then
            log_warn_event "Torrent" "Magnet link appears to be a duplicate in Transmission or already added. Message: '${stdout_output}${stderr_output}'"
            # Successful outcome for the watcher, as the torrent is effectively "handled"
        elif echo "$stdout_output$stderr_output" | grep -qE -i "torrent added"; then 
            # Sometimes success message comes with non-zero code if there are other warnings
            log_user_complete "Torrent" "🧲 Torrent added to queue (with warnings)"
        else
            log_error_event "Torrent" "$error_message"
            exit 1
        fi
    fi
else
    log_user_complete "Torrent" "🧲 Torrent added to queue"
fi

# --- Post-Action ---
# Record the successful transfer in history using common_utils.sh
# This runs if exit code was 0, or if it was a non-fatal non-zero (like duplicate)
history_log_entry="Magnet Added: ${MAGNET_URL:0:70}..."
record_transfer_to_history "$history_log_entry" || log_warn_event "Torrent" "Failed to record Magnet link in history."

# Notifications (macOS only)
if [[ "$(uname)" == "Darwin" ]]; then
    magnet_identifier="${MAGNET_URL:20:20}" # Get a short part of the hash for display
    notification_text="Link for ...${magnet_identifier}... sent to Transmission."
    safe_message=$(echo "$notification_text" | sed 's/\\/\\\\/g; s/"/\\"/g' | head -c 200)


    if [[ "${ENABLE_DESKTOP_NOTIFICATIONS:-false}" == "true" ]]; then # From jellymac_config.sh
      send_desktop_notification "JellyMac - Torrent" "$safe_message"
    fi
    
    # Use the centralized sound notification function
    # play_sound_notification "task_success" "$SCRIPT_NAME"
fi
# Use the existing TRANSMISSION_REMOTE_HOST config for web interface URL
log_user_info "Torrent" "📊 Track progress at: http://${TRANSMISSION_REMOTE_HOST}/transmission/web/"
log_user_complete "Torrent" "✅ Magnet link processing completed successfully"
exit 0 # Ensure successful exit if reached here (covers successful add and handled duplicates/warnings)
