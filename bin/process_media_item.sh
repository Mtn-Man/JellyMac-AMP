#!/bin/bash

# JellyMac_AMP/bin/process_media_item.sh
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
LOG_PREFIX_PROCESSOR="[MEDIA_ITEM_PROCESSOR]"
# Define local logging functions for this script
log_processor_info() { _log_event_if_level_met "$LOG_LEVEL_INFO" "$LOG_PREFIX_PROCESSOR" "$*"; }
log_processor_warn() { _log_event_if_level_met "$LOG_LEVEL_WARN" "⚠️ WARN: $LOG_PREFIX_PROCESSOR" "$*" >&2; }
# Use log_error_event from logging_utils.sh for fatal errors that should exit the script
# Ensure log_error_event from logging_utils.sh exits, or add explicit exit 1 after its call.
# For this script, we'll define a local one that ensures exit.
log_processor_error() {
    # Release any lock that might be held before exiting
    if [[ -n "${MAIN_ITEM_PATH:-}" ]]; then
        release_stability_lock "$MAIN_ITEM_PATH"
    fi
    log_error_event "$LOG_PREFIX_PROCESSOR" "$*"; # Call the library function
    exit 1; # Ensure this script exits
}
log_processor_debug() { _log_event_if_level_met "$LOG_LEVEL_DEBUG" "🐛 DEBUG: $LOG_PREFIX_PROCESSOR" "$*"; }

# === Temporary File Cleanup Trap ===
_PROCESS_MEDIA_ITEM_TEMP_FILES_TO_CLEAN=()
_cleanup_process_media_item_temp_files() {
    # shellcheck disable=SC2128 # We want to check array length
    if [[ ${#_PROCESS_MEDIA_ITEM_TEMP_FILES_TO_CLEAN[@]} -gt 0 ]]; then
        log_processor_debug "EXIT trap: Cleaning up temporary files (${#_PROCESS_MEDIA_ITEM_TEMP_FILES_TO_CLEAN[@]} items)..."
        local temp_file_path_to_clean # Correctly local
        for temp_file_path_to_clean in "${_PROCESS_MEDIA_ITEM_TEMP_FILES_TO_CLEAN[@]}"; do
            if [[ -n "$temp_file_path_to_clean" && -e "$temp_file_path_to_clean" ]]; then
                rm -rf "$temp_file_path_to_clean"
                log_processor_debug "EXIT trap: Removed '$temp_file_path_to_clean'"
            fi
        done
    fi
    _PROCESS_MEDIA_ITEM_TEMP_FILES_TO_CLEAN=()
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
    # Use log_processor_error which ensures exit
    log_processor_error "Usage: $0 <item_type> <item_path> [item_category_hint]"
fi

MAIN_ITEM_TYPE="$1"
MAIN_ITEM_PATH="$2"
MAIN_ITEM_CATEGORY_HINT="${3:-}" # Hint can be "Movies" or "Shows"

log_processor_info "🚀 Starting processing for: Type='$MAIN_ITEM_TYPE', Path='$MAIN_ITEM_PATH', CategoryHint='$MAIN_ITEM_CATEGORY_HINT'"

if [[ ! -e "$MAIN_ITEM_PATH" ]]; then
    log_processor_error "Item path '$MAIN_ITEM_PATH' does not exist. Cannot process."
fi

# --- Essential Config Variable Checks ---
: "${DEST_DIR_MOVIES:?PROCESSOR: DEST_DIR_MOVIES not set in config.}"
: "${DEST_DIR_SHOWS:?PROCESSOR: DEST_DIR_SHOWS not set in config.}"
: "${ERROR_DIR:?PROCESSOR: ERROR_DIR (for quarantine_item) not set in config.}"
: "${HISTORY_FILE:?PROCESSOR: HISTORY_FILE not set in config.}"
: "${RSYNC_TIMEOUT:=300}" # Default to 300s if not set
if [[ ${#MAIN_MEDIA_EXTENSIONS[@]} -eq 0 ]]; then
    log_processor_error "MAIN_MEDIA_EXTENSIONS array is not defined or empty in config."
fi

# --- Helper Functions ---
# Creates destination directory if it doesn't exist. Exits on failure.
_processor_create_safe_destination_path() {
    local dest_path="$1"
    local dest_dir
    dest_dir=$(dirname "$dest_path")
    if [[ ! -d "$dest_dir" ]]; then
        log_processor_debug "Creating destination directory: $dest_dir"
        if ! mkdir -p "$dest_dir"; then
            release_stability_lock "$MAIN_ITEM_PATH"
            log_processor_error "Failed to create destination directory: $dest_dir. Check permissions."
        fi
    elif [[ ! -w "$dest_dir" ]]; then # Check if existing dir is writable
        release_stability_lock "$MAIN_ITEM_PATH"
        log_processor_error "Destination directory '$dest_dir' is not writable."
    fi
}

# Cleans up empty subdirectories within a given base directory after processing.
_processor_cleanup_empty_source_subdirectories() {
    local base_dir_to_check="$1"
    log_processor_debug "Checking for empty subdirectories to clean up within '$base_dir_to_check'..."

    if [[ ! -d "$base_dir_to_check" ]]; then
        log_processor_debug "Directory '$base_dir_to_check' does not exist or is not accessible."
        return 0
    fi

    # Loop until no more empty directories are found
    local found_empty=true
    while [[ "$found_empty" == "true" ]]; do
        found_empty=false
        # Use portable macOS-friendly find command to get one empty directory at a time
        local empty_dir
        empty_dir=$(find "$base_dir_to_check" -mindepth 1 -type d -empty | head -n 1)

        if [[ -n "$empty_dir" && -d "$empty_dir" ]]; then
            found_empty=true
            log_processor_info "Removing empty subdirectory: $empty_dir"

            if ! rmdir "$empty_dir" 2>/dev/null; then
                log_processor_warn "Could not remove empty subdirectory '$empty_dir'. It might have been removed by another process, become non-empty, or have permission issues."
                # Break to avoid potential infinite loop if directory can't be removed
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
    local ext

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
            log_processor_warn "Single file input '$source_item_path_arg' is not a recognized main media type (ext: '$item_ext_check')."
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
        log_processor_debug "Source is a directory. Identifying main media file in '$source_content_base_path'..."

        local -a find_main_patterns_arr=()
        i=0
        for ext in "${MAIN_MEDIA_EXTENSIONS[@]}"; do
            if [[ $i -gt 0 ]]; then find_main_patterns_arr+=("-o"); fi
            find_main_patterns_arr+=("-iname"); find_main_patterns_arr+=("*${ext}")
            ((i++))
        done

        # Temp files for find and xargs output
        local find_stdout_tmp xargs_stat_stdout_tmp
        find_stdout_tmp=$(mktemp "${SCRIPT_DIR_PROCESSOR}/.media_find_stdout.XXXXXX")
        _PROCESS_MEDIA_ITEM_TEMP_FILES_TO_CLEAN+=("$find_stdout_tmp")
        xargs_stat_stdout_tmp=$(mktemp "${SCRIPT_DIR_PROCESSOR}/.media_xargs_stat_stdout.XXXXXX")
        _PROCESS_MEDIA_ITEM_TEMP_FILES_TO_CLEAN+=("$xargs_stat_stdout_tmp")

        # Find files and write to temp file (null-terminated)
        find "$source_content_base_path" -type f \( "${find_main_patterns_arr[@]}" \) -print0 2>/dev/null > "$find_stdout_tmp"

        if [[ ! -s "$find_stdout_tmp" ]]; then # Check if find_stdout_tmp is empty
            log_processor_warn "No media files matching MAIN_MEDIA_EXTENSIONS found in '$source_content_base_path'."
            if [[ "$quarantine_on_overall_failure_str" == "true" ]]; then
                if quarantine_item "$source_item_path_arg" "No media files in folder"; then PROCESSOR_EXIT_CODE=2; else PROCESSOR_EXIT_CODE=1; fi
            else
                PROCESSOR_EXIT_CODE=1
            fi
            return 1
        fi

        # Get size and name for each found file, write to another temp file
        # Using macOS stat format: size then full path name
        xargs --null -I{} stat -f "%z %N" "{}" < "$find_stdout_tmp" 2>/dev/null > "$xargs_stat_stdout_tmp"

        if [[ ! -s "$xargs_stat_stdout_tmp" ]]; then
            log_processor_warn "stat command (via xargs) produced no output for files in '$source_content_base_path'. Possible permission issue or files vanished."
            if [[ "$quarantine_on_overall_failure_str" == "true" ]]; then
                if quarantine_item "$source_item_path_arg" "stat failed for media files"; then PROCESSOR_EXIT_CODE=2; else PROCESSOR_EXIT_CODE=1; fi
            else
                PROCESSOR_EXIT_CODE=1
            fi
            return 1
        fi

        # Sort by size (first column, numeric, reverse) and get the top one (largest file)
        local sorted_stat_line temp_size temp_path
        sorted_stat_line=$(sort -rnk1,1 "$xargs_stat_stdout_tmp" | head -n1) # Sort by first field numerically

        if [[ -z "$sorted_stat_line" ]]; then
            log_processor_warn "Could not determine largest file in '$source_content_base_path' (sort/head failed or no valid stat output)."
            if [[ "$quarantine_on_overall_failure_str" == "true" ]]; then
                if quarantine_item "$source_item_path_arg" "Largest file identification failed"; then PROCESSOR_EXIT_CODE=2; else PROCESSOR_EXIT_CODE=1; fi
            else
                PROCESSOR_EXIT_CODE=1
            fi
            return 1
        fi

        # Parse the size and path from the sorted line
        temp_size=$(echo "$sorted_stat_line" | awk '{print $1}')
        temp_path=$(echo "$sorted_stat_line" | awk '{first = $1; $1 = ""; print $0}' | sed 's/^[[:space:]]*//') # Get rest of line after size

        if ! [[ "$temp_size" =~ ^[0-9]+$ ]] || [[ -z "$temp_path" ]] || [[ ! -f "$temp_path" ]]; then
            log_processor_warn "Could not reliably parse size/path for largest file from: '$sorted_stat_line'. Parsed size: '$temp_size', path: '$temp_path'."
            if [[ "$quarantine_on_overall_failure_str" == "true" ]]; then
                if quarantine_item "$source_item_path_arg" "Parse largest file details failed"; then PROCESSOR_EXIT_CODE=2; else PROCESSOR_EXIT_CODE=1; fi
            else
                PROCESSOR_EXIT_CODE=1
            fi
            return 1
        fi
        item_size_bytes="$temp_size"
        main_media_file_source_path="$temp_path"
        log_processor_info "Identified main media file: '$main_media_file_source_path' (Size: ${item_size_bytes} bytes)"
    else
        log_processor_warn "Source item '$source_item_path_arg' is not a valid file or directory."
        if [[ "$quarantine_on_overall_failure_str" == "true" ]]; then
            if quarantine_item "$source_item_path_arg" "Invalid source type"; then PROCESSOR_EXIT_CODE=2; else PROCESSOR_EXIT_CODE=1; fi
        else
            PROCESSOR_EXIT_CODE=1
        fi
        return 1
    fi

    if [[ -z "$main_media_file_source_path" ]]; then
        log_processor_warn "Main media file could not be identified for '$source_item_path_arg'."
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
    main_media_source_ext="$(get_file_extension "$main_media_source_basename")" # From common_utils.sh
    # Construct the full destination path for the main media file
    local final_main_media_dest_path="${final_dest_template}${main_media_source_ext}"

    _processor_create_safe_destination_path "$final_main_media_dest_path"

    # Check disk space at destination
    local required_kb="1"
    if [[ "$item_size_bytes" =~ ^[0-9]+$ && "$item_size_bytes" -gt 0 ]]; then
        required_kb=$(( (item_size_bytes + 1023) / 1024 )) # Ceiling division to KB
    elif [[ -f "$main_media_file_source_path" ]]; then # Fallback if item_size_bytes wasn't parsed
        required_kb=$(du -sk "$main_media_file_source_path" 2>/dev/null | awk '{print $1}')
        if ! [[ "$required_kb" =~ ^[0-9]+$ ]]; then required_kb="1"; fi
    fi

    if ! check_available_disk_space "$(dirname "$final_main_media_dest_path")" "$required_kb"; then
         log_processor_warn "Not enough disk space for '$main_media_source_basename'. Required ${required_kb}KB."
         if [[ "$quarantine_on_overall_failure_str" == "true" ]]; then
             if quarantine_item "$source_item_path_arg" "Insufficient disk space for media"; then PROCESSOR_EXIT_CODE=2; else PROCESSOR_EXIT_CODE=1; fi
         else
            PROCESSOR_EXIT_CODE=1
         fi
         return 1
    fi

    log_processor_info "Moving main media file (using rsync --remove-source-files):"
    log_processor_info "  FROM: '$main_media_file_source_path'"
    log_processor_info "  TO:   '$final_main_media_dest_path'"

    if ! rsync -av --progress --remove-source-files --timeout="$RSYNC_TIMEOUT" "$main_media_file_source_path" "$final_main_media_dest_path"; then
        log_processor_warn "rsync failed for main media file '$main_media_file_source_path'."
        # Don't quarantine the whole source_item_path_arg here, as the main file might still be at source.
        # The calling function will decide on overall quarantine if this step fails.
        PROCESSOR_EXIT_CODE=1
        return 1 # Indicate failure of this specific move
    fi
    record_transfer_to_history "$main_media_file_source_path -> $final_main_media_dest_path ($determined_category)"

    # Move associated files (subtitles, nfo, etc.)
    # Radix is the filename without extension for the destination
    local media_file_radix_for_assoc="${final_dest_template##*/}"
    local -a find_assoc_patterns_arr=()
    if [[ ${#ASSOCIATED_FILE_EXTENSIONS[@]} -gt 0 ]]; then
        i=0;
        for ext_pattern in "${ASSOCIATED_FILE_EXTENSIONS[@]}"; do
            if [[ $i -gt 0 ]]; then find_assoc_patterns_arr+=("-o"); fi
            find_assoc_patterns_arr+=("-iname"); find_assoc_patterns_arr+=("*${ext_pattern}")
            ((i++));
        done
    fi

    if [[ ${#find_assoc_patterns_arr[@]} -gt 0 ]]; then
        # Search for associated files in the same directory as the main_media_file_source_path
        local assoc_find_path="$source_content_base_path"
        # If main media was in a subfolder of source_item_path_arg (e.g. torrent folder), search there
        if [[ "$main_media_file_source_path" == "$source_content_base_path"* && "$main_media_file_source_path" != "$source_content_base_path" && -d "$(dirname "$main_media_file_source_path")" ]]; then
             assoc_find_path=$(dirname "$main_media_file_source_path")
        fi
        log_processor_debug "Searching for associated files in '$assoc_find_path'."

        local current_assoc_file_source_path
        # Find associated files and loop through them
        find "$assoc_find_path" -maxdepth 1 -type f \( "${find_assoc_patterns_arr[@]}" \) \
            -print0 2>/dev/null | while IFS= read -r -d $'\0' current_assoc_file_source_path; do
            [[ -z "$current_assoc_file_source_path" ]] && continue

            local assoc_file_basename assoc_file_source_ext_only assoc_lang_tag new_assoc_filename final_assoc_file_dest_path
            assoc_file_basename=$(basename "$current_assoc_file_source_path")
            assoc_file_source_ext_only="${assoc_file_basename##*.}" # e.g. srt

            # Attempt to preserve language tags like .en.srt
            assoc_lang_tag=""
            if [[ "$assoc_file_basename" =~ \.([a-zA-Z]{2,3})\.${assoc_file_source_ext_only}$ ]]; then
                assoc_lang_tag=".${BASH_REMATCH[1]}" # e.g. .en
            fi

            new_assoc_filename="${media_file_radix_for_assoc}${assoc_lang_tag}.${assoc_file_source_ext_only}"
            final_assoc_file_dest_path="$(dirname "$final_main_media_dest_path")/${new_assoc_filename}"

            log_processor_info "Moving associated file '$assoc_file_basename' to '$final_assoc_file_dest_path'..."
            if ! rsync -av --progress --remove-source-files "$current_assoc_file_source_path" "$final_assoc_file_dest_path"; then
                log_processor_warn "Failed to rsync associated file '$assoc_file_basename'. It remains at source."
                # This is a non-fatal error for the overall process, main media was moved.
            else
                record_transfer_to_history "$current_assoc_file_source_path -> $final_assoc_file_dest_path ($determined_category - Assoc.)"
            fi
        done
    fi

    # If the original item was a directory, try to clean up empty subdirectories within it
    if [[ -d "$source_content_base_path" ]]; then # Use source_content_base_path which is the dir
        _processor_cleanup_empty_source_subdirectories "$source_content_base_path"
        # Also attempt to remove the base source directory if it's now empty
        if [[ "$source_content_base_path" != "$DROP_FOLDER" && -d "$source_content_base_path" ]] && [[ -z "$(ls -A "$source_content_base_path")" ]]; then
            log_processor_info "Attempting to remove now-empty source directory: $source_content_base_path"
            if rmdir "$source_content_base_path"; then
                log_processor_info "Successfully removed empty source directory: $source_content_base_path"
            else
                log_processor_warn "Could not remove source directory '$source_content_base_path'. It might not be empty or has permission issues."
            fi
        fi
    fi
    return 0 # Success for this function
}

# --- Main Processing Logic Functions ---

_processor_process_as_movie() {
    local item_path="$1"
    local original_item_name movie_title final_movie_folder_name final_dest_template
    original_item_name=$(basename "$item_path")
    log_processor_info "Processing as Movie: '$item_path' (Original Name: '$original_item_name')"

    # extract_and_sanitize_movie_info from media_utils.sh (simplified version, returns title only)
    movie_title=$(extract_and_sanitize_movie_info "$original_item_name")
    # sanitize_filename is called within extract_and_sanitize_movie_info

    if [[ "$movie_title" == "Unknown Movie" || -z "$movie_title" ]]; then
        log_processor_warn "Could not determine movie title for '$original_item_name'."
        if quarantine_item "$item_path" "Unknown movie title"; then PROCESSOR_EXIT_CODE=2; else PROCESSOR_EXIT_CODE=1; fi
        return 1
    fi

    # Movie folder name is just the movie title
    final_movie_folder_name="$movie_title"
    # Destination template for the file (extension will be added by move function)
    final_dest_template="${DEST_DIR_MOVIES}/${final_movie_folder_name}/${final_movie_folder_name}"

    if ! _processor_move_media_and_associated_files "$item_path" "$final_dest_template" "Movies" "true"; then
        log_processor_warn "Failed to fully process movie '$original_item_name' (move media failed)."
        # _processor_move_media_and_associated_files sets PROCESSOR_EXIT_CODE
        return 1
    fi

    log_processor_info "🎬 Movie processed to folder: ${DEST_DIR_MOVIES}/${final_movie_folder_name}"
    if [[ "${ENABLE_JELLYFIN_SCAN_MOVIES:-false}" == "true" ]]; then
        trigger_jellyfin_library_scan "Movies"
    fi
    PROCESSOR_EXIT_CODE=0 # Explicitly set success for this path
    return 0
}

_processor_process_as_show() {
    local item_path="$1"
    local original_item_name show_name season_num episode_num extracted_year season_episode_str
    local show_info_str final_show_folder_name season_folder_name episode_filename_radix final_dest_template

    original_item_name=$(basename "$item_path")
    log_processor_info "Processing as TV Show: '$item_path' (Original Name: '$original_item_name')"

    # extract_and_sanitize_show_info from media_utils.sh (returns Title###Year###sXXeYY)
    show_info_str=$(extract_and_sanitize_show_info "$original_item_name")
    log_processor_debug "Got show_info_str: '$show_info_str'"
    
    # Use safer parsing instead of IFS to avoid delimiter issues
    show_name=$(echo "$show_info_str" | cut -d'#' -f1)
    extracted_year=$(echo "$show_info_str" | cut -d'#' -f4)
    season_episode_str=$(echo "$show_info_str" | cut -d'#' -f7)
    
    # Handle special NOYEAR placeholder
    if [[ "$extracted_year" == "NOYEAR" ]]; then
        extracted_year=""
    fi
    
    log_processor_debug "Parsed values: show_name='$show_name', year='$extracted_year', se='$season_episode_str'"
    # sanitize_filename is called within extract_and_sanitize_show_info

    if [[ "$show_name" == "Unknown Show" || -z "$season_episode_str" ]]; then
        log_processor_warn "Could not determine critical show details (Show Name or S/E) for '$original_item_name'. Got: Name='$show_name', Year='$extracted_year', SE='$season_episode_str'"
        if quarantine_item "$item_path" "Unknown show details (Name or S/E missing)"; then PROCESSOR_EXIT_CODE=2; else PROCESSOR_EXIT_CODE=1; fi
        return 1
    fi

    if [[ "$season_episode_str" =~ ^s([0-9]{2})e([0-9]{2,3})$ ]]; then # Allow 2 or 3 digit episode numbers
        season_num="${BASH_REMATCH[1]}"  # XX
        episode_num="${BASH_REMATCH[2]}" # YY or YYY
    else
        log_processor_warn "Could not parse S/E numbers from '$season_episode_str' for '$original_item_name'."
        if quarantine_item "$item_path" "Malformed S/E string from parser"; then PROCESSOR_EXIT_CODE=2; else PROCESSOR_EXIT_CODE=1; fi
        return 1
    fi

    final_show_folder_name="${show_name}${extracted_year:+" ($extracted_year)"}" # Add year if present
    season_folder_name="Season ${season_num}" # Use the already padded season_num from sXXeYY
    # Use padded S/E for filename. Ensure episode_num is padded if it was 3 digits.
    local padded_episode_num; padded_episode_num=$(printf "%02d" "$((10#$episode_num))") # Ensure at least 2 digits
    if [[ ${#episode_num} -gt 2 ]]; then padded_episode_num="$episode_num"; fi # If original was 3 digits, use it

    episode_folder_name="${show_name} S${season_num}E${padded_episode_num}"
    episode_filename_radix="${show_name} - S${season_num}E${padded_episode_num}" 
    final_dest_template="${DEST_DIR_SHOWS}/${final_show_folder_name}/${season_folder_name}/${episode_folder_name}/${episode_filename_radix}"

    if ! _processor_move_media_and_associated_files "$item_path" "$final_dest_template" "Shows" "true"; then
        log_processor_warn "Failed to fully process show '$original_item_name' (move media failed)."
        # _processor_move_media_and_associated_files sets PROCESSOR_EXIT_CODE
        return 1
    fi

    log_processor_info "📺 TV Show episode processed to: ${DEST_DIR_SHOWS}/${final_show_folder_name}/${season_folder_name}/"
    if [[ "${ENABLE_JELLYFIN_SCAN_SHOWS:-false}" == "true" ]]; then
        trigger_jellyfin_library_scan "Shows"
    fi
    PROCESSOR_EXIT_CODE=0 # Explicitly set success for this path
    return 0
}

_processor_handle_item_by_category() {
    local item_path_to_categorize="$1"
    local category_to_process_hint="$2" # This is the hint from the caller
    local item_basename
    item_basename=$(basename "$item_path_to_categorize")
    local actual_category_to_process

    # If no category hint, or hint is not explicitly "Movies" or "Shows", determine it.
    if [[ "$category_to_process_hint" != "Movies" && "$category_to_process_hint" != "Shows" ]]; then
        log_processor_info "Category hint ('$category_to_process_hint') not definitive for '$item_basename'. Auto-determining category..."
        actual_category_to_process=$(determine_media_category "$item_basename") # From media_utils.sh
        log_processor_info "Auto-determined category for '$item_basename': '$actual_category_to_process'"
    else
        log_processor_info "Using provided category hint for '$item_basename': '$category_to_process_hint'"
        actual_category_to_process="$category_to_process_hint"
    fi

    case "$actual_category_to_process" in
        "Movies")
            _processor_process_as_movie "$item_path_to_categorize"
            return $? # Return status of movie processing
            ;;
        "Shows")
            _processor_process_as_show "$item_path_to_categorize"
            return $? # Return status of show processing
            ;;
        *)
            log_processor_warn "Item '$item_basename' could not be categorized as Movies or Shows. Effective category: '$actual_category_to_process'."
            if quarantine_item "$item_path_to_categorize" "Uncategorized item ('$actual_category_to_process')"; then PROCESSOR_EXIT_CODE=2; else PROCESSOR_EXIT_CODE=1; fi
            return 1 # Uncategorized
            ;;
    esac
}

# --- Main Dispatch Logic ---
log_processor_debug "Dispatching item type: '$MAIN_ITEM_TYPE'"
# PROCESSOR_EXIT_CODE is initialized to 0. Functions will set it to 1 on error, 2 on quarantine.
# We need a temporary variable to hold the return status of the processing functions.
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
        log_processor_error "Invalid item type '$MAIN_ITEM_TYPE' received by processor."
        # log_processor_error exits, so PROCESSING_FUNCTION_RETURN_STATUS won't be used from here.
        ;;
esac

# Update PROCESSOR_EXIT_CODE based on the function's direct return status
# if it hasn't already been set to a more specific state (like 2 for quarantine) by an internal call.
if [[ "$PROCESSOR_EXIT_CODE" -eq 0 ]]; then # If not already set to 1 (error) or 2 (quarantine) by deeper functions
    if [[ "$PROCESSING_FUNCTION_RETURN_STATUS" -ne 0 ]]; then
        PROCESSOR_EXIT_CODE=1 # General error if the main processing function failed
    fi
fi
# If PROCESSOR_EXIT_CODE was set to 2 (quarantine success) by a deeper function, it remains 2.
# If PROCESSOR_EXIT_CODE was set to 1 (error) by a deeper function, it remains 1.

# --- Finalize ---
PROCESS_END_TIME=$(date +%s)
ELAPSED_SECONDS=$((PROCESS_END_TIME - PROCESS_START_TIME))
MINS=$((ELAPSED_SECONDS / 60))
SECS=$((ELAPSED_SECONDS % 60))
# Fix for shellcheck SC2155: Declare and assign separately
original_item_basename_for_log
original_item_basename_for_log=$(basename "$MAIN_ITEM_PATH")

# Before using release_stability_lock, ensure it exists
if ! declare -F release_stability_lock > /dev/null; then
    # Define it locally if missing
    release_stability_lock() {
        local item_path="$1"
        # Implementation depends on how acquire_stability_lock was defined
        # Use md5 on macOS or md5sum on Linux
        local md5_cmd
        if command -v md5 &>/dev/null; then
            md5_cmd="md5 -q"
        elif command -v md5sum &>/dev/null; then
            md5_cmd="md5sum | cut -d' ' -f1"
        else
            log_processor_warn "Neither md5 nor md5sum command found. Using basename for lock."
            md5_cmd="basename"
        fi
        
        # Fix for shellcheck SC2155: Declare and assign separately
        local lock_file
        lock_file="${STATE_DIR:-/tmp}/stability_lock_$(echo "$item_path" | eval "$md5_cmd")"
        if [[ -f "$lock_file" ]]; then
            log_processor_debug "Releasing stability lock for '$item_path': '$lock_file'"
            rm -f "$lock_file"
        fi
    }
    log_processor_debug "Defined local release_stability_lock function"
fi

if [[ "$PROCESSOR_EXIT_CODE" -eq 0 ]]; then
    log_processor_info "✨ Successfully processed '$original_item_basename_for_log'. Total time: ${MINS}m${SECS}s."
    play_sound_notification "task_success" "$LOG_PREFIX_PROCESSOR"
elif [[ "$PROCESSOR_EXIT_CODE" -eq 2 ]]; then
    # Item was successfully quarantined. This is a "successful" outcome for this script's lifecycle.
    log_processor_info "🟡 Item '$original_item_basename_for_log' was successfully quarantined. Total time: ${MINS}m${SECS}s."
    play_sound_notification "task_error" "$LOG_PREFIX_PROCESSOR" # CHANGED: Play error sound for quarantine
    PROCESSOR_EXIT_CODE=0 # Report 0 to the watcher, as the item is handled (quarantined).
else
    # PROCESSOR_EXIT_CODE is 1 (or any other non-0, non-2 code)
    log_processor_warn "💀 Failed to process '$original_item_basename_for_log'. An error occurred. Total time: ${MINS}m${SECS}s."
    play_sound_notification "task_error" "$LOG_PREFIX_PROCESSOR"
    # Ensure PROCESSOR_EXIT_CODE is 1 for general failure if it wasn't already.
    [[ "$PROCESSOR_EXIT_CODE" -eq 0 ]] && PROCESSOR_EXIT_CODE=1
fi

_cleanup_process_media_item_temp_files

# Release the stability lock acquired during wait_for_file_stability
release_stability_lock "$MAIN_ITEM_PATH"

log_processor_info "--- Processor Finished for Item: '$original_item_basename_for_log' with Reported Exit Code: $PROCESSOR_EXIT_CODE ---"
exit "$PROCESSOR_EXIT_CODE"
