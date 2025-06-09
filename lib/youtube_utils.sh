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
    for queued_url in "${queued_urls[@]}"; do
        [[ -z "$queued_url" ]] && continue
        
        ((processed_count++))
        log_user_info "JellyMac" "🎬 Processing queued download $processed_count/$total_count: '${queued_url:0:60}...'"
        
        if "$HANDLE_YOUTUBE_SCRIPT" "$queued_url"; then
            log_user_info "JellyMac" "✅ Queued download complete ($processed_count/$total_count): '${queued_url:0:60}...'"
            send_desktop_notification "JellyMac: YouTube Complete" "Queued #$processed_count: ${queued_url:0:50}..."
        else
            ((failed_count++))
            log_warn_event "JellyMac" "❌ Queued download failed ($processed_count/$total_count): '${queued_url:0:60}...'"
            send_desktop_notification "JellyMac: YouTube Error" "Failed #$processed_count: ${queued_url:0:50}..." "Basso"
            
            # Re-add failed URL to queue for retry on next startup
            echo "$queued_url" >> "$queue_file"
        fi
    done
    
    if [[ "$failed_count" -eq 0 ]]; then
        log_user_info "JellyMac" "📋 Queue processing complete! Successfully processed all $processed_count downloads."
        # Queue file was already deleted at the start, and no failures to re-add
    else
        log_user_info "JellyMac" "📋 Queue processing complete! Processed $processed_count downloads ($failed_count failed, re-queued for retry)."
        log_user_info "JellyMac" "💡 Failed downloads will be offered for retry on next JellyMac startup."
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

# Note: The main _check_clipboard_youtube function, which includes the logic
# for forking a background monitoring loop when foreground processing starts,
# will remain in jellymac.sh as it's more of an orchestrator.
# This file contains the core queue management and the specific background
# clipboard check function (_check_clipboard_youtube_for_queue) that is
# called BY that background loop.
