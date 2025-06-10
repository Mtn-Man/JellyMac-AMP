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
