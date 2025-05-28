#!/bin/bash

# lib/common_utils.sh
# Contains common utility functions shared across the JellyMac AMP (Automated Media Pipeline) project.
# These functions should be as self-contained as possible but rely on
# logging functions (from logging_utils.sh) and configuration variables
# (from jellymac_config.sh) being sourced *before* this script.
# Assumes SCRIPT_DIR is exported by the main script for mktemp.

if ! command -v log_info_event &>/dev/null; then
    echo "FATAL ERROR: common_utils.sh requires logging_utils.sh to be sourced first." >&2
    exit 1
fi

# --- Ensure STATE_DIR is available (expected from jellymac_config.sh) ---
if [[ -z "$STATE_DIR" ]]; then
    log_error_event "Utils" "CRITICAL: STATE_DIR is not set. This variable is expected from jellymac_config.sh. Exiting."
    exit 1
elif [[ ! -d "$STATE_DIR" ]]; then
    log_user_info "Utils" "STATE_DIR ('$STATE_DIR') does not exist. Attempting to create."
    if ! mkdir -p "$STATE_DIR"; then
        log_error_event "Utils" "CRITICAL: Failed to create STATE_DIR ('$STATE_DIR'). Check permissions. Exiting."
        exit 1
    fi
fi

# --- Determine MD5 Command ---
# Sets MD5_CMD variable for use in lock file naming.
_determine_md5_cmd() {
    if command -v md5 &>/dev/null && [[ "$(uname -s)" == "Darwin" ]]; then # macOS md5
        MD5_CMD="md5 -q"
    elif command -v md5sum &>/dev/null; then # Linux md5sum
        MD5_CMD="md5sum | cut -d' ' -f1"
    else
        log_warn_event "Utils" "Neither 'md5' (macOS) nor 'md5sum' (Linux) found. Lock file names will be less unique (using basename)."
        # Fallback to basename, which is not ideal for uniqueness if paths are very similar
        # but better than failing entirely. This should be caught by health checks ideally.
        MD5_CMD="basename"
    fi
}
_determine_md5_cmd # Call it to set MD5_CMD globally for this script's session

#==============================================================================
# STABILITY LOCKING FUNCTIONS (Item-specific locks)
#==============================================================================

#==============================================================================
# Function: acquire_stability_lock
# Description: Attempts to acquire a lock for a specific media item to prevent
#              concurrent processing. Uses mkdir for atomicity.
# Parameters:
#   $1: Full path to the item to lock.
# Returns: 0 if lock is acquired successfully, 1 otherwise.
#==============================================================================
acquire_stability_lock() {
    local item_path_to_lock="$1"
    if [[ -z "$item_path_to_lock" ]]; then
        log_error_event "Utils" "LOCKING: No item path provided to acquire_stability_lock."
        return 1
    fi

    local item_hash
    # shellcheck disable=SC2086 # We want word splitting for $MD5_CMD if it's "md5 -q" or "md5sum | ..."
    item_hash=$(echo -n "$item_path_to_lock" | $MD5_CMD | tr -dc 'a-zA-Z0-9')
    local lock_dir_path="${STATE_DIR}/.item_lockdir_${item_hash}"

    if mkdir "$lock_dir_path" 2>/dev/null; then
        log_debug_event "Utils" "LOCKING: Acquired lock for '$item_path_to_lock' (LockDir: $lock_dir_path)"
        return 0 # Lock acquired
    else
        log_debug_event "Utils" "LOCKING: Failed to acquire lock for '$item_path_to_lock' (LockDir: $lock_dir_path probably exists)"
        return 1 # Lock not acquired (likely already exists)
    fi
}

#==============================================================================
# Function: release_stability_lock
# Description: Releases a lock for a specific media item.
# Parameters:
#   $1: Full path to the item whose lock is to be released.
# Returns: 0 if lock is released successfully or was not found, 1 on rmdir error.
#==============================================================================
release_stability_lock() {
    local item_path_to_unlock="$1"
    if [[ -z "$item_path_to_unlock" ]]; then
        log_error_event "Utils" "LOCKING: No item path provided to release_stability_lock."
        return 1
    fi

    local item_hash
    # shellcheck disable=SC2086 # We want word splitting for $MD5_CMD
    item_hash=$(echo -n "$item_path_to_unlock" | $MD5_CMD | tr -dc 'a-zA-Z0-9')
    local lock_dir_path="${STATE_DIR}/.item_lockdir_${item_hash}"

    if [[ -d "$lock_dir_path" ]]; then
        if rmdir "$lock_dir_path" 2>/dev/null; then
            log_debug_event "Utils" "LOCKING: Released lock for '$item_path_to_unlock' (LockDir: $lock_dir_path)"
            return 0 # Lock released
        else
            log_warn_event "Utils" "LOCKING: Failed to release lock for '$item_path_to_unlock'. LockDir '$lock_dir_path' not empty or permission issue?"
            return 1 # Error releasing lock
        fi
    else
        log_debug_event "Utils" "LOCKING: No lock found to release for '$item_path_to_unlock' (LockDir: $lock_dir_path)"
        return 0 # No lock to release, consider it success
    fi
}


#==============================================================================
# HISTORY TRACKING FUNCTIONS
#==============================================================================

#==============================================================================
# Function: record_transfer_to_history
# Description: Log successful transfers or significant events to history file.
# Parameters:
#   $1: Entry to record in the history file (e.g., "Source -> Dest (Category)")
# Returns: 0 on success, 1 on failure.
# Side Effects: Creates history directory and file if they don't exist.
#==============================================================================
record_transfer_to_history() {
    local history_entry="$1"

    if [[ -z "$HISTORY_FILE" ]]; then
         log_warn_event "Utils" "HISTORY: HISTORY_FILE is not set in config. Cannot record history."
         return 1
    fi

    local history_dir; history_dir=$(dirname "$HISTORY_FILE")
    if [[ ! -d "$history_dir" ]]; then
        log_user_info "Utils" "HISTORY: History directory '$history_dir' not found. Attempting to create."
        if ! mkdir -p "$history_dir"; then
            log_error_event "Utils" "HISTORY: Failed to create history directory '$history_dir'. Cannot record history."
            return 1
        fi
    fi
    if [[ ! -w "$history_dir" ]]; then
         log_error_event "Utils" "HISTORY: History directory '$history_dir' is not writable. Cannot record history."
         return 1
    fi

    if [[ ! -f "$HISTORY_FILE" ]]; then
        log_user_info "Utils" "HISTORY: History file '$HISTORY_FILE' not found. Creating."
        log_debug_event "Utils" "HISTORY: History file '$HISTORY_FILE' not found. Creating."
        touch "$HISTORY_FILE" || { log_error_event "Utils" "HISTORY: Could not create history file: $HISTORY_FILE"; return 1; }
    fi

    local history_line; history_line="$(date '+%Y-%m-%d %H:%M:%S') - $history_entry"

    if command -v flock &>/dev/null; then
        exec 200>>"$HISTORY_FILE" # Open FD. If this fails, set -e should handle it.
        if flock -w 0.5 200; then # Attempt to acquire lock on FD 200
            # Lock acquired
            if ! echo "$history_line" >&200; then
                local echo_status=$? # Capture actual echo status for logging
                log_error_event "Utils" "HISTORY: Write to history file failed (flock held, echo status: $echo_status). File: $HISTORY_FILE"
                flock -u 200  # Release the lock
                exec 200>&-   # Close the file descriptor
                return 1      # Indicate failure
            fi
            # Echo succeeded
            flock -u 200      # Release the lock
            exec 200>&-       # Close the file descriptor
        else
            # Flock failed (timeout or other error)
            local flock_status=$? # Capture flock status for logging
            log_warn_event "Utils" "HISTORY: Flock timeout or error (status: $flock_status). Could not acquire lock for history file '$HISTORY_FILE'. Entry: '$history_entry'"
            exec 200>&-       # Close the file descriptor
            return 1          # Indicate failure
        fi
    else
        # Fallback if flock is not available
        if ! echo "$history_line" >> "$HISTORY_FILE"; then
            local echo_status=$? # Capture actual echo status for logging
            log_error_event "Utils" "HISTORY: Write to history file failed (flock not available, echo status: $echo_status). File: $HISTORY_FILE"
            return 1
        fi
        # Log warning about flock missing, but proceed as write was successful
        log_warn_event "Utils" "HISTORY: 'flock' command not found. Concurrent history writes may be unsafe."
    fi

    # If we reached here, it means the write was successful (either with flock or fallback)
    log_debug_event "Utils" "HISTORY: Recorded entry: $history_entry"
    return 0
}

#==============================================================================
# Function: get_file_extension
# Description: Get file extension (including the leading dot).
# Parameters:
#   $1: Filename or path.
# Returns: File extension via echo (e.g., ".mkv") or empty string if no extension.
#==============================================================================
get_file_extension() {
    local filename="$1"
    local extension; extension="${filename##*.}"
    if [[ "$extension" == "$filename" ]] || [[ -z "$extension" ]]; then
        echo ""
    else
        echo ".${extension}"
    fi
}

#==============================================================================
# Function: check_available_disk_space
# Description: Check available disk space before transfer for JellyMac AMP operations.
# Parameters:
#   $1: Destination path to check (directory).
#   $2: Required size in KB (as an integer string).
# Returns: 0 on success (sufficient space), 1 on failure (insufficient space or error).
#==============================================================================
check_available_disk_space() {
    local dest_path_to_check="$1"
    local required_space_kb="$2"

    if [[ -z "$dest_path_to_check" ]]; then
        log_error_event "Utils" "DISK_SPACE: Destination path not provided for check."
        return 1
    fi
    if [[ -z "$required_space_kb" ]] || ! [[ "$required_space_kb" =~ ^[0-9]+$ ]]; then
         log_error_event "Utils" "DISK_SPACE: Invalid or empty required space '$required_space_kb' provided. Must be a positive integer."
         return 1
    fi
    if (( required_space_kb < 0 )); then
         log_warn_event "Utils" "DISK_SPACE: Negative required space '$required_space_kb' provided. Treating as 0."
         required_space_kb=0
    fi

    local df_output; df_output=$(df -Pk "$dest_path_to_check" 2>/dev/null)
    local df_exit_status=$?

    if [[ $df_exit_status -ne 0 ]]; then
         log_error_event "Utils" "DISK_SPACE: 'df -Pk' command failed for '$dest_path_to_check'. Exit code: $df_exit_status."
         return 1
    fi

    local filesystem; filesystem=$(echo "$df_output" | awk 'NR==2 {print $6}')
    local available_space_kb_raw; available_space_kb_raw=$(echo "$df_output" | awk 'NR==2 {print $4}')

    if [[ -z "$filesystem" ]]; then
        log_error_event "Utils" "DISK_SPACE: Could not determine filesystem from 'df -Pk' output for '$dest_path_to_check'."
        return 1
    fi

    if [[ -z "$available_space_kb_raw" ]] || ! [[ "$available_space_kb_raw" =~ ^[0-9]+$ ]]; then
        log_error_event "Utils" "DISK_SPACE: Could not parse available space from 'df -Pk' output for '$filesystem'. Output format unexpected."
        return 1
    fi

    local available_space_kb="$available_space_kb_raw"

    log_debug_event "Utils" "DISK_SPACE: Check for '$dest_path_to_check' (FS: $filesystem): Required: ${required_space_kb} KB, Available: ${available_space_kb} KB."

    if (( available_space_kb >= required_space_kb )); then
        log_debug_event "Utils" "DISK_SPACE: Sufficient disk space available."
        return 0
    else
        log_warn_event "Utils" "DISK_SPACE: Insufficient disk space. Required: ${required_space_kb} KB, Available: ${available_space_kb} KB."
        return 1
    fi
}

#==============================================================================
# Function: find_executable
# Description: Finds the path of an executable command needed by JellyMac AMP scripts.
#              Checks hint paths and standard system PATH.
# Parameters:
#   $1: The executable name (e.g., "yt-dlp", "transmission-remote").
#   $2: (Optional) A hint path or colon-separated list of hint paths to check first.
# Returns: The full path to the executable via echo.
# Side Effects: Exits with error code 1 if executable is not found.
#==============================================================================
find_executable() {
    local exe_name="$1"
    local hint_paths="$2"
    local found_path=""
    local IFS_backup="$IFS"

    log_debug_event "Utils" "EXEC_FIND: Looking for executable: '$exe_name' (Hints: '${hint_paths:-N/A}')"

    if [[ -n "$hint_paths" ]]; then
        local current_hint_path_list="$hint_paths"
        local delimiter=":"
        local hint_path

        while [[ "$current_hint_path_list" ]]; do
            hint_path="${current_hint_path_list%%"$delimiter"*}"
            if [[ "$current_hint_path_list" == *"$delimiter"* ]]; then
                current_hint_path_list="${current_hint_path_list#*"$delimiter"}"
            else
                current_hint_path_list=""
            fi

            if [[ -n "$hint_path" ]]; then
                 log_debug_event "Utils" "EXEC_FIND: Checking hint path: '$hint_path'"
                if [[ -x "$hint_path" && "$(basename "$hint_path")" == "$exe_name" ]]; then
                     found_path="$hint_path"
                     log_debug_event "Utils" "EXEC_FIND: Found in hint path itself: '$found_path'"
                     break
                elif [[ -x "${hint_path}/${exe_name}" ]]; then
                    found_path="${hint_path}/${exe_name}"
                    log_debug_event "Utils" "EXEC_FIND: Found in hint path directory: '$found_path'"
                    break
                fi
            fi
        done
    fi

    if [[ -z "$found_path" ]]; then
        log_debug_event "Utils" "EXEC_FIND: Not found in hints, checking system PATH..."
        local path_cmd_output; path_cmd_output=$(command -v "$exe_name" 2>/dev/null)
        if [[ -n "$path_cmd_output" ]]; then
             found_path="$path_cmd_output"
             log_debug_event "Utils" "EXEC_FIND: Found in PATH: '$found_path'"
        fi
    fi

    if [[ -z "$found_path" ]] && [[ "$(uname)" == "Darwin" ]]; then
         log_debug_event "Utils" "EXEC_FIND: Not found in PATH, checking common macOS locations..."
         if [[ -x "/opt/homebrew/bin/${exe_name}" ]]; then
             found_path="/opt/homebrew/bin/${exe_name}"
             log_debug_event "Utils" "EXEC_FIND: Found in /opt/homebrew/bin: '$found_path'"
         elif [[ -x "/usr/local/bin/${exe_name}" ]]; then
             found_path="/usr/local/bin/${exe_name}"
             log_debug_event "Utils" "EXEC_FIND: Found in /usr/local/bin: '$found_path'"
         elif [[ -x "/usr/bin/${exe_name}" ]]; then
             found_path="/usr/bin/${exe_name}"
             log_debug_event "Utils" "EXEC_FIND: Found in /usr/bin: '$found_path'"
         fi
    fi

    IFS="$IFS_backup"

    if [[ -n "$found_path" ]]; then
        echo "$found_path"
        return 0
    else
        log_error_event "Utils" "CRITICAL: Required command '$exe_name' not found in PATH or specified hint path(s) ('${hint_paths:-N/A}') or common locations. Exiting."
        exit 1
    fi
}

#==============================================================================
# Function: wait_for_file_stability
# Description: Waits until a file or directory size/mtime is stable, indicating
#              completed downloads/transfers before processing.
# Parameters:
#   $1: Path to the file/directory to check.
#   $2: Number of stable checks required (e.g., 3). Uses STABLE_CHECKS_* config if not provided.
#   $3: Sleep interval between checks in seconds (e.g., 10). Uses STABLE_SLEEP_INTERVAL_* config if not provided.
# Returns: 0 if stable, 1 if not stable after checks or if item vanishes/stat fails.
# Side Effects: Creates temporary files that are tracked for cleanup.
#==============================================================================
_COMMON_UTILS_TEMP_FILES_TO_CLEAN=() # Initialize array for temp files used by this script
wait_for_file_stability() {
    local item_path="$1"
    local max_stable_checks_for_item="${2:-3}"
    local sleep_interval_for_item="${3:-10}"
    local item_basename

    if [[ -z "$2" ]]; then
        if [[ -n "${STABLE_CHECKS_DROP_FOLDER:-}" ]]; then max_stable_checks_for_item="$STABLE_CHECKS_DROP_FOLDER"; fi
    fi
    if [[ -z "$3" ]]; then
         if [[ -n "${STABLE_SLEEP_INTERVAL_DROP_FOLDER:-}" ]]; then sleep_interval_for_item="$STABLE_SLEEP_INTERVAL_DROP_FOLDER"; fi
    fi

    if [[ -z "$item_path" ]]; then
        log_error_event "Utils" "STABILITY: No item path provided for stability check."
        return 1
    fi
    if ! [[ "$max_stable_checks_for_item" =~ ^[0-9]+$ ]] || (( max_stable_checks_for_item < 1 )); then
         log_warn_event "Utils" "STABILITY: Invalid effective max_stable_checks_for_item '$max_stable_checks_for_item'. Using default 3."
         max_stable_checks_for_item=3
    fi
     if ! [[ "$sleep_interval_for_item" =~ ^[0-9]+$ ]] || (( sleep_interval_for_item < 1 )); then
         log_warn_event "Utils" "STABILITY: Invalid effective sleep_interval_for_item '$sleep_interval_for_item'. Using default 10."
         sleep_interval_for_item=10
    fi

    item_basename=$(basename "$item_path")
    local last_combined_stat=""
    local current_combined_stat=""
    local stable_count=0

    log_debug_event "Utils" "🕵️‍♂️ Stability check for '$item_basename' ($max_stable_checks_for_item checks, ${sleep_interval_for_item}s interval)..."

    for ((i=0; i < max_stable_checks_for_item; i++)); do
        if [[ ! -e "$item_path" ]]; then
            log_warn_event "Utils" "⚠️ '$item_basename': Vanished during stability check (iteration $((i+1)))."
            return 1
        fi

        local current_size_bytes=""
        local current_mtime=""

        if [[ "$(uname)" == "Darwin" ]]; then
            if [[ -d "$item_path" ]]; then
                local sum_size=0
                local find_output_temp; find_output_temp=$(mktemp "${SCRIPT_DIR:-/tmp}/.stability_find_XXXXXX")
                local xargs_stat_output_temp; xargs_stat_output_temp=$(mktemp "${SCRIPT_DIR:-/tmp}/.stability_xargs_XXXXXX")
                _COMMON_UTILS_TEMP_FILES_TO_CLEAN[${#_COMMON_UTILS_TEMP_FILES_TO_CLEAN[@]}]="$find_output_temp"
                _COMMON_UTILS_TEMP_FILES_TO_CLEAN[${#_COMMON_UTILS_TEMP_FILES_TO_CLEAN[@]}]="$xargs_stat_output_temp"

                find "$item_path" -type f -print0 2>/dev/null > "$find_output_temp"
                local find_exit=${PIPESTATUS[0]}

                if [[ $find_exit -ne 0 ]]; then
                     log_warn_event "Utils" "⚠️ '$item_basename': Find failed during size sum (iteration $((i+1))). Exit code $find_exit. Treating as unstable."
                     return 1
                fi

                if [[ -s "$find_output_temp" ]]; then
                    xargs -0 stat -f "%z" < "$find_output_temp" 2>/dev/null > "$xargs_stat_output_temp"
                    local xargs_stat_exit=${PIPESTATUS[0]}

                    if [[ $xargs_stat_exit -ne 0 ]]; then
                        log_warn_event "Utils" "⚠️ '$item_basename': Stat failed via xargs during size sum (iteration $((i+1))). Exit code $xargs_stat_exit. Treating as unstable."
                        return 1
                    fi

                    local size_line
                    while read -r size_line; do
                        if [[ "$size_line" =~ ^[0-9]+$ ]]; then
                            sum_size=$((sum_size + size_line))
                        else
                            log_debug_event "Utils" "↳ STABILITY: Skipping non-numeric size line during sum for '$item_basename': '$size_line'"
                        fi
                    done < "$xargs_stat_output_temp"
                else
                    log_debug_event "Utils" "↳ '$item_basename' is a directory with no files found by 'find -type f' for size sum."
                fi
                current_size_bytes="$sum_size"
                current_mtime=$(stat -f "%m" "$item_path" 2>/dev/null)

            elif [[ -f "$item_path" ]]; then
                local stat_output; stat_output=$(stat -f "%z %m" "$item_path" 2>/dev/null)
                local stat_exit=$?
                if [[ $stat_exit -ne 0 ]]; then
                     log_warn_event "Utils" "⚠️ '$item_basename': Stat failed for file (iteration $((i+1))). Exit code $stat_exit. Treating as unstable."
                     return 1
                fi
                current_size_bytes=$(echo "$stat_output" | awk '{print $1}')
                current_mtime=$(echo "$stat_output" | awk '{print $2}')
            else
                log_warn_event "Utils" "⚠️ '$item_basename': Not a regular file or directory for stability check. Path: $item_path. Treating as unstable."
                return 1
            fi
        else
            if [[ -d "$item_path" ]]; then
                local sum_size=0
                local find_output_temp; find_output_temp=$(mktemp "${SCRIPT_DIR:-/tmp}/.stability_find_XXXXXX")
                local xargs_stat_output_temp; xargs_stat_output_temp=$(mktemp "${SCRIPT_DIR:-/tmp}/.stability_xargs_XXXXXX")
                _COMMON_UTILS_TEMP_FILES_TO_CLEAN[${#_COMMON_UTILS_TEMP_FILES_TO_CLEAN[@]}]="$find_output_temp"
                _COMMON_UTILS_TEMP_FILES_TO_CLEAN[${#_COMMON_UTILS_TEMP_FILES_TO_CLEAN[@]}]="$xargs_stat_output_temp"

                find "$item_path" -type f -print0 2>/dev/null > "$find_output_temp"
                 local find_exit=${PIPESTATUS[0]}

                if [[ $find_exit -ne 0 ]]; then
                     log_warn_event "Utils" "⚠️ '$item_basename': Find failed during size sum (iteration $((i+1))). Exit code $find_exit. Treating as unstable."
                     return 1
                fi

                if [[ -s "$find_output_temp" ]]; then
                    xargs -0 stat -c "%s" < "$find_output_temp" 2>/dev/null > "$xargs_stat_output_temp"
                    local xargs_stat_exit=${PIPESTATUS[0]}

                    if [[ $xargs_stat_exit -ne 0 ]]; then
                         log_warn_event "Utils" "⚠️ '$item_basename': Stat failed via xargs during size sum (iteration $((i+1))). Exit code $xargs_stat_exit. Treating as unstable."
                         return 1
                    fi

                    local size_line
                    while read -r size_line; do
                         if [[ "$size_line" =~ ^[0-9]+$ ]]; then
                            sum_size=$((sum_size + size_line))
                        else
                             log_debug_event "Utils" "↳ STABILITY: Skipping non-numeric size line during sum for '$item_basename' (GNU stat): '$size_line'"
                        fi
                    done < "$xargs_stat_output_temp"
                else
                     log_debug_event "Utils" "↳ '$item_basename' is a directory with no files found by 'find -type f' for size sum (GNU stat)."
                fi
                current_size_bytes="$sum_size"
                current_mtime=$(stat -c "%Y" "$item_path" 2>/dev/null)
            elif [[ -f "$item_path" ]]; then
                local stat_output; stat_output=$(stat -c "%s %Y" "$item_path" 2>/dev/null)
                local stat_exit=$?
                 if [[ $stat_exit -ne 0 ]]; then
                     log_warn_event "Utils" "⚠️ '$item_basename': Stat failed for file (iteration $((i+1))) (GNU stat). Exit code $stat_exit. Treating as unstable."
                     return 1
                fi
                current_size_bytes=$(echo "$stat_output" | awk '{print $1}')
                current_mtime=$(echo "$stat_output" | awk '{print $2}')
            else
                 log_warn_event "Utils" "⚠️ '$item_basename': Not a regular file or directory for stability check (GNU stat). Path: $item_path. Treating as unstable."
                 return 1
            fi
        fi

        if [[ -z "$current_size_bytes" ]] || [[ -z "$current_mtime" ]]; then
             log_warn_event "Utils" "⚠️ '$item_basename': Could not determine size/mtime reliably (iteration $((i+1))). Stat output unexpected. Treating as unstable."
             return 1
        fi

        current_combined_stat="${current_size_bytes}:${current_mtime}"
        local current_size_display
        current_size_display=$(du -sh "$item_path" 2>/dev/null | awk '{print $1}')
        if [[ -z "$current_size_display" ]]; then current_size_display="N/A"; fi

        if [[ $i -gt 0 && "$current_combined_stat" != "$last_combined_stat" ]]; then
            log_debug_event "Utils" "↳ '$item_basename': Stat changed. Last: [$last_combined_stat], Current: [$current_combined_stat]. Resetting checks."
            stable_count=0
        else
            stable_count=$((stable_count + 1))
        fi

        log_debug_event "Utils" "↳ '$item_basename': Check $((i + 1))/$max_stable_checks_for_item, Display Size: ${current_size_display}, ByteSize:Mtime: [${current_combined_stat}] (Stable count: $stable_count/$max_stable_checks_for_item)"

        if [[ "$stable_count" -ge "$max_stable_checks_for_item" ]]; then
            log_user_progress "Utils" "✅ '$item_basename': Stable (${current_size_display})"
            return 0
        fi

        last_combined_stat="$current_combined_stat"

        if [[ $i -lt $((max_stable_checks_for_item - 1)) ]]; then
            log_debug_event "Utils" "⏳ '$item_basename': Waiting ${sleep_interval_for_item}s..."
            sleep "$sleep_interval_for_item"
        fi
    done

    log_warn_event "Utils" "⚠️ '$item_basename': Not stable after $max_stable_checks_for_item checks (Last ByteSize:Mtime: [${last_combined_stat}])."
    return 1
}

#==============================================================================
# Function: play_sound_notification
# Description: Plays a notification sound if enabled and afplay is available.
# Parameters:
#   $1: Sound type ('input_detected', 'task_success', 'task_error') or direct path to sound file.
#   $2: (Optional) Log prefix for warnings. Defaults to "SOUND_PLAYER".
# Returns: 0 if sound played, is disabled, or not applicable. 1 on error if sound was meant to play.
#==============================================================================
play_sound_notification() {
    local sound_type_or_path="$1"
    local log_prefix_sound="${2:-Utils}"
    local sound_file_to_play=""

    if [[ "${SOUND_NOTIFICATION:-false}" != "true" ]]; then
        return 0
    fi

    if ! command -v afplay &>/dev/null; then
        return 0  # Silently skip - sound not available on this system
    fi

    case "$sound_type_or_path" in
        "input_detected")
            sound_file_to_play="${SOUND_INPUT_DETECTED_FILE:-/System/Library/Sounds/Funk.aiff}"
            ;;
        "task_success")
            sound_file_to_play="${SOUND_TASK_SUCCESS_FILE:-/System/Library/Sounds/Glass.aiff}"
            ;;
        "task_error")
            if [[ -n "${SOUND_TASK_ERROR_FILE}" ]]; then
                sound_file_to_play="${SOUND_TASK_ERROR_FILE}"
            else
                return 0
            fi
            ;;
        *)
            if [[ -f "$sound_type_or_path" ]]; then
                sound_file_to_play="$sound_type_or_path"
            else
                log_warn_event "$log_prefix_sound" "Sound type '$sound_type_or_path' is unknown and not a valid file path. Using default input sound."
                sound_file_to_play="${SOUND_INPUT_DETECTED_FILE:-/System/Library/Sounds/Tink.aiff}"
            fi
            ;;
    esac

    if [[ -z "$sound_file_to_play" ]]; then
        log_warn_event "$log_prefix_sound" "No sound file specified or resolved for type/path '$sound_type_or_path'."
        return 1
    fi

    if [[ -f "$sound_file_to_play" ]]; then
        (afplay "$sound_file_to_play" &)
        return 0
    else
        log_warn_event "$log_prefix_sound" "Sound file not found: '$sound_file_to_play' for type/path '$sound_type_or_path'."
        return 1
    fi
}

#==============================================================================
# Function: transfer_local_file
# Description: Simple local file transfer using mv. For known good files on local storage.
# Parameters:
#   $1: source path
#   $2: destination path
#   $3: log prefix (optional, defaults to "Utils")
# Returns: 0 on success, 1 on failure
#==============================================================================
transfer_local_file() {
    local source_path="$1"
    local dest_path="$2"
    local log_prefix="${3:-Utils}"
    
    local source_basename; source_basename=$(basename "$source_path")
    
    log_debug_event "$log_prefix" "Local transfer: '$source_path' -> '$dest_path'"
    
    if mv "$source_path" "$dest_path"; then
        log_debug_event "$log_prefix" "Local transfer successful: '$source_basename'"
        return 0
    else
        local mv_exit_code=$?
        log_error_event "$log_prefix" "Failed to move '$source_basename' to destination (exit code: $mv_exit_code)"
        return 1
    fi
}

#==============================================================================
# Function: transfer_file_smart
# Description: Smart file transfer - uses transfer_local_file for local paths,
#              rsync_with_network_retry for network paths (/Volumes/*)
# Parameters:
#   $1: source path
#   $2: destination path
#   $3: log prefix (optional, defaults to "Utils")
# Returns: 0 on success, 1 on failure
#==============================================================================
transfer_file_smart() {
    local source_path="$1"
    local dest_path="$2"
    local log_prefix="${3:-Utils}"
    
    if [[ -z "$source_path" || -z "$dest_path" ]]; then
        log_error_event "$log_prefix" "transfer_file_smart: Source and destination paths required"
        return 1
    fi
    
    # Validate network volumes before transfer
    if ! validate_network_volume_before_transfer "$dest_path" "$log_prefix"; then
        return 1
    fi
    
    # Use same detection logic as rsync_with_network_retry for consistency
    if [[ "$dest_path" == /Volumes/* ]]; then
        log_debug_event "$log_prefix" "Network destination detected, using rsync with retry"
        rsync_with_network_retry "$source_path" "$dest_path" "-av --progress --remove-source-files"
    else
        log_debug_event "$log_prefix" "Local destination detected, using local transfer"
        transfer_local_file "$source_path" "$dest_path" "$log_prefix"
    fi
}

#==============================================================================
# Function: quarantine_item
# Description: Moves a failed or problematic item to the error/quarantine directory.
# Parameters:
#   $1: Path to the item to quarantine (file or directory).
#   $2: Reason for quarantine (string).
# Returns: 0 on success (or if source was already gone), 1 on failure to quarantine.
# Side Effects: Creates quarantine directory if needed, logs to history.
#==============================================================================
quarantine_item() {
    local item_to_quarantine_path="$1"
    local reason_for_quarantine="$2"
    local item_basename_for_log; item_basename_for_log=$(basename "$item_to_quarantine_path")

    log_warn_event "Utils" "QUARANTINE: Attempting to quarantine item '$item_basename_for_log' due to: $reason_for_quarantine"

    if [[ -z "$ERROR_DIR" ]]; then
        log_error_event "Utils" "QUARANTINE: ERROR_DIR is not set in config. Cannot quarantine."
        return 1
    fi
    if [[ ! -d "$ERROR_DIR" ]]; then
        log_user_info "Utils" "QUARANTINE: Quarantine directory '$ERROR_DIR' does not exist. Creating."
        if ! mkdir -p "$ERROR_DIR"; then
            log_error_event "Utils" "QUARANTINE: Failed to create quarantine directory '$ERROR_DIR'. Check permissions."
            return 1
        fi
    fi
    if [[ ! -w "$ERROR_DIR" ]]; then
         log_error_event "Utils" "QUARANTINE: Quarantine directory '$ERROR_DIR' is not writable. Cannot quarantine."
         return 1
    fi

    if [[ ! -e "$item_to_quarantine_path" ]]; then
        log_warn_event "Utils" "QUARANTINE: Cannot quarantine '$item_basename_for_log': Source path '$item_to_quarantine_path' does not exist or is not accessible."
        log_user_info "Utils" "QUARANTINE: Source item '$item_to_quarantine_path' not found. Assuming it was already handled or removed. Skipping quarantine move."
        return 0
    fi

    local quarantine_dest_path="${ERROR_DIR}/${item_basename_for_log}"
    if [[ -e "$quarantine_dest_path" ]]; then
        local unique_suffix; unique_suffix="_failed_$(date +%Y%m%d_%H%M%S)_$RANDOM"
        local dest_basename; dest_basename="${item_basename_for_log}"
        local dest_ext=""; if [[ -f "$item_to_quarantine_path" ]]; then dest_ext=$(get_file_extension "$item_to_quarantine_path"); fi
        if [[ -n "$dest_ext" ]]; then
             dest_basename="${item_basename_for_log%"${dest_ext}"}"
             quarantine_dest_path="${ERROR_DIR}/${dest_basename}${unique_suffix}${dest_ext}"
        else
             quarantine_dest_path="${ERROR_DIR}/${dest_basename}${unique_suffix}"
        fi
        log_warn_event "Utils" "QUARANTINE: Destination '$quarantine_dest_path' exists in quarantine, using unique name."
    fi

    log_user_info "Utils" "QUARANTINE: Moving '$item_basename_for_log' to quarantine '$quarantine_dest_path'..."
    if mv "$item_to_quarantine_path" "$quarantine_dest_path"; then
        log_user_info "Utils" "QUARANTINE: Item successfully moved to quarantine: $quarantine_dest_path"
        record_transfer_to_history "$item_to_quarantine_path -> $quarantine_dest_path (QUARANTINED: $reason_for_quarantine)" || \
            log_warn_event "Utils" "QUARANTINE: Failed to record quarantine in history."
        return 0
    else
        log_error_event "Utils" "QUARANTINE: Failed to move item to quarantine: '$item_to_quarantine_path' -> '$quarantine_dest_path'. Manual intervention needed."
        return 1
    fi
}

#==============================================================================
# Function: rsync_with_network_retry
# Description: rsync wrapper with retry logic for network destinations.
#              Uses existing volume detection from doctor_utils.sh for consistency.
#              Automatically resumes transfers from where they left off on retry.
# Parameters:
#   $1: source path
#   $2: destination path  
#   $3: rsync options (optional, defaults to "-av --progress --remove-source-files")
#   $4: max retries (optional, defaults to 3)
# Returns: rsync exit code (0 on success, non-zero on failure)
# Side Effects: Logs retry attempts, may create partial files during transfer
#==============================================================================
rsync_with_network_retry() {
    local source_path="$1"
    local dest_path="$2"
    local rsync_options="${3:--av --progress --remove-source-files}"
    local max_retries="${4:-3}"
    
    if [[ -z "$source_path" || -z "$dest_path" ]]; then
        log_error_event "Utils" "rsync_with_network_retry: Source and destination paths required"
        return 1
    fi
    
    # Simple network destination detection - trust that doctor validated mounts
    local is_network_dest=false
    if [[ "$dest_path" == /Volumes/* ]]; then
        is_network_dest=true
        log_debug_event "Utils" "Network destination detected: $dest_path"
    else
        log_debug_event "Utils" "Local destination detected: $dest_path"
    fi
    
    # For local destinations, use standard rsync
    if [[ "$is_network_dest" != "true" ]]; then
        log_debug_event "Utils" "Local destination detected, using standard rsync: $dest_path"
        rsync "$rsync_options" "$source_path" "$dest_path"
        return $?
    fi
    
    # Network destination - use retry logic with resume capability
    log_debug_event "Utils" "Network destination detected, using retry logic with resume: $dest_path"
    
    local attempt=1
    local retry_delays=(10 30 60)  # Fixed intervals: 10s, 30s, 60s
    local source_basename
    source_basename=$(basename "$source_path")
    
    # Build retry options array instead of string manipulation
    local retry_rsync_args=()
    local remove_source_on_success=false
    
    # Parse original options into array
    local opt
    for opt in $rsync_options; do
        if [[ "$opt" == "--remove-source-files" ]]; then
            remove_source_on_success=true
            # Skip adding this to retry args
        else
            retry_rsync_args+=("$opt")
        fi
    done
    
    # Add required options
    retry_rsync_args+=("--partial")
    retry_rsync_args+=("--timeout=${RSYNC_TIMEOUT:-300}")
    
    while [[ $attempt -le $max_retries ]]; do
        log_user_progress "Utils" "📡 Network transfer attempt $attempt/$max_retries: $source_basename"
        log_debug_event "Utils" "rsync attempt $attempt/$max_retries: $source_path -> $dest_path"
        
        # DEBUG: Show exactly what rsync will execute
        log_debug_event "Utils" "DEBUG: rsync args: ${retry_rsync_args[*]}"
        
        # Use array expansion for clean argument passing
        if rsync "${retry_rsync_args[@]}" "$source_path" "$dest_path"; then
            log_user_progress "Utils" "✅ Network transfer succeeded on attempt $attempt: $source_basename"
            
            # If transfer succeeded and we need to remove source, do it now
            if [[ "$remove_source_on_success" == "true" ]]; then
                log_debug_event "Utils" "Transfer complete, removing source file: $source_path"
                if rm "$source_path"; then
                    log_debug_event "Utils" "Successfully removed source file after transfer"
                else
                    log_warn_event "Utils" "Transfer completed but failed to remove source file: $source_path"
                fi
            fi
            
            return 0
        fi
        
        local rsync_exit_code=$?
        log_warn_event "Utils" "Network transfer attempt $attempt failed (exit code: $rsync_exit_code): $source_basename"
        
        if [[ $attempt -lt $max_retries ]]; then
            local delay=${retry_delays[$((attempt-1))]}
            log_user_progress "Utils" "⏳ Retrying in ${delay}s... (Network transfer will resume from where it left off)"
            log_debug_event "Utils" "Waiting ${delay}s before retry attempt $((attempt+1))..."
            sleep "$delay"
        fi
        
        ((attempt++))
    done
    
    # All retries failed - show user-friendly message
    log_error_event "Utils" "❌ Network transfer failed after $max_retries attempts: $source_basename"
    log_user_info "Utils" "💡 Transfer failed. Please check your network connection and try again."
    log_user_info "Utils" "   • Verify the network volume is still mounted"
    log_user_info "Utils" "   • Check network connectivity to your media server"
    log_user_info "Utils" "   • The transfer will automatically resume from where it stopped"
    
    return "$rsync_exit_code"
}

#==============================================================================
# Function: validate_network_volume_before_transfer
# Description: Validates network volumes are mounted and accessible before transfer
# Parameters:
#   $1: Destination path to validate
#   $2: Log prefix (optional, defaults to "Utils")
# Returns: 0 if valid or local path, 1 if network volume unavailable
#==============================================================================
validate_network_volume_before_transfer() {
    local dest_path="$1"
    local log_prefix="${2:-Utils}"
    
    # Skip validation for local paths
    if [[ "$dest_path" != /Volumes/* ]]; then
        return 0
    fi
    
    # Extract volume name
    local volume_name
    if [[ "$dest_path" =~ ^/Volumes/([^/]+) ]]; then
        volume_name="${BASH_REMATCH[1]}"
    else
        log_error_event "$log_prefix" "Invalid /Volumes/ path format: $dest_path"
        return 1
    fi
    
    # Check if volume is mounted
    if [[ ! -d "/Volumes/$volume_name" ]]; then
        log_error_event "$log_prefix" "Volume '$volume_name' is no longer mounted"
        log_user_info "$log_prefix" "💔 Network share disconnected: '$volume_name'"
        log_user_info "$log_prefix" "🔗 To reconnect: Finder → Cmd+K → reconnect to server"
        
        return 1
    fi
    
    # Extract destination directory (not the full file path)
    local dest_dir
    if [[ -f "$dest_path" || "$dest_path" == */* ]]; then
        dest_dir="$(dirname "$dest_path")"
    else
        dest_dir="$dest_path"
    fi
    
    # Check if destination directory exists and is writable
    if [[ ! -d "$dest_dir" ]] || [[ ! -w "$dest_dir" ]]; then
        log_error_event "$log_prefix" "Destination directory unavailable: $dest_dir"
        log_user_info "$log_prefix" "💔 Media folder inaccessible on '$volume_name'"
        
        # Play error sound for access issues
        play_sound_notification "task_error" "$log_prefix"
        
        return 1
    fi
    
    return 0
}

#==============================================================================
# Function: send_desktop_notification
# Description: Sends macOS desktop notification with title, message, and optional sound
# Parameters:
#   $1: Notification title
#   $2: Notification message  
#   $3: Sound name (optional, defaults to "Purr")
# Returns: None
# Side Effects: Displays macOS notification if enabled and on Darwin platform
#==============================================================================
send_desktop_notification() {
    local title="$1"; local message="$2"; local sound_name="${3:-Purr}"

    if [[ "${ENABLE_DESKTOP_NOTIFICATIONS:-false}" != "true" || "$(uname)" != "Darwin" ]]; then return; fi
    
    # Find osascript command
    local osascript_cmd
    osascript_cmd=$(find_executable "osascript" "")
    if [[ "$osascript_cmd" == "NOT_FOUND" ]]; then return; fi

    # Validate required parameters
    if [[ -z "$title" || -z "$message" ]]; then
        log_warn_event "Notification" "send_desktop_notification called with missing title or message parameters. Skipping notification."
        return
    fi

    local safe_title; safe_title=$(echo "$title" | sed 's/\\/\\\\/g; s/"/\\"/g' | head -c 100)
    local safe_message; safe_message=$(echo "$message" | sed 's/\\/\\\\/g; s/"/\\"/g' | head -c 200)
    local osascript_command_str="display notification \"${safe_message}\" with title \"${safe_title}\""
    if [[ -n "$sound_name" ]]; then osascript_command_str+=" sound name \"${sound_name}\""; fi

    log_debug_event "Notification" "Sending desktop notification: Title='${title}', Message='${message}'"
    "$osascript_cmd" -e "$osascript_command_str" >/dev/null 2>&1 &
}

#==============================================================================
# Function: _cleanup_common_utils_temp_files
# Description: Cleans up any temporary files created by functions in this script.
# Parameters: None.
# Returns: None (cleans up files tracked in _COMMON_UTILS_TEMP_FILES_TO_CLEAN).
# Note: The main script should add this to its trap handlers.
#==============================================================================
_cleanup_common_utils_temp_files() {
    # shellcheck disable=SC2128 # We want to check array length
    if [[ ${#_COMMON_UTILS_TEMP_FILES_TO_CLEAN[@]} -gt 0 ]]; then
        log_debug_event "Utils" "EXIT trap: Cleaning up common_utils temporary files (${#_COMMON_UTILS_TEMP_FILES_TO_CLEAN[@]})..."
        local temp_file_path_to_clean
        for temp_file_path_to_clean in "${_COMMON_UTILS_TEMP_FILES_TO_CLEAN[@]}"; do
            if [[ -n "$temp_file_path_to_clean" && -e "$temp_file_path_to_clean" ]]; then
                rm -rf "$temp_file_path_to_clean"
                log_debug_event "Utils" "EXIT trap: Removed '$temp_file_path_to_clean'"
            fi
        done
    fi
    _COMMON_UTILS_TEMP_FILES_TO_CLEAN=()
}
# Note: Trap is NOT set here. The calling script (JellyMac.sh) must set a trap
# that includes a call to _cleanup_common_utils_temp_files.
