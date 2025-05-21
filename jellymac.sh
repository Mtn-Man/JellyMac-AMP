#!/bin/bash
#==============================================================================
# JellyMac_AMP/jellymac.sh
#==============================================================================
# Main watcher script for JellyMac Automated Media Pipeline.
#
# Purpose:
# - Monitors clipboard for YouTube links and magnet URLs
# - Watches DROP_FOLDER for new media files/folders
# - Launches appropriate processing scripts for each media type
# - Manages concurrent processing of multiple media items if desired
# - Can fully automate the media aquisition pipeline for Jellyfin users
#
# Author: Eli Sher (Mtn_Man)
# Version: 0.1.1
# Last Updated: 2025-05-20

# --- Set Terminal Title ---
printf "\033]0;JellyMac AMP\007"

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
JELLYMAC_PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
export JELLYMAC_PROJECT_ROOT
SCRIPT_DIR="$JELLYMAC_PROJECT_ROOT" # Alias for clarity

# --- State Directory ---
STATE_DIR="${SCRIPT_DIR}/.state" # For lock files, temporary scan files etc.

# --- Source Essential Libraries (Order Matters) ---
# 1. Logging Utilities (provides primitive log functions)
# shellcheck source=lib/logging_utils.sh
source "${SCRIPT_DIR}/lib/logging_utils.sh"

# 2. Configuration (defines LOG_LEVEL, paths, features)
# Replace 'jellymac_config.sh' with your actual new config filename if different
CONFIG_FILE_NAME="jellymac_config.sh" # Or "jellymac_config.sh" if you didn't rename it
if [[ -f "${SCRIPT_DIR}/lib/${CONFIG_FILE_NAME}" ]]; then
    # shellcheck source=lib/jellymac_config.sh
    source "${SCRIPT_DIR}/lib/${CONFIG_FILE_NAME}"
else
    # Use primitive echo for this critical early error
    echo "$(date '+%Y-%m-%d %H:%M:%S') - CRITICAL WATCHER: Config file '${SCRIPT_DIR}/lib/${CONFIG_FILE_NAME}' not found. Exiting." >&2
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
source "${SCRIPT_DIR}/lib/common_utils.sh"

# 5. Doctor Utilities (Health Checks)
# shellcheck source=lib/doctor_utils.sh
source "${SCRIPT_DIR}/lib/doctor_utils.sh"

# 6. Media Utilities (for determine_media_category by watcher if needed)
# shellcheck source=lib/media_utils.sh
source "${SCRIPT_DIR}/lib/media_utils.sh"

# --- Paths to Helper Scripts in bin/ ---
HANDLE_YOUTUBE_SCRIPT="${SCRIPT_DIR}/bin/handle_youtube_link.sh"
HANDLE_MAGNET_SCRIPT="${SCRIPT_DIR}/bin/handle_magnet_link.sh"
PROCESS_MEDIA_ITEM_SCRIPT="${SCRIPT_DIR}/bin/process_media_item.sh"

# --- Local Logging Setup (File Logging & Rotation) ---
_WATCHER_LOG_PREFIX="📡 JellyMac" # This is the unique prefix for jellymac.sh logs
CURRENT_LOG_FILE_PATH=""          # Path to the current log file
LAST_LOG_DATE_CHECKED=""          # Used to track if we need to create a new log file

#==============================================================================
# LOG FILE MANAGEMENT FUNCTIONS
#==============================================================================
# Functions for creating, rotating, and cleaning up log files

# Function: _delete_old_logs
# Description: Deletes log files older than LOG_RETENTION_DAYS
# Parameters: None
# Returns: None
_delete_old_logs() {
    if [[ "${LOG_ROTATION_ENABLED:-false}" != "true" || -z "$LOG_DIR" || -z "$LOG_FILE_BASENAME" || -z "$LOG_RETENTION_DAYS" || "$LOG_RETENTION_DAYS" -lt 1 ]]; then
        # Use log_debug_event from logging_utils.sh as local log_debug isn't fully set up yet
        log_debug_event "$_WATCHER_LOG_PREFIX" "_delete_old_logs: Rotation not enabled or critical config missing. Skipping."
        return
    fi
    local retention_days_for_find=$((LOG_RETENTION_DAYS - 1))
    [[ "$retention_days_for_find" -lt 0 ]] && retention_days_for_find=0
    log_debug_event "$_WATCHER_LOG_PREFIX" "_delete_old_logs: Checking logs older than $LOG_RETENTION_DAYS days in '$LOG_DIR' (base: '$LOG_FILE_BASENAME')."
    if [[ ! -d "$LOG_DIR" ]]; then
        log_warn_event "$_WATCHER_LOG_PREFIX" "_delete_old_logs: Log directory '$LOG_DIR' not found. Skipping deletion."
        return
    fi
    local old_log_count
    old_log_count=$(find "$LOG_DIR" -name "${LOG_FILE_BASENAME}_*.log" -type f -mtime +"$retention_days_for_find" -print 2>/dev/null | wc -l)
    if [[ "$old_log_count" -gt 0 ]]; then
        log_info_event "$_WATCHER_LOG_PREFIX" "_delete_old_logs: Found $old_log_count old log file(s) to delete."
        find "$LOG_DIR" -name "${LOG_FILE_BASENAME}_*.log" -type f -mtime +"$retention_days_for_find" -delete
        log_info_event "$_WATCHER_LOG_PREFIX" "_delete_old_logs: Deletion attempt complete."
    else
        log_debug_event "$_WATCHER_LOG_PREFIX" "_delete_old_logs: No old log files found."
    fi
}

# Function: _ensure_log_file_updated
# Description: Creates or updates the log file path based on current date
# Parameters: None
# Returns: None
# Side Effects: Updates CURRENT_LOG_FILE_PATH and LAST_LOG_DATE_CHECKED globals
_ensure_log_file_updated() {
    if [[ "${LOG_ROTATION_ENABLED:-false}" != "true" || -z "$LOG_DIR" || -z "$LOG_FILE_BASENAME" ]]; then
        CURRENT_LOG_FILE_PATH=""
        return
    fi
    local current_date; current_date=$(date +%F)
    if [[ "$current_date" != "$LAST_LOG_DATE_CHECKED" || ! -f "$CURRENT_LOG_FILE_PATH" ]]; then
        LAST_LOG_DATE_CHECKED="$current_date"
        CURRENT_LOG_FILE_PATH="${LOG_DIR}/${LOG_FILE_BASENAME}_${current_date}.log"
        if ! mkdir -p "$LOG_DIR"; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') - CRITICAL WATCHER: Failed to create log directory '$LOG_DIR'. Disabling file logging for this session." >&2
            CURRENT_LOG_FILE_PATH=""
            LOG_ROTATION_ENABLED="false" # Disable for this session
            return
        fi
        # Use log_info_event from logging_utils.sh as local log_info isn't fully set up yet
        log_info_event "$_WATCHER_LOG_PREFIX" "Log file for today: $CURRENT_LOG_FILE_PATH"
        _delete_old_logs
    fi
}
_ensure_log_file_updated # Initial setup call

_log_to_file_and_console() {
    local required_level_num="$1"
    local log_event_func_name="$2" # e.g., "log_debug_event" (from logging_utils.sh)
    local log_prefix_for_event="$3" # e.g., "$_WATCHER_LOG_PREFIX"
    local message_to_log="$4"
    local output_to_stderr="${5:-false}" # For console part
    local file_log_message # Declare separately for SC2034/set -e safety with command substitution

    _ensure_log_file_updated # Ensure log file path is current

    if [[ "$SCRIPT_CURRENT_LOG_LEVEL" -le "$required_level_num" ]]; then
        # 1. Log to console (using the primitive from logging_utils.sh)
        #    The primitive itself (e.g. log_debug_event) handles adding emoji/severity and timestamp.
        #    It also decides its own output stream (typically stderr).
        #    The output_to_stderr here is a bit redundant if primitives always go to stderr,
        #    but kept for potential future flexibility if primitives change.
        if [[ "$output_to_stderr" == "true" ]]; then
            "$log_event_func_name" "$log_prefix_for_event" "$message_to_log" >&2
        else
            "$log_event_func_name" "$log_prefix_for_event" "$message_to_log"
        fi

        # 2. Log to file (if enabled and path is valid)
        if [[ "${LOG_ROTATION_ENABLED:-false}" == "true" && -n "$CURRENT_LOG_FILE_PATH" ]]; then
            # Construct the message for the file: Prefix + Timestamp + Message
            # The log_event_func_name (e.g. log_debug_event) already formats with emoji/severity/timestamp.
            # So, we need to reconstruct a similar format but ensure it's clean for the file.
            # Let's use the raw prefix and add our own timestamp for the file log for consistency.
            local severity_label
            case "$required_level_num" in
                "$LOG_LEVEL_DEBUG") severity_label="DEBUG:" ;;
                "$LOG_LEVEL_INFO")  severity_label="" ;; # INFO often doesn't have a label
                "$LOG_LEVEL_WARN")  severity_label="WARN:" ;;
                "$LOG_LEVEL_ERROR") severity_label="ERROR:" ;;
                *)                  severity_label="LOG:" ;;
            esac
            
            # Assign value with command substitution on a new line
            file_log_message="${log_prefix_for_event} $(date '+%Y-%m-%d %H:%M:%S') - ${severity_label} ${message_to_log}"
            
            if command -v flock &>/dev/null; then
                exec 200>>"$CURRENT_LOG_FILE_PATH" # Open FD for flock
                if flock -w 0.5 200; then # Try to lock for 0.5s
                    echo "$file_log_message" >&200
                    flock -u 200 # Release lock
                else
                    log_warn_event "$_WATCHER_LOG_PREFIX" "Flock timeout writing to log file. Appending directly (potential race)."
                    echo "[FLOCK_TIMEOUT] $file_log_message" >> "$CURRENT_LOG_FILE_PATH"
                fi
                exec 200>&- # Close FD
            else
                # This case should ideally be caught by doctor_utils.sh if flock is critical
                log_warn_event "$_WATCHER_LOG_PREFIX" "'flock' command not found. File logging might be unsafe."
                echo "$file_log_message" >> "$CURRENT_LOG_FILE_PATH"
            fi
        fi
    fi
}

# Define local log functions for jellymac.sh, using the wrapper.
# These will now correctly pass only the $_WATCHER_LOG_PREFIX to the underlying
# log_X_event functions from logging_utils.sh, which will add the emoji/severity.
log_debug() { _log_to_file_and_console "$LOG_LEVEL_DEBUG" "log_debug_event" "$_WATCHER_LOG_PREFIX" "$1"; }
log_info()  { _log_to_file_and_console "$LOG_LEVEL_INFO"  "log_info_event"  "$_WATCHER_LOG_PREFIX" "$1"; }
log_warn()  { _log_to_file_and_console "$LOG_LEVEL_WARN"  "log_warn_event"  "$_WATCHER_LOG_PREFIX" "$1" "true"; }
log_error() { 
    _log_to_file_and_console "$LOG_LEVEL_ERROR" "log_error_event" "$_WATCHER_LOG_PREFIX" "$1" "true";
    # For critical errors in the watcher's own logic that should stop it.
    # Consider if graceful_shutdown should be invoked instead of direct exit for some cases.
    exit 1; 
}

# --- Single Instance Lock ---
LOCK_FILE="${STATE_DIR}/jellymac.sh.lock"
_acquire_lock() {
    log_debug "Attempting to acquire instance lock: $LOCK_FILE"
    if [[ ! -d "$STATE_DIR" ]]; then
        if ! mkdir -p "$STATE_DIR"; then
            # Use primitive echo for critical startup error
            echo "$(date '+%Y-%m-%d %H:%M:%S') - CRITICAL WATCHER: Failed to create state dir '$STATE_DIR'. Cannot acquire lock. Exiting." >&2
            exit 1;
        fi
        log_info "State directory '$STATE_DIR' created."
    fi

    # 'flock' command availability is checked by perform_system_health_checks earlier.
    # If flock is not available, find_executable in doctor_utils.sh would have exited.
    exec 201>"$LOCK_FILE" # Open file descriptor 201 for flock.
    if ! flock -n 201; then 
        log_error "Another instance of jellymac.sh is already running (Lock file: '$LOCK_FILE'). Exiting."
        # log_error defined above will exit the script.
    fi
    log_info "Instance lock acquired: $LOCK_FILE"
}
_release_lock() {
    log_debug "Releasing instance lock: $LOCK_FILE"
    if [[ -n "$LOCK_FILE" ]]; then 
        exec 201>&- # Close file descriptor
        # rm -f "$LOCK_FILE" # Optional: remove lock file, flock releases advisory lock anyway
        log_info "Instance lock released."
    fi
}

# --- Desktop Notification Function (macOS Only) ---
_OSASCRIPT_CMD="" # Initialized during startup checks
send_desktop_notification() {
    local title="$1"; local message="$2"; local sound_name="${3:-Purr}" # Default sound

    if [[ "${ENABLE_DESKTOP_NOTIFICATIONS:-false}" != "true" || "$(uname)" != "Darwin" ]]; then return; fi
    if [[ "$_OSASCRIPT_CMD" == "NOT_FOUND" ]]; then return; fi 
    if [[ -z "$_OSASCRIPT_CMD" ]]; then 
        log_warn "_OSASCRIPT_CMD not initialized before use in send_desktop_notification. This is a script bug."
        return; 
    fi

    local safe_title; safe_title=$(echo "$title" | sed 's/\\/\\\\/g; s/"/\\"/g' | head -c 100)
    local safe_message; safe_message=$(echo "$message" | sed 's/\\/\\\\/g; s/"/\\"/g' | head -c 200)
    local osascript_command_str="display notification \"${safe_message}\" with title \"${safe_title}\""
    if [[ -n "$sound_name" ]]; then osascript_command_str+=" sound name \"${sound_name}\""; fi

    log_debug "Sending desktop notification: Title='${title}', Message='${message}'"
    "$_OSASCRIPT_CMD" -e "$osascript_command_str" &>/dev/null &
}

# --- Caffeinate and Process Management ---
CAFFEINATE_PROCESS_ID=""
CAFFEINATE_CMD_PATH="" 
_ACTIVE_PROCESSOR_INFO_STRING="" 
LAST_CLIPBOARD_CONTENT_YOUTUBE=""
LAST_CLIPBOARD_CONTENT_MAGNET=""
PBPASTE_CMD="" 

#==============================================================================
# PROCESS MANAGEMENT FUNCTIONS
#==============================================================================
# Functions for managing child processes, cleanup operations, and graceful exit

# Function: _cleanup_jellymac_temp_files
# Description: Cleans up any temporary files created by the watcher
# Parameters: None
# Returns: None
_cleanup_jellymac_temp_files() {
    log_debug "Cleaning up jellymac.sh specific temp files..."
    log_debug "No specific jellymac.sh temp files to clean in this version beyond what functions manage themselves."
}
# Function: graceful_shutdown_and_cleanup
# Description: Main cleanup handler called when script exits (normal or interrupted)
# Parameters: None
# Returns: None (exits the script)
# Note: Registered as a trap for SIGINT, SIGTERM, and EXIT signals
graceful_shutdown_and_cleanup() {
    echo; log_info "👋 Exiting JellyMac AMP..." 

    if [[ -n "$CAFFEINATE_PROCESS_ID" ]] && ps -p "$CAFFEINATE_PROCESS_ID" > /dev/null; then
        log_info "Stopping caffeinate (PID: $CAFFEINATE_PROCESS_ID)..."
        kill "$CAFFEINATE_PROCESS_ID" 2>/dev/null || log_warn "Caffeinate PID $CAFFEINATE_PROCESS_ID not found or already exited."
    fi

    log_info "Terminating any active child processors..."
    local old_ifs="$IFS"; IFS='|'
    local script_name_killed 
    set -f 
    # shellcheck disable=SC2206 
    local p_info_array=(${_ACTIVE_PROCESSOR_INFO_STRING//|||/|})
    set +f 
    IFS="$old_ifs"
    local entry_count=${#p_info_array[@]}

    if [[ $entry_count -gt 0 && $((entry_count % 4)) -eq 0 ]]; then
        for ((idx=0; idx<entry_count; idx+=4)); do
            local pid_to_kill="${p_info_array[idx]}"
            script_name_killed="$(basename "${p_info_array[idx+1]}")" 
            local item_killed="${p_info_array[idx+2]}"
            if [[ -n "$pid_to_kill" ]] && ps -p "$pid_to_kill" > /dev/null; then
                log_info "  Terminating PID $pid_to_kill ($script_name_killed for '${item_killed:0:50}...')..."
                kill "$pid_to_kill" 2>/dev/null || log_warn "  Failed to send SIGTERM to PID $pid_to_kill."
            fi
        done
    elif [[ -n "$_ACTIVE_PROCESSOR_INFO_STRING" ]]; then 
        log_warn "Could not parse _ACTIVE_PROCESSOR_INFO_STRING for child process cleanup: '$_ACTIVE_PROCESSOR_INFO_STRING'"
    fi
    
    _release_lock 
    
    if command -v _cleanup_common_utils_temp_files &>/dev/null; then
        _cleanup_common_utils_temp_files 
    fi
    _cleanup_jellymac_temp_files   

    printf "\033]0;%s\007" "${SHELL##*/}"; log_info "JellyMac AMP shutdown complete." 
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
    # shellcheck disable=SC2206 
    local p_info_array=(${_ACTIVE_PROCESSOR_INFO_STRING//|||/|})
    set +f 
    IFS="$old_ifs"
    local entry_count=${#p_info_array[@]}

    if [[ $entry_count -eq 0 || $((entry_count % 4)) -ne 0 ]]; then
        if [[ -n "$_ACTIVE_PROCESSOR_INFO_STRING" ]]; then 
             log_warn "manage_active_processors: _ACTIVE_PROCESSOR_INFO_STRING ('$_ACTIVE_PROCESSOR_INFO_STRING') is malformed. Clearing."
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
            if [[ -n "$still_running_string" ]]; then still_running_string+="|||"; fi 
            still_running_string+="${pid}|||${script_full_path}|||${item_identifier}|||${ts_launch}"
        else 
            local exit_status=255 
            if wait "$pid" &>/dev/null; then 
                 exit_status=$?
            else
                 log_debug "manage_active_processors: wait for PID $pid failed or already reaped. Assuming finished."
            fi
            log_info "✅ Processor PID $pid ($script_basename for '${item_identifier:0:70}...') completed. Exit status: $exit_status."
            
            if [[ "$script_full_path" == "$PROCESS_MEDIA_ITEM_SCRIPT" ]]; then
                if [[ "$exit_status" -eq 0 ]]; then 
                    if [[ -n "$item_identifier" && -e "$item_identifier" ]]; then 
                        log_info "🗑️ Deleting successfully processed/quarantined item from DROP_FOLDER: '$item_identifier'"
                        if rm -rf "$item_identifier"; then
                            log_info "✅ Successfully deleted '$item_identifier' from DROP_FOLDER."
                            record_transfer_to_history "DELETED from DROP_FOLDER: $(basename "$item_identifier") (Processed by $script_basename, status $exit_status)"
                        else
                            log_error "❌ Failed to delete '$item_identifier' from DROP_FOLDER. Manual cleanup may be required." 
                        fi
                    else
                        log_warn "Could not delete '$item_identifier' from DROP_FOLDER: path invalid or item already gone."
                    fi
                else 
                    log_warn "Processor PID $pid ($script_basename for '$item_identifier') failed (status $exit_status). Item remains in DROP_FOLDER."
                fi
            fi
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
    # shellcheck disable=SC2206 
    local p_info_array=(${_ACTIVE_PROCESSOR_INFO_STRING//|||/|})
    set +f 
    IFS="$old_ifs"
    local entry_count=${#p_info_array[@]}

    if [[ $entry_count -eq 0 || $((entry_count % 4)) -ne 0 ]]; then
        log_debug "is_item_being_processed: malformed _ACTIVE_PROCESSOR_INFO_STRING. Checked for '$item_to_check'."
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
        log_warn "Failed to read clipboard for YouTube monitoring. 'pbpaste' might have failed."
        return
    fi

    if [[ "$current_cb_content" != "$LAST_CLIPBOARD_CONTENT_YOUTUBE" && -n "$current_cb_content" ]]; then
        LAST_CLIPBOARD_CONTENT_YOUTUBE="$current_cb_content" 
        local trimmed_cb; trimmed_cb="$(echo -E "${current_cb_content}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        if [[ "$trimmed_cb" =~ ^https:\/\/(www\.youtube\.com\/watch\?v=|youtu\.be\/) ]]; then
            log_info "▶️ Detected YouTube URL: '${trimmed_cb:0:70}...' Processing in foreground."
            play_sound_notification "input_detected" "$_WATCHER_LOG_PREFIX" 
            
            if "$HANDLE_YOUTUBE_SCRIPT" "$trimmed_cb"; then
                log_info "✅ YouTube processing complete for: ${trimmed_cb:0:70}..."
                send_desktop_notification "JellyMac: YouTube" "Completed: ${trimmed_cb:0:60}..."
            else
                send_desktop_notification "JellyMac: YouTube Error" "Failed: ${trimmed_cb:0:60}..." "Basso"
                # Changed to log_warn to prevent watcher exit on single YouTube failure
                log_warn "❌ YouTube processing FAILED for: ${trimmed_cb:0:70}... Helper script indicated an error."
            fi
        fi
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
        log_warn "Failed to read clipboard for magnet link monitoring. 'pbpaste' might have failed."
        return
    fi

    if [[ "$current_cb_content" != "$LAST_CLIPBOARD_CONTENT_MAGNET" && -n "$current_cb_content" ]]; then
        LAST_CLIPBOARD_CONTENT_MAGNET="$current_cb_content" 
        local trimmed_cb; trimmed_cb="$(echo -E "${current_cb_content}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        if [[ "$trimmed_cb" =~ ^magnet:\?xt=urn:btih:[a-zA-Z0-9]{32,} ]]; then
            log_info "🧲 Detected Magnet URL: '${trimmed_cb:0:70}...'";
            play_sound_notification "input_detected" "$_WATCHER_LOG_PREFIX" 

            if "$HANDLE_MAGNET_SCRIPT" "$trimmed_cb"; then
                log_info "✅ Magnet link processing appears successful for: ${trimmed_cb:0:70}..."
                send_desktop_notification "JellyMac: Magnet" "Sent to client: ${trimmed_cb:0:60}..." 
            else
                # Changed to log_warn to prevent watcher exit on single magnet failure
                log_warn "❌ Failed to process magnet link via helper script: ${trimmed_cb:0:70}... Helper script indicated an error."; 
            fi
        fi
    fi
}

# Function: process_drop_folder
# Description: Scans the DROP_FOLDER for new media files/folders and processes them
# Parameters: None
# Returns: None
# Side Effects: Launches child processes for media processing, updates _ACTIVE_PROCESSOR_INFO_STRING
process_drop_folder() {
    if [[ -z "$DROP_FOLDER" || ! -d "$DROP_FOLDER" ]]; then
        log_warn "DROP_FOLDER ('${DROP_FOLDER:-N/A}') not configured or found. Skipping scan."
        return
    fi
    log_debug "Scanning DROP_FOLDER: $DROP_FOLDER"
    local find_results_file 
    if [[ ! -d "$STATE_DIR" ]]; then 
        mkdir -p "$STATE_DIR" || { log_error "Failed to create STATE_DIR '$STATE_DIR' for temp scan file. Cannot scan DROP_FOLDER."; }
    fi
    find_results_file=$(mktemp "${STATE_DIR}/.drop_folder_scan.XXXXXX")
    
    find "$DROP_FOLDER" -mindepth 1 -maxdepth 1 \( -type f -o -type d \) -print0 > "$find_results_file"
    
    while IFS= read -r -d $'\0' item_path; do
        [[ -z "$item_path" ]] && continue 

        local item_basename; item_basename=$(basename "$item_path")

        if [[ "$item_basename" == ".DS_Store" || "$item_basename" == "desktop.ini" || \
              "$item_basename" == ".stfolder" || "$item_basename" == ".stversions" || \
              "$item_basename" == ".localized" || "$item_basename" =~ ^\._ || \
              "$item_basename" =~ \.part$ || "$item_basename" =~ \.crdownload$ ]]; then 
            log_debug "Skipping common/temp file in DROP_FOLDER: '$item_basename'"; continue
        fi

        if is_item_being_processed "$item_path"; then
            log_debug "Item '$item_basename' (DROP_FOLDER) already processing. Skipping."; continue
        fi

        log_info "Checking stability for item in DROP_FOLDER: '$item_basename'"
        if ! wait_for_file_stability "$item_path" "${STABLE_CHECKS_DROP_FOLDER:-3}" "${STABLE_SLEEP_INTERVAL_DROP_FOLDER:-10}"; then
            log_debug "Item '$item_basename' (DROP_FOLDER) not stable. Will re-check next cycle."; continue
        fi
        log_info "✅ Item '$item_basename' (DROP_FOLDER) is stable."

        manage_active_processors 

        local old_ifs="$IFS"; IFS='|'
        set -f 
        # shellcheck disable=SC2206 
        local p_array_temp=(${_ACTIVE_PROCESSOR_INFO_STRING//|||/|})
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

            log_info "🚀 Launching media processor for '$item_basename'. Type: $item_type_for_processor, Hint: '$category_hint_for_processor'"
            play_sound_notification "input_detected" "$_WATCHER_LOG_PREFIX" 

            local ts_launch; ts_launch=$(date +%s)
            "$PROCESS_MEDIA_ITEM_SCRIPT" "$item_type_for_processor" "$item_path" "$category_hint_for_processor" & 
            local child_pid=$! 

            if [[ -n "$_ACTIVE_PROCESSOR_INFO_STRING" ]]; then _ACTIVE_PROCESSOR_INFO_STRING+="|||"; fi
            _ACTIVE_PROCESSOR_INFO_STRING+="${child_pid}|||${PROCESS_MEDIA_ITEM_SCRIPT}|||${item_path}|||${ts_launch}"
            
            log_info "🚀 Launched Media Processor (PID $child_pid). Active processors: $((p_count+1))."
            send_desktop_notification "JellyMac: Processing" "Item: ${item_basename:0:60}..."
        else
            log_warn "🚦 Max concurrent processors (${MAX_CONCURRENT_PROCESSORS:-2}) reached. Deferring processing for '$item_basename' from DROP_FOLDER."
        fi
    done < "$find_results_file" 
    rm -f "$find_results_file" 
}

# --- Main Initialization & Startup ---

# Perform System Health Checks (Moved earlier)
log_info "🩺 Performing system health checks..."
health_status=0
perform_system_health_checks || health_status=$? # from doctor_utils.sh # from doctor_utils.sh

if [[ "$health_status" -eq 1 ]]; then # Critical failure from health check (find_executable exits before this)
    log_error "CRITICAL system health checks failed. Exiting." # This log_error will exit
elif [[ "$health_status" -eq 2 ]]; then # Optional checks failed
    log_warn "Optional system health checks failed. Some features may be degraded or unavailable. Continuing."
fi
# If flock was missing, perform_system_health_checks (via find_executable) would have exited.

# Validate configuration filepaths
log_info "🔍 Validating configuration filepaths..."
if ! validate_config_filepaths; then
    log_error "CRITICAL: Configuration validation failed. Please fix the filepath issues and restart." 
fi

# Acquire Single Instance Lock (AFTER health checks)
_acquire_lock # Ensure only one instance runs

log_info "🚀 JellyMac AMP Starting..."
log_info "   Version: 0.1.1 ($(date '+%Y-%m-%d %H:%M:%S'))"  
log_info "   Project Root: $JELLYMAC_PROJECT_ROOT"
log_info "   Log Level: ${LOG_LEVEL:-INFO} (Effective Syslog Level: $SCRIPT_CURRENT_LOG_LEVEL)"
if [[ "${LOG_ROTATION_ENABLED:-false}" == "true" && -n "$CURRENT_LOG_FILE_PATH" ]]; then
    log_info "   Log File: $CURRENT_LOG_FILE_PATH (Retention: ${LOG_RETENTION_DAYS:-7} days)"
else 
    log_info "   File Logging: Disabled or not configured. Logging to console only."
fi

if [[ ! -d "$STATE_DIR" ]]; then 
    log_info "🛠️ State directory was created: $STATE_DIR" 
else
    log_info "✅ State directory OK: $STATE_DIR"
fi

# pbpaste check (now primarily handled by doctor_utils.sh, this is for PBPASTE_CMD var)
if [[ "${ENABLE_CLIPBOARD_YOUTUBE:-false}" == "true" || "${ENABLE_CLIPBOARD_MAGNET:-false}" == "true" ]]; then
    if command -v pbpaste &>/dev/null; then 
        PBPASTE_CMD="pbpaste"; 
        log_info "✅ 'pbpaste' is available for clipboard monitoring."
    else 
        PBPASTE_CMD=""; 
        # Warning about pbpaste missing is handled by doctor_utils.sh
        # Here we just ensure clipboard features are effectively disabled if pbpaste is not usable.
        ENABLE_CLIPBOARD_YOUTUBE="false"
        ENABLE_CLIPBOARD_MAGNET="false"
        log_info "Clipboard monitoring features disabled as 'pbpaste' is unavailable."
    fi
fi

# macOS specific command path initializations (caffeinate, osascript)
# These are checked by doctor_utils.sh; here we just set the command path variables.
if [[ "$(uname)" == "Darwin" ]]; then
    if command -v caffeinate &>/dev/null; then CAFFEINATE_CMD_PATH="caffeinate"; 
    else CAFFEINATE_CMD_PATH=""; fi # doctor_utils warns if missing
    
    if [[ "${ENABLE_DESKTOP_NOTIFICATIONS:-false}" == "true" ]]; then
        if command -v osascript &>/dev/null; then _OSASCRIPT_CMD="osascript"; 
        else _OSASCRIPT_CMD="NOT_FOUND"; ENABLE_DESKTOP_NOTIFICATIONS="false"; fi # doctor_utils warns if missing
    fi
fi

log_info "Verifying essential directories..."
declare -a critical_dest_paths_to_check=("${DEST_DIR_MOVIES:-}" "${DEST_DIR_SHOWS:-}" "${DEST_DIR_YOUTUBE:-}")
declare -a local_operational_paths_to_create=("${DROP_FOLDER:-}" "${LOCAL_DIR_YOUTUBE:-}" "${ERROR_DIR:-}")

for pth_to_check in "${critical_dest_paths_to_check[@]}"; do
    if [[ -z "$pth_to_check" ]]; then 
        log_warn "Config for a critical destination path (e.g. DEST_DIR_MOVIES) is empty in config." 
    elif [[ ! -d "$pth_to_check" ]]; then 
        log_error "❌ CRITICAL: Destination Directory '$pth_to_check' not found or not accessible." 
    else 
        log_debug "✅ Critical Destination Directory '$pth_to_check' OK."
    fi
done

for pth_to_create in "${local_operational_paths_to_create[@]}"; do
    if [[ -z "$pth_to_create" ]]; then 
        log_error "CRITICAL: Config for an essential local path (DROP_FOLDER, ERROR_DIR, etc.) is empty. Exiting."
    fi
    if [[ ! -d "$pth_to_create" ]]; then
        log_info "🛠️ Local operational directory '$pth_to_create' not found. Creating..."
        if mkdir -p "$pth_to_create"; then log_info "✅ Successfully created '$pth_to_create'.";
        else
            log_error "❌ Failed to create '$pth_to_create'. Check permissions." 
        fi
    else 
        log_debug "✅ Local operational directory '$pth_to_create' exists."
    fi
done
log_info "✅ Directory verification complete."

log_info "Verifying helper scripts are executable..."
for helper_script_path in "$HANDLE_YOUTUBE_SCRIPT" "$HANDLE_MAGNET_SCRIPT" "$PROCESS_MEDIA_ITEM_SCRIPT"; do
    if [[ ! -x "$helper_script_path" ]]; then
        log_error "CRITICAL: Helper script '$helper_script_path' is not found or not executable. Exiting."
    fi
done; log_info "✅ Helper scripts are executable."

if [[ -n "$CAFFEINATE_CMD_PATH" ]]; then
    log_info "☕ Starting 'caffeinate' to prevent system sleep..."
    "$CAFFEINATE_CMD_PATH" -i & CAFFEINATE_PROCESS_ID=$! 
    log_info "☕ Caffeinate running with PID: $CAFFEINATE_PROCESS_ID"
fi

if [[ -n "$HISTORY_FILE" ]]; then
    if [[ ! -f "$HISTORY_FILE" ]]; then log_info "📝 History file '$HISTORY_FILE' will be created on first use.";
    else log_info "📝 Using history file: $HISTORY_FILE"; fi
else log_warn "HISTORY_FILE not configured. No history will be recorded."; fi

log_info "--- JellyMac AMP Configuration Summary (v0.1.1) ---"
log_info "  Monitoring DROP_FOLDER: ${DROP_FOLDER:-N/A} (Checks: ${STABLE_CHECKS_DROP_FOLDER:-3}, Interval: ${STABLE_SLEEP_INTERVAL_DROP_FOLDER:-10}s)"
log_info "  Max Concurrent Media Processors: ${MAX_CONCURRENT_PROCESSORS:-2}"
log_info "  Desktop Notifications (macOS): ${ENABLE_DESKTOP_NOTIFICATIONS:-false}"
log_info "  Sound Notifications (macOS): ${SOUND_NOTIFICATION:-false}" 
log_info "    -> Input Detected Sound: ${SOUND_INPUT_DETECTED_FILE:-N/A}"
log_info "    -> Task Success Sound: ${SOUND_TASK_SUCCESS_FILE:-N/A}"
log_info "  YouTube Clipboard: ${ENABLE_CLIPBOARD_YOUTUBE:-false} (Local: ${LOCAL_DIR_YOUTUBE:-N/A}, Dest: ${DEST_DIR_YOUTUBE:-N/A})"
log_info "  Magnet Clipboard: ${ENABLE_CLIPBOARD_MAGNET:-false} (Torrent CLI: ${TORRENT_CLIENT_CLI_PATH:-N/A})"
log_info "  Movie Dest: ${DEST_DIR_MOVIES:-N/A}, Show Dest: ${DEST_DIR_SHOWS:-N/A}"
log_info "  Error/Quarantine Dir: ${ERROR_DIR:-N/A}"
log_info "  Main Loop Interval: ${MAIN_LOOP_SLEEP_INTERVAL:-15}s"
log_info "-------------------------------------------------------"

log_info "👀 Performing initial scan of DROP_FOLDER..."
process_drop_folder
if [[ -n "$PBPASTE_CMD" ]]; then
    log_info "📋 Performing initial clipboard checks..."; 
    _check_clipboard_youtube; 
    _check_clipboard_magnet
else log_info "📋 Skipping initial clipboard checks ('pbpaste' not available or clipboard features disabled)."; fi

log_info "🔄 Main loop active. Interval: ${MAIN_LOOP_SLEEP_INTERVAL:-15}s."
while true; do
    manage_active_processors    
    if [[ -n "$PBPASTE_CMD" ]]; then 
        _check_clipboard_youtube; 
        _check_clipboard_magnet; 
    fi
    process_drop_folder         
    
    log_debug "Main loop iter done. Sleeping ${MAIN_LOOP_SLEEP_INTERVAL:-15}s."
    sleep "${MAIN_LOOP_SLEEP_INTERVAL:-15}"
done

exit 0
