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
_SCRIPT_TEMP_FILES_TO_CLEAN=()
_cleanup_script_temp_files() {
    # shellcheck disable=SC2128 # We want to check array length
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
    _SCRIPT_TEMP_FILES_TO_CLEAN=()
}
trap _cleanup_script_temp_files EXIT SIGINT SIGTERM

# --- Source Libraries ---
# shellcheck source=../lib/logging_utils.sh
source "${LIB_DIR}/logging_utils.sh"
# shellcheck source=../lib/jellymac_config.sh 
# Make sure this matches your actual config file name (e.g., combined.conf.sh or jellymac_config.sh)
source "${LIB_DIR}/jellymac_config.sh" 
# shellcheck source=../lib/common_utils.sh
source "${LIB_DIR}/common_utils.sh" 
# shellcheck source=../lib/jellyfin_utils.sh
source "${LIB_DIR}/jellyfin_utils.sh" 

# --- Log Level & Prefix Initialization ---
LOG_PREFIX_SCRIPT="[YT_LINK_HANDLER]"
log_info() { _log_event_if_level_met "$LOG_LEVEL_INFO" "$LOG_PREFIX_SCRIPT" "$*"; }
log_warn() { _log_event_if_level_met "$LOG_LEVEL_WARN" "⚠️ WARN: $LOG_PREFIX_SCRIPT" "$*" >&2; }
log_debug() { _log_event_if_level_met "$LOG_LEVEL_DEBUG" "🐛 DEBUG: $LOG_PREFIX_SCRIPT" "$*"; }

# --- Argument Validation ---
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

# --- Pre-flight Checks ---
YTDLP_EXECUTABLE=$(find_executable "yt-dlp" "${YTDLP_PATH:-}")
: "${LOCAL_DIR_YOUTUBE:?YT_HANDLER: LOCAL_DIR_YOUTUBE not set.}"
: "${DEST_DIR_YOUTUBE:?YT_HANDLER: DEST_DIR_YOUTUBE not set.}"
: "${YTDLP_FORMAT:?YT_HANDLER: YTDLP_FORMAT for YouTube not set in config.}"
: "${RSYNC_TIMEOUT:=300}" 

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

# --- Download Video ---
log_info "Starting download for: ${YOUTUBE_URL:0:70}..."
YTDLP_OUTPUT_TEMPLATE="${LOCAL_DIR_YOUTUBE}/%(title).200B.%(ext)s"

declare -a ytdlp_command_args=()
ytdlp_command_args+=("--ignore-errors") 
ytdlp_command_args+=("--format" "$YTDLP_FORMAT")
ytdlp_command_args+=("--output" "$YTDLP_OUTPUT_TEMPLATE")

progress_option_set=false
if [[ ${#YTDLP_OPTS[@]} -gt 0 ]]; then
    for opt_check in "${YTDLP_OPTS[@]}"; do
        if [[ "$opt_check" == "--progress" || "$opt_check" == "--no-progress" ]]; then
            progress_option_set=true
            break
        fi
    done
fi
if [[ "$progress_option_set" == "false" ]]; then
    ytdlp_command_args+=("--progress") 
fi

if [[ ${#YTDLP_OPTS[@]} -gt 0 ]]; then
    ytdlp_command_args+=("${YTDLP_OPTS[@]}")
fi

if [[ -n "$DOWNLOAD_ARCHIVE_YOUTUBE" ]]; then
    archive_dir=$(dirname "$DOWNLOAD_ARCHIVE_YOUTUBE")
    if [[ ! -d "$archive_dir" ]]; then
        log_info "Creating archive directory '$archive_dir'..."
        if mkdir -p "$archive_dir"; then
            ytdlp_command_args+=("--download-archive" "$DOWNLOAD_ARCHIVE_YOUTUBE")
            log_info "Download archive enabled: $DOWNLOAD_ARCHIVE_YOUTUBE"
        else
             log_warn "Failed to create archive dir '$archive_dir'. Archive will NOT be used for this run."
        fi
    else
        ytdlp_command_args+=("--download-archive" "$DOWNLOAD_ARCHIVE_YOUTUBE")
        log_info "Download archive enabled: $DOWNLOAD_ARCHIVE_YOUTUBE"
    fi
else
    log_info "No DOWNLOAD_ARCHIVE_YOUTUBE configured. Archive will not be used."
fi

if [[ -n "$COOKIES_FILE" ]]; then
    if [[ -f "$COOKIES_FILE" ]]; then 
        ytdlp_command_args+=("--cookies" "$COOKIES_FILE"); 
    else 
        log_warn "Cookies file '$COOKIES_FILE' not found. Proceeding without cookies."; 
    fi
fi
ytdlp_command_args+=("$YOUTUBE_URL") 

# Capture stdout and stderr to files, while also teeing them to the script's stdout/stderr
YTDLP_STDOUT_CAPTURE_FILE=$(mktemp "${SCRIPT_DIR}/.ytdlp_stdout.XXXXXX")
YTDLP_STDERR_CAPTURE_FILE=$(mktemp "${SCRIPT_DIR}/.ytdlp_stderr.XXXXXX")
_SCRIPT_TEMP_FILES_TO_CLEAN+=("$YTDLP_STDOUT_CAPTURE_FILE" "$YTDLP_STDERR_CAPTURE_FILE")

log_debug "Executing command: $YTDLP_EXECUTABLE ${ytdlp_command_args[*]}"

# *** MODIFIED yt-dlp EXECUTION BLOCK START ***
set +e 
# Execute yt-dlp:
# - Its stderr is redirected to a process substitution that tees to STDERR_CAPTURE_FILE and the script's stderr.
# - Its stdout is piped to tee, which writes to STDOUT_CAPTURE_FILE and the script's stdout (for live progress).
"$YTDLP_EXECUTABLE" "${ytdlp_command_args[@]}" \
    2> >(tee "$YTDLP_STDERR_CAPTURE_FILE" >&2) \
    | tee "$YTDLP_STDOUT_CAPTURE_FILE"

# Get exit codes from the pipeline
# PIPESTATUS[0] is for yt-dlp (the first command in the pipe)
# PIPESTATUS[1] is for tee (the second command in the pipe for stdout)
YTDLP_EXIT_CODE=${PIPESTATUS[0]} 
_tee_stdout_ec=${PIPESTATUS[1]}
set -e 

# Optional: Check if tee for stdout itself had an issue
if [[ "$_tee_stdout_ec" -ne 0 ]]; then
    log_warn "The 'tee' command for yt-dlp stdout exited with status $_tee_stdout_ec. Stdout capture might be affected, but yt-dlp progress should have been attempted."
fi
# *** MODIFIED yt-dlp EXECUTION BLOCK END ***

ytdlp_stdout_content=$(<"$YTDLP_STDOUT_CAPTURE_FILE")
ytdlp_stderr_content=$(<"$YTDLP_STDERR_CAPTURE_FILE")

DOWNLOADED_FILE_FULL_PATH="" 

# Handle yt-dlp exit codes and attempt to find downloaded file
# Check both stdout and stderr for "max-downloads"
if [[ "$YTDLP_EXIT_CODE" -eq 0 ]] || \
   ([[ "$YTDLP_EXIT_CODE" -eq 101 ]] && (grep -q -i "max-downloads" <<< "$ytdlp_stdout_content" || grep -q -i "max-downloads" <<< "$ytdlp_stderr_content") ); then

    log_debug "yt-dlp exited with $YTDLP_EXIT_CODE. Adding 2s delay for file finalization..."
    sleep 2

    # Check if video was already in archive (typically on stderr, but check stdout just in case for robustness)
    if (grep -q -i "already been recorded in the archive" <<< "$ytdlp_stderr_content" || grep -q -i "already been recorded in the archive" <<< "$ytdlp_stdout_content"); then
        log_info "yt-dlp (exit $YTDLP_EXIT_CODE) indicated video is already in archive. Stdout: [$ytdlp_stdout_content] Stderr: [$ytdlp_stderr_content]"
        log_info "Assuming video already processed and available. Exiting successfully."
        exit 0 
    fi
    
    if [[ "$YTDLP_EXIT_CODE" -eq 101 ]]; then 
        log_info "yt-dlp (exit 101) indicated --max-downloads limit was respected. Will attempt to find downloaded file. Stdout: [$ytdlp_stdout_content] Stderr: [$ytdlp_stderr_content]"
    fi

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
    # This handles other exit 101 cases if not "max-downloads" (e.g., pure archive hit)
    if (grep -q -i "already been recorded in the archive" <<< "$ytdlp_stderr_content" || grep -q -i "already been recorded in the archive" <<< "$ytdlp_stdout_content"); then
        log_info "yt-dlp (exit 101) indicated video is already in archive. Stdout: [$ytdlp_stdout_content] Stderr: [$ytdlp_stderr_content]"
        log_info "Assuming video already processed and available. Exiting successfully."
        exit 0
    else
        log_error_event "$LOG_PREFIX_SCRIPT" "yt-dlp exited 101 (unhandled reason). Stdout: [$ytdlp_stdout_content] Stderr: [$ytdlp_stderr_content]"
        exit 1
    fi
else 
    log_error_event "$LOG_PREFIX_SCRIPT" "yt-dlp failed. Exit: $YTDLP_EXIT_CODE. Stdout: [$ytdlp_stdout_content] Stderr: [$ytdlp_stderr_content]"
    find "$LOCAL_DIR_YOUTUBE" -maxdepth 1 -name "*.part" -exec rm -f {} \; -print0 2>/dev/null | xargs -0 -r -I {} log_debug "Removed partial: {}"
    exit 1
fi

if [[ -z "$DOWNLOADED_FILE_FULL_PATH" || ! -f "$DOWNLOADED_FILE_FULL_PATH" ]]; then
    log_error_event "$LOG_PREFIX_SCRIPT" "FATAL LOGIC ERROR: No valid downloaded file path. Path: '${DOWNLOADED_FILE_FULL_PATH:-EMPTY}'. Review logs."
    exit 1
fi

# --- RENAME FILE TO USE SPACES AND CORRECT ' s ' PATTERN ---
original_downloaded_filename=$(basename "$DOWNLOADED_FILE_FULL_PATH")
download_dir=$(dirname "$DOWNLOADED_FILE_FULL_PATH") 
file_ext="${original_downloaded_filename##*.}"
filename_no_ext="${original_downloaded_filename%.*}"

filename_with_spaces_initial=$(echo "$filename_no_ext" | tr '_' ' ')
filename_corrected_possessive_s=$(echo "$filename_with_spaces_initial" | sed -e 's/ s /s /g' -e 's/ s$/s/')

final_local_filename_no_ext="$filename_corrected_possessive_s"
final_local_filename="${final_local_filename_no_ext}.${file_ext}"
final_local_full_path="${download_dir}/${final_local_filename}" 

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
    log_debug "Filename '$original_downloaded_filename' does not require renaming based on underscore/possessive rules."
    final_local_filename="$original_downloaded_filename" 
fi
# --- END RENAME ---

log_info "✅ Confirmed media file for processing: '$DOWNLOADED_FILE_FULL_PATH' (Filename: '$final_local_filename')"

# --- Move to Final Destination ---
final_destination_path="${DEST_DIR_YOUTUBE}/${final_local_filename}" 

file_size_bytes=$(stat -f "%z" "$DOWNLOADED_FILE_FULL_PATH" 2>/dev/null || echo "0") 
file_size_kb="1" 
if [[ "$file_size_bytes" =~ ^[0-9]+$ && "$file_size_bytes" -gt 0 ]]; then 
    file_size_kb=$(( (file_size_bytes + 1023) / 1024 )); 
fi

if ! check_available_disk_space "${DEST_DIR_YOUTUBE}" "$file_size_kb"; then
    log_error_event "$LOG_PREFIX_SCRIPT" "Insufficient disk space in '$DEST_DIR_YOUTUBE' for '$final_local_filename'."
    if [[ -f "$DOWNLOADED_FILE_FULL_PATH" ]]; then 
        quarantine_item "$DOWNLOADED_FILE_FULL_PATH" "No remote disk space for YouTube video" || log_warn "Quarantine failed for '$DOWNLOADED_FILE_FULL_PATH'"; 
    fi
    exit 1
fi

log_info "Moving '$final_local_filename' to '$DEST_DIR_YOUTUBE'..."
if ! rsync -av --progress --remove-source-files --timeout="$RSYNC_TIMEOUT" "$DOWNLOADED_FILE_FULL_PATH" "$final_destination_path"; then
    log_error_event "$LOG_PREFIX_SCRIPT" "Failed rsync: '$DOWNLOADED_FILE_FULL_PATH' to '$final_destination_path'."
    if [[ -f "$DOWNLOADED_FILE_FULL_PATH" ]]; then 
        quarantine_item "$DOWNLOADED_FILE_FULL_PATH" "rsync_failed_youtube" || log_warn "Quarantine failed for '$DOWNLOADED_FILE_FULL_PATH'"; 
    fi
    exit 1
fi
log_info "↪️ Successfully moved to: $final_destination_path"
record_transfer_to_history "YouTube: ${YOUTUBE_URL:0:70}... -> ${final_destination_path}" || log_warn "History record failed."

# --- Post-Move Actions ---
if [[ "${ENABLE_JELLYFIN_SCAN_YOUTUBE:-false}" == "true" ]]; then
    log_info "Triggering Jellyfin scan for YouTube..."
    trigger_jellyfin_library_scan "YouTube" || log_warn "Jellyfin scan for YouTube may have failed. Check Jellyfin logs."
fi

if [[ "$(uname)" == "Darwin" ]]; then
    notification_title_safe=$(echo "$final_local_filename" | head -c 200) 
    if [[ "${ENABLE_DESKTOP_NOTIFICATIONS:-false}" == "true" ]]; then
        osascript_cmd_str="display notification \"Download complete: ${notification_title_safe}\" with title \"JellyMac - YouTube\""
        if command -v osascript &>/dev/null; then 
            osascript -e "$osascript_cmd_str" || log_warn "osascript desktop notification failed."; 
        else 
            log_warn "'osascript' not found. Cannot send desktop notification."; 
        fi
    fi
    play_sound_notification "task_success" "$SCRIPT_NAME"
fi

log_info "🎉 YouTube processing for '$YOUTUBE_URL' completed successfully. Final file: $final_destination_path"
exit 0
