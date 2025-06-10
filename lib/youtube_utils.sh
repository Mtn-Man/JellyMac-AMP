#!/bin/bash
#==============================================================================
# JellyMac/lib/youtube_utils.sh
#==============================================================================
# Utility functions for managing YouTube link processing, queueing,
# and background monitoring.
#
# This script is intended to be sourced by the main jellymac.sh script.
# It relies on global variables and functions defined in jellymac.sh
# and its sourced libraries (common_utils.sh, logging_utils.sh, etc.).
#==============================================================================

# Ensure logging_utils.sh is sourced, as this script may use log_*_event functions
if ! command -v log_debug_event &>/dev/null; then # Using log_debug_event as a representative function
    _YOUTUBE_UTILS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
    if [[ -f "${_YOUTUBE_UTILS_LIB_DIR}/logging_utils.sh" ]]; then
        # shellcheck source=logging_utils.sh
        # shellcheck disable=SC1091
        source "${_YOUTUBE_UTILS_LIB_DIR}/logging_utils.sh"
    else
        echo "WARNING: youtube_utils.sh: logging_utils.sh not found at ${_YOUTUBE_UTILS_LIB_DIR}/logging_utils.sh. Logging functions may be unavailable if not already sourced." >&2
    fi
fi

# --- YouTube Queue Management Functions ---

# Function: _add_youtube_to_queue
# Description: Adds a YouTube URL to the processing queue
# Parameters:
#   $1 - YouTube URL to queue
# Returns: None
# Depends on: STATE_DIR, log_user_info, send_desktop_notification, play_sound_notification
_add_youtube_to_queue() {
    local youtube_url="$1"
    local queue_file="${STATE_DIR}/youtube_queue.txt"
    
    # Create queue file if it doesn't exist
    touch "$queue_file"
    
    # Check if URL is already in queue
    if grep -Fxq "$youtube_url" "$queue_file" 2>/dev/null; then
        log_user_info "JellyMac" "📋 YouTube URL already queued: '${youtube_url:0:60}...'"
        return
    fi
    
    # Add to queue
    echo "$youtube_url" >> "$queue_file"
    local queue_count
    queue_count=$(wc -l < "$queue_file" 2>/dev/null || echo "0")
    
    log_user_info "JellyMac" "📋 YouTube URL queued (#$queue_count): '${youtube_url:0:60}...'"
    send_desktop_notification "JellyMac: YouTube Queued" "Position #$queue_count: ${youtube_url:0:50}..."
    
    # 🔊 Play input detected sound for queued items
    play_sound_notification "input_detected" "JellyMac"
}

# Function: _process_youtube_queue
# Description: Processes all queued YouTube URLs sequentially  
# Parameters: None
# Returns: None
# Depends on: STATE_DIR, HANDLE_YOUTUBE_SCRIPT, log_user_info, send_desktop_notification, log_warn_event
_process_youtube_queue() {
    local queue_file="${STATE_DIR}/youtube_queue.txt"
    
    if [[ ! -f "$queue_file" ]]; then
        return
    fi
    
    # Read all URLs into an array first, then process
    local queued_urls=()
    while IFS= read -r queued_url; do
        [[ -n "$queued_url" ]] && queued_urls+=("$queued_url")
    done < "$queue_file"
    
    # Clear the queue file immediately to prevent new items affecting count
    rm -f "$queue_file"
    
    local total_count=${#queued_urls[@]}
    
    if [[ "$total_count" -eq 0 ]]; then
        return
    fi
    
    log_user_info "JellyMac" "📋 Processing $total_count queued YouTube downloads..."
    
    local processed_count=0
    local failed_count=0
    local interrupted_count=0
    
    for queued_url in "${queued_urls[@]}"; do
        [[ -z "$queued_url" ]] && continue
        
        ((processed_count++))
        log_user_info "JellyMac" "🎬 Processing queued download $processed_count/$total_count: '${queued_url:0:60}...'"
        
        # Update global tracking for this queued item
        _ACTIVE_YOUTUBE_URL="$queued_url"
        
        # Start the download process
        "$HANDLE_YOUTUBE_SCRIPT" "$queued_url" &
        local handler_pid=$!
        _ACTIVE_YOUTUBE_PID="$handler_pid"
        
        # Wait for completion and check result
        if wait "$handler_pid"; then
            local wait_exit_code=$?
            if [[ "$wait_exit_code" -eq 0 ]]; then
                log_user_info "JellyMac" "✅ Queued download complete ($processed_count/$total_count): '${queued_url:0:60}...'"
                send_desktop_notification "JellyMac: YouTube Complete" "Queued #$processed_count: ${queued_url:0:50}..."
            elif [[ "$wait_exit_code" -eq 130 ]]; then
                # Interrupted (SIGINT)
                ((interrupted_count++))
                log_warn_event "JellyMac" "🔄 Queued download interrupted ($processed_count/$total_count): '${queued_url:0:60}...'"
                # Re-add to queue for retry
                echo "$queued_url" >> "$queue_file"
            else
                # Other failure
                ((failed_count++))
                log_warn_event "JellyMac" "❌ Queued download failed ($processed_count/$total_count): '${queued_url:0:60}...'"
                send_desktop_notification "JellyMac: YouTube Error" "Failed #$processed_count: ${queued_url:0:50}..." "Basso"
                # Re-add failed URL to queue for retry on next startup
                echo "$queued_url" >> "$queue_file"
            fi
        else
            # wait command itself failed
            ((failed_count++))
            log_warn_event "JellyMac" "❌ Failed to wait for queued download ($processed_count/$total_count): '${queued_url:0:60}...'"
            # Re-add to queue for retry
            echo "$queued_url" >> "$queue_file"
        fi
        
        # Clear tracking variables
        _ACTIVE_YOUTUBE_URL=""
        _ACTIVE_YOUTUBE_PID=""
    done
    
    # Summary reporting
    local success_count=$((processed_count - failed_count - interrupted_count))
    
    if [[ "$failed_count" -eq 0 && "$interrupted_count" -eq 0 ]]; then
        log_user_info "JellyMac" "📋 Queue processing complete! Successfully processed all $processed_count downloads."
    else
        local requeued_count=$((failed_count + interrupted_count))
        log_user_info "JellyMac" "📋 Queue processing complete! $success_count successful, $failed_count failed, $interrupted_count interrupted."
        if [[ "$requeued_count" -gt 0 ]]; then
            log_user_info "JellyMac" "💡 $requeued_count downloads re-queued for retry on next JellyMac startup."
        fi
    fi
}

# Function: _check_clipboard_youtube_for_queue
# Description: Background clipboard monitoring that only queues (doesn't process).
#              This function is intended to be called from the background monitoring
#              loop when foreground YouTube processing is active.
# Parameters: None
# Returns: None
# Depends on: ENABLE_CLIPBOARD_YOUTUBE, PBPASTE_CMD, LAST_CLIPBOARD_CONTENT_YOUTUBE, _add_youtube_to_queue
_check_clipboard_youtube_for_queue() {
    if [[ "${ENABLE_CLIPBOARD_YOUTUBE:-false}" != "true" || -z "$PBPASTE_CMD" ]]; then return; fi
    local current_cb_content
    current_cb_content=$("$PBPASTE_CMD" 2>/dev/null || echo "CLIPBOARD_READ_ERROR")
    if [[ "$current_cb_content" == "CLIPBOARD_READ_ERROR" ]]; then
        # Silently return on clipboard read error in background queue mode to avoid log spam
        return
    fi

    if [[ "$current_cb_content" != "$LAST_CLIPBOARD_CONTENT_YOUTUBE" && -n "$current_cb_content" ]]; then
        LAST_CLIPBOARD_CONTENT_YOUTUBE="$current_cb_content" 
        local trimmed_cb; trimmed_cb="$(echo -E "${current_cb_content}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        
        case "$trimmed_cb" in
            https://www.youtube.com/watch?v=*|https://youtu.be/*)
                # Add to queue (function handles duplicate checking and sound)
                _add_youtube_to_queue "$trimmed_cb"
                ;;
        esac
    fi
}

# --- YouTube Processing Pre-flight Checks ---

# Function: _perform_youtube_preflight_checks
# Description: Performs essential checks before attempting YouTube processing.
#              Exits with an error if critical checks fail.
# Parameters: None
# Returns: 0 on success, exits on failure.
# Depends on: Global config variables (YTDLP_EXECUTABLE, LOCAL_DIR_YOUTUBE, DEST_DIR_YOUTUBE, YTDLP_FORMAT, MIN_FREE_SPACE_GB_LOCAL_YOUTUBE)
#             Functions from common_utils.sh (is_network_volume, get_free_space_gb, validate_network_volume_before_transfer)
#             Functions from logging_utils.sh (log_fatal_event, log_error_event, log_debug_event)
_perform_youtube_preflight_checks() {
    log_debug_event "YouTubeUtils" "Performing YouTube pre-flight checks..."

    # Check 1: yt-dlp executable
    if [[ -z "${YTDLP_EXECUTABLE:-}" ]] || ! command -v "$YTDLP_EXECUTABLE" &>/dev/null; then
        log_fatal_event "YT_PREFLIGHT" "yt-dlp executable not found or not configured (YTDLP_EXECUTABLE: '${YTDLP_EXECUTABLE:-Not Set}'). Please install yt-dlp and/or configure YTDLP_EXECUTABLE in jellymac_config.sh."
    fi

    # Check 2: Local YouTube directory
    if [[ -z "${LOCAL_DIR_YOUTUBE:-}" ]]; then
        log_fatal_event "YT_PREFLIGHT" "LOCAL_DIR_YOUTUBE is not configured in jellymac_config.sh."
    fi
    if [[ ! -d "$LOCAL_DIR_YOUTUBE" ]]; then
        log_debug_event "YT_PREFLIGHT" "Local YouTube directory '$LOCAL_DIR_YOUTUBE' does not exist. Attempting to create..."
        if ! mkdir -p "$LOCAL_DIR_YOUTUBE"; then
            log_fatal_event "YT_PREFLIGHT" "Failed to create local YouTube directory '$LOCAL_DIR_YOUTUBE'. Please check permissions."
        else
            log_debug_event "YT_PREFLIGHT" "Successfully created local YouTube directory '$LOCAL_DIR_YOUTUBE'."
        fi
    fi
    if [[ ! -w "$LOCAL_DIR_YOUTUBE" ]]; then
        log_fatal_event "YT_PREFLIGHT" "Local YouTube directory '$LOCAL_DIR_YOUTUBE' is not writable. Please check permissions."
    fi

    # Check 3: Destination YouTube directory
    if [[ -z "${DEST_DIR_YOUTUBE:-}" ]]; then
        log_fatal_event "YT_PREFLIGHT" "DEST_DIR_YOUTUBE is not configured in jellymac_config.sh."
    fi
    # Use validate_network_volume_before_transfer for a comprehensive check of the destination
    # This function (from common_utils.sh) checks existence, writability, and mount status for network volumes.
    # It logs detailed errors and returns 1 on failure, 0 on success.
    if ! validate_network_volume_before_transfer "$DEST_DIR_YOUTUBE" "YT_PREFLIGHT"; then
        # validate_network_volume_before_transfer logs its own detailed errors.
        # We log a general fatal event here to ensure script exit.
        log_fatal_event "YT_PREFLIGHT" "Destination YouTube directory '$DEST_DIR_YOUTUBE' validation failed. Please review previous error messages."
    else
        log_debug_event "YT_PREFLIGHT" "Destination YouTube directory '$DEST_DIR_YOUTUBE' is validated and accessible."
    fi

    # Check 4: yt-dlp format string
    if [[ -z "${YTDLP_FORMAT:-}" ]]; then
        log_fatal_event "YT_PREFLIGHT" "YTDLP_FORMAT for YouTube not set in config. Please configure it in jellymac_config.sh."
    fi

    # Check 5: Disk space in LOCAL_DIR_YOUTUBE
    local local_free_space_gb
    local_free_space_gb=$(get_free_space_gb "$LOCAL_DIR_YOUTUBE")
    local min_free_space_local_youtube="${MIN_FREE_SPACE_GB_LOCAL_YOUTUBE:-5}" # Default to 5GB if not set

    if (( $(echo "$local_free_space_gb < $min_free_space_local_youtube" | bc -l) )); then
        log_fatal_event "YT_PREFLIGHT" "Insufficient free space in local YouTube directory '$LOCAL_DIR_YOUTUBE'. Found $local_free_space_gb GB, require $min_free_space_local_youtube GB."
    else
        log_debug_event "YT_PREFLIGHT" "Sufficient free space in '$LOCAL_DIR_YOUTUBE': $local_free_space_gb GB available (min required: $min_free_space_local_youtube GB)."
    fi

    log_debug_event "YouTubeUtils" "YouTube pre-flight checks passed."
    return 0
}

# --- YouTube Command Execution ---

# Function: _execute_ytdlp_command
# Description: Executes the yt-dlp command with specified arguments,
#              capturing stdout and stderr to temporary files while also
#              displaying live output.
# Parameters:
#   $1       - Path to the yt-dlp executable.
#   $2       - Name of a variable in the caller's scope to store the stdout capture file path.
#   $3       - Name of a variable in the caller's scope to store the stderr capture file path.
#   $@ (from 4th onwards) - Arguments to pass to yt-dlp.
# Returns: The exit code of the yt-dlp command.
#          Sets the variables named by $2 and $3 in the caller's scope to the paths of the capture files.
# Depends on: mktemp, tee, _COMMON_UTILS_TEMP_FILES_TO_CLEAN (from common_utils.sh),
#             log_debug_event, log_warn_event, log_fatal_event (from logging_utils.sh)
#             STATE_DIR (global config, expected to be validated by common_utils.sh)
_execute_ytdlp_command() {
    local ytdlp_executable="$1"
    local __stdout_capture_var_name="$2" # Indirect variable assignment target
    local __stderr_capture_var_name="$3" # Indirect variable assignment target
    shift 3 # Remove the first three params, rest are yt-dlp args
    local ytdlp_args=("$@")

    if [[ -z "$ytdlp_executable" ]] || ! command -v "$ytdlp_executable" &>/dev/null || ! [[ -x "$ytdlp_executable" ]]; then
        log_fatal_event "YT_EXEC" "yt-dlp executable '$ytdlp_executable' is not valid, not found, or not executable."
        return 255 # Should not happen if preflight checks passed
    fi
    if [[ -z "$__stdout_capture_var_name" || -z "$__stderr_capture_var_name" ]]; then
        log_fatal_event "YT_EXEC" "Internal error: stdout/stderr capture variable names not provided to _execute_ytdlp_command."
        return 254
    fi
    if [[ -z "$STATE_DIR" || ! -d "$STATE_DIR" || ! -w "$STATE_DIR" ]]; then
        log_fatal_event "YT_EXEC" "STATE_DIR ('${STATE_DIR:-Not Set}') is not available or not writable for temp files."
        return 253
    fi

    local stdout_file
    local stderr_file
    stdout_file=$(mktemp "${STATE_DIR}/.ytdlp_stdout.XXXXXX")
    stderr_file=$(mktemp "${STATE_DIR}/.ytdlp_stderr.XXXXXX")

    # Add to common_utils.sh's cleanup array if available
    # This array is cleaned by _cleanup_common_utils_temp_files, called by the main script's trap
    if declare -p _COMMON_UTILS_TEMP_FILES_TO_CLEAN &>/dev/null; then
        _COMMON_UTILS_TEMP_FILES_TO_CLEAN+=("$stdout_file")
        _COMMON_UTILS_TEMP_FILES_TO_CLEAN+=("$stderr_file")
        log_debug_event "YT_EXEC" "Added $stdout_file and $stderr_file to _COMMON_UTILS_TEMP_FILES_TO_CLEAN."
    else
        log_warn_event "YT_EXEC" "Temp files created ($stdout_file, $stderr_file) but _COMMON_UTILS_TEMP_FILES_TO_CLEAN (from common_utils.sh) not found. Manual cleanup might be needed if script exits unexpectedly."
    fi

    # Set the caller's variables to the temp file paths
    # Using eval for indirect assignment, ensure var names are safe (controlled internally)
    eval "$__stdout_capture_var_name=\"$stdout_file\""
    eval "$__stderr_capture_var_name=\"$stderr_file\""

    log_debug_event "YT_EXEC" "Executing: $ytdlp_executable ${ytdlp_args[*]}"
    log_debug_event "YT_EXEC" "Stdout will be captured to: $stdout_file"
    log_debug_event "YT_EXEC" "Stderr will be captured to: $stderr_file"

    local ytdlp_actual_exit_code
    local tee_stdout_ec
    local tee_stderr_exit_code # Renamed for clarity

    # Temporary file to capture the exit code of the tee command handling stderr
    local stderr_tee_ec_capture_file
    stderr_tee_ec_capture_file=$(mktemp "${STATE_DIR}/.ytdlp_stderr_ec.XXXXXX")

    if declare -p _COMMON_UTILS_TEMP_FILES_TO_CLEAN &>/dev/null; then
        _COMMON_UTILS_TEMP_FILES_TO_CLEAN+=("$stderr_tee_ec_capture_file")
        log_debug_event "YT_EXEC" "Added $stderr_tee_ec_capture_file to _COMMON_UTILS_TEMP_FILES_TO_CLEAN for cleanup."
    else
        # This warning is already present for stdout_file and stderr_file, so it's consistent
        log_warn_event "YT_EXEC" "Temp file for stderr tee exit code created ($stderr_tee_ec_capture_file) but _COMMON_UTILS_TEMP_FILES_TO_CLEAN not found."
    fi

    set +e # Allow capturing PIPESTATUS
    # Execute yt-dlp:
    # 1. yt-dlp's stderr is redirected to a process substitution.
    # 2. Inside the process substitution:
    #    - 'tee' writes stderr to the capture file ($stderr_file) AND to the original stderr (>&2).
    #    - After 'tee' finishes, its exit code ($?) is written to $stderr_tee_ec_capture_file.
    # 3. The entire compound command { ... }'s stdout (which is yt-dlp's stdout) is piped to another 'tee'.
    { "$ytdlp_executable" "${ytdlp_args[@]}" 2> >(tee "$stderr_file" >&2 ; echo $? > "$stderr_tee_ec_capture_file") ; } | tee "$stdout_file"
    
    # PIPESTATUS[0] will be the exit code of the compound command { ... }, 
    # which is the exit code of its last simple command: "$ytdlp_executable"...
    ytdlp_actual_exit_code=${PIPESTATUS[0]} 
    # PIPESTATUS[1] will be the exit code of the 'tee "$stdout_file"'
    tee_stdout_ec=${PIPESTATUS[1]}      
    set -e

    # Read the captured exit code of the tee command that handled stderr
    if [[ -f "$stderr_tee_ec_capture_file" ]]; then
        tee_stderr_exit_code=$(<"$stderr_tee_ec_capture_file")
        # Validate it's a number; default to 0 if not (though echo $? should be reliable)
        if ! [[ "$tee_stderr_exit_code" =~ ^[0-9]+$ ]]; then
            log_warn_event "YT_EXEC" "Invalid exit code format read from stderr tee capture file ('$stderr_tee_ec_capture_file'): '$tee_stderr_exit_code'. Assuming 0."
            tee_stderr_exit_code=0
        fi
    else
        log_warn_event "YT_EXEC" "Stderr tee exit code capture file ('$stderr_tee_ec_capture_file') not found. Assuming 0 for its status."
        tee_stderr_exit_code=0 
    fi

    if [[ "$tee_stdout_ec" -ne 0 ]]; then
        log_warn_event "YT_EXEC" "The 'tee' command for yt-dlp stdout exited with status $tee_stdout_ec. Stdout capture might be affected."
    fi
    if [[ "$tee_stderr_exit_code" -ne 0 ]]; then
        log_warn_event "YT_EXEC" "The 'tee' command for yt-dlp stderr exited with status $tee_stderr_exit_code. Stderr capture might be affected."
    fi
    
    log_debug_event "YT_EXEC" "yt-dlp execution finished. Exit code: $ytdlp_actual_exit_code"
    return "$ytdlp_actual_exit_code"
}

# --- YouTube SABR Error Handling and Retry ---

# Function: _handle_ytdlp_sabr_retry
# Description: Attempts to retry yt-dlp download if specific SABR-related errors are detected.
# Parameters:
#   $1       - Initial yt-dlp exit code.
#   $2       - Path to the stdout capture file from the initial attempt (currently unused but good for future use).
#   $3       - Path to the stderr capture file from the initial attempt.
#   $4       - Path to the yt-dlp executable.
#   $5       - Name of a variable in the caller's scope to store/update the stdout capture file path.
#   $6       - Name of a variable in the caller's scope to store/update the stderr capture file path.
#   $@ (from 7th onwards) - Original arguments passed to yt-dlp (excluding the executable itself).
# Returns: The final exit code of yt-dlp (original or from retry).
#          Updates variables named by $5 and $6 in the caller's scope if a retry occurs.
# Depends on: _execute_ytdlp_command, log_user_info, log_warn_event, log_debug_event
#             Global config: YOUTUBE_SABR_RETRY_PLAYER_CLIENTS (array, e.g., ("android" "ios"))
_handle_ytdlp_sabr_retry() {
    local initial_exit_code="$1"
    # local initial_stdout_file="$2" # Parameter kept for future use, e.g. if stdout analysis becomes necessary
    local initial_stderr_file="$3"
    local ytdlp_executable="$4"
    local __stdout_capture_var_name="$5" # Indirect variable assignment target
    local __stderr_capture_var_name="$6" # Indirect variable assignment target
    shift 6 # Remove the first six params, rest are original yt-dlp args
    local original_ytdlp_args=("$@")

    local final_exit_code="$initial_exit_code"
    local stderr_content

    # Only attempt retry if initial command failed in a way that suggests SABR issues
    # yt-dlp error 101 is "max-downloads" reached, not a SABR error.
    if [[ "$initial_exit_code" -eq 0 || "$initial_exit_code" -eq 101 ]]; then
        log_debug_event "YT_SABR" "Initial yt-dlp exit code $initial_exit_code does not indicate a SABR-retryable error."
        return "$initial_exit_code"
    fi

    if [[ ! -f "$initial_stderr_file" ]]; then
        log_warn_event "YT_SABR" "Initial stderr capture file '$initial_stderr_file' not found. Cannot attempt SABR retry."
        return "$initial_exit_code"
    fi
    stderr_content=$(<"$initial_stderr_file")

    # Define SABR error patterns (expanded from original handle_youtube_link.sh)
    # Common patterns indicating potential signature/cipher issues or client restrictions.
    local sabr_patterns=(
        "SABR_ERR_NO_STREAM"
        "Your GAPI key is probably invalid"
        "Video unavailable"
        "This video is unavailable"
        "Unable to extract video data"
        "ERROR: Unable to extract video data"
        "ERROR: Video unavailable"
        "ERROR: This video is unavailable"
        "Forbidden"
        "HTTP Error 403"
        "KeyError: 'cipher'"
        "KeyError: 'signatureCipher'"
        "KeyError: 's'"
    )

    local sabr_error_detected=false
    for pattern in "${sabr_patterns[@]}"; do
        if [[ "$stderr_content" == *"$pattern"* ]]; then
            sabr_error_detected=true
            log_debug_event "YT_SABR" "SABR-related error pattern matched: '$pattern'"
            break
        fi
    done

    if [[ "$sabr_error_detected" == "true" ]]; then
        log_user_info "YouTube" "🚦 SABR-related error detected. Attempting recovery strategies..."

        # Default player clients to try if not configured
        # Ensure YOUTUBE_SABR_RETRY_PLAYER_CLIENTS is treated as an array
        local player_clients_to_try
        if [[ -n "${YOUTUBE_SABR_RETRY_PLAYER_CLIENTS[*]}" && ${#YOUTUBE_SABR_RETRY_PLAYER_CLIENTS[@]} -gt 0 ]]; then
            player_clients_to_try=("${YOUTUBE_SABR_RETRY_PLAYER_CLIENTS[@]}")
        else
            player_clients_to_try=("android" "ios") # Default if not set or empty
        fi
        log_debug_event "YT_SABR" "Player clients to try for SABR retry: ${player_clients_to_try[*]}"

        for client in "${player_clients_to_try[@]}"; do
            log_user_info "YouTube" "Retrying with YouTube player client: $client"
            
            local retry_args=()
            local skip_next_arg=false
            local i
            for i in "${!original_ytdlp_args[@]}"; do
                local arg="${original_ytdlp_args[$i]}"
                if [[ "$skip_next_arg" == "true" ]]; then
                    skip_next_arg=false
                    continue
                fi
                # Remove existing player client and its value
                if [[ "$arg" == "--youtube-player-client" ]]; then
                    skip_next_arg=true 
                    continue
                fi
                # Remove cookies if retrying with android client (matches handle_youtube_link.sh behavior)
                if [[ "$client" == "android" && "$arg" == "--cookies" ]]; then
                    skip_next_arg=true
                    continue
                fi
                retry_args+=("$arg")
            done

            retry_args+=("--youtube-player-client" "$client")
            # Ensure --youtube-skip-dash-manifest is present
            if ! printf '%s\0' "${retry_args[@]}" | grep -Fxqz -- "--youtube-skip-dash-manifest"; then
                 retry_args+=("--youtube-skip-dash-manifest")
            fi

            local retry_stdout_file # Will be set by _execute_ytdlp_command
            local retry_stderr_file # Will be set by _execute_ytdlp_command

            _execute_ytdlp_command "$ytdlp_executable" \
                "retry_stdout_file" \
                "retry_stderr_file" \
                "${retry_args[@]}"
            final_exit_code=$?

            # Update caller's capture file variables with the paths from the retry
            eval "$__stdout_capture_var_name=\"$retry_stdout_file\""
            eval "$__stderr_capture_var_name=\"$retry_stderr_file\""

            if [[ "$final_exit_code" -eq 0 ]]; then
                log_user_info "YouTube" "✅ SABR retry successful with client '$client'!"
                return 0 # Success
            elif [[ "$final_exit_code" -eq 101 ]]; then
                log_user_info "YouTube" "✅ SABR retry with client '$client' hit max-downloads (archive). Considered success."
                return 101 # Max-downloads
            else
                log_warn_event "YouTube" "SABR retry with client '$client' failed. Exit code: $final_exit_code."
                if [[ -f "$retry_stderr_file" ]]; then
                    stderr_content=$(<"$retry_stderr_file") # Update for next potential pattern match if more strategies were added
                else
                    stderr_content="" # Clear if file not found
                fi
            fi
        done
        
        log_warn_event "YouTube" "All SABR player client retries failed."
    else
        log_debug_event "YT_SABR" "No specific SABR error pattern matched in stderr. Not attempting SABR retry."
    fi
    
    return "$final_exit_code" # Return original or last retry exit code
}

# --- YouTube File Discovery ---

# Function: _find_downloaded_video_file
# Description: Attempts to find the downloaded video file after yt-dlp execution.
#              Prioritizes parsing filename from yt-dlp stdout if --print filename was used.
#              Falls back to finding the newest video file in the directory.
# Parameters:
#   $1 - Directory to search (e.g., LOCAL_DIR_YOUTUBE).
#   $2 - yt-dlp exit code from the download attempt.
#   $3 - Content of yt-dlp's stdout (expected to contain filename if --print filename was used).
#   $4 - Content of yt-dlp's stderr.
# Returns:
#   Prints the full path of the found video file to stdout on success.
#   Prints "ALREADY_IN_ARCHIVE" to stdout if archive message detected.
#   Prints nothing and returns non-zero on failure to find an expected file.
# Depends on: log_debug_event, log_warn_event
_find_downloaded_video_file() {
    local search_dir="$1"
    local ytdlp_exit_code="$2"
    local stdout_content="$3"
    local stderr_content="$4"

    local combined_output="${stdout_content}${stderr_content}" # Combine for easier searching

    # Check for "already in archive" messages first
    if [[ "$combined_output" == *"already been recorded in the archive"* ]]; then
        log_debug_event "YT_FIND" "yt-dlp output indicates video is already in archive."
        printf "%s\n" "ALREADY_IN_ARCHIVE"
        return 0 # Successful indication, not an error
    fi

    # Proceed if exit code suggests success or a max-downloads scenario where a file might exist
    if [[ "$ytdlp_exit_code" -eq 0 ]] || \
       { [[ "$ytdlp_exit_code" -eq 101 ]] && \
         { [[ "$combined_output" == *"[download] Overwriting existing file"* || \
            "$combined_output" == *"--max-downloads"*"reached"* || \
            "$combined_output" == *"has already been downloaded"* ]] || \
           [[ -z "$combined_output" ]] ;} ;} ; then

        log_debug_event "YT_FIND" "yt-dlp exit code $ytdlp_exit_code. Attempting to find downloaded file in '$search_dir'."
        
        if [[ ! -d "$search_dir" ]]; then
            log_warn_event "YT_FIND" "Search directory '$search_dir' does not exist."
            return 1
        fi

        # Add a small delay for file system to settle, as in original script
        sleep 2

        # Primary Method: Parse filename from stdout (if --print filename was used)
        # The filename is expected to be the last non-empty line from yt-dlp's stdout.
        local printed_filename
        # Get the last non-empty line from stdout_content
        local last_non_empty_line=""
        local current_line
        while IFS= read -r current_line; do
            if [[ -n "$current_line" ]]; then # Check if line is not empty
                last_non_empty_line="$current_line"
            fi
        done <<< "$stdout_content"
        printed_filename="$last_non_empty_line"

        if [[ -n "$printed_filename" ]]; then
            # Construct full path. yt-dlp --print filename usually prints just the basename.
            local potential_file_from_stdout="${search_dir}/${printed_filename}"
            if [[ -f "$potential_file_from_stdout" ]]; then
                log_debug_event "YT_FIND" "Successfully found video file via --print filename: '$potential_file_from_stdout'"
                printf "%s\n" "$potential_file_from_stdout"
                return 0
            else
                log_debug_event "YT_FIND" "Filename '$printed_filename' from stdout not found as '$potential_file_from_stdout'. Will attempt fallback."
            fi
        else
            log_debug_event "YT_FIND" "No filename found in yt-dlp stdout. Will attempt fallback to find newest file."
        fi

        # Fallback Method: Find newest video file in the directory
        log_debug_event "YT_FIND" "Fallback: Attempting to find newest common video file in '$search_dir'."
        local potential_file_full_path_fallback
        local find_ls_exit_code

        set +e # Allow capturing find/ls exit code
        potential_file_full_path_fallback=$(find "${search_dir}" -maxdepth 1 -type f \( -iname "*.mkv" -o -iname "*.mp4" -o -iname "*.webm" -o -iname "*.mov" -o -iname "*.avi" -o -iname "*.flv" \) -print0 2>/dev/null | xargs -0 -r ls -t 2>/dev/null | head -n 1)
        find_ls_exit_code=$?
        set -e
        
        if [[ "$find_ls_exit_code" -eq 0 && -n "$potential_file_full_path_fallback" ]]; then
            # If find/ls produced a relative path, make it absolute based on search_dir
            if [[ "$potential_file_full_path_fallback" != /* ]]; then
                potential_file_full_path_fallback="${search_dir}/${potential_file_full_path_fallback}"
            fi

            if [[ -f "$potential_file_full_path_fallback" ]]; then
                log_debug_event "YT_FIND" "Fallback: Found potential newest video file: '$potential_file_full_path_fallback'"
                printf "%s\n" "$potential_file_full_path_fallback"
                return 0
            else
                log_warn_event "YT_FIND" "Fallback: Path '$potential_file_full_path_fallback' from find/ls is not a valid file."
                return 1
            fi
        elif [[ "$find_ls_exit_code" -ne 0 && "$find_ls_exit_code" -ne 123 ]]; then # 123 can be xargs if no input
             log_warn_event "YT_FIND" "Fallback: Command to find newest video file failed (exit code $find_ls_exit_code)."
             return 1
        else # Includes find_ls_exit_code == 123 (no files found by find)
            log_warn_event "YT_FIND" "Fallback: No common video files found in '$search_dir' after yt-dlp run (exit code $ytdlp_exit_code)."
            return 1
        fi

    elif [[ "$ytdlp_exit_code" -eq 101 ]]; then
        # Handle other exit 101 cases (not max-downloads, not archive hit that was caught above)
        log_warn_event "YT_FIND" "yt-dlp exited 101 (unhandled reason, not archive hit or clear max-downloads). No file search attempted. Combined output: $combined_output"
        return 1
    else
        # yt-dlp failed with an error other than 0 or 101
        log_debug_event "YT_FIND" "yt-dlp failed with exit code $ytdlp_exit_code. No file search attempted."
        return 1 # No file expected
    fi
}

# --- YouTube Filename Processing ---

# Function: _normalize_and_rename_video_file
# Description: Normalizes a video filename by converting underscores to spaces,
#              fixing common English contractions, and truncating if too long.
#              Performs actual file renames on the filesystem.
# Parameters:
#   $1 - Full path to the downloaded video file.
#   $2 - (Optional) Maximum filename length. Defaults to 200.
# Returns:
#   Prints the final full path of the (potentially renamed) file to stdout.
#   Returns 0 on success (even if some renames failed but a valid path is returned).
#   Returns 1 if the input path is invalid or a critical error occurs.
# Depends on: log_debug_event, log_warn_event, log_user_progress (from logging_utils.sh)
_normalize_and_rename_video_file() {
    local current_file_full_path="$1"
    local max_len=${2:-200} # Default max filename length

    if [[ -z "$current_file_full_path" || ! -f "$current_file_full_path" ]]; then
        log_warn_event "YT_NORMALIZE" "Invalid or non-existent file provided for normalization: '$current_file_full_path'"
        printf "%s\n" "$current_file_full_path" # Return original path
        return 1
    fi

    local download_dir
    download_dir=$(dirname "$current_file_full_path")
    local current_filename
    current_filename=$(basename "$current_file_full_path")
    local original_filename_for_log="$current_filename"

    local file_ext="${current_filename##*.}"
    local filename_no_ext="${current_filename%.*}"

    # Step 1: Normalization (Underscores, Possessives, Contractions)
    log_debug_event "YT_NORMALIZE" "Normalizing filename: '$current_filename'"
    local filename_with_spaces_initial
    filename_with_spaces_initial=$(echo "$filename_no_ext" | tr '_' ' ')

    local filename_corrected_possessive_s
    filename_corrected_possessive_s=$(echo "$filename_with_spaces_initial" | sed -e 's/ s /s /g' -e 's/ s$/s/')

    local filename_with_fixed_contractions
    filename_with_fixed_contractions=$(echo "$filename_corrected_possessive_s" | \
        sed -E "
            s/([[:alpha:]]+) re /\1're /g;
            s/([[:alpha:]]+) ll /\1'll /g;
            s/([[:alpha:]]+) ve /\1've /g;
            s/([[:alpha:]]+) m /\1'm /g;
            s/([[:alpha:]]+) d /\1'd /g;
            s/([[:alpha:]]+) t /\1't /g;
        ")

    local normalized_filename_no_ext="$filename_with_fixed_contractions"
    local normalized_filename="${normalized_filename_no_ext}.${file_ext}"

    if [[ "$current_filename" != "$normalized_filename" ]]; then
        log_user_progress "YouTube" "Correcting filename format: '$current_filename' -> '$normalized_filename'"
        local normalized_full_path="${download_dir}/${normalized_filename}"
        if mv "$current_file_full_path" "$normalized_full_path"; then
            log_debug_event "YT_NORMALIZE" "Successfully renamed (normalization) to '$normalized_filename'"
            current_file_full_path="$normalized_full_path"
            current_filename="$normalized_filename"
        else
            log_warn_event "YT_NORMALIZE" "Failed to rename (normalization) '$current_filename' to '$normalized_filename'. Proceeding with '$current_filename'."
            # Keep current_file_full_path and current_filename as they are
        fi
    else
        log_debug_event "YT_NORMALIZE" "Filename '$current_filename' does not require underscore/contraction normalization."
    fi

    # Step 2: Filename Length Truncation
    if [[ ${#current_filename} -gt $max_len ]]; then
        log_user_progress "YouTube" "Filename too long (${#current_filename} chars), truncating to $max_len chars: '$current_filename'"
        
        local trunc_file_ext="${current_filename##*.}"
        local trunc_filename_no_ext="${current_filename%.*}"
        local available_len_for_name=$((max_len - ${#trunc_file_ext} - 1)) # -1 for the dot

        local truncated_basename_no_ext
        if [[ $available_len_for_name -lt 3 ]]; then # Not enough space for ellipsis
            truncated_basename_no_ext="${trunc_filename_no_ext:0:$available_len_for_name}"
        else
            truncated_basename_no_ext="${trunc_filename_no_ext:0:$((available_len_for_name - 3))}..."
        fi
        
        local truncated_filename="${truncated_basename_no_ext}.${trunc_file_ext}"
        local truncated_full_path="${download_dir}/${truncated_filename}"

        if mv "$current_file_full_path" "$truncated_full_path"; then
            log_debug_event "YT_NORMALIZE" "Successfully renamed (truncation): '$current_filename' -> '$truncated_filename'"
            current_file_full_path="$truncated_full_path"
            # current_filename="$truncated_filename" # Not strictly needed as we print current_file_full_path at the end
        else
            log_warn_event "YT_NORMALIZE" "Failed to rename (truncation) '$current_filename' to '$truncated_filename'. Proceeding with '$current_filename'."
            # current_file_full_path remains unchanged from before truncation attempt
        fi
    else
        log_debug_event "YT_NORMALIZE" "Filename length OK (${#current_filename} chars, max: $max_len). No truncation needed."
    fi

    log_debug_event "YT_NORMALIZE" "Final processed file path for '$original_filename_for_log' is '$current_file_full_path'"
    printf "%s\n" "$current_file_full_path"
    return 0
}

# --- YouTube Archive Management ---

# Function: _youtube_utils_remove_url_from_archive
# Description: Removes a specific YouTube video ID from the yt-dlp download archive file.
#              Based on _remove_url_from_youtube_archive from jellymac.sh.
# Parameters:
#   $1 - The YouTube URL (e.g., https://www.youtube.com/watch?v=VIDEO_ID or https://youtu.be/VIDEO_ID).
#   $2 - Path to the yt-dlp download archive file.
# Returns:
#   0 if removal was attempted (even if ID not found or archive didn't exist).
#   1 if critical preconditions are not met (e.g., no URL, no archive file path).
# Depends on: log_debug_event, log_warn_event (from logging_utils.sh)
_youtube_utils_remove_url_from_archive() {
    local url_to_remove="$1"
    local archive_file_path="$2"
    local video_id

    if [[ -z "$url_to_remove" ]]; then
        log_warn_event "YT_ARCHIVE" "No URL provided to remove from archive."
        return 1
    fi
    if [[ -z "$archive_file_path" ]]; then
        log_warn_event "YT_ARCHIVE" "No archive file path provided for URL '$url_to_remove'."
        return 1
    fi

    # Extract video ID from URL using Bash string manipulation
    case "$url_to_remove" in
        *watch?v=*)
            video_id="${url_to_remove#*watch?v=}" # Remove prefix up to "watch?v="
            video_id="${video_id%%&*}"            # Remove suffix from "&" onwards
            ;;
        *youtu.be/*)
            video_id="${url_to_remove#*youtu.be/}" # Remove prefix up to "youtu.be/"
            video_id="${video_id%%\?*}"           # Remove suffix from "?" onwards
            ;;
        *) video_id="" ;;
    esac

    if [[ -z "$video_id" ]]; then
        log_warn_event "YT_ARCHIVE" "Could not extract video ID from URL '$url_to_remove'. Cannot remove from archive."
        return 1
    fi

    log_debug_event "YT_ARCHIVE" "Attempting to remove video ID '$video_id' (from URL '$url_to_remove') from archive file '$archive_file_path'."

    if [[ ! -f "$archive_file_path" ]]; then
        log_debug_event "YT_ARCHIVE" "Archive file '$archive_file_path' does not exist. Nothing to remove for video ID '$video_id'."
        return 0 # Not an error, just nothing to do
    fi

    local archive_backup_file="${archive_file_path}.bak"
    if ! cp "$archive_file_path" "$archive_backup_file"; then
        log_warn_event "YT_ARCHIVE" "Failed to create backup of archive file '$archive_file_path' to '$archive_backup_file'. Aborting removal."
        return 1
    fi

    # Use grep to filter out the line. yt-dlp archive format is typically 'youtube VIDEO_ID'.
    # Ensure the pattern is specific enough to avoid accidental removals if IDs are substrings of others.
    # Using a pattern that matches the start of the line for 'youtube' followed by the ID.
    # Considering yt-dlp might just store the ID for some services, but 'youtube VIDEO_ID' is common.
    # Let's assume the common 'youtube VIDEO_ID' format for now.
    if grep -v "^youtube ${video_id}$" "$archive_backup_file" > "$archive_file_path"; then
        log_debug_event "YT_ARCHIVE" "Successfully updated archive file '$archive_file_path' by removing (if present) ID '$video_id'."
        local lines_before lines_after
        lines_before=$(wc -l < "$archive_backup_file")
        lines_after=$(wc -l < "$archive_file_path")
        if [[ "$lines_before" -gt "$lines_after" ]]; then
            log_debug_event "YT_ARCHIVE" "Video ID '$video_id' was found and removed from archive."
        else
            log_debug_event "YT_ARCHIVE" "Video ID '$video_id' was not found in archive '$archive_file_path'. File remains unchanged by grep."
        fi
    else
        log_warn_event "YT_ARCHIVE" "Failed to update archive file '$archive_file_path' for video ID '$video_id'. Restoring from backup."
        if mv "$archive_backup_file" "$archive_file_path"; then
            log_debug_event "YT_ARCHIVE" "Successfully restored archive file '$archive_file_path' from backup."
        else
            log_warn_event "YT_ARCHIVE" "CRITICAL: Failed to restore archive file '$archive_file_path' from backup '$archive_backup_file'. Archive may be corrupted."
            return 1 # Indicate a more serious failure
        fi
        return 1 # Indicate failure to update
    fi

    if ! rm -f "$archive_backup_file"; then
        log_warn_event "YT_ARCHIVE" "Failed to remove archive backup file '$archive_backup_file'."
    fi

    return 0
}

# --- YouTube File Transfer ---

# Function: _transfer_youtube_video
# Description: Transfers a processed YouTube video file to its final destination directory,
#              handling subfolder creation, disk space checks, and transfer errors.
# Parameters:
#   $1 - processed_local_file_path: Full path to the video file in LOCAL_DIR_YOUTUBE.
#   $2 - base_destination_config: Value of DEST_DIR_YOUTUBE (final base directory).
#   $3 - create_subfolder_config: String "true" or "false" (from YOUTUBE_CREATE_SUBFOLDER_PER_VIDEO).
#   $4 - original_youtube_url: The original URL of the video (for logging and archive removal on failure).
#   $5 - download_archive_file_config: Value of DOWNLOAD_ARCHIVE_YOUTUBE (for removing entry on failure).
# Returns:
#   0 on successful transfer.
#   1 on failure (e.g., disk space error, transfer error, critical setup issue).
# Depends on:
#   Global config: ERROR_DIR, HISTORY_FILE, SOUND_NOTIFICATION, ENABLE_DESKTOP_NOTIFICATIONS.
#   Functions from common_utils.sh: check_available_disk_space, quarantine_item,
#                                   transfer_file_smart, record_transfer_to_history,
#                                   play_sound_notification, send_desktop_notification.
#   Functions from youtube_utils.sh: _youtube_utils_remove_url_from_archive.
#   Functions from logging_utils.sh: log_debug_event, log_user_progress, log_error_event, etc.
_transfer_youtube_video() {
    local processed_local_file_path="$1"
    local base_destination_config="$2"
    local create_subfolder_config="$3"
    local original_youtube_url="$4"
    local download_archive_file_config="$5"

    local func_log_prefix="YT_TRANSFER"

    # --- Parameter Validation ---
    if [[ -z "$processed_local_file_path" ]]; then log_error_event "$func_log_prefix" "Processed local file path not provided."; return 1; fi
    if [[ ! -f "$processed_local_file_path" ]]; then log_error_event "$func_log_prefix" "Processed local file '$processed_local_file_path' not found or not a file."; return 1; fi
    if [[ -z "$base_destination_config" ]]; then log_error_event "$func_log_prefix" "Base destination directory (DEST_DIR_YOUTUBE) not configured."; return 1; fi
    if [[ -z "$original_youtube_url" ]]; then log_error_event "$func_log_prefix" "Original YouTube URL not provided."; return 1; fi
    if [[ -z "$download_archive_file_config" ]]; then log_error_event "$func_log_prefix" "Download archive file path (DOWNLOAD_ARCHIVE_YOUTUBE) not configured."; return 1; fi

    log_debug_event "$func_log_prefix" "Initiating transfer for: '$processed_local_file_path'"
    log_debug_event "$func_log_prefix" "Base Dest: '$base_destination_config', Subfolder: '$create_subfolder_config', URL: '$original_youtube_url'"

    local final_filename
    final_filename=$(basename "$processed_local_file_path")
    local final_filename_no_ext="${final_filename%.*}"

    local target_directory
    local final_file_destination_path

    # --- 1. Determine Final Destination Path ---
    if [[ "$create_subfolder_config" == "true" ]]; then
        # Sanitize final_filename_no_ext for directory name (basic: replace / or \\ with _)
        local safe_subfolder_name
        safe_subfolder_name="${final_filename_no_ext//[\\/]/_}"
        target_directory="${base_destination_config}/${safe_subfolder_name}"
        final_file_destination_path="${target_directory}/${final_filename}"
        log_debug_event "$func_log_prefix" "Subfolder creation enabled. Target directory: '$target_directory'"
    else
        target_directory="$base_destination_config"
        final_file_destination_path="${target_directory}/${final_filename}"
        log_debug_event "$func_log_prefix" "Subfolder creation disabled. Target directory: '$target_directory'"
    fi
    log_debug_event "$func_log_prefix" "Final destination path determined: '$final_file_destination_path'"

    # --- 2. Pre-Transfer Checks ---
    # --- 2a. Disk Space Check ---
    local file_size_kb
    file_size_kb=$(du -sk "$processed_local_file_path" | awk '{print $1}')
    if ! [[ "$file_size_kb" =~ ^[0-9]+$ ]]; then
        log_error_event "$func_log_prefix" "Could not determine size of '$processed_local_file_path'. Aborting transfer."
        quarantine_item "$processed_local_file_path" "YouTube transfer - unknown source size" "$func_log_prefix"
        return 1
    fi
    log_debug_event "$func_log_prefix" "Source file size: '$file_size_kb' KB."

    # check_available_disk_space expects destination directory, not full file path
    if ! check_available_disk_space "$target_directory" "$file_size_kb"; then
        log_error_event "$func_log_prefix" "Insufficient disk space at '$target_directory' for '$final_filename' (${file_size_kb}KB)."
        # common_utils.check_available_disk_space logs details. We quarantine the source.
        quarantine_item "$processed_local_file_path" "YouTube transfer - insufficient disk space at destination" "$func_log_prefix"
        return 1
    fi

    # --- 2b. Create Target Directory (if subfolder enabled and directory doesn't exist) ---
    if [[ "$create_subfolder_config" == "true" ]]; then
        if [[ ! -d "$target_directory" ]]; then
            log_user_progress "YouTube" "Creating subfolder: '$target_directory'"
            if ! mkdir -p "$target_directory"; then
                log_error_event "$func_log_prefix" "Failed to create target subfolder '$target_directory'. Check permissions."
                # Don't quarantine source yet, as the issue is with destination structure creation.
                return 1
            fi
            log_debug_event "$func_log_prefix" "Successfully created target subfolder: '$target_directory'"
        fi
    fi # If not creating subfolders, base_destination_config should already exist (checked by preflight)

    # --- 3. Perform File Transfer --- #
    log_user_progress "YouTube" "🚀 Transferring '$final_filename' to library..."
    
    local transfer_exit_code
    # transfer_file_smart (from common_utils.sh) handles local vs network, retries for network,
    # and removes source on success for rsync.
    transfer_file_smart "$processed_local_file_path" "$final_file_destination_path" "YouTube"
    transfer_exit_code=$?

    # --- 4. Post-Transfer Handling ---
    if [[ "$transfer_exit_code" -eq 0 ]]; then
        log_user_success "YouTube" "✅ Successfully transferred '$final_filename' to '$final_file_destination_path'"
        record_transfer_to_history "YouTube: ${original_youtube_url:0:70}... -> ${final_file_destination_path}"
        play_sound_notification "task_success" "YouTube"
        send_desktop_notification "JellyMac: YouTube Transferred" "Video '$final_filename' moved to library."
        return 0
    else
        log_error_event "$func_log_prefix" "Transfer of '$final_filename' to '$final_file_destination_path' failed with exit code ${transfer_exit_code}."
        play_sound_notification "task_error" "YouTube"

        log_user_info "YouTube" "Attempting to remove '$original_youtube_url' from download archive to allow retry."
        _youtube_utils_remove_url_from_archive "$original_youtube_url" "$download_archive_file_config"
        # _youtube_utils_remove_url_from_archive logs its own success/failure.

        # If the source file still exists after a failed transfer, quarantine it.
        # transfer_file_smart with rsync might leave partials at dest and source intact on some errors.
        # mv (local transfer in transfer_file_smart) would mean source is gone or still there.
        if [[ -f "$processed_local_file_path" ]]; then
            log_warn_event "$func_log_prefix" "Source file '$processed_local_file_path' still exists after failed transfer. Quarantining."
            quarantine_item "$processed_local_file_path" "YouTube transfer failure" "$func_log_prefix"
        else
            log_debug_event "$func_log_prefix" "Source file '$processed_local_file_path' does not exist after failed transfer (already moved or removed by transfer attempt)."
        fi
        return 1
    fi
}

# --- YouTube Command Construction ---

# Function: _build_ytdlp_single_video_args
# Description: Constructs a common set of yt-dlp arguments for downloading a
#              single YouTube video. Arguments are printed to stdout, one per line.
# Parameters:
#   $1       - The YouTube video URL.
#   $2       - The desired output template (e.g., "/path/to/%(title)s.%(ext)s").
#              This path should be absolute or relative to where yt-dlp will be run.
#   $3       - (Optional) Boolean true/false to force adding "--print filename"
#              (defaults to false).
# Depends on:
#   Global config variables: YTDLP_FORMAT, YTDLP_OPTS (array),
#                            DOWNLOAD_ARCHIVE_YOUTUBE, COOKIES_ENABLED, COOKIES_FILE.
#   Functions: log_debug_event, log_warn_event (from logging_utils.sh)
# Returns: Prints each constructed argument to stdout on a new line.
#          Caller should capture using a loop, e.g.:
#          local my_args_array=()
#          while IFS= read -r arg_line; do
#            [[ -n "$arg_line" ]] && my_args_array+=("$arg_line")
#          done < <(_build_ytdlp_single_video_args "url" "template" "true")

_build_ytdlp_single_video_args() {
    local video_url="$1"
    local output_template="$2"
    local force_print_filename="${3:-false}"

    local local_args_array=() # Build args in this local, temporary array

    # --- Basic yt-dlp options ---
    local_args_array+=("--ignore-errors") # Continue on non-fatal errors for individual videos
    local_args_array+=("--format")
    local_args_array+=("${YTDLP_FORMAT:-bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]/best}") # Use configured or default format

    local_args_array+=("--output")
    local_args_array+=("$output_template")

    # --- Progress option ---
    local user_specified_progress_option=false
    if [[ ${#YTDLP_OPTS[@]} -gt 0 ]]; then
        for opt_check in "${YTDLP_OPTS[@]}"; do
            if [[ "$opt_check" == "--progress" || "$opt_check" == "--no-progress" ]]; then
                user_specified_progress_option=true
                break
            fi
        done
    fi
    if [[ "$user_specified_progress_option" == "false" ]]; then
        local_args_array+=("--progress") # Add default --progress if user hasn't specified either
    fi

    # --- User-specified yt-dlp options (YTDLP_OPTS) ---
    if [[ ${#YTDLP_OPTS[@]} -gt 0 ]]; then
        # Add each element from YTDLP_OPTS individually to preserve spaces in arguments
        for opt in "${YTDLP_OPTS[@]}"; do
            local_args_array+=("$opt")
        done
    fi

    # --- Download Archive ---
    if [[ -n "${DOWNLOAD_ARCHIVE_YOUTUBE:-}" ]]; then
        local archive_dir
        archive_dir=$(dirname "$DOWNLOAD_ARCHIVE_YOUTUBE")
        # Ensure archive directory exists or can be created
        if [[ ! -d "$archive_dir" ]]; then
            log_debug_event "YouTubeUtils" "Attempting to create archive directory '$archive_dir'..."
            if mkdir -p "$archive_dir"; then
                log_debug_event "YouTubeUtils" "Successfully created archive directory '$archive_dir'."
            else
                log_warn_event "YouTubeUtils" "Failed to create archive directory '$archive_dir'. Archive will NOT be used for this download."
            fi
        fi
        # Add archive flags only if directory exists (or was just created)
        if [[ -d "$archive_dir" ]]; then
             local_args_array+=("--download-archive")
             local_args_array+=("$DOWNLOAD_ARCHIVE_YOUTUBE")
             log_debug_event "YouTubeUtils" "Download archive enabled: $DOWNLOAD_ARCHIVE_YOUTUBE"
        fi
    else
        log_debug_event "YouTubeUtils" "No DOWNLOAD_ARCHIVE_YOUTUBE configured. Archive will not be used."
    fi

    # --- Cookies ---
    if [[ "${COOKIES_ENABLED:-false}" == "true" && -n "${COOKIES_FILE:-}" ]]; then
        if [[ -f "$COOKIES_FILE" ]]; then
            local_args_array+=("--cookies")
            local_args_array+=("$COOKIES_FILE")
            log_debug_event "YouTubeUtils" "Using cookies file: $COOKIES_FILE"
        else
            log_warn_event "YouTubeUtils" "Cookies file '$COOKIES_FILE' not found. Proceeding without cookies."
        fi
    else
        log_debug_event "YouTubeUtils" "Cookies disabled or COOKIES_FILE not configured. Proceeding without cookies."
    fi

    # --- --print filename (optional) ---
    if [[ "$force_print_filename" == "true" ]]; then
        local already_has_print_filename=false
        if [[ ${#YTDLP_OPTS[@]} -gt 0 ]]; then
            local i
            for i in "${!YTDLP_OPTS[@]}"; do
                if [[ "${YTDLP_OPTS[$i]}" == "--print" ]]; then
                    # Check if the next element exists and is "filename"
                    # Ensure i+1 is a valid index
                    local next_index=$((i + 1))
                    if [[ "$next_index" -lt "${#YTDLP_OPTS[@]}" && "${YTDLP_OPTS[$next_index]}" == "filename" ]]; then
                        already_has_print_filename=true
                        break
                    fi
                fi
            done
        fi

        if [[ "$already_has_print_filename" == "false" ]]; then
            local_args_array+=("--print" "filename")
        else
            log_debug_event "YouTubeUtils" "YTDLP_OPTS already contains '--print filename'. Not adding it again."
        fi
    fi

    # --- Finally, the URL ---
    local_args_array+=("$video_url")

    log_debug_event "YouTubeUtils" "Built yt-dlp args (to be printed): ${local_args_array[*]}"
    
    # Print each argument on a new line
    # This ensures arguments with spaces are handled correctly by the caller's read loop
    local arg
    for arg in "${local_args_array[@]}"; do
        printf "%s\\n" "$arg"
    done
}
