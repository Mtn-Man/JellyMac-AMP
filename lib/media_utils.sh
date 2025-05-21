#!/bin/bash

# lib/media_utils.sh
# Contains utility functions for media file processing,
# including filename parsing, sanitization, and category determination.
# Simplified: Defaults to "Movies", specifically identifies "Shows".

# This script primarily provides functions that return values via echo.
# Logging within these functions should be minimal (e.g., debug logs if necessary),
# allowing the calling script (process_media_item.sh) to handle main logging.

# Function to sanitize a string for use as a valid filename.
# Replaces common problematic characters with underscores or removes them.
# Arguments:
#   $1: String to sanitize
#   $2: (Optional) Default string if $1 is empty after sanitization
# Returns: Sanitized string via echo
sanitize_filename() {
    local input_string="$1"
    local default_string="${2:-sanitized_name}"
    local sanitized_string

    # Remove leading/trailing whitespace
    sanitized_string=$(echo "$input_string" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

    # Handle specific problematic characters for filenames more carefully
    # Added colon removal, which is important for macOS/Windows compatibility in paths
    sanitized_string=$(echo "$sanitized_string" | sed \
        -e 's/|/—/g' \
        -e 's/&/ and /g' \
        -e 's/"//g' \
        -e "s/'//g" \
        -e 's/://g' \
        -e 's/[\/\\]/ /g' \
        -e 's/[*]/ /g' \
        -e 's/?/ /g' \
        -e 's/</ /g' \
        -e 's/>/ /g' )

    # Replace multiple spaces with a single space
    sanitized_string=$(echo "$sanitized_string" | tr -s ' ')

    # Remove trailing dots and spaces (bash 3.2 compatible)
    # shellcheck disable=SC2001
    sanitized_string=$(echo "$sanitized_string" | sed 's/[. ]*$//')
    # Remove leading dots and spaces (bash 3.2 compatible)
    # shellcheck disable=SC2001
    sanitized_string=$(echo "$sanitized_string" | sed 's/^[. ]*//')

    # If, after all this, the string is empty, use the default
    if [[ -z "$sanitized_string" ]]; then
        sanitized_string="$default_string"
    fi

    echo "$sanitized_string"
}

# Function to determine media category (Movies/Shows) from item name.
# Defaults to "Movies" if not identified as a "Show".
# Arguments:
#   $1: item_name (basename of the torrent download or file)
# Returns: "Movies" or "Shows" via echo
determine_media_category() {
    local item_name_to_check="$1"
    local determined_category="Movies" # Default to Movies

    # --- Regex for TV Shows ---
    # Check for SxxExx, Season xx, Episode xx, Part xx, Series, Show, Season Pack
    # This regex is crucial for differentiating shows.
    if echo "$item_name_to_check" | grep -qE -i \
        '([Ss]([0-9]{1,3})[._ ]?[EeXx]([0-9]{1,4}))|([Ss]eason[._ ]?([0-9]{1,3}))|([Ee]pisode[._ ]?([0-9]{1,4}))|\b(Part|Pt)[._ ]?([0-9IVX]+)\b|\b(Series|Show)\b|\b(Season[._ ]Pack)\b'; then
        determined_category="Shows"
    fi

    echo "$determined_category"
}


# Function to extract and sanitize show information.
# Arguments:
#   $1: Filename or item name
# Returns: SanitizedShowTitle::Year::sXXeYY (Year can be empty)
extract_and_sanitize_show_info() {
    local original_name="$1"
    local raw_title_part=""
    local show_title=""
    local year="" # Year is still useful for Show folder naming, e.g. "Show Title (2023)"
    local season_episode_str="" # Will be sXXeYY (lowercase)
    local s_num_padded=""
    local e_num_padded=""

    # Use user-configurable tag blacklist, fallback to default if not set
    local tag_regex="${MEDIA_TAG_BLACKLIST:-1080p|720p|480p|2160p|WEB[- ]?DL|WEBRip|BluRay|BRRip|HDRip|DDP5?\\.1|AAC|AC3|x265|x264|HEVC|H\\.264|H\\.265|REMUX|NeoNoir}"
    local release_group_regex='-[a-zA-Z0-9]+$' # e.g. -GROUPNAME, common in scene releases

    # --- Extract Season/Episode using Bash Regex ---
    local se_regex_pattern_strict='[Ss]([0-9]{1,3})[._ ]?[EeXx]([0-9]{1,4})' 
    local se_match_full="" 

    if [[ "$original_name" =~ $se_regex_pattern_strict ]]; then
        se_match_full="${BASH_REMATCH[0]}"
        local season_match="${BASH_REMATCH[1]}"
        local episode_match="${BASH_REMATCH[2]}" 

        # The part before the S/E match is likely the show title (and potentially year)
        raw_title_part="${original_name%%"${se_match_full}"*}"
        # Episode title extraction logic remains removed as per previous state

        if [[ -n "$season_match" && -n "$episode_match" ]]; then
            # Remove leading zeros before printf to avoid octal interpretation if season_match is e.g. "08"
            s_num_padded=$(printf "%02d" $((10#$season_match))) # Force base 10
            e_num_padded=$(printf "%02d" $((10#$episode_match))) # Force base 10
            season_episode_str="s${s_num_padded}e${e_num_padded}" 
        else
            season_episode_str="" # Should not happen if BASH_REMATCH[0] was set
        fi
    else
        # If no S/E pattern, the whole name (minus extension) is the raw title part for now
        # This case is less likely if determine_media_category already classified it as a show
        raw_title_part=$(echo "$original_name" | sed -E 's/\.[^.]{2,4}$//') # Remove common extensions
        season_episode_str=""
    fi
    # --- End S/E Extraction ---

    # --- Clean the Raw Title Part (Show Title) ---
    # Remove www.domain.com - prefixes
    show_title=$(echo "$raw_title_part" | sed -E 's/^[[:space:]]*[wW][wW][wW]\.[^[:space:]]+[[:space:]]*-*[[:space:]]*//') 
    # Remove release group suffix if present
    show_title=$(echo "$show_title" | sed -E "s/${release_group_regex}//")
    show_title_lower=$(echo "$show_title" | tr '[:upper:]' '[:lower:]')
    show_title=$(echo "$show_title_lower" | sed -E \
        -e 's/^[\[\(][^\]\)]*[\]\)]//g' \
        -e 's/[\[\(][^\]\)]*[\]\)]$//g' \
        -e "s/${tag_regex}//gI" \
        -e 's/[._-]/ /g' \
        | tr -s ' ' \
        | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
    )
    # --- End Show Title Cleaning ---

    # --- Extract Year from Cleaned Show Title (Year is often part of a show's identity) ---
    local year_regex='^(.*)[[:space:]]([12][90][0-9]{2})$' # Year at the very end of the string
    if [[ "$show_title" =~ $year_regex ]]; then
        local potential_title_part="${BASH_REMATCH[1]}"
        local potential_year="${BASH_REMATCH[2]}"
        # Avoid mistaking a year if it's preceded by a season number, e.g. "Show Title S01 2023"
        local season_keyword_regex_at_end='(s[0-9]+|season[._ ]?[0-9]+)$'
        if ! [[ "$potential_title_part" =~ $season_keyword_regex_at_end ]] && [[ ${#potential_title_part} -gt 2 ]]; then
            show_title="$potential_title_part" # Update show_title to be part before year
            year="$potential_year"
        fi
    fi
    # --- End Year Extraction ---

    # --- Final Formatting and Fallbacks for Show Title ---
    # Capitalize each word
    show_title=$(echo "$show_title" | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2)); print}')
    show_title=$(sanitize_filename "$show_title" "Unknown Show") # Sanitize the final title

    # Fallback if title is "Unknown Show" but S/E was found (try to get title from original again)
    if [[ "$show_title" == "Unknown Show" && -n "$season_episode_str" ]]; then
        local potential_title_from_original
        # Try to grab everything before the strict S/E pattern in the original name
        if [[ "$original_name" =~ ^(.*)${se_regex_pattern_strict} ]]; then
             potential_title_from_original="${BASH_REMATCH[1]}"
             potential_title_from_original=$(echo "$potential_title_from_original" | sed -E 's/^[[:space:]]*[wW][wW][wW]\.[^[:space:]]+[[:space:]]*-*[[:space:]]*//')
             potential_title_from_original=$(echo "$potential_title_from_original" | sed -E "s/${release_group_regex}//")
             potential_title_from_original=$(echo "$potential_title_from_original" | sed -e 's/[._-]/ /g' | tr -s ' ' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2)); print}' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
             
             if [[ -n "$potential_title_from_original" ]]; then
                 show_title=$(sanitize_filename "$potential_title_from_original" "Unknown Show")
                 # Re-check for year in this fallback title
                 if [[ "$show_title" =~ $year_regex ]]; then 
                     local pt="${BASH_REMATCH[1]}"; local py="${BASH_REMATCH[2]}"
                     local sk_regex_end='(s[0-9]+|season[._ ]?[0-9]+)$'
                     if ! [[ "$pt" =~ $sk_regex_end ]] && [[ ${#pt} -gt 2 ]]; then
                         show_title="$pt"; # Update title
                         year="$py";    # Update year
                     fi
                 else
                     year="" # Clear year if not found in this fallback title
                 fi
             fi
        fi
    fi
    
    # Debug what's being returned
    if [[ "${SCRIPT_CURRENT_LOG_LEVEL:-1}" -le "$LOG_LEVEL_DEBUG" ]]; then
        log_debug_event "MEDIA_UTILS" "Before return: Title='$show_title', Year='$year', SE='$season_episode_str' from '$original_name'"
    fi
    
    # Then modify the return line to explicitly handle empty values better:
    if [[ -z "$show_title" || "$show_title" == "Unknown Show" ]]; then
        # Extract a basic title from the original name if we couldn't parse one
        show_title=$(echo "$original_name" | sed -E 's/\.S[0-9]+E[0-9]+.*//' | sed 's/\./ /g' | xargs)
        show_title=$(echo "$show_title" | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2)); print}')
        log_debug_event "MEDIA_UTILS" "Used fallback title extraction: '$show_title'"
    fi
    
    # Special handling for "Name.SxxExx" format (common in scene releases)
    if [[ -z "$show_title" || "$show_title" == "Unknown Show" ]]; then
        if [[ "$original_name" =~ ^([A-Za-z0-9]+)\.([Ss][0-9]{2}[Ee][0-9]{2}) ]]; then
            # Direct extraction for "Name.S01E04" pattern, preserve original casing
            show_name_raw="${BASH_REMATCH[1]}"
            # Don't split CamelCase, just keep original name (MobLand stays MobLand)
            show_title="$show_name_raw"
            log_debug_event "MEDIA_UTILS" "Applied special handler for 'Name.SxxExx' format: '$show_title'"
        fi
    fi

    # Ensure clean format for the output
    if [[ -z "$show_title" || "$show_title" == "Unknown Show" ]]; then
        log_debug_event "MEDIA_UTILS" "WARNING: Title extraction failed entirely for '$original_name'"
    fi
    
    # Debug the exact string we're returning
    log_debug_event "MEDIA_UTILS" "Returning formatted string with values - Title: '$show_title', Year: '$year', SE: '$season_episode_str'"
    
    # Debug the exact formatted string
    formatted_string="${show_title:-Unknown Show}###${year:-NOYEAR}###${season_episode_str}"
    log_debug_event "MEDIA_UTILS" "Final output string: '$formatted_string'"
    
    # Return with a different delimiter that won't be confused with shell pipes
    echo "$formatted_string"
}


# Function to extract and sanitize movie information.
# Improved movie info extraction for filenames like:
#   A.Minecraft.Movie.2025.1080p.WEB-DL.DDP5.1.x265-NeoNoir.mkv -> A Minecraft Movie (2025)
extract_and_sanitize_movie_info() {
    local filename="$1"
    local name_no_ext="${filename%.*}"
    # 1. Replace dots/underscores with spaces
    local name_spaced="${name_no_ext//[._]/ }"
    
    # Use user-configurable tag blacklist, fallback to default if not set
    local tag_regex="${MEDIA_TAG_BLACKLIST:-1080p|720p|480p|2160p|WEB[- ]?DL|WEBRip|BluRay|BRRip|HDRip|DDP5?\\.1|AAC|AC3|x265|x264|HEVC|H\\.264|H\\.265|REMUX|NeoNoir}"
    
    # Remove known media tags first to clean up the string
    local cleaned_name
    cleaned_name=$(echo "$name_spaced" | sed -E "s/ ?($tag_regex)( |$)/ /gI" | tr -s ' ')
    
    # 2. Extract year (rightmost 4-digit number that looks like a year)
    local year=""
    # Find the last occurrence of a year pattern
    if [[ $cleaned_name =~ .*(^|[^0-9])([12][0-9]{3})($|[^0-9]) ]]; then
        year="${BASH_REMATCH[2]}"
        
        # Remove the year from the title part
        # Use parameter expansion for a cleaner approach - split on year and take first part
        local title_before_year="${cleaned_name%"$year"*}"
        local title_after_year="${cleaned_name#*"$year"}"
        
        # Check if anything substantial remains after the year
        # If substantial text remains after the year, it's likely part of the title, not a release year
        if [[ ${#title_after_year} -gt 15 ]]; then
            # Just use cleaned name with tags removed
            title_part="$cleaned_name"
            year="" # Don't assume this is the release year
        else
            # This is likely the correct release year, use just the part before
            title_part="$title_before_year"
        fi
    else
        # No year found
        title_part="$cleaned_name"
    fi
    
    # Remove trailing/leading spaces
    title_part="$(echo "$title_part" | sed -E 's/^ +| +$//g')"
    
    # Capitalize first letter of each word
    title_part="$(echo "$title_part" | awk '{for(i=1;i<=NF;i++){$i=toupper(substr($i,1,1)) tolower(substr($i,2))}}1')"
    
    # Format as 'Title (Year)' if year found
    if [[ -n "$year" ]]; then
        echo "$title_part ($year)"
    else
        echo "$title_part"
    fi
}

