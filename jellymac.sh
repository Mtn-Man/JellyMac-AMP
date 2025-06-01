#!/bin/bash
#==============================================================================
# JellyMac Watcher/jellymac.sh
#==============================================================================
# Main watcher script for JellyMac Media Automator.
#
# Purpose:
# - Monitors clipboard for YouTube links and magnet URLs
# - Watches DROP_FOLDER for new media files/folders
# - Launches appropriate processing scripts for each media type
# - Manages concurrent processing of multiple media items if desired
# - Can fully automate the media acquisition pipeline for Jellyfin users (or Plex/Emby)
#
# Author: Eli Sher (Mtn_Man)
# Version: v0.2.1
# Last Updated: 2025-05-26
# License: MIT Open Source

# --- Set Terminal Title ---
printf "\033]0;JellyMac\007"

# --- Strict Mode ---
set -eo pipefail # Exit on error, and error on undefined vars (via pipefail implicitly for commands)

# --- Adjust PATH for macOS Homebrew ---
# Prepend Homebrew's default binary path for Apple Silicon Macs (and common for Intel)
# This helps ensure commands installed via Homebrew (like flock) are found.
if [[ "$(uname)" == "Darwin" ]]; then
    export PATH="/opt/homebrew/bin:$PATH"
    # For older Intel Macs, Homebrew might be in /usr/local/bin. instead
    # If /opt/homebrew/bin doesn't exist or flock is still not found,
    # you might need to add /usr/local/bin as well or ensure your
    # .zshrc/.bash_profile correctly sets the PATH for all shell sessions.
    # Example: export PATH="/usr/local/bin:$PATH"
fi

# --- Project Root Directory ---
JELLYMAC_PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
export JELLYMAC_PROJECT_ROOT
SCRIPT_DIR="$JELLYMAC_PROJECT_ROOT" # Alias for clarity

# --- State Directory ---
STATE_DIR="${SCRIPT_DIR}/.state" # For lock files, temporary scan files etc.

# --- Source Essential Libraries (Order Matters) ---
# 1. Logging Utilities (provides primitive log functions)
# shellcheck source=lib/logging_utils.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/logging_utils.sh"

# 2. Configuration Setup - Handle missing config file
CONFIG_FILE_NAME="jellymac_config.sh"
CONFIG_PATH="${SCRIPT_DIR}/lib/${CONFIG_FILE_NAME}"
EXAMPLE_PATH="${SCRIPT_DIR}/lib/jellymac_config.example.sh"

# Auto-setup configuration if needed
if [[ ! -f "$CONFIG_PATH" ]]; then
    if [[ -f "$EXAMPLE_PATH" ]]; then
        log_user_info "JELLYMAC_SETUP" "No configuration found."
        log_user_info "JELLYMAC_SETUP" ""
        log_user_info "JELLYMAC_SETUP" "🚀 First time setup - Would you like to create a config file with default settings?"
        log_user_info "JELLYMAC_SETUP" "   This will copy: jellymac_config.example.sh → jellymac_config.sh"
        log_user_info "JELLYMAC_SETUP" "   You can customize paths later by editing lib/jellymac_config.sh"
        log_user_info "JELLYMAC_SETUP" ""
        
        read -r -p "Create default config? (Y/n): " response
        
        case "$(echo "$response" | tr '[:upper:]' '[:lower:]')" in
            ""|y|yes)
                if cp "$EXAMPLE_PATH" "$CONFIG_PATH"; then
                    log_user_info "JELLYMAC_SETUP" "✅ Created jellymac_config.sh with default settings."
                    log_user_info "JELLYMAC_SETUP" "   Edit lib/jellymac_config.sh to customize paths for your setup."
                    log_user_info "JELLYMAC_SETUP" ""
                else
                    log_error_event "JELLYMAC_SETUP" "❌ Failed to create config file. Check permissions."
                    exit 1
                fi
                ;;
            *)
                log_user_info "JELLYMAC_SETUP" "Setup cancelled. Please create config manually:"
                log_user_info "JELLYMAC_SETUP" "   cd lib && cp jellymac_config.example.sh jellymac_config.sh"
                exit 1
                ;;
        esac
    else
        log_error_event "JELLYMAC_SETUP" "CRITICAL: Neither config file nor example found!"
        log_error_event "JELLYMAC_SETUP" "Expected files:"
        log_error_event "JELLYMAC_SETUP" "  - ${CONFIG_PATH}"
        log_error_event "JELLYMAC_SETUP" "  - ${EXAMPLE_PATH}"
        log_error_event "JELLYMAC_SETUP" "Please ensure JellyMac is properly installed."
        exit 1
    fi
fi

# Now source the config (either existing or newly created)
if [[ -f "$CONFIG_PATH" ]]; then
    # shellcheck source=lib/jellymac_config.sh
    # shellcheck disable=SC1091
    source "$CONFIG_PATH"
else
    log_error_event "JELLYMAC_SETUP" "CRITICAL: Config file still missing after setup attempt."
    exit 1
fi

# 3. Initialize SCRIPT_CURRENT_LOG_LEVEL (based on LOG_LEVEL from config)
case "$(echo "${LOG_LEVEL:-INFO}" | tr '[:lower:]' '[:upper:]')" in
    "DEBUG") SCRIPT_CURRENT_LOG_LEVEL=$LOG_LEVEL_DEBUG ;;
    "INFO")  SCRIPT_CURRENT_LOG_LEVEL=$LOG_LEVEL_INFO ;;
    "WARN")  SCRIPT_CURRENT_LOG_LEVEL=$LOG_LEVEL_WARN ;;
    "ERROR") SCRIPT_CURRENT_LOG_LEVEL=$LOG_LEVEL_ERROR ;;
    *)
        SCRIPT_CURRENT_LOG_LEVEL=$LOG_LEVEL_INFO
        # Use log_warn_event directly from logging_utils.sh as local log_warn isn't defined yet
        log_warn_event "[JELLYMAC_SETUP]" "LOG_LEVEL ('${LOG_LEVEL:-NOT SET}') is invalid in config. Defaulting to INFO."
        ;;
esac
export SCRIPT_CURRENT_LOG_LEVEL

# 4. Common Utilities (provides play_sound_notification, find_executable, etc.)
# shellcheck source=lib/common_utils.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common_utils.sh"

# 5. Doctor Utilities (Health Checks)
# shellcheck source=lib/doctor_utils.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/doctor_utils.sh"

# 6. Media Utilities (for determine_media_category by watcher if needed)
# shellcheck source=lib/media_utils.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/media_utils.sh"

# --- Paths to Helper Scripts in bin/ ---
HANDLE_YOUTUBE_SCRIPT="${SCRIPT_DIR}/bin/handle_youtube_link.sh"
HANDLE_MAGNET_SCRIPT="${SCRIPT_DIR}/bin/handle_magnet_link.sh"
PROCESS_MEDIA_ITEM_SCRIPT="${SCRIPT_DIR}/bin/process_media_item.sh"

# --- Local Logging Setup (File Logging & Rotation) ---
_WATCHER_LOG_PREFIX="JellyMac" # This is the unique prefix for jellymac.sh logs
CURRENT_LOG_FILE_PATH=""       # Path to the current log file
LAST_LOG_DATE_CHECKED=""       # Used to track if we need to create a new log file

#==============================================================================
# LOG FILE MANAGEMENT FUNCTIONS
#==============================================================================
# Functions for creating, rotating, and cleaning up log files

#==================================================================
# Function: _delete_old_logs
# Description: Deletes log files older than LOG_RETENTION_DAYS
# Parameters: None
# Returns: None
_delete_old_logs() {
    if [[ "${LOG_ROTATION_ENABLED:-false}" != "true" || -z "$LOG_DIR" || -z "$LOG_FILE_BASENAME" || -z "$LOG_RETENTION_DAYS" || "$LOG_RETENTION_DAYS" -lt 1 ]]; then
        return
    fi
    
    local retention_days_for_find=$((LOG_RETENTION_DAYS - 1))
    [[ "$retention_days_for_find" -lt 0 ]] && retention_days_for_find=0
    
    if [[ ! -d "$LOG_DIR" ]]; then
        return
    fi
    
    local old_log_count
    old_log_count=$(find "$LOG_DIR" -name "${LOG_FILE_BASENAME}_*.log" -type f -mtime +"$retention_days_for_find" -print 2>/dev/null | wc -l)
    
    if [[ "$old_log_count" -gt 0 ]]; then
        find "$LOG_DIR" -name "${LOG_FILE_BASENAME}_*.log" -type f -mtime +"$retention_days_for_find" -delete
    fi
}
#=================================================================

#==============================================================================
# Function: _ensure_log_file_updated
# Description: Creates or updates the log file path based on current date
# Parameters: None
# Returns: None
# Side Effects: Updates CURRENT_LOG_FILE_PATH and LAST_LOG_DATE_CHECKED globals
#==============================================================================
_ensure_log_file_updated() {
    if [[ "${LOG_ROTATION_ENABLED:-false}" != "true" || -z "$LOG_DIR" || -z "$LOG_FILE_BASENAME" ]]; then
        CURRENT_LOG_FILE_PATH=""
        return
    fi
    
    local current_date; current_date=$(date +%F)
    if [[ "$current_date" != "$LAST_LOG_DATE_CHECKED" || ! -f "$CURRENT_LOG_FILE_PATH" ]]; then
        LAST_LOG_DATE_CHECKED="$current_date"
        CURRENT_LOG_FILE_PATH="${LOG_DIR}/${LOG_FILE_BASENAME}_${current_date}.log"
    
        # Create log directory - succeed or exit
        mkdir -p "$LOG_DIR"
        local mkdir_exit_code=$?
        if [[ $mkdir_exit_code -ne 0 ]]; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') - CRITICAL WATCHER: Failed to create log directory '$LOG_DIR'. Check permissions and filesystem. Exiting." >&2
            exit 1
        fi
        _delete_old_logs
    fi
}
_ensure_log_file_updated # Initial setup call

#==============================================================================
# Function: _log_to_current_file
# Description: File-only logging helper for logging_utils.sh emoji-based functions
# Parameters:
#   $1: Required level number (LOG_LEVEL_DEBUG, LOG_LEVEL_INFO, etc.)
#   $2: Prefix string (includes emoji)
#   $3: Message string
# Returns: None
# Side Effects: Writes to CURRENT_LOG_FILE_PATH if file logging is enabled
# Dev Note: makes heavy use of shellcheck disable=SC2317 to prevent false positives, 
# since this is a helper for the emoji-based logging system in loggin_utils.sh.
#==============================================================================
_log_to_current_file() {
    # shellcheck disable=SC2317
    local required_level_num="$1"
    # shellcheck disable=SC2317
    local prefix="$2" 
    # shellcheck disable=SC2317
    local message="$3"
    # Only log if file logging is enabled and path is valid
    # shellcheck disable=SC2317
    if [[ "${LOG_ROTATION_ENABLED:-false}" != "true" || -z "$CURRENT_LOG_FILE_PATH" ]]; then
        return
    fi
    
    # Ensure log file path is current (handles rotation)
    # shellcheck disable=SC2317
    _ensure_log_file_updated
    
    # Convert numeric level to severity label for file
    # shellcheck disable=SC2317
    local severity_label
    # shellcheck disable=SC2317
    case "$required_level_num" in
        "$LOG_LEVEL_DEBUG") severity_label="DEBUG:" ;;
        "$LOG_LEVEL_INFO")  severity_label="" ;;
        "$LOG_LEVEL_WARN")  severity_label="WARN:" ;;
        "$LOG_LEVEL_ERROR") severity_label="ERROR:" ;;
        *)                  severity_label="LOG:" ;;
    esac
    
    # Construct file log message
    # shellcheck disable=SC2317
    local file_log_message
    # shellcheck disable=SC2317
    file_log_message="${prefix} $(date '+%Y-%m-%d %H:%M:%S') - ${severity_label} ${message}"
    
    # Write to file with flock protection (same pattern as existing code)
    # Use flock to ensure safe concurrent writes
    # shellcheck disable=SC2317
    if command -v flock >/dev/null 2>&1; then
        exec 200>>"$CURRENT_LOG_FILE_PATH"
        if flock -w 0.5 200; then
            echo "$file_log_message" >&200
            flock -u 200
        else
            echo "[FLOCK_TIMEOUT] $file_log_message" >> "$CURRENT_LOG_FILE_PATH"
        fi
        exec 200>&-
    else
        echo "$file_log_message" >> "$CURRENT_LOG_FILE_PATH"
    fi
}

# Define local log function for jellymac.sh using the modern emoji-based system
# shellcheck disable=SC2317
log_debug() { log_debug_event "JellyMac" "$1"; }


# --- Single Instance Lock ---
LOCK_FILE="${STATE_DIR}/jellymac.sh.lock"
_acquire_lock() {
    log_debug_event "JellyMac" "Attempting to acquire instance lock: $LOCK_FILE"
    if [[ ! -d "$STATE_DIR" ]]; then
        if ! mkdir -p "$STATE_DIR"; then
            # Use primitive echo for critical startup error
            echo "$(date '+%Y-%m-%d %H:%M:%S') - CRITICAL WATCHER: Failed to create state dir '$STATE_DIR'. Cannot acquire lock. Exiting." >&2
            exit 1;
        fi
        log_user_info "JellyMac" "State directory '$STATE_DIR' created."
    fi

    # 'flock' command availability is checked by perform_system_health_checks earlier.
    # If flock is not available, find_executable in doctor_utils.sh would have exited.
    exec 201>"$LOCK_FILE" # Open file descriptor 201 for flock.
    if ! flock -n 201; then 
        log_error_event "JellyMac" "Another instance of jellymac.sh is already running (Lock file: '$LOCK_FILE'). Exiting."
        exit 1
    fi
    log_debug_event "JellyMac" "Instance lock acquired: $LOCK_FILE"
}
_release_lock() {
    # shellcheck disable=SC2317
    log_debug_event "JellyMac" "Releasing instance lock: $LOCK_FILE"
    # shellcheck disable=SC2317
    if [[ -n "$LOCK_FILE" ]]; then 
        exec 201>&- # Close file descriptor
        # rm -f "$LOCK_FILE" # Optional: remove lock file, flock releases advisory lock anyway
        log_debug_event "JellyMac" "Instance lock released."
    fi
}

# --- Desktop Notification Function (macOS Only) ---
# Now handled by send_desktop_notification() in common_utils.sh

# --- Caffeinate and Process Management ---
CAFFEINATE_PROCESS_ID=""
CAFFEINATE_CMD_PATH="" 
_ACTIVE_PROCESSOR_INFO_STRING="" 
LAST_CLIPBOARD_CONTENT_YOUTUBE=""
LAST_CLIPBOARD_CONTENT_MAGNET=""
PBPASTE_CMD="" 
_SHUTDOWN_IN_PROGRESS="" 

#==============================================================================
# PROCESS MANAGEMENT FUNCTIONS
#==============================================================================
# Functions for managing child processes, cleanup operations, and graceful exit

# Function: _cleanup_jellymac_temp_files
# Description: Cleans up any temporary files created by the watcher
# Parameters: None
# Returns: None
_cleanup_jellymac_temp_files() {
    #shellcheck disable=SC2317
    log_debug_event "JellyMac" "Cleaning up jellymac.sh specific temp files..."
    #shellcheck disable=SC2317
    log_debug_event "JellyMac" "No specific jellymac.sh temp files to clean in this version beyond what functions manage themselves."
}

# Function: graceful_shutdown_and_cleanup
# Description: Main cleanup handler called when script exits (normal or interrupted)
# Parameters: None
# Returns: None (exits the script)
# Note: Registered as a trap for SIGINT, SIGTERM, and EXIT signals
# We make heavy use of shellcheck disable=SC2317 to prevent false positives in shutdown functions
graceful_shutdown_and_cleanup() {
    # Prevent duplicate execution
    #shellcheck disable=SC2317
    if [[ "$_SHUTDOWN_IN_PROGRESS" == "true" ]]; then
        return
    fi
    #shellcheck disable=SC2317
    _SHUTDOWN_IN_PROGRESS="true"
    # shellcheck disable=SC2317
    echo 
    # shellcheck disable=SC2317
    log_user_shutdown "JellyMac" "Exiting JellyMac..." 
    #shellcheck disable=SC2317
    if [[ -n "$CAFFEINATE_PROCESS_ID" ]] && ps -p "$CAFFEINATE_PROCESS_ID" > /dev/null; then
        log_user_info "JellyMac" "Stopping caffeinate (PID: $CAFFEINATE_PROCESS_ID)..."
        kill "$CAFFEINATE_PROCESS_ID" 2>/dev/null || log_warn_event "JellyMac" "Caffeinate PID $CAFFEINATE_PROCESS_ID not found or already exited."
    fi
    #shellcheck disable=SC2317
    log_debug_event "JellyMac" "Cleaning up any active child processes..."
    #shellcheck disable=SC2317
    local old_ifs="$IFS" 
    #shellcheck disable=SC2317
    IFS='|'
    # shellcheck disable=SC2317
    local script_name_killed 
    # shellcheck disable=SC2317
    set -f 
    # Bash 3.2 compatible: Use explicit string replacement then array assignment
    # shellcheck disable=SC2317
    local processor_string_modified
    # shellcheck disable=SC2317
    processor_string_modified="${_ACTIVE_PROCESSOR_INFO_STRING//|||/|}"
    # shellcheck disable=SC2317
    local p_info_array
    # shellcheck disable=SC2317
    read -ra p_info_array <<< "$processor_string_modified"
    # shellcheck disable=SC2317
    set +f 
    # shellcheck disable=SC2317
    IFS="$old_ifs"
    # shellcheck disable=SC2317
    local entry_count=${#p_info_array[@]}

    # shellcheck disable=SC2317
    if [[ $entry_count -gt 0 && $((entry_count % 4)) -eq 0 ]]; then
        for ((idx=0; idx<entry_count; idx+=4)); do
            local pid_to_kill="${p_info_array[idx]}"
            script_name_killed="$(basename "${p_info_array[idx+1]}")" 
            local item_killed="${p_info_array[idx+2]}"
            if [[ -n "$pid_to_kill" ]] && ps -p "$pid_to_kill" > /dev/null; then
                log_user_info "JellyMac" "  Terminating PID $pid_to_kill ($script_name_killed for '${item_killed:0:50}...')..."
                kill "$pid_to_kill" 2>/dev/null || log_warn_event "JellyMac" "  Failed to send SIGTERM to PID $pid_to_kill."
            fi
        done
    elif [[ -n "$_ACTIVE_PROCESSOR_INFO_STRING" ]]; then 
        log_warn_event "JellyMac" "Could not parse _ACTIVE_PROCESSOR_INFO_STRING for child process cleanup: '$_ACTIVE_PROCESSOR_INFO_STRING'"
    fi
    
    # shellcheck disable=SC2317
    _release_lock 
    
    # shellcheck disable=SC2317
    if command -v _cleanup_common_utils_temp_files >/dev/null 2>&1; then
        _cleanup_common_utils_temp_files 
    fi
    # shellcheck disable=SC2317
    _cleanup_jellymac_temp_files   

    # shellcheck disable=SC2317
    printf "\033]0;%s\007" "${SHELL##*/}" 
    # shellcheck disable=SC2317
    log_user_shutdown "JellyMac" "JellyMac shutdown complete. See ya next time! 👋" 
    # shellcheck disable=SC2317
    exit 0 
}
trap graceful_shutdown_and_cleanup SIGINT SIGTERM EXIT

# Function: manage_active_processors
# Description: Checks status of all running child processes and updates their tracking
# Parameters: None
# Returns: None
# Side Effects: Updates _ACTIVE_PROCESSOR_INFO_STRING, cleans up completed tasks
manage_active_processors() {
    [[ -z "$_ACTIVE_PROCESSOR_INFO_STRING" ]] && return 

    local still_running_string="" 
    local old_ifs="$IFS"; IFS='|'
    set -f 
    local processor_string_modified
    processor_string_modified="${_ACTIVE_PROCESSOR_INFO_STRING//|||/|}"
    local p_info_array
    read -ra p_info_array <<< "$processor_string_modified"
    set +f 
    IFS="$old_ifs"
    local entry_count=${#p_info_array[@]}

    if [[ $entry_count -eq 0 || $((entry_count % 4)) -ne 0 ]]; then
        if [[ -n "$_ACTIVE_PROCESSOR_INFO_STRING" ]]; then 
             log_warn_event "JellyMac" "manage_active_processors: _ACTIVE_PROCESSOR_INFO_STRING ('$_ACTIVE_PROCESSOR_INFO_STRING') is malformed. Clearing."
        fi
        _ACTIVE_PROCESSOR_INFO_STRING="" 
        return
    fi
    
    for ((idx=0; idx<entry_count; idx+=4)); do
        local pid="${p_info_array[idx]}"
        local script_full_path="${p_info_array[idx+1]}"
        local item_identifier="${p_info_array[idx+2]}" 
        local ts_launch="${p_info_array[idx+3]}"
        local script_basename; script_basename=$(basename "$script_full_path")

        if ps -p "$pid" > /dev/null; then 
            # Bash 3.2 compatible string concatenation
            if [[ -n "$still_running_string" ]]; then 
                still_running_string="${still_running_string}|||"
            fi 
            still_running_string="${still_running_string}${pid}|||${script_full_path}|||${item_identifier}|||${ts_launch}"
        else 
            local exit_status=255 
            if wait "$pid" >/dev/null 2>&1; then 
                 exit_status=$?
            else
                 log_debug_event "JellyMac" "manage_active_processors: wait for PID $pid failed or already reaped. Assuming finished."
            fi
            log_debug_event "JellyMac" "✅ Processor PID $pid ($script_basename for '${item_identifier:0:70}...') completed. Exit status: $exit_status."
            
        fi
    done
    _ACTIVE_PROCESSOR_INFO_STRING="$still_running_string" 
}

# Function: is_item_being_processed
# Description: Checks if a specific item is already being processed by any child process
# Parameters:
#   $1 - Full path to the item to check
# Returns:
#   0 - Item is being processed
#   1 - Item is not being processed
is_item_being_processed() {
    local item_to_check="$1"
    [[ -z "$_ACTIVE_PROCESSOR_INFO_STRING" ]] && return 1 

    local old_ifs="$IFS"; IFS='|'
    set -f 
    # Bash 3.2 compatible: Use explicit string replacement then array assignment
    local processor_string_modified
    processor_string_modified="${_ACTIVE_PROCESSOR_INFO_STRING//|||/|}"
    local p_info_array
    read -ra p_info_array <<< "$processor_string_modified"
    set +f 
    IFS="$old_ifs"
    local entry_count=${#p_info_array[@]}

    if [[ $entry_count -eq 0 || $((entry_count % 4)) -ne 0 ]]; then
        log_debug_event "JellyMac" "is_item_being_processed: malformed _ACTIVE_PROCESSOR_INFO_STRING. Checked for '$item_to_check'."
        return 1 
    fi
    for ((idx=0; idx<entry_count; idx+=4)); do
        if [[ "${p_info_array[idx+2]}" == "$item_to_check" ]]; then
            return 0 
        fi
    done
    return 1 
}

#==============================================================================
# MEDIA DETECTION AND PROCESSING FUNCTIONS
#==============================================================================
# Functions for detecting and processing media from various sources

# Function: _check_clipboard_youtube
# Description: Checks clipboard for YouTube URLs and processes them if found
# Parameters: None
# Returns: None
# Side Effects: Updates LAST_CLIPBOARD_CONTENT_YOUTUBE
_check_clipboard_youtube() {
    if [[ "${ENABLE_CLIPBOARD_YOUTUBE:-false}" != "true" || -z "$PBPASTE_CMD" ]]; then return; fi
    local current_cb_content
    current_cb_content=$("$PBPASTE_CMD" 2>/dev/null || echo "CLIPBOARD_READ_ERROR")
    if [[ "$current_cb_content" == "CLIPBOARD_READ_ERROR" ]]; then
        log_warn_event "JellyMac" "Failed to read clipboard for YouTube monitoring. 'pbpaste' might have failed."
        return
    fi

    if [[ "$current_cb_content" != "$LAST_CLIPBOARD_CONTENT_YOUTUBE" && -n "$current_cb_content" ]]; then
        LAST_CLIPBOARD_CONTENT_YOUTUBE="$current_cb_content" 
        local trimmed_cb; trimmed_cb="$(echo -E "${current_cb_content}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        # Bash 3.2 compatible: Use case statement instead of regex where possible
        case "$trimmed_cb" in
            https://www.youtube.com/watch\?v=*|https://youtu.be/*)
                log_user_info "JellyMac" "▶️ Detected YouTube URL: '${trimmed_cb:0:70}...'"
                play_sound_notification "input_detected" "$_WATCHER_LOG_PREFIX" 
                
                if "$HANDLE_YOUTUBE_SCRIPT" "$trimmed_cb"; then
                    log_debug_event "JellyMac" "✅ YouTube processing complete for: ${trimmed_cb:0:70}..."
                else
                    send_desktop_notification "JellyMac: YouTube Error" "Failed: ${trimmed_cb:0:60}..." "Basso"
                    log_warn_event "JellyMac" "❌ YouTube processing FAILED for: ${trimmed_cb:0:70}..."
                    log_warn_event "JellyMac" "Close JellyMac, run yt-dlp -u, restart JellyMac and try again."
                fi
                ;;
        esac
    fi
}

# Function: _check_clipboard_magnet
# Description: Checks clipboard for magnet links and processes them if found
# Parameters: None
# Returns: None
# Side Effects: Updates LAST_CLIPBOARD_CONTENT_MAGNET
_check_clipboard_magnet() {
    if [[ "${ENABLE_CLIPBOARD_MAGNET:-false}" != "true" || -z "$PBPASTE_CMD" ]]; then return; fi
    local current_cb_content
    current_cb_content=$("$PBPASTE_CMD" 2>/dev/null || echo "CLIPBOARD_READ_ERROR")
    if [[ "$current_cb_content" == "CLIPBOARD_READ_ERROR" ]]; then
        log_warn_event "JellyMac" "Failed to read clipboard for magnet link monitoring. 'pbpaste' might have failed."
        return
    fi

    if [[ "$current_cb_content" != "$LAST_CLIPBOARD_CONTENT_MAGNET" && -n "$current_cb_content" ]]; then
        LAST_CLIPBOARD_CONTENT_MAGNET="$current_cb_content" 
        local trimmed_cb; trimmed_cb="$(echo -E "${current_cb_content}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        # Bash 3.2 compatible: Use case statement instead of regex
        case "$trimmed_cb" in
            magnet:\?xt=urn:btih:*)
                log_user_info "JellyMac" "🧲 Detected Magnet URL: '${trimmed_cb:0:70}...'";
                play_sound_notification "input_detected" "$_WATCHER_LOG_PREFIX" 

                if "$HANDLE_MAGNET_SCRIPT" "$trimmed_cb"; then
                    log_debug_event "JellyMac" "✅ Magnet link processing appears successful for: ${trimmed_cb:0:70}..."
                    send_desktop_notification "JellyMac: Magnet" "Sent to client: ${trimmed_cb:0:60}..." 
                else
                    # Changed to log_warn to prevent watcher exit on single magnet failure
                    log_warn_event "JellyMac" "❌ Failed to process magnet link: ${trimmed_cb:0:70}... Check the logs for more details."; 
                fi
                ;;
        esac
    fi
}

# Function: process_drop_folder
# Description: Scans the DROP_FOLDER for new media files/folders and processes them
# Parameters: None
# Returns: None
# Side Effects: Launches child processes for media processing, updates _ACTIVE_PROCESSOR_INFO_STRING
process_drop_folder() {
    if [[ -z "$DROP_FOLDER" || ! -d "$DROP_FOLDER" ]]; then
        log_warn_event "JellyMac" "Drop Folder ('${DROP_FOLDER:-N/A}') not configured or found. Skipping scan."
        return
    fi
    log_debug_event "JellyMac" "Scanning Drop Folder: $DROP_FOLDER"
    local find_results_file 
    if [[ ! -d "$STATE_DIR" ]]; then 
        mkdir -p "$STATE_DIR" || { log_error_event "JellyMac" "Failed to create STATE_DIR '$STATE_DIR' for temp scan file. Cannot scan DROP_FOLDER."; exit 1; }
    fi
    find_results_file=$(mktemp "${STATE_DIR}/.drop_folder_scan.XXXXXX")
    
    find "$DROP_FOLDER" -mindepth 1 -maxdepth 1 \( -type f -o -type d \) -print0 > "$find_results_file"
    
    while IFS= read -r -d $'\0' item_path; do
        [[ -z "$item_path" ]] && continue 

        local item_basename; item_basename=$(basename "$item_path")

        # Bash 3.2 compatible: Use case statement instead of regex
        case "$item_basename" in
            .DS_Store|desktop.ini|.stfolder|.stversions|.localized|._*|*.part|*.crdownload)
                log_debug_event "JellyMac" "Skipping common/temp file in DROP_FOLDER: '$item_basename'"; continue
                ;;
        esac

        if is_item_being_processed "$item_path"; then
            log_debug_event "JellyMac" "Item '$item_basename' (DROP_FOLDER) already processing. Skipping."; continue
        fi

        log_user_info "JellyMac" "Checking stability for an item in your Drop Folder: '$item_basename'"
        if ! wait_for_file_stability "$item_path" "${STABLE_CHECKS_DROP_FOLDER:-3}" "${STABLE_SLEEP_INTERVAL_DROP_FOLDER:-10}"; then
            log_debug_event "JellyMac" "Item '$item_basename' (DROP_FOLDER) not stable. Will re-check next cycle."; continue
        fi
        log_user_info "JellyMac" "✅ Item '$item_basename' (DROP_FOLDER) is stable."

        manage_active_processors 

        local old_ifs="$IFS"; IFS='|'
        set -f 
        # Bash 3.2 compatible: Use explicit string replacement then array assignment
        local processor_string_modified
        processor_string_modified="${_ACTIVE_PROCESSOR_INFO_STRING//|||/|}"
        local p_array_temp
        read -ra p_array_temp <<< "$processor_string_modified"
        set +f 
        IFS="$old_ifs"
        local p_count=$(( ${#p_array_temp[@]} / 4 )) 

        if [[ "$p_count" -lt "${MAX_CONCURRENT_PROCESSORS:-2}" ]]; then
            local item_type_for_processor="generic_file"; if [[ -d "$item_path" ]]; then item_type_for_processor="media_folder"; fi
            
            local category_hint_for_processor
            category_hint_for_processor=$(determine_media_category "$item_basename") 
            if [[ "$category_hint_for_processor" != "Movies" && "$category_hint_for_processor" != "Shows" ]]; then
                category_hint_for_processor="" 
            fi

            log_user_info "JellyMac" "🚀 Launching media processor for '$item_basename'. Type: $item_type_for_processor, Hint: '$category_hint_for_processor'"
            play_sound_notification "input_detected" "$_WATCHER_LOG_PREFIX" 

            local ts_launch; ts_launch=$(date +%s)
            "$PROCESS_MEDIA_ITEM_SCRIPT" "$item_type_for_processor" "$item_path" "$category_hint_for_processor" & 
            local child_pid=$! 

            # Bash 3.2 compatible string concatenation
            if [[ -n "$_ACTIVE_PROCESSOR_INFO_STRING" ]]; then 
                _ACTIVE_PROCESSOR_INFO_STRING="${_ACTIVE_PROCESSOR_INFO_STRING}|||"
            fi
            _ACTIVE_PROCESSOR_INFO_STRING="${_ACTIVE_PROCESSOR_INFO_STRING}${child_pid}|||${PROCESS_MEDIA_ITEM_SCRIPT}|||${item_path}|||${ts_launch}"
            
            log_user_info "JellyMac" "🚀 Launched Media Processor (PID $child_pid). Active processors: $((p_count+1))."
            send_desktop_notification "JellyMac: Processing" "Item: ${item_basename:0:60}..."
        else
            log_warn_event "JellyMac" "🚦 Max concurrent processors (${MAX_CONCURRENT_PROCESSORS:-2}) reached. Deferring processing for '$item_basename' from DROP_FOLDER."
        fi
    done < "$find_results_file" 
    rm -f "$find_results_file" 
}
#==============================================================================
# Function: show_startup_banner
# Description: Displays ASCII startup banner if enabled in config
# Parameters: None
# Returns: None
#==============================================================================
show_startup_banner() {
    if [[ "${SHOW_STARTUP_BANNER:-true}" != "true" ]]; then
        return
    fi
    
    echo
    echo "┌─────────────────────────────────────────────────────────────┐"
    echo "│                     J E L L Y M A C                         │"
    echo "│          Automated Media Assistant for macOS                │"
    echo "└─────────────────────────────────────────────────────────────┘"
    echo
}

# --- Main Initialization & Startup ---

# Perform System Health Checks
health_status=0
perform_system_health_checks || health_status=$? # from doctor_utils.sh

if [[ "$health_status" -eq 1 ]]; then # Critical failure from health check (find_executable exits before this)
    log_error_event "JellyMac" "CRITICAL system health checks failed. Exiting."
    exit 1
elif [[ "$health_status" -eq 2 ]]; then # Optional checks failed
    log_warn_event "JellyMac" "Optional system health checks failed. Some features may be degraded or unavailable. Continuing."
fi
# If flock was missing, perform_system_health_checks (via find_executable) would have exited.
# If we reach here, all critical checks passed, and flock is available.

# Acquire Single Instance Lock (AFTER health checks)
_acquire_lock  # Ensure only one instance of JellyMac runs at a time

show_startup_banner  # Call the startup banner function if enabled

log_user_info "JellyMac" "🚀 JellyMac Starting..."
log_user_info "JellyMac" "Version: v0.2.1 (2025-05-31)"
log_user_info "JellyMac" "JellyMac location: $JELLYMAC_PROJECT_ROOT"
log_debug_event "JellyMac" "   Log Level: ${LOG_LEVEL:-INFO} (Effective Syslog Level: $SCRIPT_CURRENT_LOG_LEVEL)"
if [[ "${LOG_ROTATION_ENABLED:-false}" == "true" && -n "$CURRENT_LOG_FILE_PATH" ]]; then
    log_debug_event "JellyMac" "   Log File: $CURRENT_LOG_FILE_PATH"
    log_debug_event "JellyMac" "   (Retention: ${LOG_RETENTION_DAYS:-7} days)"
else 
    log_user_info "JellyMac" "   File Logging: Disabled or not configured. Logging to console only."
fi

if [[ ! -d "$STATE_DIR" ]]; then 
    log_debug_event "JellyMac" "🛠️ State directory was created: $STATE_DIR" 
else
    log_debug_event "JellyMac" "✅ State directory OK: $STATE_DIR"
fi

log_debug_event "JellyMac" "Verifying essential directory configurations..."
declare -a critical_dest_paths_to_check=("${DEST_DIR_MOVIES:-}" "${DEST_DIR_SHOWS:-}" "${DEST_DIR_YOUTUBE:-}")
declare -a local_operational_paths_to_check=("${DROP_FOLDER:-}" "${LOCAL_DIR_YOUTUBE:-}" "${ERROR_DIR:-}" "${LOG_DIR:-}" "${STATE_DIR:-}") # Added LOG_DIR and STATE_DIR for completeness

for pth_to_check in "${critical_dest_paths_to_check[@]}"; do
    if [[ -z "$pth_to_check" ]]; then 
        log_error_event "JellyMac" "CRITICAL: Config for a critical destination path (e.g. DEST_DIR_MOVIES) is empty. Exiting."
        exit 1 
    else 
        # Assuming doctor_utils.sh handled existence/creation and would have exited on failure.
        log_debug_event "JellyMac" "✅ Critical Destination Directory '$pth_to_check' configuration is present (existence/accessibility checked by doctor_utils.sh)."
    fi
done

for pth_to_check in "${local_operational_paths_to_check[@]}"; do
    if [[ -z "$pth_to_check" ]]; then 
        log_error_event "JellyMac" "CRITICAL: Config for an essential local path (DROP_FOLDER, ERROR_DIR, LOG_DIR, STATE_DIR etc.) is empty. Exiting."
        exit 1
    else
        # Assuming doctor_utils.sh handled existence/creation and would have exited on failure.
        log_debug_event "JellyMac" "✅ Local operational path '$pth_to_check' configuration is present (existence/creation checked by doctor_utils.sh)."
    fi
done
log_user_info "JellyMac" "✅ Directory configuration verification complete."

log_debug_event "JellyMac" "Verifying program files are executable..."
for helper_script_path in "$HANDLE_YOUTUBE_SCRIPT" "$HANDLE_MAGNET_SCRIPT" "$PROCESS_MEDIA_ITEM_SCRIPT"; do
    if [[ ! -x "$helper_script_path" ]]; then
        log_error_event "JellyMac" "CRITICAL: Essential program file '$helper_script_path' is not found or not executable. Exiting."
        exit 1
    fi
done; log_user_info "JellyMac" "✅ All essential program files ready to go!"

if [[ -n "$CAFFEINATE_CMD_PATH" ]]; then
    log_user_info "JellyMac" "☕ Starting 'caffeinate' to prevent system sleep..."
    "$CAFFEINATE_CMD_PATH" -i & 
    CAFFEINATE_PROCESS_ID=$!
    # Validate caffeinate started successfully
    if ! ps -p "$CAFFEINATE_PROCESS_ID" >/dev/null 2>&1; then
        log_warn_event "JellyMac" "Failed to start caffeinate process."
        CAFFEINATE_PROCESS_ID=""
    else
        log_user_info "JellyMac" "☕ Caffeinate running with PID: $CAFFEINATE_PROCESS_ID"
    fi
fi

if [[ -n "$HISTORY_FILE" ]]; then
    if [[ ! -f "$HISTORY_FILE" ]]; then log_user_info "JellyMac" "📝 History file '$HISTORY_FILE' will be created on first use.";
    else log_debug_event "JellyMac" "📝 Using history file: $HISTORY_FILE"; fi
else log_warn_event "JellyMac" "HISTORY_FILE not configured. No history will be recorded."; fi

# --- Store command paths as needed for runtime ---
# After doctor_utils.sh has verified command availability, simply assign paths

# Set pbpaste path (it must exist if clipboard features are enabled, otherwise doctor_utils would have failed)
if [[ "${ENABLE_CLIPBOARD_YOUTUBE:-false}" == "true" || "${ENABLE_CLIPBOARD_MAGNET:-false}" == "true" ]]; then
    PBPASTE_CMD="pbpaste" 
fi

# macOS specific command path initializations
if [[ "$(uname)" == "Darwin" ]]; then
    # If we reached here with these features enabled, doctor_utils.sh already verified the commands exist
    CAFFEINATE_CMD_PATH="caffeinate"
fi

# If we get here, directory checks are already done by validate_config_filepaths() in doctor_utils.sh

log_user_info "JellyMac" "✅ All critical checks passed and paths validated."

log_user_info "JellyMac" ""
log_user_info "JellyMac" "--- JellyMac Configuration Summary (v0.2.1) ---"
log_user_info "JellyMac" "⏱️  Check Interval: ${MAIN_LOOP_SLEEP_INTERVAL:-15}s | Max Processors: ${MAX_CONCURRENT_PROCESSORS:-2}"
log_user_info "JellyMac" ""
log_user_info "JellyMac" "🎬 Media Destinations:"
log_user_info "JellyMac" "   Movies  → ${DEST_DIR_MOVIES:-N/A}"
log_user_info "JellyMac" "   Shows   → ${DEST_DIR_SHOWS:-N/A}"
log_user_info "JellyMac" "   YouTube → ${DEST_DIR_YOUTUBE:-N/A}"
log_user_info "JellyMac" ""
log_user_info "JellyMac" "📂 Drop Folder: ${DROP_FOLDER:-N/A}"
log_user_info "JellyMac" "📋 Clipboard: YouTube=${ENABLE_CLIPBOARD_YOUTUBE:-false} | Magnet=${ENABLE_CLIPBOARD_MAGNET:-false}"


# Jellyfin status
if [[ -n "${JELLYFIN_SERVER:-}" && -n "${JELLYFIN_API_KEY:-}" ]]; then
    log_user_info "JellyMac" "🪼 Jellyfin: ${JELLYFIN_SERVER}"
    log_user_info "JellyMac" "   Auto-Syncing → Movies:${ENABLE_JELLYFIN_SCAN_MOVIES:-false} Shows:${ENABLE_JELLYFIN_SCAN_SHOWS:-false} YouTube:${ENABLE_JELLYFIN_SCAN_YOUTUBE:-false}"
else
    log_user_info "JellyMac" "🪼 Jellyfin: Auto-Sync not configured"
fi

log_user_info "JellyMac" "🔔 Notifications:${ENABLE_DESKTOP_NOTIFICATIONS:-false} | Sounds:${SOUND_NOTIFICATION:-false}"
log_user_info "JellyMac" "------------------------------------------------"
log_user_info "JellyMac" ""
log_user_info "JellyMac" "🔍 Checking the Drop Folder for movies or shows..."
process_drop_folder
if [[ -n "$PBPASTE_CMD" ]]; then
    log_user_info "JellyMac" "📋 Checking the clipboard for links..."; 
    _check_clipboard_youtube; 
    _check_clipboard_magnet
else log_user_info "JellyMac" "📋 Skipping initial clipboard checks ('pbpaste' not available or clipboard features disabled)."; fi

log_user_status "JellyMac" "🔄 JellyMac is ready! Watching for new links or media every ${MAIN_LOOP_SLEEP_INTERVAL:-15} seconds..."
log_user_status "JellyMac" "(Press Ctrl+C to exit any time)"
while true; do
    manage_active_processors    
    if [[ -n "$PBPASTE_CMD" ]]; then 
        _check_clipboard_youtube; 
        _check_clipboard_magnet; 
    fi
    process_drop_folder         
    
    log_debug_event "JellyMac" "Main loop iter done. Sleeping ${MAIN_LOOP_SLEEP_INTERVAL:-15}s."
    sleep "${MAIN_LOOP_SLEEP_INTERVAL:-15}"
done

exit 0
