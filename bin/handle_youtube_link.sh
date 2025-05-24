#!/bin/bash

# JellyMac_AMP/bin/handle_youtube_link.sh
# Handles downloading a YouTube video given a URL.
# Attempts to find the newest video file if yt-dlp exits successfully or hits max-downloads.
# Captures both stdout and stderr for more robust message checking, while showing live progress.

# --- Strict Mode & Globals ---
set -eo pipefail
# set -u # Uncomment for stricter undefined variable checks after thorough testing

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "${SCRIPT_DIR}/../lib" && pwd)" # Assumes lib is one level up from bin

# --- Temp File Management for this script ---
#==============================================================================
# Function: _cleanup_script_temp_files
# Description: Cleans up temporary files created during script execution.
# Parameters: None
# Returns: None
#==============================================================================
_cleanup_script_temp_files() {
    # shellcheck disable=SC2317 
    if [[ ${#_SCRIPT_TEMP_FILES_TO_CLEAN[@]} -gt 0 ]]; then
        echo "INFO: $(date '+%Y-%m-%d %H:%M:%S') - [${SCRIPT_NAME}_TRAP] Cleaning up temporary files (${#_SCRIPT_TEMP_FILES_TO_CLEAN[@]})..." >&2
        local temp_file_to_clean 
        for temp_file_to_clean in "${_SCRIPT_TEMP_FILES_TO_CLEAN[@]}"; do
            if [[ -n "$temp_file_to_clean" && -e "$temp_file_to_clean" ]]; then
                rm -f "$temp_file_to_clean" 
                echo "INFO: $(date '+%Y-%m-%d %H:%M:%S') - [${SCRIPT_NAME}_TRAP] Removed '$temp_file_to_clean'" >&2
            fi
        done
    fi
    # shellcheck disable=SC2317
    _SCRIPT_TEMP_FILES_TO_CLEAN=()
}
trap _cleanup_script_temp_files EXIT SIGINT SIGTERM

# --- Source Libraries ---
# shellcheck source=../lib/logging_utils.sh
source "${LIB_DIR}/logging_utils.sh"
# shellcheck source=../lib/jellymac_config.sh 
source "${LIB_DIR}/jellymac_config.sh" 
# shellcheck source=../lib/common_utils.sh
source "${LIB_DIR}/common_utils.sh" 
# shellcheck source=../lib/jellyfin_utils.sh
source "${LIB_DIR}/jellyfin_utils.sh" 

# --- Log Level & Prefix Initialization ---
#==============================================================================
# Function: log_info
# Description: Logs an INFO message with the script's prefix.
# Parameters:
#   $1: Message string
# Returns: None
#==============================================================================
log_info() { _log_event_if_level_met "$LOG_LEVEL_INFO" "$LOG_PREFIX_SCRIPT" "$*"; }

#==============================================================================
# Function: log_warn
# Description: Logs a WARN message with the script's prefix.
# Parameters:
#   $1: Message string
# Returns: None
#==============================================================================
log_warn() { _log_event_if_level_met "$LOG_LEVEL_WARN" "⚠️ WARN: $LOG_PREFIX_SCRIPT" "$*" >&2; }

#==============================================================================
# Function: log_debug
# Description: Logs a DEBUG message with the script's prefix.
# Parameters:
#   $1: Message string
# Returns: None
#==============================================================================
log_debug() { _log_event_if_level_met "$LOG_LEVEL_DEBUG" "🐛 DEBUG: $LOG_PREFIX_SCRIPT" "$*"; }

#==============================================================================
# ARGUMENT VALIDATION AND SETUP
#==============================================================================
if [[ $# -ne 1 ]]; then
    log_error_event "$LOG_PREFIX_SCRIPT" "Usage: $SCRIPT_NAME <youtube_url>"
    exit 1
fi
YOUTUBE_URL="$1"
if [[ -z "$YOUTUBE_URL" ]]; then
    log_error_event "$LOG_PREFIX_SCRIPT" "YouTube URL cannot be empty."
    exit 1
fi
log_info "▶️ Processing YouTube URL: ${YOUTUBE_URL:0:100}..."

#==============================================================================
# PRE-FLIGHT CHECKS AND DIRECTORY VALIDATION
#==============================================================================
# Validate required configuration variables and locate yt-dlp executable
YTDLP_EXECUTABLE=$(find_executable "yt-dlp" "${YTDLP_PATH:-}")
: "${LOCAL_DIR_YOUTUBE:?YT_HANDLER: LOCAL_DIR_YOUTUBE not set.}"
: "${DEST_DIR_YOUTUBE:?YT_HANDLER: DEST_DIR_YOUTUBE not set.}"
: "${YTDLP_FORMAT:?YT_HANDLER: YTDLP_FORMAT for YouTube not set in config.}"
: "${RSYNC_TIMEOUT:=300}"

# Validate and create required directories with write permissions
for dir_var_name_check in LOCAL_DIR_YOUTUBE DEST_DIR_YOUTUBE; do
    current_dir_path="${!dir_var_name_check}" 
    if [[ ! -d "$current_dir_path" ]]; then
        log_info "Creating directory '$current_dir_path'..."
        if ! mkdir -p "$current_dir_path"; then 
            log_error_event "$LOG_PREFIX_SCRIPT" "Failed to create dir '$current_dir_path'. Check permissions."
            exit 1; 
        fi
    fi
    if [[ ! -w "$current_dir_path" ]]; then 
        log_error_event "$LOG_PREFIX_SCRIPT" "Dir '$current_dir_path' not writable."
        exit 1; 
    fi
done

if ! check_available_disk_space "${LOCAL_DIR_YOUTUBE}" "10240"; then # 10MB
    log_error_event "$LOG_PREFIX_SCRIPT" "Insufficient disk space in '$LOCAL_DIR_YOUTUBE'."
    exit 1
fi

#==============================================================================
# DOWNLOAD EXECUTION AND COMMAND PREPARATION
#==============================================================================
log_info "Starting download for: ${YOUTUBE_URL:0:70}..."
YTDLP_OUTPUT_TEMPLATE="${LOCAL_DIR_YOUTUBE}/%(title).200B.%(ext)s"

# Build yt-dlp command arguments array
declare -a ytdlp_command_args=()
ytdlp_command_args[${#ytdlp_command_args[@]}]="--ignore-errors"  # Continue on non-fatal errors
ytdlp_command_args[${#ytdlp_command_args[@]}]="--format"
ytdlp_command_args[${#ytdlp_command_args[@]}]="$YTDLP_FORMAT"  # Use configured quality preference
ytdlp_command_args[${#ytdlp_command_args[@]}]="--output"
ytdlp_command_args[${#ytdlp_command_args[@]}]="$YTDLP_OUTPUT_TEMPLATE"  # Set filename template

# Check if progress option is already specified in user config
progress_option_set=false
if [[ ${#YTDLP_OPTS[@]} -gt 0 ]]; then
    for opt_check in "${YTDLP_OPTS[@]}"; do
        if [[ "$opt_check" == "--progress" || "$opt_check" == "--no-progress" ]]; then
            progress_option_set=true
            break
        fi
    done
fi
# Add progress option if not already specified by user
if [[ "$progress_option_set" == "false" ]]; then
    ytdlp_command_args[${#ytdlp_command_args[@]}]="--progress"
fi

# Apply user-specified yt-dlp options from YTDLP_OPTS array
if [[ ${#YTDLP_OPTS[@]} -gt 0 ]]; then
    for opt in "${YTDLP_OPTS[@]}"; do
        ytdlp_command_args[${#ytdlp_command_args[@]}]="$opt"
    done
fi

# Enable download archive if configured via DOWNLOAD_ARCHIVE_YOUTUBE
if [[ -n "$DOWNLOAD_ARCHIVE_YOUTUBE" ]]; then
    archive_dir=$(dirname "$DOWNLOAD_ARCHIVE_YOUTUBE")
    if [[ ! -d "$archive_dir" ]]; then
        log_info "Creating archive directory '$archive_dir'..."
        if mkdir -p "$archive_dir"; then
            ytdlp_command_args[${#ytdlp_command_args[@]}]="--download-archive"
            ytdlp_command_args[${#ytdlp_command_args[@]}]="$DOWNLOAD_ARCHIVE_YOUTUBE"
            log_info "Download archive enabled: $DOWNLOAD_ARCHIVE_YOUTUBE"
        else
             log_warn "Failed to create archive dir '$archive_dir'. Archive will NOT be used for this run."
        fi
    else
        ytdlp_command_args[${#ytdlp_command_args[@]}]="--download-archive"
        ytdlp_command_args[${#ytdlp_command_args[@]}]="$DOWNLOAD_ARCHIVE_YOUTUBE"
        log_info "Download archive enabled: $DOWNLOAD_ARCHIVE_YOUTUBE"
    fi
else
    log_info "No DOWNLOAD_ARCHIVE_YOUTUBE configured. Archive will not be used."
fi

# Apply cookies configuration if enabled
if [[ "${COOKIES_ENABLED:-false}" == "true" && -n "$COOKIES_FILE" ]]; then
    if [[ -f "$COOKIES_FILE" ]]; then 
        ytdlp_command_args[${#ytdlp_command_args[@]}]="--cookies"
        ytdlp_command_args[${#ytdlp_command_args[@]}]="$COOKIES_FILE"
        log_debug "Using cookies file: $COOKIES_FILE"
    else 
        log_warn "Cookies file '$COOKIES_FILE' not found. Proceeding without cookies."; 
    fi
else
    log_debug "Cookies disabled in config or not configured. Proceeding without cookies."
fi
ytdlp_command_args[${#ytdlp_command_args[@]}]="$YOUTUBE_URL" 

# Create temporary files to capture yt-dlp output for error analysis
YTDLP_STDOUT_CAPTURE_FILE=$(mktemp "${SCRIPT_DIR}/.ytdlp_stdout.XXXXXX")
YTDLP_STDERR_CAPTURE_FILE=$(mktemp "${SCRIPT_DIR}/.ytdlp_stderr.XXXXXX")
_SCRIPT_TEMP_FILES_TO_CLEAN+=("$YTDLP_STDOUT_CAPTURE_FILE" "$YTDLP_STDERR_CAPTURE_FILE")

log_debug "Executing command: $YTDLP_EXECUTABLE ${ytdlp_command_args[*]}"

#==============================================================================
# YTDLP EXECUTION WITH LIVE PROGRESS AND ERROR CAPTURE
#==============================================================================
set +e 
# Execute yt-dlp with dual output capture:
# - stderr: tee to capture file and display to user
# - stdout: tee to capture file and display progress to user
"$YTDLP_EXECUTABLE" "${ytdlp_command_args[@]}" \
    2> >(tee "$YTDLP_STDERR_CAPTURE_FILE" >&2) \
    | tee "$YTDLP_STDOUT_CAPTURE_FILE"

# Capture exit codes from the pipeline
YTDLP_EXIT_CODE=${PIPESTATUS[0]}  # yt-dlp exit code
_tee_stdout_ec=${PIPESTATUS[1]}   # tee exit code
set -e 

# Check for tee command issues (optional diagnostic)
if [[ "$_tee_stdout_ec" -ne 0 ]]; then
    log_warn "The 'tee' command for yt-dlp stdout exited with status $_tee_stdout_ec. Stdout capture might be affected, but yt-dlp progress should have been attempted."
fi

# Read captured output for error analysis
ytdlp_stdout_content=$(<"$YTDLP_STDOUT_CAPTURE_FILE")
ytdlp_stderr_content=$(<"$YTDLP_STDERR_CAPTURE_FILE")

DOWNLOADED_FILE_FULL_PATH="" 

#==============================================================================
# SABR STREAMING ERROR RECOVERY
#==============================================================================
# SABR (Streaming Audio/Video Browser Rendering) is a YouTube streaming method
# that can cause download failures. This section handles those errors with
# progressive retry attempts using different player clients.
if [[ "$YTDLP_EXIT_CODE" -ne 0 ]] && \
   (grep -q "YouTube is forcing SABR streaming" <<< "$ytdlp_stderr_content" || \
    grep -q "Only images are available for download" <<< "$ytdlp_stderr_content" || \
    grep -q "nsig extraction failed" <<< "$ytdlp_stderr_content"); then
    
    log_info "Detected YouTube SABR streaming issue. Retrying with alternative player client..."
    
    # Create retry arguments, excluding cookies (incompatible with Android client)
    declare -a ytdlp_retry_args=()
    prev_arg=""
    for arg in "${ytdlp_command_args[@]}"; do
        if [[ "$arg" != "$COOKIES_FILE" && "$prev_arg" != "--cookies" ]]; then
            ytdlp_retry_args[${#ytdlp_retry_args[@]}]="$arg"
        fi
        prev_arg="$arg"
    done
    
    # Add Android client arguments (better SABR compatibility)
    ytdlp_retry_args[${#ytdlp_retry_args[@]}]="--extractor-args"
    ytdlp_retry_args[${#ytdlp_retry_args[@]}]="youtube:player_client=android"
    
    # Inform user about cookies removal if they were enabled
    if [[ "${COOKIES_ENABLED:-false}" == "true" && -n "$COOKIES_FILE" ]]; then
        log_info "Note: Cookies disabled for Android client retry (not supported)"
    fi
    
    # Execute first retry attempt with Android client
    log_debug "Retrying with command: $YTDLP_EXECUTABLE ${ytdlp_retry_args[*]}"
    
    set +e
    "$YTDLP_EXECUTABLE" "${ytdlp_retry_args[@]}" \
        2> >(tee "$YTDLP_STDERR_CAPTURE_FILE" >&2) \
        | tee "$YTDLP_STDOUT_CAPTURE_FILE"
    
    YTDLP_EXIT_CODE=${PIPESTATUS[0]}
    _tee_stdout_ec=${PIPESTATUS[1]}
    set -e
    
    if [[ "$YTDLP_EXIT_CODE" -eq 0 ]]; then
        log_info "✅ SABR stream retry successful using android player client!"
        ytdlp_stdout_content=$(<"$YTDLP_STDOUT_CAPTURE_FILE")
        ytdlp_stderr_content=$(<"$YTDLP_STDERR_CAPTURE_FILE")
    else
        log_warn "Android player client retry also failed. Trying with iOS player and 'b' format as final attempt..."
        
        # Prepare final attempt with iOS client and simplified format
        declare -a ytdlp_final_args=()
        prev_arg=""
        for arg in "${ytdlp_command_args[@]}"; do
            if [[ "$arg" != "$YTDLP_FORMAT" && "$prev_arg" != "--format" && 
                  "$arg" != "$COOKIES_FILE" && "$prev_arg" != "--cookies" ]]; then
                ytdlp_final_args[${#ytdlp_final_args[@]}]="$arg"
            fi
            prev_arg="$arg"
        done
        # Use 'b' format (best) with iOS player client as final attempt
        ytdlp_final_args[${#ytdlp_final_args[@]}]="--format"
        ytdlp_final_args[${#ytdlp_final_args[@]}]="b"
        ytdlp_final_args[${#ytdlp_final_args[@]}]="--extractor-args"
        ytdlp_final_args[${#ytdlp_final_args[@]}]="youtube:player_client=ios"
        
        # Inform user about format and cookies changes
        if [[ "${COOKIES_ENABLED:-false}" == "true" && -n "$COOKIES_FILE" ]]; then
            log_info "Note: Using format 'b' with iOS player and cookies disabled for final retry attempt"
        else
            log_info "Note: Using format 'b' with iOS player for final retry attempt"
        fi
        
        log_debug "Final attempt with command: $YTDLP_EXECUTABLE ${ytdlp_final_args[*]}"
        
        set +e
        "$YTDLP_EXECUTABLE" "${ytdlp_final_args[@]}" \
            2> >(tee "$YTDLP_STDERR_CAPTURE_FILE" >&2) \
            | tee "$YTDLP_STDOUT_CAPTURE_FILE"
        
        YTDLP_EXIT_CODE=${PIPESTATUS[0]}
        _tee_stdout_ec=${PIPESTATUS[1]}
        set -e
        
        ytdlp_stdout_content=$(<"$YTDLP_STDOUT_CAPTURE_FILE")
        ytdlp_stderr_content=$(<"$YTDLP_STDERR_CAPTURE_FILE")
        
        if [[ "$YTDLP_EXIT_CODE" -eq 0 ]]; then
            log_info "✅ Final attempt with iOS player and 'b' format successful!"
        else
            log_warn "All retry attempts failed for this YouTube URL."
            
            # Provide detailed user-friendly error information for SABR issues
            if grep -q "SABR streaming" <<< "$ytdlp_stderr_content" || grep -q "Only images are available" <<< "$ytdlp_stderr_content"; then
                log_warn "=========================================================================================="
                log_warn "⚠️  This YouTube video cannot be downloaded due to a recent YouTube streaming change (SABR)"
                log_warn "   JellyMac attempted multiple methods to download this video, but all failed."
                log_warn ""
                log_warn "   Possible workarounds:"
                log_warn "   1. Try again later - YouTube sometimes rotates video delivery methods"
                log_warn "   2. Try an alternative URL for this video (e.g., mobile or YouTube Music URL)"
                log_warn "   3. Upgrade yt-dlp when a new version becomes available: 'yt-dlp -U'"
                log_warn ""
                log_warn "   This is a known limitation with YouTube's new streaming format and not a JellyMac issue."
                log_warn "   For more details see: https://github.com/yt-dlp/yt-dlp/issues/12482"
                log_warn "=========================================================================================="
                
                # Show desktop notification if enabled
                if [[ "$(uname)" == "Darwin" && "${ENABLE_DESKTOP_NOTIFICATIONS:-false}" == "true" ]]; then
                    if command -v osascript &>/dev/null; then
                        osascript -e 'display notification "Cannot download this video due to YouTube SABR streaming limitations. See terminal for details." with title "JellyMac - YouTube Download Failed"' || true
                    fi
                fi
            fi
        fi
    fi
fi

#==============================================================================
# DOWNLOAD RESULT PROCESSING AND FILE DISCOVERY
#==============================================================================
# Handle yt-dlp exit codes and attempt to find downloaded file
# Exit code 0: Successful download
# Exit code 101: Max downloads reached OR video already in archive
if [[ "$YTDLP_EXIT_CODE" -eq 0 ]] || \
   ([[ "$YTDLP_EXIT_CODE" -eq 101 ]] && (grep -q -i "max-downloads" <<< "$ytdlp_stdout_content" || grep -q -i "max-downloads" <<< "$ytdlp_stderr_content") ); then

    log_debug "yt-dlp exited with $YTDLP_EXIT_CODE. Adding 2s delay for file finalization..."
    sleep 2

    # Check if video was already processed (archive hit)
    if (grep -q -i "already been recorded in the archive" <<< "$ytdlp_stderr_content" || grep -q -i "already been recorded in the archive" <<< "$ytdlp_stdout_content"); then
        log_info "yt-dlp (exit $YTDLP_EXIT_CODE) indicated video is already in archive. Stdout: [$ytdlp_stdout_content] Stderr: [$ytdlp_stderr_content]"
        log_info "Assuming video already processed and available. Exiting successfully."
        exit 0 
    fi
    
    if [[ "$YTDLP_EXIT_CODE" -eq 101 ]]; then 
        log_info "yt-dlp (exit 101) indicated --max-downloads limit was respected. Will attempt to find downloaded file. Stdout: [$ytdlp_stdout_content] Stderr: [$ytdlp_stderr_content]"
    fi

    # Search for the newest video file in the download directory
    log_info "Attempting to find the newest video file (any common extension) in '${LOCAL_DIR_YOUTUBE}'..."
    if [[ -d "${LOCAL_DIR_YOUTUBE}" ]]; then
        set +e 
        potential_file_full_path=$(find "${LOCAL_DIR_YOUTUBE}" -maxdepth 1 -type f \( -iname "*.mkv" -o -iname "*.mp4" -o -iname "*.webm" \) -print0 2>/dev/null | xargs -0 -r ls -Ft 2>/dev/null | head -n 1 | sed 's/[*@/]$//')
        find_ls_exit_code=$? 
        set -e

        if [[ "$find_ls_exit_code" -eq 0 && -n "$potential_file_full_path" && -f "$potential_file_full_path" ]]; then
            DOWNLOADED_FILE_FULL_PATH="$potential_file_full_path"
            log_info "Found potential newest video file: '$DOWNLOADED_FILE_FULL_PATH'"
        elif [[ "$find_ls_exit_code" -ne 0 ]]; then
            log_warn "Command to find newest video file failed (exit code $find_ls_exit_code)."
        elif [[ -z "$potential_file_full_path" ]]; then
            log_warn "No common video files (.mkv, .mp4, .webm) found in '${LOCAL_DIR_YOUTUBE}' after yt-dlp run (exit code $YTDLP_EXIT_CODE)."
        else 
             log_warn "Found path '$potential_file_full_path' from find/ls, but it's not a valid file or test failed."
        fi
    else
        log_warn "LOCAL_DIR_YOUTUBE ('${LOCAL_DIR_YOUTUBE}') is not a directory."
    fi
    
    # Validate discovered file
    if [[ -n "$DOWNLOADED_FILE_FULL_PATH" && -f "$DOWNLOADED_FILE_FULL_PATH" ]]; then
         log_info "Proceeding with discovered file: '$DOWNLOADED_FILE_FULL_PATH'"
    else
        if [[ "$YTDLP_EXIT_CODE" -eq 0 ]]; then
            log_warn "Could not reliably determine downloaded file after yt-dlp exited 0. Stdout: [$ytdlp_stdout_content] Stderr: [$ytdlp_stderr_content]"
            exit 1 
        else 
            log_info "yt-dlp exited 101 (max-downloads) but no new video file was found. Assuming limit respected before download or file not a recognized video type. Stdout: [$ytdlp_stdout_content] Stderr: [$ytdlp_stderr_content]"
            exit 0 
        fi
    fi

elif [[ "$YTDLP_EXIT_CODE" -eq 101 ]]; then 
    # Handle other exit 101 cases (not max-downloads related)
    if (grep -q -i "already been recorded in the archive" <<< "$ytdlp_stderr_content" || grep -q -i "already been recorded in the archive" <<< "$ytdlp_stdout_content"); then
        log_info "yt-dlp (exit 101) indicated video is already in archive. Stdout: [$ytdlp_stdout_content] Stderr: [$ytdlp_stderr_content]"
        log_info "Assuming video already processed and available. Exiting successfully."
        exit 0
    else
        log_error_event "$LOG_PREFIX_SCRIPT" "yt-dlp exited 101 (unhandled reason). Stdout: [$ytdlp_stdout_content] Stderr: [$ytdlp_stderr_content]"
        exit 1
    fi
else 
    # Handle all other error cases
    log_error_event "$LOG_PREFIX_SCRIPT" "yt-dlp failed. Exit: $YTDLP_EXIT_CODE. Stdout: [$ytdlp_stdout_content] Stderr: [$ytdlp_stderr_content]"
    # Clean up any partial downloads (.part files)
    find "$LOCAL_DIR_YOUTUBE" -maxdepth 1 -name "*.part" -exec rm -f {} \; -print0 2>/dev/null | xargs -0 -r -I {} log_debug "Removed partial: {}"
    exit 1
fi

# Final validation of discovered file
if [[ -z "$DOWNLOADED_FILE_FULL_PATH" || ! -f "$DOWNLOADED_FILE_FULL_PATH" ]]; then
    log_error_event "$LOG_PREFIX_SCRIPT" "FATAL LOGIC ERROR: No valid downloaded file path. Path: '${DOWNLOADED_FILE_FULL_PATH:-EMPTY}'. Review logs."
    exit 1
fi

#==============================================================================
# FILENAME NORMALIZATION AND CORRECTION
#==============================================================================
# Convert underscores to spaces and fix common English contractions
# for better readability in media libraries
original_downloaded_filename=$(basename "$DOWNLOADED_FILE_FULL_PATH")
download_dir=$(dirname "$DOWNLOADED_FILE_FULL_PATH") 
file_ext="${original_downloaded_filename##*.}"
filename_no_ext="${original_downloaded_filename%.*}"

# Step 1: Convert underscores to spaces for readability
filename_with_spaces_initial=$(echo "$filename_no_ext" | tr '_' ' ')

# Step 2: Fix possessive 's patterns (e.g., "user s" -> "user's")
filename_corrected_possessive_s=$(echo "$filename_with_spaces_initial" | sed -e 's/ s /s /g' -e 's/ s$/s/')

# Step 3: Fix common English contractions for natural language appearance
filename_with_fixed_contractions=$(echo "$filename_corrected_possessive_s" | 
    sed -E "
        # Fix 're contractions (they're, we're, you're)
        s/([[:alpha:]]+) re /\1're /g;
        # Fix 'll contractions (we'll, they'll, he'll)
        s/([[:alpha:]]+) ll /\1'll /g;
        # Fix 've contractions (could've, would've, they've)
        s/([[:alpha:]]+) ve /\1've /g;
        # Fix 'm contractions (I'm)
        s/([[:alpha:]]+) m /\1'm /g;
        # Fix 'd contractions (they'd, we'd, etc.)
        s/([[:alpha:]]+) d /\1'd /g;
        # Fix 't contraction (isn't, wasn't, don't, won't, can't)
        s/([[:alpha:]]+) t /\1't /g;
    ")

# Apply the corrected filename
final_local_filename_no_ext="$filename_with_fixed_contractions"
final_local_filename="${final_local_filename_no_ext}.${file_ext}"
final_local_full_path="${download_dir}/${final_local_filename}" 

# Rename file if corrections were made
if [[ "$DOWNLOADED_FILE_FULL_PATH" != "$final_local_full_path" ]]; then
    log_info "Renaming downloaded file from '$original_downloaded_filename' to '$final_local_filename'..."
    if mv "$DOWNLOADED_FILE_FULL_PATH" "$final_local_full_path"; then
        log_info "Successfully renamed to '$final_local_filename'"
        DOWNLOADED_FILE_FULL_PATH="$final_local_full_path" 
    else
        log_error_event "$LOG_PREFIX_SCRIPT" "Failed to rename '$original_downloaded_filename' to '$final_local_filename'. Proceeding with original name."
        final_local_filename="$original_downloaded_filename" 
    fi
else
    log_debug "Filename '$original_downloaded_filename' does not require renaming based on underscore/possessive/contraction rules."
    final_local_filename="$original_downloaded_filename" 
fi

log_info "✅ Confirmed media file for processing: '$DOWNLOADED_FILE_FULL_PATH' (Filename: '$final_local_filename')"

#==============================================================================
# FINAL TRANSFER TO DESTINATION
#==============================================================================
final_destination_path="${DEST_DIR_YOUTUBE}/${final_local_filename}" 

# Calculate file size for disk space check
file_size_bytes=$(stat -f "%z" "$DOWNLOADED_FILE_FULL_PATH" 2>/dev/null || echo "0") 
file_size_kb="1" 
if [[ "$file_size_bytes" =~ ^[0-9]+$ && "$file_size_bytes" -gt 0 ]]; then 
    file_size_kb=$(( (file_size_bytes + 1023) / 1024 )); 
fi

# Verify sufficient disk space in destination
if ! check_available_disk_space "${DEST_DIR_YOUTUBE}" "$file_size_kb"; then
    log_error_event "$LOG_PREFIX_SCRIPT" "Insufficient disk space in '$DEST_DIR_YOUTUBE' for '$final_local_filename'."
    if [[ -f "$DOWNLOADED_FILE_FULL_PATH" ]]; then 
        quarantine_item "$DOWNLOADED_FILE_FULL_PATH" "No remote disk space for YouTube video" || log_warn "Quarantine failed for '$DOWNLOADED_FILE_FULL_PATH'"; 
    fi
    exit 1
fi

# Transfer file to final destination using rsync
log_info "Moving '$final_local_filename' to '$DEST_DIR_YOUTUBE'..."
if ! rsync -av --progress --remove-source-files --timeout="$RSYNC_TIMEOUT" "$DOWNLOADED_FILE_FULL_PATH" "$final_destination_path"; then
    log_error_event "$LOG_PREFIX_SCRIPT" "Failed rsync: '$DOWNLOADED_FILE_FULL_PATH' to '$final_destination_path'."
    if [[ -f "$DOWNLOADED_FILE_FULL_PATH" ]]; then 
        quarantine_item "$DOWNLOADED_FILE_FULL_PATH" "rsync_failed_youtube" || log_warn "Quarantine failed for '$DOWNLOADED_FILE_FULL_PATH'"; 
    fi
    exit 1
fi
log_info "↪️ Successfully moved to: $final_destination_path"

# Record successful transfer in history
record_transfer_to_history "YouTube: ${YOUTUBE_URL:0:70}... -> ${final_destination_path}" || log_warn "History record failed."

#==============================================================================
# POST-PROCESSING AND NOTIFICATIONS
#==============================================================================
# Trigger Jellyfin library scan if configured
if [[ "${ENABLE_JELLYFIN_SCAN_YOUTUBE:-false}" == "true" ]]; then
    log_info "Triggering Jellyfin scan for YouTube..."
    trigger_jellyfin_library_scan "YouTube" || log_warn "Jellyfin scan for YouTube may have failed. Check Jellyfin logs."
fi

# macOS-specific notifications and sound alerts
if [[ "$(uname)" == "Darwin" ]]; then
    notification_title_safe=$(echo "$final_local_filename" | head -c 200) 
    
    # Desktop notification if enabled
    if [[ "${ENABLE_DESKTOP_NOTIFICATIONS:-false}" == "true" ]]; then
        osascript_cmd_str="display notification \"Download complete: ${notification_title_safe}\" with title \"JellyMac - YouTube\""
        if command -v osascript &>/dev/null; then 
            osascript -e "$osascript_cmd_str" || log_warn "osascript desktop notification failed."; 
        else 
            log_warn "'osascript' not found. Cannot send desktop notification."; 
        fi
    fi
    
    # Sound notification for successful completion
    play_sound_notification "task_success" "$SCRIPT_NAME"
fi

log_info "🎉 YouTube processing for '$YOUTUBE_URL' completed successfully. Final file: $final_destination_path"
exit 0