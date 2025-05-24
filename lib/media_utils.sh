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
# Returns: SanitizedShowTitle###Year###sXXeYY (Year can be empty or "NOYEAR")
extract_and_sanitize_show_info() {
    local original_name="$1"
    local raw_title_part=""
    local show_title=""
    local year="" 
    local season_episode_str="" 
    local s_num_padded=""
    local e_num_padded=""

    # Use user-configurable tag blacklist, fallback to default if not set
    local tag_regex="${MEDIA_TAG_BLACKLIST:-1080p|720p|480p|2160p|WEB[- ]?DL|WEBRip|BluRay|BRRip|HDRip|DDP5?\\.1|AAC|AC3|x265|x264|HEVC|H\\.264|H\\.265|REMUX|NeoNoir}"
    local release_group_regex='-[a-zA-Z0-9]+$' 

    local se_regex_pattern_strict='[Ss]([0-9]{1,3})[._ ]?[EeXx]([0-9]{1,4})' 
    local se_match_full="" 

    if [[ "$original_name" =~ $se_regex_pattern_strict ]]; then
        se_match_full="${BASH_REMATCH[0]}"
        local season_match="${BASH_REMATCH[1]}"
        local episode_match="${BASH_REMATCH[2]}" 

        raw_title_part="${original_name%%"${se_match_full}"*}"
        
        if [[ -n "$season_match" && -n "$episode_match" ]]; then
            s_num_padded=$(printf "%02d" $((10#$season_match))) 
            e_num_padded=$(printf "%02d" $((10#$episode_match))) 
            season_episode_str="s${s_num_padded}e${e_num_padded}" 
        else
            season_episode_str="" 
        fi
    else
        raw_title_part=$(echo "$original_name" | sed -E 's/\.[^.]{2,4}$//') 
        season_episode_str=""
    fi

    show_title=$(echo "$raw_title_part" | sed -E 's/^[[:space:]]*[wW][wW][wW]\.[^[:space:]]+[[:space:]]*-*[[:space:]]*//') 
    show_title=$(echo "$show_title" | sed -E "s/${release_group_regex}//")
    # Convert to lowercase before applying tag regex for case-insensitivity with sed -E 's///gI'
    # and before general cleaning.
    show_title_lower=$(echo "$show_title" | tr '[:upper:]' '[:lower:]')
    show_title=$(echo "$show_title_lower" | sed -E \
        -e 's/^[\[\(][^\]\)]*[\]\)]//g' \
        -e 's/[\[\(][^\]\)]*[\]\)]$//g' \
        -e "s/${tag_regex}//gI" \
        -e 's/[._-]/ /g' \
        | tr -s ' ' \
        | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
    )

    local year_regex='^(.*)[[:space:]]([12][90][0-9]{2})$' 
    if [[ "$show_title" =~ $year_regex ]]; then
        local potential_title_part="${BASH_REMATCH[1]}"
        local potential_year="${BASH_REMATCH[2]}"
        local season_keyword_regex_at_end='(s[0-9]+|season[._ ]?[0-9]+)$'
        if ! [[ "$potential_title_part" =~ $season_keyword_regex_at_end ]] && [[ ${#potential_title_part} -gt 2 ]]; then
            show_title="$potential_title_part" 
            year="$potential_year"
        fi
    fi

    show_title=$(echo "$show_title" | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2)); print}')
    show_title=$(sanitize_filename "$show_title" "Unknown Show") 

    if [[ "$show_title" == "Unknown Show" && -n "$season_episode_str" ]]; then
        local potential_title_from_original
        if [[ "$original_name" =~ ^(.*)${se_regex_pattern_strict} ]]; then
             potential_title_from_original="${BASH_REMATCH[1]}"
             potential_title_from_original=$(echo "$potential_title_from_original" | sed -E 's/^[[:space:]]*[wW][wW][wW]\.[^[:space:]]+[[:space:]]*-*[[:space:]]*//')
             potential_title_from_original=$(echo "$potential_title_from_original" | sed -E "s/${release_group_regex}//")
             potential_title_from_original=$(echo "$potential_title_from_original" | sed -e 's/[._-]/ /g' | tr -s ' ' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2)); print}' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
             
             if [[ -n "$potential_title_from_original" ]]; then
                 show_title=$(sanitize_filename "$potential_title_from_original" "Unknown Show")
                 if [[ "$show_title" =~ $year_regex ]]; then 
                     local pt="${BASH_REMATCH[1]}"; local py="${BASH_REMATCH[2]}"
                     local sk_regex_end='(s[0-9]+|season[._ ]?[0-9]+)$'
                     if ! [[ "$pt" =~ $sk_regex_end ]] && [[ ${#pt} -gt 2 ]]; then
                         show_title="$pt"; 
                         year="$py";    
                     fi
                 else
                     year="" 
                 fi
             fi
        fi
    fi
    
    if [[ -z "$show_title" || "$show_title" == "Unknown Show" ]]; then
        if [[ "$original_name" =~ ^([A-Za-z0-9]+)\.([Ss][0-9]{2}[Ee][0-9]{2}) ]]; then
            show_name_raw="${BASH_REMATCH[1]}"
            show_title="$show_name_raw"
        elif [[ -n "$season_episode_str" ]]; then # If S/E found but title is still unknown
            # Fallback: use original name part before S/E, minimal cleaning
            show_title_fallback="${original_name%%"${se_match_full}"*}"
            show_title_fallback=$(echo "$show_title_fallback" | sed -e 's/[._]/ /g' | tr -s ' ' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2)); print}' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
            if [[ -n "$show_title_fallback" ]]; then
                show_title=$(sanitize_filename "$show_title_fallback" "Unknown Show")
                # Attempt to extract year from this fallback title
                if [[ "$show_title" =~ $year_regex ]]; then
                    local pt_fb="${BASH_REMATCH[1]}"; local py_fb="${BASH_REMATCH[2]}"
                    local sk_regex_end_fb='(s[0-9]+|season[._ ]?[0-9]+)$'
                    if ! [[ "$pt_fb" =~ $sk_regex_end_fb ]] && [[ ${#pt_fb} -gt 2 ]]; then
                        show_title="$pt_fb";
                        year="$py_fb";
                    fi
                fi
            fi
        fi
    fi
    
    # Debug logging for show info extraction (if debug level is enabled)
    log_debug_event "Media" "extract_and_sanitize_show_info: Title='$show_title', Year='$year', SE='$season_episode_str' (from '$original_name')"
    
    local formatted_string="${show_title:-Unknown Show}###${year:-NOYEAR}###${season_episode_str}"
    
    log_debug_event "Media" "extract_and_sanitize_show_info: Final output string: '$formatted_string'"
    
    echo "$formatted_string"
}


# Function to extract and sanitize movie information.
# Improved movie info extraction for filenames like:
#   A.Minecraft.Movie.2025.1080p.WEB-DL.DDP5.1.x265-NeoNoir.mkv -> A Minecraft Movie (2025)
extract_and_sanitize_movie_info() {
    local filename="$1"
    local name_no_ext="${filename%.*}"
    local name_spaced="${name_no_ext//[._]/ }"
    
    local tag_regex="${MEDIA_TAG_BLACKLIST:-1080p|720p|480p|2160p|WEB[- ]?DL|WEBRip|BluRay|BRRip|HDRip|DDP5?\\.1|AAC|AC3|x265|x264|HEVC|H\\.264|H\\.265|REMUX|NeoNoir}"
    
    local cleaned_name
    cleaned_name=$(echo "$name_spaced" | sed -E "s/ ?($tag_regex)( |$)/ /gI" | tr -s ' ')
    
    local year=""
    if [[ $cleaned_name =~ .*(^|[^0-9])([12][0-9]{3})($|[^0-9]) ]]; then
        year="${BASH_REMATCH[2]}"
        
        local title_before_year="${cleaned_name%"$year"*}"
        local title_after_year="${cleaned_name#*"$year"}"
        
        if [[ ${#title_after_year} -gt 15 ]]; then
            title_part="$cleaned_name"
            year="" 
        else
            title_part="$title_before_year"
        fi
    else
        title_part="$cleaned_name"
    fi
    
    title_part="$(echo "$title_part" | sed -E 's/^ +| +$//g')"
    
    title_part="$(echo "$title_part" | awk '{for(i=1;i<=NF;i++){$i=toupper(substr($i,1,1)) tolower(substr($i,2))}}1')"
    
    if [[ -n "$year" ]]; then
        echo "$title_part ($year)"
    else
        echo "$title_part"
    fi
}
