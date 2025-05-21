#!/bin/bash

# lib/common_utils.sh
# Contains common utility functions shared across the JellyMac AMP (Automated Media Pipeline) project.
# These functions should be as self-contained as possible but rely on
# logging functions (from logging_utils.sh) and configuration variables
# (from combined.conf.sh) being sourced *before* this script.
# Assumes SCRIPT_DIR is exported by the main script for mktemp.

# Check that required logging functions are available (basic check)
if ! command -v log_info_event &>/dev/null; then
    echo "FATAL ERROR: common_utils.sh requires logging_utils.sh to be sourced first." >&2
    exit 1
fi

#==============================================================================
# HISTORY TRACKING FUNCTIONS
#==============================================================================

# Function: record_transfer_to_history
# Description: Log successful transfers or significant events to history file
# Parameters:
#   $1: Entry to record in the history file (e.g., "Source -> Dest (Category)")
# Returns: 0 on success, 1 on failure
# Side Effects: Creates history directory and file if they don't exist
record_transfer_to_history() {
    local history_entry="$1"

    if [[ -z "$HISTORY_FILE" ]]; then
         log_warn_event "COMMON_UTILS" "HISTORY: HISTORY_FILE is not set in config. Cannot record history."
         return 1
    fi

    # Check if the directory exists and is writable, attempt creation if not
    local history_dir; history_dir=$(dirname "$HISTORY_FILE")
    if [[ ! -d "$history_dir" ]]; then
        log_info_event "COMMON_UTILS" "HISTORY: History directory '$history_dir' not found. Attempting to create."
        if ! mkdir -p "$history_dir"; then
            log_error_event "COMMON_UTILS" "HISTORY: Failed to create history directory '$history_dir'. Cannot record history."
            return 1
        fi
    fi
    if [[ ! -w "$history_dir" ]]; then
         log_error_event "COMMON_UTILS" "HISTORY: History directory '$history_dir' is not writable. Cannot record history."
         return 1
    fi

    # Check if the history file itself exists, attempt creation if not
    if [[ ! -f "$HISTORY_FILE" ]]; then
        log_info_event "COMMON_UTILS" "HISTORY: History file '$HISTORY_FILE' not found. Creating."
        # Use direct echo here as log_info_event might not be fully set up for file logging
        echo "$(date '+%Y-%m-%d %H:%M:%S') - INFO: COMMON_UTILS - History file '$HISTORY_FILE' not found. Creating." >> /dev/stderr # Log creation to stderr just in case
        touch "$HISTORY_FILE" || { log_error_event "COMMON_UTILS" "HISTORY: Could not create history file: $HISTORY_FILE"; return 1; }
    fi

    # Prepare the line to write
    local history_line; history_line="$(date '+%Y-%m-%d %H:%M:%S') - $history_entry"

    # Append the new entry with timestamp
    # Using flock for safer concurrent writes if multiple scripts try to write history
    if command -v flock &>/dev/null; then
        exec 200>>"$HISTORY_FILE" 
        if flock -w 0.5 200; then # Wait up to 0.5 seconds for lock on fd 200
            echo "$history_line" >&200
            # shellcheck disable=SC2320
            local write_status=$?
            if [[ $write_status -ne 0 ]]; then
                log_error_event "COMMON_UTILS" "HISTORY: Write failed (flock used). Status $write_status. Could not write to history file: $HISTORY_FILE"
                exec 200>&-
                return 1
            fi
        else
            log_warn_event "COMMON_UTILS" "HISTORY: Flock timeout. Could not write to history file '$HISTORY_FILE'. Entry: $history_entry"
            exec 200>&-
            return 1
        fi
        exec 200>&-
    else
        # Fallback if flock is not available (less robust for concurrency)
        echo "$history_line" >> "$HISTORY_FILE" || \
            { log_error_event "COMMON_UTILS" "HISTORY: Could not write to history file (flock missing): $HISTORY_FILE"; return 1; }
        log_warn_event "COMMON_UTILS" "HISTORY: 'flock' command not found. Concurrent history writes may be unsafe."
    fi

    log_debug_event "COMMON_UTILS" "HISTORY: Recorded entry: $history_entry"
    return 0
}

# Function: get_file_extension
# Description: Get file extension (including the leading dot)
# Parameters:
#   $1: Filename or path
# Returns: File extension via echo (e.g., ".mkv") or empty string if no extension
get_file_extension() {
    local filename="$1"
    local extension; extension="${filename##*.}"
    if [[ "$extension" == "$filename" ]] || [[ -z "$extension" ]]; then
        # No dot found, or filename is just a dot, or empty filename
        echo ""
    else
        echo ".${extension}"
    fi
}

# Function: check_available_disk_space
# Description: Check available disk space before transfer for JellyMac AMP operations
# Parameters:
#   $1: Destination path to check (directory)
#   $2: Required size in KB (as an integer string)
# Returns: 0 on success (sufficient space), 1 on failure (insufficient space or error)
check_available_disk_space() {
    local dest_path_to_check="$1"
    local required_space_kb="$2"

    if [[ -z "$dest_path_to_check" ]]; then
        log_error_event "COMMON_UTILS" "DISK_SPACE: Destination path not provided for check."
        return 1
    fi
    # Validate required_space_kb is a non-negative integer
    if [[ -z "$required_space_kb" ]] || ! [[ "$required_space_kb" =~ ^[0-9]+$ ]]; then
         log_error_event "COMMON_UTILS" "DISK_SPACE: Invalid or empty required space '$required_space_kb' provided. Must be a positive integer."
         return 1
    fi
    if (( required_space_kb < 0 )); then # Should be caught by regex but being defensive
         log_warn_event "COMMON_UTILS" "DISK_SPACE: Negative required space '$required_space_kb' provided. Treating as 0."
         required_space_kb=0
    fi

    # Use df to get available space in 1KB blocks (-P) for the filesystem containing dest_path
    # Handle potential errors from df gracefully.
    local df_output; df_output=$(df -Pk "$dest_path_to_check" 2>/dev/null)
    local df_exit_status=$?

    if [[ $df_exit_status -ne 0 ]]; then
         log_error_event "COMMON_UTILS" "DISK_SPACE: 'df -Pk' command failed for '$dest_path_to_check'. Exit code: $df_exit_status."
         return 1 # df command failed
    fi

    local filesystem; filesystem=$(echo "$df_output" | awk 'NR==2 {print $6}')
    local available_space_kb_raw; available_space_kb_raw=$(echo "$df_output" | awk 'NR==2 {print $4}')

    if [[ -z "$filesystem" ]]; then
        log_error_event "COMMON_UTILS" "DISK_SPACE: Could not determine filesystem from 'df -Pk' output for '$dest_path_to_check'."
        return 1
    fi

    # Validate available_space_kb_raw is a non-negative integer
    if [[ -z "$available_space_kb_raw" ]] || ! [[ "$available_space_kb_raw" =~ ^[0-9]+$ ]]; then
        log_error_event "COMMON_UTILS" "DISK_SPACE: Could not parse available space from 'df -Pk' output for '$filesystem'. Output format unexpected."
        return 1
    fi

    local available_space_kb="$available_space_kb_raw" # Rename for clarity

    log_debug_event "COMMON_UTILS" "DISK_SPACE: Check for '$dest_path_to_check' (FS: $filesystem): Required: ${required_space_kb} KB, Available: ${available_space_kb} KB."

    if (( available_space_kb >= required_space_kb )); then
        log_debug_event "COMMON_UTILS" "DISK_SPACE: Sufficient disk space available."
        return 0 # Sufficient space
    else
        log_warn_event "COMMON_UTILS" "DISK_SPACE: Insufficient disk space. Required: ${required_space_kb} KB, Available: ${available_space_kb} KB."
        return 1 # Insufficient space
    fi
}


# Function: find_executable
# Description: Finds the path of an executable command needed by JellyMac AMP scripts.
#              Checks hint paths and standard system PATH.
# Parameters:
#   $1: The executable name (e.g., "yt-dlp", "transmission-remote")
#   $2: (Optional) A hint path or colon-separated list of hint paths to check first
# Returns: The full path to the executable via echo
# Side Effects: Exits with error code 1 if executable is not found
find_executable() {
    local exe_name="$1"
    local hint_paths="$2" # Can be a single path or colon-separated list
    local found_path=""
    local IFS_backup="$IFS" # Save current IFS

    log_debug_event "COMMON_UTILS" "EXEC_FIND: Looking for executable: '$exe_name' (Hints: '${hint_paths:-N/A}')"

    # 1. Check hint paths first
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

            if [[ -n "$hint_path" ]]; then # Ensure path is not empty
                 log_debug_event "COMMON_UTILS" "EXEC_FIND: Checking hint path: '$hint_path'"
                # Check if hint_path itself is the executable (e.g., /path/to/yt-dlp)
                if [[ -x "$hint_path" && "$(basename "$hint_path")" == "$exe_name" ]]; then
                     found_path="$hint_path"
                     log_debug_event "COMMON_UTILS" "EXEC_FIND: Found in hint path itself: '$found_path'"
                     break # Found it, exit loop
                # Check if the executable is inside the hint_path (e.g., /path/to/bin/yt-dlp)
                elif [[ -x "${hint_path}/${exe_name}" ]]; then
                    found_path="${hint_path}/${exe_name}"
                    log_debug_event "COMMON_UTILS" "EXEC_FIND: Found in hint path directory: '$found_path'"
                    break # Found it, exit loop
                fi
            fi
        done
    fi

    # 2. If not found in hints, check standard PATH
    if [[ -z "$found_path" ]]; then
        log_debug_event "COMMON_UTILS" "EXEC_FIND: Not found in hints, checking system PATH..."
        local path_cmd_output; path_cmd_output=$(command -v "$exe_name" 2>/dev/null) # Capture output and errors
        if [[ -n "$path_cmd_output" ]]; then
             found_path="$path_cmd_output" # command -v outputs the path on success
             log_debug_event "COMMON_UTILS" "EXEC_FIND: Found in PATH: '$found_path'"
        fi
    fi

    # 3. If still not found, check common Homebrew/standard locations on macOS
    if [[ -z "$found_path" ]] && [[ "$(uname)" == "Darwin" ]]; then
         log_debug_event "COMMON_UTILS" "EXEC_FIND: Not found in PATH, checking common macOS locations..."
         if [[ -x "/opt/homebrew/bin/${exe_name}" ]]; then
             found_path="/opt/homebrew/bin/${exe_name}"
             log_debug_event "COMMON_UTILS" "EXEC_FIND: Found in /opt/homebrew/bin: '$found_path'"
         elif [[ -x "/usr/local/bin/${exe_name}" ]]; then
             found_path="/usr/local/bin/${exe_name}"
             log_debug_event "COMMON_UTILS" "EXEC_FIND: Found in /usr/local/bin: '$found_path'"
         elif [[ -x "/usr/bin/${exe_name}" ]]; then
             found_path="/usr/bin/${exe_name}"
             log_debug_event "COMMON_UTILS" "EXEC_FIND: Found in /usr/bin: '$found_path'"
         fi
    fi

    IFS="$IFS_backup" # Restore IFS

    if [[ -n "$found_path" ]]; then
        echo "$found_path" # Return the found path
        return 0 # Success
    else
        # Critical error: executable not found. Log error and exit the script.
        log_error_event "COMMON_UTILS" "CRITICAL: Required command '$exe_name' not found in PATH or specified hint path(s) ('${hint_paths:-N/A}') or common locations. Exiting."
        exit 1 # Exit the script
    fi
}


# Function: wait_for_file_stability
# Description: Waits until a file or directory size/mtime is stable, indicating
#              completed downloads/transfers before processing
# Parameters:
#   $1: Path to the file/directory to check
#   $2: Number of stable checks required (e.g., 3). Uses STABLE_CHECKS_* config if not provided.
#   $3: Sleep interval between checks in seconds (e.g., 10). Uses STABLE_SLEEP_INTERVAL_* config if not provided.
# Returns: 0 if stable, 1 if not stable after checks or if item vanishes/stat fails
# Side Effects: Creates temporary files that are tracked for cleanup
wait_for_file_stability() {
    local item_path="$1"
    local max_stable_checks_for_item="${2:-3}" # Default if arg 2 is empty or unset
    local sleep_interval_for_item="${3:-10}" # Default if arg 3 is empty or unset
    local item_basename

    # Use config defaults if arguments weren't provided and config vars exist
    # Priority: Arg > Config > Hardcoded Default
    if [[ -z "$2" ]]; then # Only apply config if arg 2 wasn't explicitly passed
        if [[ -n "${STABLE_CHECKS_DROP_FOLDER:-}" ]]; then max_stable_checks_for_item="$STABLE_CHECKS_DROP_FOLDER"; fi # Example using a config default
        # Could add more config checks here if needed for other contexts
    fi
    if [[ -z "$3" ]]; then # Only apply config if arg 3 wasn't explicitly passed
         # Note: Corrected typo STABLE_SLEP_INTERVAL_DROP_FOLDER -> STABLE_SLEEP_INTERVAL_DROP_FOLDER
         if [[ -n "${STABLE_SLEEP_INTERVAL_DROP_FOLDER:-}" ]]; then sleep_interval_for_item="$STABLE_SLEEP_INTERVAL_DROP_FOLDER"; fi # Example using a config default
         # Could add more config checks here if needed for other contexts
    fi


    # Validate arguments/config values
    if [[ -z "$item_path" ]]; then
        log_error_event "COMMON_UTILS" "STABILITY: No item path provided for stability check."
        return 1
    fi
    if ! [[ "$max_stable_checks_for_item" =~ ^[0-9]+$ ]] || (( max_stable_checks_for_item < 1 )); then
         log_warn_event "COMMON_UTILS" "STABILITY: Invalid effective max_stable_checks_for_item '$max_stable_checks_for_item'. Using default 3."
         max_stable_checks_for_item=3
    fi
     if ! [[ "$sleep_interval_for_item" =~ ^[0-9]+$ ]] || (( sleep_interval_for_item < 1 )); then
         log_warn_event "COMMON_UTILS" "STABILITY: Invalid effective sleep_interval_for_item '$sleep_interval_for_item'. Using default 10."
         sleep_interval_for_item=10
    fi

    item_basename=$(basename "$item_path")
    local last_combined_stat=""
    local current_combined_stat=""
    local stable_count=0

    log_debug_event "COMMON_UTILS" "🕵️‍♂️ Stability check for '$item_basename' ($max_stable_checks_for_item checks, ${sleep_interval_for_item}s interval)..."

    for ((i=0; i < max_stable_checks_for_item; i++)); do
        # Re-check existence at the start of each loop
        if [[ ! -e "$item_path" ]]; then
            log_warn_event "COMMON_UTILS" "⚠️ '$item_basename': Vanished during stability check (iteration $((i+1)))."
            return 1 # Item disappeared
        fi

        local current_size_bytes=""
        local current_mtime=""

        # Get size in bytes and modification time using stat
        # Use correct stat flags for macOS (BSD) and handle potential Linux (GNU) stat differences
        if [[ "$(uname)" == "Darwin" ]]; then # macOS BSD stat
            # For directories, sum sizes of all files within using find and stat
            if [[ -d "$item_path" ]]; then
                local sum_size=0
                # Use null termination for find and process in bash loop for robustness
                # Redirect errors from find and stat to /dev/null
                # Collect all sizes first, then sum (safer than summing inside the loop if find is slow)
                # Use a temp file with find + xargs as process substitution can be tricky in bash 3.2 traps/loops
                local find_output_temp; find_output_temp=$(mktemp "${SCRIPT_DIR:-/tmp}/.stability_find_XXXXXX")
                local xargs_stat_output_temp; xargs_stat_output_temp=$(mktemp "${SCRIPT_DIR:-/tmp}/.stability_xargs_XXXXXX")
                 _COMMON_UTILS_TEMP_FILES_TO_CLEAN+=("$find_output_temp" "$xargs_stat_output_temp") # Add to cleanup

                find "$item_path" -type f -print0 2>/dev/null > "$find_output_temp"
                local find_exit=${PIPESTATUS[0]} # Get exit status of find

                if [[ $find_exit -ne 0 ]]; then
                     log_warn_event "COMMON_UTILS" "⚠️ '$item_basename': Find failed during size sum (iteration $((i+1))). Exit code $find_exit. Treating as unstable."
                     # Temp files added to cleanup, will be removed on exit
                     return 1
                fi

                if [[ -s "$find_output_temp" ]]; then # Only run xargs if find found files
                    xargs -0 stat -f "%z" < "$find_output_temp" 2>/dev/null > "$xargs_stat_output_temp"
                    local xargs_stat_exit=${PIPESTATUS[0]} # Get exit status of xargs

                    if [[ $xargs_stat_exit -ne 0 ]]; then
                        # stat failed for one or more files. Treat as unstable.
                        log_warn_event "COMMON_UTILS" "⚠️ '$item_basename': Stat failed via xargs during size sum (iteration $((i+1))). Exit code $xargs_stat_exit. Treating as unstable."
                        # Temp files added to cleanup, will be removed on exit
                        return 1
                    fi

                     # Sum the collected sizes from the temp file
                    local size_line # Declare before loop
                    while read -r size_line; do
                         # Ensure size_line is a number before summing
                        if [[ "$size_line" =~ ^[0-9]+$ ]]; then
                            sum_size=$((sum_size + size_line))
                        else
                            log_debug_event "COMMON_UTILS" "↳ STABILITY: Skipping non-numeric size line during sum for '$item_basename': '$size_line'"
                        fi
                    done < "$xargs_stat_output_temp"
                else
                    # If find returned no files (e.g. empty directory), sum_size remains 0. This is fine.
                    log_debug_event "COMMON_UTILS" "↳ '$item_basename' is a directory with no files found by 'find -type f' for size sum."
                fi
                current_size_bytes="$sum_size"

                # Get the modification time of the directory itself
                current_mtime=$(stat -f "%m" "$item_path" 2>/dev/null)

            elif [[ -f "$item_path" ]]; then
                # For regular files
                local stat_output; stat_output=$(stat -f "%z %m" "$item_path" 2>/dev/null)
                local stat_exit=$?
                if [[ $stat_exit -ne 0 ]]; then
                     log_warn_event "COMMON_UTILS" "⚠️ '$item_basename': Stat failed for file (iteration $((i+1))). Exit code $stat_exit. Treating as unstable."
                     return 1
                fi
                 # Extract size and mtime from stat output
                current_size_bytes=$(echo "$stat_output" | awk '{print $1}')
                current_mtime=$(echo "$stat_output" | awk '{print $2}')
            else
                # Not a directory or regular file that stat can handle (e.g. symlink to nowhere, device)
                log_warn_event "COMMON_UTILS" "⚠️ '$item_basename': Not a regular file or directory for stability check. Path: $item_path. Treating as unstable."
                # Temp files added to cleanup, will be removed on exit
                return 1
            fi

        else # Assuming GNU stat for Linux/other systems
             # For directories, sum sizes of all files within
            if [[ -d "$item_path" ]]; then
                local sum_size=0
                local find_output_temp; find_output_temp=$(mktemp "${SCRIPT_DIR:-/tmp}/.stability_find_XXXXXX")
                local xargs_stat_output_temp; xargs_stat_output_temp=$(mktemp "${SCRIPT_DIR:-/tmp}/.stability_xargs_XXXXXX")
                 _COMMON_UTILS_TEMP_FILES_TO_CLEAN+=("$find_output_temp" "$xargs_stat_output_temp") # Add to cleanup

                find "$item_path" -type f -print0 2>/dev/null > "$find_output_temp"
                 local find_exit=${PIPESTATUS[0]} # Get exit status of find

                if [[ $find_exit -ne 0 ]]; then
                     log_warn_event "COMMON_UTILS" "⚠️ '$item_basename': Find failed during size sum (iteration $((i+1))). Exit code $find_exit. Treating as unstable."
                     return 1
                fi

                if [[ -s "$find_output_temp" ]]; then # Only run xargs if find found files
                    xargs -0 stat -c "%s" < "$find_output_temp" 2>/dev/null > "$xargs_stat_output_temp"
                    local xargs_stat_exit=${PIPESTATUS[0]} # Get exit status of xargs

                    if [[ $xargs_stat_exit -ne 0 ]]; then
                         log_warn_event "COMMON_UTILS" "⚠️ '$item_basename': Stat failed via xargs during size sum (iteration $((i+1))). Exit code $xargs_stat_exit. Treating as unstable."
                         return 1
                    fi

                    local size_line # Declare before loop
                    while read -r size_line; do
                         if [[ "$size_line" =~ ^[0-9]+$ ]]; then
                            sum_size=$((sum_size + size_line))
                        else
                             log_debug_event "COMMON_UTILS" "↳ STABILITY: Skipping non-numeric size line during sum for '$item_basename' (GNU stat): '$size_line'"
                        fi
                    done < "$xargs_stat_output_temp"
                else
                     log_debug_event "COMMON_UTILS" "↳ '$item_basename' is a directory with no files found by 'find -type f' for size sum (GNU stat)."
                fi
                current_size_bytes="$sum_size"

                # Get the modification time of the directory itself
                current_mtime=$(stat -c "%Y" "$item_path" 2>/dev/null)

            elif [[ -f "$item_path" ]]; then
                 # For regular files
                local stat_output; stat_output=$(stat -c "%s %Y" "$item_path" 2>/dev/null)
                local stat_exit=$?
                 if [[ $stat_exit -ne 0 ]]; then
                     log_warn_event "COMMON_UTILS" "⚠️ '$item_basename': Stat failed for file (iteration $((i+1))) (GNU stat). Exit code $stat_exit. Treating as unstable."
                     return 1
                fi
                # Extract size and mtime from stat output
                current_size_bytes=$(echo "$stat_output" | awk '{print $1}')
                current_mtime=$(echo "$stat_output" | awk '{print $2}')

            else
                 log_warn_event "COMMON_UTILS" "⚠️ '$item_basename': Not a regular file or directory for stability check (GNU stat). Path: $item_path. Treating as unstable."
                 return 1
            fi
        fi # End of stat type specific logic

        # Check if size and mtime were determined (even if 0 for size/mtime in certain edge cases)
        if [[ -z "$current_size_bytes" ]] || [[ -z "$current_mtime" ]]; then
             # If stat command itself failed (exit code > 0), the log_warn_event inside
             # the platform-specific blocks should cover it. This check is for cases
             # where stat succeeded but returned empty output or non-numeric results
             # that weren't explicitly caught.
             log_warn_event "COMMON_UTILS" "⚠️ '$item_basename': Could not determine size/mtime reliably (iteration $((i+1))). Stat output unexpected. Treating as unstable."
             # Temp files added to cleanup, will be removed on exit
             return 1
        fi


        current_combined_stat="${current_size_bytes}:${current_mtime}"

        # For logging display, get human-readable size (best effort, less critical)
        local current_size_display # For logging only, from du -sh (best effort)
        current_size_display=$(du -sh "$item_path" 2>/dev/null | awk '{print $1}')
        if [[ -z "$current_size_display" ]]; then current_size_display="N/A"; fi # Handle cases where du fails

        if [[ $i -gt 0 && "$current_combined_stat" != "$last_combined_stat" ]]; then
            log_debug_event "COMMON_UTILS" "↳ '$item_basename': Stat changed. Last: [$last_combined_stat], Current: [$current_combined_stat]. Resetting checks."
            stable_count=0 # Reset stable count
        else
            stable_count=$((stable_count + 1))
        fi

        log_debug_event "COMMON_UTILS" "↳ '$item_basename': Check $((i + 1))/$max_stable_checks_for_item, Display Size: ${current_size_display}, ByteSize:Mtime: [${current_combined_stat}] (Stable count: $stable_count/$max_stable_checks_for_item)"

        if [[ "$stable_count" -ge "$max_stable_checks_for_item" ]]; then
            log_info_event "COMMON_UTILS" "✅ '$item_basename': Stable (Display Size: ${current_size_display}, ByteSize:Mtime: [${current_combined_stat}])."
            # Temp files added to cleanup, will be removed on exit
            return 0 # Stable
        fi

        last_combined_stat="$current_combined_stat"

        if [[ $i -lt $((max_stable_checks_for_item - 1)) ]]; then # Don't sleep after the last check
            log_debug_event "COMMON_UTILS" "⏳ '$item_basename': Waiting ${sleep_interval_for_item}s..."
            sleep "$sleep_interval_for_item"
        fi
    done

    log_warn_event "COMMON_UTILS" "⚠️ '$item_basename': Not stable after $max_stable_checks_for_item checks (Last ByteSize:Mtime: [${last_combined_stat}])."
    # Temp files added to cleanup, will be removed on exit
    return 1 # Not stable
}

# Function: play_sound_notification
# Description: Plays a notification sound if enabled and afplay is available
# Parameters:
#   $1: Sound type ('input_detected', 'task_success', 'task_error') or direct path to sound file.
#       If a type is provided, it looks up the corresponding SOUND_*_FILE variable from config.
#   $2: (Optional) Log prefix for warnings. Defaults to "SOUND_PLAYER".
# Returns: 0 if sound played, is disabled, or not applicable. 1 on error if sound was meant to play.
play_sound_notification() {
    local sound_type_or_path="$1"
    local log_prefix_sound="${2:-SOUND_PLAYER}" # Use the provided prefix or a default
    local sound_file_to_play=""

    # Check master sound notification toggle
    if [[ "${SOUND_NOTIFICATION:-false}" != "true" ]]; then
        # log_debug_event "$log_prefix_sound" "Sound notifications are disabled globally." # Optional: for debugging
        return 0 # Sounds are globally disabled
    fi

    # Check if afplay command exists
    if ! command -v afplay &>/dev/null; then
        log_warn_event "$log_prefix_sound" "'afplay' command not found. Cannot play sound notification."
        return 1
    fi

    # Determine the sound file based on type or direct path
    case "$sound_type_or_path" in
        "input_detected")
            sound_file_to_play="${SOUND_INPUT_DETECTED_FILE:-/System/Library/Sounds/Submarine.aiff}"
            ;;
        "task_success")
            sound_file_to_play="${SOUND_TASK_SUCCESS_FILE:-/System/Library/Sounds/Glass.aiff}"
            ;;
        "task_error")
            # Only proceed if SOUND_TASK_ERROR_FILE is defined and not empty
            if [[ -n "${SOUND_TASK_ERROR_FILE}" ]]; then
                sound_file_to_play="${SOUND_TASK_ERROR_FILE}"
            else
                # log_debug_event "$log_prefix_sound" "Task error sound not configured or intentionally empty." # Optional
                return 0 # No error sound configured, not an error condition for sound playing itself
            fi
            ;;
        *)
            # Assume it's a direct path if not a known type
            if [[ -f "$sound_type_or_path" ]]; then
                sound_file_to_play="$sound_type_or_path"
            else
                log_warn_event "$log_prefix_sound" "Sound type '$sound_type_or_path' is unknown and not a valid file path. Using default input sound."
                sound_file_to_play="${SOUND_INPUT_DETECTED_FILE:-/System/Library/Sounds/Tink.aiff}" # Fallback to a generic sound
            fi
            ;;
    esac

    if [[ -z "$sound_file_to_play" ]]; then
        log_warn_event "$log_prefix_sound" "No sound file specified or resolved for type/path '$sound_type_or_path'."
        return 1
    fi

    # Play the sound if the file exists
    if [[ -f "$sound_file_to_play" ]]; then
        # Play in the background so the script doesn't wait for the sound to finish
        (afplay "$sound_file_to_play" &)
        # log_debug_event "$log_prefix_sound" "Playing sound: $sound_file_to_play" # Optional: for debugging
        return 0
    else
        log_warn_event "$log_prefix_sound" "Sound file not found: '$sound_file_to_play' for type/path '$sound_type_or_path'."
        return 1
    fi
}

# Function: quarantine_item
# Description: Moves a failed or problematic item to the error/quarantine directory
# Parameters:
#   $1: Path to the item to quarantine (file or directory)
#   $2: Reason for quarantine (string)
# Returns: 0 on success (or if source was already gone), 1 on failure to quarantine.
# Side Effects: Creates quarantine directory if needed, logs to history
quarantine_item() {
    local item_to_quarantine_path="$1"
    local reason_for_quarantine="$2"
    local item_basename_for_log; item_basename_for_log=$(basename "$item_to_quarantine_path")

    log_warn_event "COMMON_UTILS" "QUARANTINE: Attempting to quarantine item '$item_basename_for_log' due to: $reason_for_quarantine"

    if [[ -z "$ERROR_DIR" ]]; then
        log_error_event "COMMON_UTILS" "QUARANTINE: ERROR_DIR is not set in config. Cannot quarantine."
        return 1
    fi
    if [[ ! -d "$ERROR_DIR" ]]; then
        log_info_event "COMMON_UTILS" "QUARANTINE: Quarantine directory '$ERROR_DIR' does not exist. Creating."
        if ! mkdir -p "$ERROR_DIR"; then
            log_error_event "COMMON_UTILS" "QUARANTINE: Failed to create quarantine directory '$ERROR_DIR'. Check permissions."
            return 1
        fi
    fi
    if [[ ! -w "$ERROR_DIR" ]]; then
         log_error_event "COMMON_UTILS" "QUARANTINE: Quarantine directory '$ERROR_DIR' is not writable. Cannot quarantine."
         return 1
    fi

    # Check if the source item exists BEFORE trying to move it
    if [[ ! -e "$item_to_quarantine_path" ]]; then
        log_warn_event "COMMON_UTILS" "QUARANTINE: Cannot quarantine '$item_basename_for_log': Source path '$item_to_quarantine_path' does not exist or is not accessible."
        log_info_event "COMMON_UTILS" "QUARANTINE: Source item '$item_to_quarantine_path' not found. Assuming it was already handled or removed. Skipping quarantine move."
        return 0 # Source not found, nothing to quarantine, treat as successful (nothing needed doing)
    fi

    local quarantine_dest_path="${ERROR_DIR}/${item_basename_for_log}"
    # Avoid overwriting existing items in quarantine by adding a unique suffix if needed
    if [[ -e "$quarantine_dest_path" ]]; then
        # Construct a unique path. Add a timestamp and random number.
        local unique_suffix; unique_suffix="_failed_$(date +%Y%m%d_%H%M%S)_$RANDOM"
        local dest_basename; dest_basename="${item_basename_for_log}"
        local dest_ext=""; if [[ -f "$item_to_quarantine_path" ]]; then dest_ext=$(get_file_extension "$item_to_quarantine_path"); fi # Get extension for files
        if [[ -n "$dest_ext" ]]; then
             # Remove extension from basename, add suffix, then add extension back
             dest_basename="${item_basename_for_log%${dest_ext}}" # Use parameter expansion to remove suffix
             quarantine_dest_path="${ERROR_DIR}/${dest_basename}${unique_suffix}${dest_ext}"
        else
             # No extension, just append suffix
             quarantine_dest_path="${ERROR_DIR}/${dest_basename}${unique_suffix}"
        fi

        log_warn_event "COMMON_UTILS" "QUARANTINE: Destination '$quarantine_dest_path' exists in quarantine, using unique name."
    fi

    log_info_event "COMMON_UTILS" "QUARANTINE: Moving '$item_basename_for_log' to quarantine '$quarantine_dest_path'..."
    # Use mv for moving within the same filesystem for speed, but rsync might be safer across filesystems.
    # Given this is error handling, mv is simpler and often sufficient for local ERROR_DIR.
    if mv "$item_to_quarantine_path" "$quarantine_dest_path"; then
        log_info_event "COMMON_UTILS" "QUARANTINE: Item successfully moved to quarantine: $quarantine_dest_path"
        # Record the quarantine event in history
        record_transfer_to_history "$item_to_quarantine_path -> $quarantine_dest_path (QUARANTINED: $reason_for_quarantine)" || \
            log_warn_event "COMMON_UTILS" "QUARANTINE: Failed to record quarantine in history."
        return 0 # Success
    else
        # mv failed. The item remains in its original location.
        log_error_event "COMMON_UTILS" "QUARANTINE: Failed to move item to quarantine: '$item_to_quarantine_path' -> '$quarantine_dest_path'. Manual intervention needed."
        return 1 # Failure to move
    fi
}


# --- Temporary File Cleanup for this specific library ---
# Array to hold temporary files created *by functions within this script*.

# Function: _cleanup_common_utils_temp_files
# Description: Cleans up any temporary files created by functions in this script
# Parameters: None
# Returns: None (cleans up files tracked in _COMMON_UTILS_TEMP_FILES_TO_CLEAN)
# Note: The main script should add this to its trap handlers
_cleanup_common_utils_temp_files() {
    # shellcheck disable=SC2128 # We want to check array length
    if [[ ${#_COMMON_UTILS_TEMP_FILES_TO_CLEAN[@]} -gt 0 ]]; then
        # Using standard echo here as trap context might be limited for logging.
        # Redirect to stderr to ensure visibility.
        echo "$(date '+%Y-%m-%d %H:%M:%S') - INFO: COMMON_UTILS_TRAP - Cleaning up common_utils temporary files (${#_COMMON_UTILS_TEMP_FILES_TO_CLEAN[@]})..." >&2
        local temp_file_path_to_clean # Correctly local
        for temp_file_path_to_clean in "${_COMMON_UTILS_TEMP_FILES_TO_CLEAN[@]}"; do
            if [[ -n "$temp_file_path_to_clean" && -e "$temp_file_path_to_clean" ]]; then
                rm -rf "$temp_file_path_to_clean"
                echo "$(date '+%Y-%m-%d %H:%M:%S') - INFO: COMMON_UTILS_TRAP - Removed '$temp_file_path_to_clean'" >&2
            fi
        done
    fi
    _COMMON_UTILS_TEMP_FILES_TO_CLEAN=()
}
# Note: Trap is NOT set here. The calling script (JellyMac.sh) must set a trap
# that includes a call to _cleanup_common_utils_temp_files.