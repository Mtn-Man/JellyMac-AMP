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
    local tee_stderr_ec

    # Execute yt-dlp with dual output capture:
    # stderr: tee to capture file and display to user
    # stdout: tee to capture file and display progress to user
    set +e # Allow capturing PIPESTATUS
    { "$ytdlp_executable" "${ytdlp_args[@]}" \
        2> >(tee "$stderr_file" >&2); \
        tee_stderr_ec=${PIPESTATUS[1]}; \
    } | tee "$stdout_file"
    
    ytdlp_actual_exit_code=${PIPESTATUS[0]} # yt-dlp exit code (from the compound command on the left of the main pipe)
    tee_stdout_ec=${PIPESTATUS[1]}      # tee for stdout exit code
    set -e

    if [[ "$tee_stdout_ec" -ne 0 ]]; then
        log_warn_event "YT_EXEC" "The 'tee' command for yt-dlp stdout exited with status $tee_stdout_ec. Stdout capture might be affected."
    fi
    # tee_stderr_ec is captured from within the compound command for stderr's tee.
    if [[ "$tee_stderr_ec" -ne 0 ]]; then
        log_warn_event "YT_EXEC" "The 'tee' command for yt-dlp stderr exited with status $tee_stderr_ec. Stderr capture might be affected."
    fi
    
    log_debug_event "YT_EXEC" "yt-dlp execution finished. Exit code: $ytdlp_actual_exit_code"
    return "$ytdlp_actual_exit_code"
}

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
