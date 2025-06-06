#!/bin/bash

# JellyMac/bin/process_media_item.sh
# Main media processing script. Handles individual media files and folders
# (e.g., completed torrents or manually dropped files), categorizing
# and organizing them into final Movie or Show libraries.
# Adapted for simplified categorization (Movies default, identify Shows).

# --- Strict Mode & Start Time ---
set -eo pipefail
PROCESS_START_TIME=$(date +%s)

# --- Script Directories and Paths ---
SCRIPT_DIR_PROCESSOR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "${SCRIPT_DIR_PROCESSOR}/../lib" && pwd)"

# --- Source Libraries ---
# shellcheck source=../lib/logging_utils.sh
source "${LIB_DIR}/logging_utils.sh"
# shellcheck source=../lib/jellymac_config.sh
source "${LIB_DIR}/jellymac_config.sh"
# shellcheck source=../lib/media_utils.sh
source "${LIB_DIR}/media_utils.sh"
# shellcheck source=../lib/jellyfin_utils.sh
source "${LIB_DIR}/jellyfin_utils.sh"
# shellcheck source=../lib/common_utils.sh
source "${LIB_DIR}/common_utils.sh" # Provides find_executable, quarantine_item, play_sound_notification etc.

# --- Log Level & Prefix Initialization (after config is sourced) ---
# Set script log level from global configuration
# shellcheck disable=SC2034  # Variable used by logging functions in sourced files
SCRIPT_CURRENT_LOG_LEVEL=${JELLYMAC_LOG_LEVEL:-$LOG_LEVEL_INFO}

# === Temporary File Cleanup Trap ===
_PROCESS_MEDIA_ITEM_TEMP_FILES_TO_CLEAN=()
_cleanup_process_media_item_temp_files() {
    # shellcheck disable=SC2128 # We want to check array length
    if [[ ${#_PROCESS_MEDIA_ITEM_TEMP_FILES_TO_CLEAN[@]} -gt 0 ]]; then
        log_debug_event "Processing" "EXIT trap: Cleaning up temporary files (${#_PROCESS_MEDIA_ITEM_TEMP_FILES_TO_CLEAN[@]} items)..."
        local temp_file_path_to_clean # Correctly local
        for temp_file_path_to_clean in "${_PROCESS_MEDIA_ITEM_TEMP_FILES_TO_CLEAN[@]}"; do
            if [[ -n "$temp_file_path_to_clean" && -e "$temp_file_path_to_clean" ]]; then
                rm -rf "$temp_file_path_to_clean"
                log_debug_event "Processing" "EXIT trap: Removed '$temp_file_path_to_clean'"
            fi
        done
    fi
    _PROCESS_MEDIA_ITEM_TEMP_FILES_TO_CLEAN=()
     # CRITICAL: Always call library cleanup if common_utils is sourced
    if command -v _cleanup_common_utils_temp_files >/dev/null 2>&1; then
        _cleanup_common_utils_temp_files
    fi
}
trap _cleanup_process_media_item_temp_files EXIT SIGINT SIGTERM

# --- Global Variables ---
# PROCESSOR_EXIT_CODE will be used to determine the final outcome.
# 0: Success
# 1: Error during processing (item not moved or quarantined, may still be in source)
# 2: Item was successfully quarantined (considered a "successful" handling of a problematic item)
PROCESSOR_EXIT_CODE=0

# --- Argument Parsing ---
if [[ $# -lt 2 ]] || [[ $# -gt 3 ]]; then
    log_error_event "Processing" "Usage: $0 <item_type> <item_path> [item_category_hint]"
    exit 1
fi

MAIN_ITEM_TYPE="$1"
MAIN_ITEM_PATH="$2"
MAIN_ITEM_CATEGORY_HINT="${3:-}" # Hint can be "Movies" or "Shows"

log_user_start "Processing" "🚀 Processing: $(basename "$MAIN_ITEM_PATH")"

if [[ ! -e "$MAIN_ITEM_PATH" ]]; then
    log_error_event "Processing" "Item path '$MAIN_ITEM_PATH' does not exist. Cannot process."
    exit 1
fi

# --- Essential Config Variable Checks ---
: "${DEST_DIR_MOVIES:?PROCESSOR: DEST_DIR_MOVIES not set in config.}"
: "${DEST_DIR_SHOWS:?PROCESSOR: DEST_DIR_SHOWS not set in config.}"
: "${ERROR_DIR:?PROCESSOR: ERROR_DIR (for quarantine_item) not set in config.}"
: "${HISTORY_FILE:?PROCESSOR: HISTORY_FILE not set in config.}"
: "${RSYNC_TIMEOUT:=300}" # Default to 300s if not set
if [[ ${#MAIN_MEDIA_EXTENSIONS[@]} -eq 0 ]]; then
    log_error_event "Processing" "MAIN_MEDIA_EXTENSIONS array is not defined or empty in config."
    exit 1
fi

# --- Helper Functions ---
#==============================================================================
# Function: _processor_final_drop_folder_cleanup
# Description: Attempts to remove the original MAIN_ITEM_PATH from the DROP_FOLDER
#              if it was a directory and processing was successful. This is the
#              final cleanup step for the original source item.
# Parameters: None (relies on global MAIN_ITEM_PATH, DROP_FOLDER)
# Returns: 0 (this function does not alter PROCESSOR_EXIT_CODE directly)
#==============================================================================
_processor_final_drop_folder_cleanup() {
    log_debug_event "Processing" "Initiating final cleanup check for original item: '$MAIN_ITEM_PATH'"

    # This function should only be called if the main processing was successful.
    # We check if MAIN_ITEM_PATH still exists and if it's a directory.
    if [[ -d "$MAIN_ITEM_PATH" ]]; then
        # Safety check: Ensure MAIN_ITEM_PATH is not the DROP_FOLDER itself.
        # Resolve paths to their absolute, canonical form to prevent accidental deletion of DROP_FOLDER
        # if MAIN_ITEM_PATH was, for example, "." within DROP_FOLDER.
        local main_item_realpath resolved_drop_folder_path
        
        if command -v realpath &>/dev/null; then
            main_item_realpath=$(realpath "$MAIN_ITEM_PATH" 2>/dev/null)
            resolved_drop_folder_path=$(realpath "$DROP_FOLDER" 2>/dev/null)
        else
            # Fallback if realpath is not available (less robust for symlinks/complex paths)
            log_warn_event "Processing" "realpath command not found. Using basic path comparison for safety check."
            main_item_realpath="$MAIN_ITEM_PATH" # Simplified
            resolved_drop_folder_path="$DROP_FOLDER" # Simplified
        fi

        # Additional check for robustness if realpath failed to resolve
        [[ -z "$main_item_realpath" ]] && main_item_realpath="$MAIN_ITEM_PATH"
        [[ -z "$resolved_drop_folder_path" ]] && resolved_drop_folder_path="$DROP_FOLDER"

        if [[ "$main_item_realpath" == "$resolved_drop_folder_path" ]]; then
            log_warn_event "Processing" "SAFETY PREVENTED: Final cleanup target '$MAIN_ITEM_PATH' resolves to DROP_FOLDER itself. Skipping rm -rf."
            return 0
        fi

        log_info_event "Processing" "🗑️ Performing final cleanup of original source directory from DROP_FOLDER: '$MAIN_ITEM_PATH'"
        if rm -rf "$MAIN_ITEM_PATH"; then
            log_info_event "Processing" "✅ Successfully deleted original source directory (and its contents) from DROP_FOLDER: '$MAIN_ITEM_PATH'"
            # Record this final deletion in history
            record_transfer_to_history "DELETED (final cleanup): $(basename "$MAIN_ITEM_PATH") from DROP_FOLDER" # In common_utils.sh
        else
            local rm_exit_status=$?
            log_warn_event "Processing" "⚠️ Failed to delete original source directory '$MAIN_ITEM_PATH' during final cleanup (rm -rf exit code: $rm_exit_status). Manual check may be needed."
            # This is a warning; the main media processing was successful.
        fi
    elif [[ -f "$MAIN_ITEM_PATH" ]]; then
        # If it's a file and still exists, rsync --remove-source-files should have handled it.
        # This implies it wasn't the main media or an associated file moved by rsync.
        log_debug_event "Processing" "Original item '$MAIN_ITEM_PATH' is a file and still exists. The rsync --remove-source-files in _processor_move_media_and_associated_files should have handled it if it was part of the processed media. No action by this specific cleanup function."
    else
        log_debug_event "Processing" "Original item '$MAIN_ITEM_PATH' no longer exists. No final cleanup needed by this function."
    fi
    return 0
}

# Creates destination directory if it doesn't exist. Exits on failure.
_processor_create_safe_destination_path() {
    local dest_path="$1"
    local dest_dir
    dest_dir=$(dirname "$dest_path")
    if [[ ! -d "$dest_dir" ]]; then
        log_debug_event "Processing" "Creating destination directory: $dest_dir"
        if ! mkdir -p "$dest_dir"; then
            log_error_event "Processing" "Failed to create destination directory: $dest_dir. Check permissions."
            exit 1
        fi
    elif [[ ! -w "$dest_dir" ]]; then # Check if existing dir is writable
        log_error_event "Processing" "Destination directory '$dest_dir' is not writable."
        exit 1
    fi
}

# Cleans up empty subdirectories within a given base directory after processing.
_processor_cleanup_empty_source_subdirectories() {
    local base_dir_to_check="$1"
    log_debug_event "Processing" "Checking for empty subdirectories to clean up within '$base_dir_to_check'..."

    if [[ ! -d "$base_dir_to_check" ]]; then
        log_debug_event "Processing" "Directory '$base_dir_to_check' does not exist or is not accessible for cleanup."
        return 0
    fi

    local found_empty=true
    while [[ "$found_empty" == "true" ]]; do
        found_empty=false
        local empty_dir
        # Find one empty directory. Using head -n 1 to process one at a time.
        empty_dir=$(find "$base_dir_to_check" -mindepth 1 -type d -empty -print 2>/dev/null | head -n 1)

        if [[ -n "$empty_dir" && -d "$empty_dir" ]]; then
            found_empty=true
            log_info_event "Processing" "Removing empty subdirectory: $empty_dir"

            if ! rmdir "$empty_dir" 2>/dev/null; then
                log_warn_event "Processing" "Could not remove empty subdirectory '$empty_dir'. It might have been removed by another process, become non-empty, or have permission issues."
                break 
            fi
        fi
    done
}

# Core function to move media and associated files
# Arguments:
#   $1: source_item_path_arg (file or directory)
#   $2: final_dest_template (e.g., /path/to/Movies/MovieTitle/MovieTitle - extension added later)
#   $3: determined_category ("Movies" or "Shows")
#   $4: quarantine_on_overall_failure_str ("true" or "false") - whether to quarantine original item if this function fails
# Returns: 0 on success, 1 on failure. Sets PROCESSOR_EXIT_CODE accordingly.
_processor_move_media_and_associated_files() {
    local source_item_path_arg="$1"
    local final_dest_template="$2"
    local determined_category="$3"
    local quarantine_on_overall_failure_str="${4:-true}"

    local main_media_file_source_path=""
    local source_content_base_path=""    # Directory where source files are located
    local item_size_bytes=""
    local i

    if [[ -f "$source_item_path_arg" ]]; then
        main_media_file_source_path="$source_item_path_arg"
        source_content_base_path=$(dirname "$source_item_path_arg")
        local item_ext_check
        item_ext_check="$(get_file_extension "$source_item_path_arg")" # From common_utils.sh
        local is_main_media="false"
        local main_ext
        for main_ext in "${MAIN_MEDIA_EXTENSIONS[@]}"; do
            if [[ "$item_ext_check" == "$main_ext" ]]; then is_main_media="true"; break; fi;
        done
        if [[ "$is_main_media" != "true" ]]; then
            log_warn_event "Processing" "Single file input '$source_item_path_arg' is not a recognized main media type (ext: '$item_ext_check')."
            if [[ "$quarantine_on_overall_failure_str" == "true" ]]; then
                if quarantine_item "$source_item_path_arg" "Not main media type"; then PROCESSOR_EXIT_CODE=2; else PROCESSOR_EXIT_CODE=1; fi
            else
                PROCESSOR_EXIT_CODE=1
            fi
            return 1
        fi
        item_size_bytes=$(stat -f "%z" "$main_media_file_source_path" 2>/dev/null) # macOS stat

    elif [[ -d "$source_item_path_arg" ]]; then
        source_content_base_path="$source_item_path_arg"
        log_debug_event "Processing" "Source is a directory. Identifying main media file in '$source_content_base_path'..."

        local -a find_main_patterns_arr=()
        i=0
        for ext_pattern_loop in "${MAIN_MEDIA_EXTENSIONS[@]}"; do # Renamed 'ext' to 'ext_pattern_loop' to avoid conflict
            if [[ $i -gt 0 ]]; then 
                find_main_patterns_arr[${#find_main_patterns_arr[@]}]="-o"
            fi
            find_main_patterns_arr[${#find_main_patterns_arr[@]}]="-iname"
            find_main_patterns_arr[${#find_main_patterns_arr[@]}]="*${ext_pattern_loop}"
            ((i++))
        done

        local find_stdout_tmp xargs_stat_stdout_tmp
        find_stdout_tmp=$(mktemp "${STATE_DIR}/.media_find_proc_stdout.XXXXXX")
        _PROCESS_MEDIA_ITEM_TEMP_FILES_TO_CLEAN[${#_PROCESS_MEDIA_ITEM_TEMP_FILES_TO_CLEAN[@]}]="$find_stdout_tmp"
        xargs_stat_stdout_tmp=$(mktemp "${STATE_DIR}/.media_xargs_stat_proc.XXXXXX")
        _PROCESS_MEDIA_ITEM_TEMP_FILES_TO_CLEAN[${#_PROCESS_MEDIA_ITEM_TEMP_FILES_TO_CLEAN[@]}]="$xargs_stat_stdout_tmp"

        find "$source_content_base_path" -maxdepth 1 -type f \( "${find_main_patterns_arr[@]}" \) -print0 2>/dev/null > "$find_stdout_tmp"

        if [[ ! -s "$find_stdout_tmp" ]]; then 
            log_warn_event "Processing" "No media files matching MAIN_MEDIA_EXTENSIONS found directly in '$source_content_base_path'. Checking subdirectories (depth 1)..."
            # If no files directly in the folder, check one level deeper (common for torrents with a single subfolder)
            # This find is more complex to get the largest file from any immediate subfolder.
            # We'll find all media files, stat them, sort by size, and pick the largest.
            find "$source_content_base_path" -mindepth 1 -maxdepth 2 -type f \( "${find_main_patterns_arr[@]}" \) -print0 2>/dev/null > "$find_stdout_tmp"
            if [[ ! -s "$find_stdout_tmp" ]]; then
                 log_warn_event "Processing" "No media files matching MAIN_MEDIA_EXTENSIONS found in '$source_content_base_path' or its immediate subdirectories."
                 if [[ "$quarantine_on_overall_failure_str" == "true" ]]; then
                    if quarantine_item "$source_item_path_arg" "No media files in folder/subfolder"; then PROCESSOR_EXIT_CODE=2; else PROCESSOR_EXIT_CODE=1; fi
                else
                    PROCESSOR_EXIT_CODE=1
                fi
                return 1
            fi
        fi
        
        xargs -0 -I{} stat -f "%z %N" "{}" < "$find_stdout_tmp" 2>/dev/null > "$xargs_stat_stdout_tmp"
        
        if [[ ! -s "$xargs_stat_stdout_tmp" ]]; then
            log_warn_event "Processing" "stat command (via xargs) produced no output for files in '$source_content_base_path' (or subdirs). Possible permission issue or files vanished."
            if [[ "$quarantine_on_overall_failure_str" == "true" ]]; then
                if quarantine_item "$source_item_path_arg" "stat failed for media files"; then PROCESSOR_EXIT_CODE=2; else PROCESSOR_EXIT_CODE=1; fi
            else
                PROCESSOR_EXIT_CODE=1
            fi
            return 1
        fi
        
        local sorted_stat_line temp_size temp_path 
        sorted_stat_line=$(sort -rnk1,1 "$xargs_stat_stdout_tmp" | head -n1) 
        
        if [[ -z "$sorted_stat_line" ]]; then
            log_warn_event "Processing" "Could not determine largest file in '$source_content_base_path' (sort/head failed or no valid stat output)."
            if [[ "$quarantine_on_overall_failure_str" == "true" ]]; then
                if quarantine_item "$source_item_path_arg" "Largest file identification failed"; then PROCESSOR_EXIT_CODE=2; else PROCESSOR_EXIT_CODE=1; fi
            else
                PROCESSOR_EXIT_CODE=1
            fi
            return 1
        fi
        
        temp_size=$(echo "$sorted_stat_line" | awk '{print $1}')
        temp_path=$(echo "$sorted_stat_line" | sed -E 's/^[0-9]+[[:space:]]+//')

        if ! [[ "$temp_size" =~ ^[0-9]+$ ]] || [[ -z "$temp_path" ]] || [[ ! -f "$temp_path" ]]; then
            log_warn_event "Processing" "Could not reliably parse size/path for largest file from: '$sorted_stat_line'. Parsed size: '$temp_size', path: '$temp_path'."
            if [[ "$quarantine_on_overall_failure_str" == "true" ]]; then
                if quarantine_item "$source_item_path_arg" "Parse largest file details failed"; then PROCESSOR_EXIT_CODE=2; else PROCESSOR_EXIT_CODE=1; fi
            else
                PROCESSOR_EXIT_CODE=1
            fi
            return 1
        fi
        item_size_bytes="$temp_size"
        main_media_file_source_path="$temp_path"
        # Update source_content_base_path to be the directory of the identified main media file
        # This is important for finding associated files later.
        source_content_base_path=$(dirname "$main_media_file_source_path")
        log_info_event "Processing" "Identified main media file: '$main_media_file_source_path' (Size: ${item_size_bytes} bytes) within '$source_content_base_path'"
    else
        log_warn_event "Processing" "Source item '$source_item_path_arg' is not a valid file or directory."
        if [[ "$quarantine_on_overall_failure_str" == "true" ]]; then
            if quarantine_item "$source_item_path_arg" "Invalid source type"; then PROCESSOR_EXIT_CODE=2; else PROCESSOR_EXIT_CODE=1; fi
        else
            PROCESSOR_EXIT_CODE=1
        fi
        return 1
    fi

    if [[ -z "$main_media_file_source_path" ]]; then
        log_warn_event "Processing" "Main media file could not be identified for '$source_item_path_arg'."
        if [[ "$quarantine_on_overall_failure_str" == "true" ]]; then
            if quarantine_item "$source_item_path_arg" "Main media not identified"; then PROCESSOR_EXIT_CODE=2; else PROCESSOR_EXIT_CODE=1; fi
        else
            PROCESSOR_EXIT_CODE=1
        fi
        return 1
    fi

    local main_media_source_basename    
    main_media_source_basename=$(basename "$main_media_file_source_path")
    local main_media_source_ext         
    main_media_source_ext="$(get_file_extension "$main_media_source_basename")" 
    final_main_media_dest_path="${final_dest_template}${main_media_source_ext}" 

    _processor_create_safe_destination_path "$final_main_media_dest_path"

    local required_kb="1" 
    if [[ "$item_size_bytes" =~ ^[0-9]+$ && "$item_size_bytes" -gt 0 ]]; then
        required_kb=$(( (item_size_bytes + 1023) / 1024 )) 
    elif [[ -f "$main_media_file_source_path" ]]; then 
        required_kb=$(du -sk "$main_media_file_source_path" 2>/dev/null | awk '{print $1}')
        if ! [[ "$required_kb" =~ ^[0-9]+$ ]]; then required_kb="1"; fi
    fi

    if ! check_available_disk_space "$(dirname "$final_main_media_dest_path")" "$required_kb"; then 
         log_warn_event "Processing" "Not enough disk space for '$main_media_source_basename'. Required ${required_kb}KB."
         if [[ "$quarantine_on_overall_failure_str" == "true" ]]; then
             if quarantine_item "$source_item_path_arg" "Insufficient disk space for media"; then PROCESSOR_EXIT_CODE=2; else PROCESSOR_EXIT_CODE=1; fi
         else
            PROCESSOR_EXIT_CODE=1
         fi
         return 1
    fi

    log_user_progress "Processing" "📁 Moving: $(basename "$final_main_media_dest_path")"
    log_debug_event "Processing" "Moving main media file (using smart transfer):"
    log_debug_event "Processing" "  FROM: '$main_media_file_source_path'"
    log_debug_event "Processing" "  TO:   '$final_main_media_dest_path'"

   if ! transfer_file_smart "$main_media_file_source_path" "$final_main_media_dest_path" "Processing"; then
        log_warn_event "Processing" "transfer failed for main media file '$main_media_file_source_path'."
        PROCESSOR_EXIT_CODE=1 
        return 1 
    fi
    record_transfer_to_history "$main_media_file_source_path -> $final_main_media_dest_path ($determined_category)" 

    local media_file_radix_for_assoc="${final_dest_template##*/}" 
    local -a find_assoc_patterns_arr=() 
    if [[ ${#ASSOCIATED_FILE_EXTENSIONS[@]} -gt 0 ]]; then 
        i=0; 
        for ext_pattern in "${ASSOCIATED_FILE_EXTENSIONS[@]}"; do 
            if [[ $i -gt 0 ]]; then 
                find_assoc_patterns_arr[${#find_assoc_patterns_arr[@]}]="-o"
            fi
            find_assoc_patterns_arr[${#find_assoc_patterns_arr[@]}]="-iname"
            find_assoc_patterns_arr[${#find_assoc_patterns_arr[@]}]="*${ext_pattern}"
            ((i++));
        done
    fi

    if [[ ${#find_assoc_patterns_arr[@]} -gt 0 ]]; then
        # Now, assoc_find_path is simply source_content_base_path, which was updated to be
        # the directory of the main media file if it was found in a subfolder.
        local assoc_find_path="$source_content_base_path"
        log_debug_event "Processing" "Searching for associated files in '$assoc_find_path'."

        local current_assoc_file_source_path 
        find "$assoc_find_path" -maxdepth 1 -type f \( "${find_assoc_patterns_arr[@]}" \) \
            -print0 2>/dev/null | while IFS= read -r -d $'\0' current_assoc_file_source_path; do
            [[ -z "$current_assoc_file_source_path" ]] && continue 
            
            local assoc_file_basename assoc_file_source_ext_only assoc_lang_tag new_assoc_filename final_assoc_file_dest_path
            assoc_file_basename=$(basename "$current_assoc_file_source_path")
            assoc_file_source_ext_only="${assoc_file_basename##*.}" 
            
            assoc_lang_tag=""
            if [[ "$assoc_file_basename" =~ \.([a-zA-Z]{2,3})\.${assoc_file_source_ext_only}$ ]]; then
                assoc_lang_tag=".${BASH_REMATCH[1]}" 
            fi
            
            new_assoc_filename="${media_file_radix_for_assoc}${assoc_lang_tag}.${assoc_file_source_ext_only}" 
            final_assoc_file_dest_path="$(dirname "$final_main_media_dest_path")/${new_assoc_filename}"

            log_info_event "Processing" "Moving associated file '$assoc_file_basename' to '$final_assoc_file_dest_path'..."
            if ! transfer_file_smart "$current_assoc_file_source_path" "$final_assoc_file_dest_path" "Processing"; then
                log_warn_event "Processing" "Failed to transfer associated file '$assoc_file_basename'. It remains at source."
            else
                record_transfer_to_history "$current_assoc_file_source_path -> $final_assoc_file_dest_path ($determined_category - Assoc.)"
            fi
        done
    fi

    # If the original item was a directory (source_item_path_arg), try to clean it up.
    # source_content_base_path is the directory where the main media file was found.
    # source_item_path_arg is the original item passed to this function.
    if [[ -d "$source_item_path_arg" ]]; then
        _processor_cleanup_empty_source_subdirectories "$source_item_path_arg" # Clean within original arg
        # If the original source_item_path_arg itself is now empty, try to remove it.
        # This handles cases where the media was in a subfolder that got emptied,
        # and now the top-level torrent folder might also be empty.
        if [[ "$source_item_path_arg" != "$DROP_FOLDER" && -d "$source_item_path_arg" ]] && [[ -z "$(ls -A "$source_item_path_arg" 2>/dev/null)" ]]; then
            log_info_event "Processing" "Attempting to remove now-empty original source directory: $source_item_path_arg"
            if rmdir "$source_item_path_arg" 2>/dev/null; then
                log_info_event "Processing" "Successfully removed empty original source directory: $source_item_path_arg"
            else
                log_warn_event "Processing" "Could not remove original source directory '$source_item_path_arg'. It might not be empty or has permission issues."
            fi
        fi
    fi
    return 0 
}

# --- Main Processing Logic Functions ---

_processor_process_as_movie() {
    local item_path="$1"    
    local original_item_name movie_title final_movie_folder_name final_dest_template 
    original_item_name=$(basename "$item_path")
    log_debug_event "Processing" "Processing as Movie: '$item_path' (Original Name: '$original_item_name')"

    movie_title=$(extract_and_sanitize_movie_info "$original_item_name")

    if [[ "$movie_title" == "Unknown Movie" || -z "$movie_title" ]]; then
        log_warn_event "Processing" "Could not determine movie title for '$original_item_name'."
        if quarantine_item "$item_path" "Unknown movie title"; then PROCESSOR_EXIT_CODE=2; else PROCESSOR_EXIT_CODE=1; fi
        return 1 
    fi

    final_movie_folder_name="$movie_title" 
    final_dest_template="${DEST_DIR_MOVIES}/${final_movie_folder_name}/${final_movie_folder_name}"

    if ! _processor_move_media_and_associated_files "$item_path" "$final_dest_template" "Movies" "true"; then
        log_warn_event "Processing" "Failed to fully process movie '$original_item_name' (move media failed)."
        return 1 
    fi

    log_user_complete "Processing" "🎬 Movie organized: Movies/${final_movie_folder_name}/"
    if [[ "${ENABLE_JELLYFIN_SCAN_MOVIES:-false}" == "true" ]]; then 
        trigger_jellyfin_library_scan "Movies" 
    fi
    PROCESSOR_EXIT_CODE=0 
    return 0 
}

_processor_process_as_show() {
    local item_path="$1"    
    local original_item_name show_name season_num episode_num extracted_year season_episode_str 
    local show_info_str final_show_folder_name season_folder_name episode_filename_radix final_dest_template 

    original_item_name=$(basename "$item_path")
    log_debug_event "Processing" "Processing as TV Show: '$item_path' (Original Name: '$original_item_name')"

    show_info_str=$(extract_and_sanitize_show_info "$original_item_name")
    log_debug_event "Processing" "Got show_info_str from media_utils: '$show_info_str'"
    
    show_name=$(echo "$show_info_str" | awk -F'###' '{print $1}')
    extracted_year=$(echo "$show_info_str" | awk -F'###' '{print $2}')
    season_episode_str=$(echo "$show_info_str" | awk -F'###' '{print $3}')
    
    if [[ "$extracted_year" == "NOYEAR" ]]; then
        extracted_year=""
    fi
    
    log_debug_event "Processing" "Parsed values: show_name='$show_name', year='$extracted_year', se='$season_episode_str'"

    if [[ "$show_name" == "Unknown Show" || -z "$season_episode_str" ]]; then
        log_warn_event "Processing" "Could not determine critical show details (Show Name or S/E) for '$original_item_name'. Got: Name='$show_name', Year='$extracted_year', SE='$season_episode_str'"
        if quarantine_item "$item_path" "Unknown show details (Name or S/E missing)"; then PROCESSOR_EXIT_CODE=2; else PROCESSOR_EXIT_CODE=1; fi
        return 1 
    fi
    
    if [[ "$season_episode_str" =~ ^s([0-9]{2})e([0-9]{2,3})$ ]]; then 
        season_num="${BASH_REMATCH[1]}"  
        episode_num="${BASH_REMATCH[2]}" 
    else
        log_warn_event "Processing" "Could not parse S/E numbers from '$season_episode_str' for '$original_item_name'."
        if quarantine_item "$item_path" "Malformed S/E string from parser ('$season_episode_str')"; then PROCESSOR_EXIT_CODE=2; else PROCESSOR_EXIT_CODE=1; fi
        return 1
    fi

    final_show_folder_name="${show_name}${extracted_year:+" ($extracted_year)"}" 
    season_folder_name="Season ${season_num}" 
    local padded_episode_num; padded_episode_num=$(printf "%02d" "$((10#$episode_num))") 
    if [[ ${#episode_num} -gt 2 ]]; then padded_episode_num="$episode_num"; fi 

    # For TV shows, each episode usually gets its own subfolder for better organization of multiple files (video, subs, nfo)
    local episode_subfolder_name="${show_name} S${season_num}E${padded_episode_num}"
    episode_filename_radix="${show_name} - S${season_num}E${padded_episode_num}" 
    final_dest_template="${DEST_DIR_SHOWS}/${final_show_folder_name}/${season_folder_name}/${episode_subfolder_name}/${episode_filename_radix}"

    if ! _processor_move_media_and_associated_files "$item_path" "$final_dest_template" "Shows" "true"; then
        log_warn_event "Processing" "Failed to fully process show '$original_item_name' (moving file failed)."
        return 1 
    fi

    log_user_complete "Processing" "📺 TV Show organized: Shows/${final_show_folder_name}/${season_folder_name}/${episode_subfolder_name}/"
    if [[ "${ENABLE_JELLYFIN_SCAN_SHOWS:-false}" == "true" ]]; then 
        trigger_jellyfin_library_scan "Shows" 
    fi
    PROCESSOR_EXIT_CODE=0 
    return 0 
}

_processor_handle_item_by_category() {
    local item_path_to_categorize="$1"  
    local category_to_process_hint="$2"       
    local item_basename                 
    item_basename=$(basename "$item_path_to_categorize")
    local actual_category_to_process

    if [[ "$category_to_process_hint" != "Movies" && "$category_to_process_hint" != "Shows" ]]; then
        log_debug_event "Processing" "Category hint ('$category_to_process_hint') not definitive for '$item_basename'. Auto-determining category..."
        actual_category_to_process=$(determine_media_category "$item_basename") 
        log_debug_event "Processing" "Auto-determined category for '$item_basename': '$actual_category_to_process'"
    else
        log_debug_event "Processing" "Using provided category hint for '$item_basename': '$category_to_process_hint'"
        actual_category_to_process="$category_to_process_hint"
    fi

    case "$actual_category_to_process" in
        "Movies") 
            _processor_process_as_movie "$item_path_to_categorize"
            return $? 
            ;;
        "Shows")  
            _processor_process_as_show "$item_path_to_categorize"
            return $? 
            ;;
        *) 
            log_warn_event "Processing" "Item '$item_basename' could not be categorized as Movies or Shows. Effective category: '$actual_category_to_process'."
            if quarantine_item "$item_path_to_categorize" "Uncategorized item ('$actual_category_to_process')"; then PROCESSOR_EXIT_CODE=2; else PROCESSOR_EXIT_CODE=1; fi
            return 1 
            ;;
    esac
}

# --- Main Dispatch Logic ---
log_debug_event "Processing" "Dispatching item type: '$MAIN_ITEM_TYPE'"
PROCESSING_FUNCTION_RETURN_STATUS=1 

case "$MAIN_ITEM_TYPE" in
    "movie_file"|"movie_folder"|"Movies") 
        _processor_process_as_movie "$MAIN_ITEM_PATH"
        PROCESSING_FUNCTION_RETURN_STATUS=$?
        ;;
    "show_file"|"show_folder"|"Shows") 
        _processor_process_as_show "$MAIN_ITEM_PATH"
        PROCESSING_FUNCTION_RETURN_STATUS=$?
        ;;
    "media_folder"|"torrent"|"generic_file"|"generic_folder") 
        _processor_handle_item_by_category "$MAIN_ITEM_PATH" "$MAIN_ITEM_CATEGORY_HINT"
        PROCESSING_FUNCTION_RETURN_STATUS=$?
        ;;
    *)
        log_error_event "Processing" "Invalid item type '$MAIN_ITEM_TYPE' received by processor."
        exit 1
        ;;
esac

# if processing successful, clean up remaining files and folder in DROP_FOLDER
if [[ "$PROCESSOR_EXIT_CODE" -eq 0 ]]; then 
    if [[ "$PROCESSING_FUNCTION_RETURN_STATUS" -ne 0 ]]; then
        PROCESSOR_EXIT_CODE=1 
    fi
fi

if [[ "$PROCESSOR_EXIT_CODE" -eq 0 ]]; then
    # Only perform final cleanup if all primary processing was successful (not quarantined or errored before this point)
    _processor_final_drop_folder_cleanup
fi
# ================================================================= #


# --- Finalize ---
PROCESS_END_TIME=$(date +%s)
ELAPSED_SECONDS=$((PROCESS_END_TIME - PROCESS_START_TIME))
MINS=$((ELAPSED_SECONDS / 60))
SECS=$((ELAPSED_SECONDS % 60))
original_item_basename_for_log=$(basename "$MAIN_ITEM_PATH")

if [[ "$PROCESSOR_EXIT_CODE" -eq 0 ]]; then
    # Get the main media filename that was just organized
    organized_filename="$(basename "${final_main_media_dest_path:-$(basename "$MAIN_ITEM_PATH")}")"
    log_user_complete "Processing" "✨ Successfully processed: $organized_filename (${MINS}m${SECS}s)"
    play_sound_notification "task_success" "Processing"
elif [[ "$PROCESSOR_EXIT_CODE" -eq 2 ]]; then 
    log_warn_event "Processing" "🟡 Item quarantined: $(basename "$MAIN_ITEM_PATH") (${MINS}m${SECS}s)"
    play_sound_notification "task_error" "Processing" 
    PROCESSOR_EXIT_CODE=0 
else 
    log_warn_event "Processing" "💀 Processing failed: $(basename "$MAIN_ITEM_PATH") (${MINS}m${SECS}s)"
    play_sound_notification "task_error" "Processing"
    [[ "$PROCESSOR_EXIT_CODE" -eq 0 ]] && PROCESSOR_EXIT_CODE=1 
fi

_cleanup_process_media_item_temp_files 

log_debug_event "Processing" "--- Processor Finished for Item: '$original_item_basename_for_log' with Reported Exit Code: $PROCESSOR_EXIT_CODE ---"

exit "$PROCESSOR_EXIT_CODE"

