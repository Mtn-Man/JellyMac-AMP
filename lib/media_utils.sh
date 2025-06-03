#!/bin/bash

# lib/media_utils.sh
# Contains utility functions for media file processing,
# including filename parsing, sanitization, and category determination.
# Simplified: Defaults to "Movies", specifically identifies "Shows".

# This script primarily provides functions that return values via echo.
# Logging within these functions should be minimal (e.g., debug logs if necessary),
# allowing the calling script (process_media_item.sh) to handle main logging.

#==============================================================================
# Function: is_valid_media_year
# Description: Validates if a year is within reasonable range for media content
# Checks if the provided year is a 4-digit number within the valid range for media content (1920-2029).
# Parameters: $1: year - Year to validate (4-digit string)
# Returns: 0 if valid, 1 if invalid
#==============================================================================
is_valid_media_year() {
    local year_to_check="$1"
    
    # Check if it's a 4-digit number
    if [[ ! "$year_to_check" =~ ^[0-9]{4}$ ]]; then
        return 1
    fi
    
    # Check if within valid range (1920-2029)
    if [[ "$year_to_check" -ge 1920 && "$year_to_check" -le 2029 ]]; then
        return 0
    else
        return 1
    fi
}

#==============================================================================
# Function: sanitize_filename
# Description: Sanitizes a string for use as a valid filename
# Replaces common problematic characters with underscores or removes them.
# Handles specific characters that cause issues in filenames across different operating systems.
# Parameters: $1: input_string - String to sanitize, $2: default_string - (Optional) Default string if input is empty after sanitization
# Returns: Sanitized string suitable for use as filename
# Dependencies: None
#==============================================================================
sanitize_filename() {
    local input_string="$1"
    local default_string="${2:-sanitized_name}"
    local sanitized_string

    # Remove leading/trailing whitespace
    sanitized_string=$(echo "$input_string" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

    # Handle specific problematic characters for filenames
    # Added colon removal, which is important for macOS/Windows compatibility in paths
    # Using Bash parameter expansion for better performance
    sanitized_string="${sanitized_string//|/—}"
    sanitized_string="${sanitized_string//&/ and }"
    sanitized_string="${sanitized_string//\"/}"
    sanitized_string="${sanitized_string//\'/}"
    sanitized_string="${sanitized_string//:/}"
    sanitized_string="${sanitized_string//\//}"
    sanitized_string="${sanitized_string//\\/}"
    sanitized_string="${sanitized_string//\*/ }"
    sanitized_string="${sanitized_string//\?/ }"
    sanitized_string="${sanitized_string//</}"
    sanitized_string="${sanitized_string//>/}"

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

#==============================================================================
# Function: determine_media_category
# Description: Determines media category (Movies/Shows) from item name
# Defaults to "Movies" if not identified as a "Show". Uses regex patterns to detect TV show indicators like SxxExx, Season xx, Episode xx formats.
# Parameters: $1: item_name - The basename of the torrent download or file
# Returns: "Movies" or "Shows" via echo
# Dependencies: None
#==============================================================================
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


#==============================================================================
# Function: extract_and_sanitize_show_info
# Description: Extracts and sanitizes TV show title, year, and episode info from filename
# Processes TV show filenames to extract clean titles, years, and season/episode information. Handles various naming conventions and removes quality tags and release groups while preserving core show information.
# Example: "Show.Name.S01E05.720p.WEB-DL.mkv" -> "Show Name###2024###s01e05"
# Parameters: $1: original_name - The TV show filename to process
# Returns: Formatted string: "ShowTitle###Year###sXXeYY" (Year can be "NOYEAR")
# Dependencies: sanitize_filename(), is_valid_media_year(), log_debug_event(), MEDIA_TAG_BLACKLIST
#==============================================================================
extract_and_sanitize_show_info() {
    local original_name="$1"
    local raw_title_part=""
    local show_title=""
    local year="" 
    local season_episode_str="" 
    local s_num_padded=""
    local e_num_padded=""

    # Use user-configurable tag blacklist, fallback to default (all lowercase) if not set. Convert to lowercase.
    local config_tag_blacklist="${MEDIA_TAG_BLACKLIST:-1080p|720p|480p|2160p|web[- ]?dl|webrip|bluray|brrip|hdrip|ddp5?\\.1|aac|ac3|x265|x264|hevc|h\\.264|h\\.265|remux|neonoir}" # Default is now lowercase
    local tag_regex
    tag_regex=$(echo "$config_tag_blacklist" | tr '[:upper:]' '[:lower:]')
    
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
        raw_title_part="${original_name%.*}" 
        season_episode_str=""
    fi

    show_title=$(echo "$raw_title_part" | sed -E 's/^[[:space:]]*[wW][wW][wW]\.[^[:space:]]+[[:space:]]*-*[[:space:]]*//') 
    show_title=$(echo "$show_title" | sed -E "s/${release_group_regex}//")
    
    # Convert to lowercase before applying tag regex and general cleaning.
    local show_title_lower
    show_title_lower=$(echo "$show_title" | tr '[:upper:]' '[:lower:]')
    
    show_title=$(echo "$show_title_lower" | sed -E \
        -e 's/^[\[\(][^\]\)]*[\]\)]//g' \
        -e 's/[\[\(][^\]\)]*[\]\)]$//g' \
        -e "s/${tag_regex}//g" \
        -e 's/[._-]/ /g' \
        | tr -s ' ' \
        | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
    )

    local year_regex='^(.*)[[:space:]]([12][90][0-9]{2})$' 
    if [[ "$show_title" =~ $year_regex ]]; then
        local potential_title_part="${BASH_REMATCH[1]}"
        local potential_year="${BASH_REMATCH[2]}"
        local season_keyword_regex_at_end='(s[0-9]+|season[._ ]?[0-9]+)$'
        if ! [[ "$potential_title_part" =~ $season_keyword_regex_at_end ]] && [[ ${#potential_title_part} -gt 2 ]] && is_valid_media_year "$potential_year"; then
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
                     if ! [[ "$pt" =~ $sk_regex_end ]] && [[ ${#pt} -gt 2 ]] && is_valid_media_year "$py"; then
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
            local show_name_raw="${BASH_REMATCH[1]}"
            show_title="$show_name_raw" # This might need further sanitization/title casing
        elif [[ -n "$season_episode_str" ]]; then # If S/E found but title is still unknown
            # Fallback: use original name part before S/E, minimal cleaning
            local show_title_fallback="${original_name%%"${se_match_full}"*}"
            # Replace dots and underscores with spaces using parameter expansion
            show_title_fallback="${show_title_fallback//[._]/ }"
            # Use external commands for complex operations (space collapse, title case, whitespace trim)
            show_title_fallback=$(echo "$show_title_fallback" | tr -s ' ' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2)); print}' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
            if [[ -n "$show_title_fallback" ]]; then
                show_title=$(sanitize_filename "$show_title_fallback" "Unknown Show")
                # Attempt to extract year from this fallback title
                if [[ "$show_title" =~ $year_regex ]]; then
                    local pt_fb="${BASH_REMATCH[1]}"; local py_fb="${BASH_REMATCH[2]}"
                    local sk_regex_end_fb='(s[0-9]+|season[._ ]?[0-9]+)$'
                    if ! [[ "$pt_fb" =~ $sk_regex_end_fb ]] && [[ ${#pt_fb} -gt 2 ]] && is_valid_media_year "$py_fb"; then
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

#==============================================================================
# Function: extract_and_sanitize_movie_info
# Description: Extracts and sanitizes movie title and year from filename
# Processes movie filenames to extract clean titles and years, handling various naming conventions and release formats. Removes quality tags, release groups, and metadata while preserving core title information. Prioritizes parentheses year format but falls back to other year patterns.
# Example: "A.Minecraft.Movie.2025.1080p.WEB-DL.x265-NeoNoir.mkv" -> "A Minecraft Movie (2025)"
# Parameters: $1: filename - The movie filename to process
# Returns: Sanitized movie title with year in parentheses (if valid year found) Format: "Movie Title (YYYY)" or "Movie Title" (if no valid year)
# Dependencies: sanitize_filename(), is_valid_media_year(), log_debug_event(), MEDIA_TAG_BLACKLIST
#==============================================================================
extract_and_sanitize_movie_info() {
    local filename="$1"
    local name_no_ext="${filename%.*}"
    local name_spaced="${name_no_ext//[._]/ }"
    
    log_debug_event "Media" "extract_and_sanitize_movie_info: Starting with filename='$filename'"
    log_debug_event "Media" "extract_and_sanitize_movie_info: After extension removal='$name_no_ext'"
    log_debug_event "Media" "extract_and_sanitize_movie_info: After dot/underscore replacement='$name_spaced'"
    
    # Remove release group at the end (e.g., "- OneHack", "- NeoNoir")
    name_spaced=$(echo "$name_spaced" | sed -E 's/ - [a-zA-Z0-9]+$//g')
    log_debug_event "Media" "extract_and_sanitize_movie_info: After release group removal='$name_spaced'"
    
    # Remove bracketed content like [700MB], [RARBG], etc.
    name_spaced=$(echo "$name_spaced" | sed -E 's/\[[^\]]*\]//g')
    log_debug_event "Media" "extract_and_sanitize_movie_info: After bracketed content removal='$name_spaced'"
    
    # Clean multiple spaces that might result from removals
    name_spaced=$(echo "$name_spaced" | tr -s ' ' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    log_debug_event "Media" "extract_and_sanitize_movie_info: After space cleanup='$name_spaced'"
    
    # Ensure tag_regex is lowercase
    local config_tag_blacklist="${MEDIA_TAG_BLACKLIST:-1080p|720p|480p|2160p|web[- ]?dl|webrip|bluray|brrip|hdrip|ddp5?\\.1|aac|ac3|x265|x264|hevc|h\\.264|h\\.265|remux|neonoir}" # Default is now lowercase
    local tag_regex
    tag_regex=$(echo "$config_tag_blacklist" | tr '[:upper:]' '[:lower:]')
    log_debug_event "Media" "extract_and_sanitize_movie_info: Using (lowercase) tag regex='$tag_regex'"

    # Convert input string to lowercase for matching
    local name_spaced_lower
    name_spaced_lower=$(echo "$name_spaced" | tr '[:upper:]' '[:lower:]')
    log_debug_event "Media" "extract_and_sanitize_movie_info: Lowercase name for tag removal='$name_spaced_lower'"
    
    # Remove quality/encoding tags using lowercase input and lowercase regex
    local cleaned_name_lower # This will be the result after tag removal, in lowercase
    cleaned_name_lower=$(echo "$name_spaced_lower" | sed -E "s/ ($tag_regex)( |$)/ /g" | tr -s ' ') # 'I' flag removed
    log_debug_event "Media" "extract_and_sanitize_movie_info: After tag removal (still lowercase)='$cleaned_name_lower'"

    # Use the lowercase version for subsequent processing, it will be title-cased later.
    local cleaned_name="$cleaned_name_lower"
    
    # STEP 1: Check if year is already in parentheses (like "Thunderbolts (2025)")
    # Note: Year extraction regex should work fine on lowercase 'cleaned_name'
    if [[ $cleaned_name =~ ^(.*[[:space:]])\(([12][0-9]{3})\)(.*)$ ]]; then
        local title_part="${BASH_REMATCH[1]}"
        local year="${BASH_REMATCH[2]}"
        local remaining="${BASH_REMATCH[3]}"
        
        log_debug_event "Media" "extract_and_sanitize_movie_info: Found parentheses year format - title='$title_part', year='$year', remaining='$remaining'"
        
        # If there's minimal content after the year, accept this format
        if [[ ${#remaining} -lt 10 ]]; then
            log_debug_event "Media" "extract_and_sanitize_movie_info: Minimal content after year (${#remaining} chars), accepting format"
            
            # Clean title (which is currently lowercase) and keep the year
            title_part=$(echo "$title_part" | sed -E 's/[[:space:]]*$//')
            # Title casing will happen at the end. For now, sanitize.
            title_part=$(sanitize_filename "$title_part" "Unknown Movie") 
            
            log_debug_event "Media" "extract_and_sanitize_movie_info: Processed title (pre-titlecase)='$title_part'"
            
            # Validate year before returning (title will be cased later)
            if is_valid_media_year "$year"; then
                log_debug_event "Media" "extract_and_sanitize_movie_info: Year '$year' is valid. Title part: '$title_part'. Will be title-cased and returned."
                # Title case before returning
                title_part=$(echo "$title_part" | awk '{for(i=1;i<=NF;i++){$i=toupper(substr($i,1,1)) tolower(substr($i,2))}}1')
                echo "$title_part ($year)"
                return 0
            else
                log_debug_event "Media" "extract_and_sanitize_movie_info: Year '$year' is invalid, continuing to fallback logic"
            fi
        else
            log_debug_event "Media" "extract_and_sanitize_movie_info: Too much content after year (${#remaining} chars), continuing to fallback logic"
        fi
    else
        log_debug_event "Media" "extract_and_sanitize_movie_info: No parentheses year format found, continuing to fallback logic"
    fi
    
    # STEP 3: Fallback to existing logic for other year formats (operates on lowercase 'cleaned_name')
    local year="" # Reset year for fallback logic
    local title_part # This will be assigned based on fallback
    if [[ $cleaned_name =~ .*(^|[^0-9])([12][0-9]{3})($|[^0-9]) ]]; then
        year="${BASH_REMATCH[2]}"
        
        local title_before_year="${cleaned_name%"$year"*}"
        local title_after_year="${cleaned_name#*"$year"}"
        
        log_debug_event "Media" "extract_and_sanitize_movie_info: Found year '$year' in fallback logic"
        log_debug_event "Media" "extract_and_sanitize_movie_info: Title before year='$title_before_year'"
        log_debug_event "Media" "extract_and_sanitize_movie_info: Title after year='$title_after_year' (${#title_after_year} chars)"
        
        if [[ ${#title_after_year} -gt 15 ]]; then
            log_debug_event "Media" "extract_and_sanitize_movie_info: Too much content after year, treating as no year"
            title_part="$cleaned_name" # The full lowercase name without tags
            year="" 
        else
            log_debug_event "Media" "extract_and_sanitize_movie_info: Using title before year"
            title_part="$title_before_year" # Lowercase part before year
        fi
    else
        log_debug_event "Media" "extract_and_sanitize_movie_info: No year found in fallback logic"
        title_part="$cleaned_name" # The full lowercase name without tags
    fi
    
    log_debug_event "Media" "extract_and_sanitize_movie_info: Pre-titlecase/sanitization title_part='$title_part', year='$year'"
    
    # STEP 4: Title case and sanitization
    title_part=$(echo "$title_part" | sed -E 's/^ +| +$//g') # Trim spaces first
    title_part=$(echo "$title_part" | awk '{for(i=1;i<=NF;i++){$i=toupper(substr($i,1,1)) tolower(substr($i,2))}}1')
    title_part=$(sanitize_filename "$title_part" "Unknown Movie")
    
    log_debug_event "Media" "extract_and_sanitize_movie_info: After titlecase/sanitization title_part='$title_part'"
    
    # Final validation and formatting
    if [[ -n "$year" ]]; then
        if is_valid_media_year "$year"; then
            log_debug_event "Media" "extract_and_sanitize_movie_info: Final output with valid year: '$title_part ($year)'"
            echo "$title_part ($year)"
        else
            log_debug_event "Media" "extract_and_sanitize_movie_info: Year '$year' is invalid, final output without year: '$title_part'"
            echo "$title_part"
        fi
    else
        log_debug_event "Media" "extract_and_sanitize_movie_info: No year present, final output: '$title_part'"
        echo "$title_part"
    fi
}
