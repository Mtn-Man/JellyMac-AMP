#!/bin/bash

# lib/logging_utils.sh
# Contains common logging functions for the Media Automator project.

# --- Log Level Definitions ---
# These are numeric representations of log levels.
# Lower numbers are more verbose.
LOG_LEVEL_DEBUG=0
LOG_LEVEL_INFO=1
LOG_LEVEL_WARN=2
LOG_LEVEL_ERROR=3

# --- Global Variable for Script's Current Log Level ---
# This variable should be set by the script sourcing this library,
# typically based on a configuration file (e.g., LOG_LEVEL="INFO").
# It defaults to INFO if not set by the calling script.
# Example: SCRIPT_CURRENT_LOG_LEVEL=$LOG_LEVEL_INFO
: "${SCRIPT_CURRENT_LOG_LEVEL:=$LOG_LEVEL_INFO}"

# --- Leveled Logging Event Functions ---

# _log_event_if_level_met
# Internal helper function to check level and print message.
# Arguments:
#   $1: Required numeric level for this message (e.g., LOG_LEVEL_DEBUG)
#   $2: Prefix string (e.g., emoji or script name)
#   $3: Message string
#   $4: (Optional) Output stream override. If set to ">&1", forces stdout.
#       Otherwise, behavior is determined by the calling function (e.g. log_warn_event sends to stderr).
#       If not provided, default behavior is stderr for DEBUG/INFO/WARN/ERROR for safety.
_log_event_if_level_met() {
    local required_level="$1"
    local prefix="$2"
    local message="$3"
    local output_stream_override="${4}" # Optional override

    if [[ "$SCRIPT_CURRENT_LOG_LEVEL" -le "$required_level" ]]; then
        if [[ "$output_stream_override" == ">&1" ]]; then # Explicitly send to stdout if requested
            echo "$prefix $(date '+%Y-%m-%d %H:%M:%S') - $message"
        else # Default to stderr for all log types unless overridden
            echo "$prefix $(date '+%Y-%m-%d %H:%M:%S') - $message" >&2
        fi
    fi
}

# Log a DEBUG message
# Arguments:
#   $1: Prefix (e.g., emoji or script name)
#   $2: Message string
log_debug_event() {
    # Debug messages go to stderr to avoid interfering with command substitutions.
    _log_event_if_level_met "$LOG_LEVEL_DEBUG" "🐛 DEBUG: $1" "$2"
}

# Log an INFO message
# Arguments:
#   $1: Prefix (e.g., emoji or script name)
#   $2: Message string
log_info_event() {
    # Info messages go to stderr to avoid interfering with command substitutions.
    _log_event_if_level_met "$LOG_LEVEL_INFO" "$1" "$2"
}

# Log a WARN message
# Arguments:
#   $1: Prefix (e.g., emoji or script name)
#   $2: Message string
log_warn_event() {
    # Warnings always go to stderr.
    _log_event_if_level_met "$LOG_LEVEL_WARN" "⚠️ WARN: $1" "$2" # Implicitly to stderr by _log_event_if_level_met default
}

# Log an ERROR message
# Arguments:
#   $1: Prefix (e.g., emoji or script name)
#   $2: Message string
log_error_event() {
    # Errors always go to stderr.
    _log_event_if_level_met "$LOG_LEVEL_ERROR" "❌ ERROR: $1" "$2" # Implicitly to stderr by _log_event_if_level_met default
}

# --- Deprecated Generic Functions (for backward compatibility during transition) ---
# These can be phased out once all scripts are updated to use leveled logging.

# Generic log message function (DEPRECATED - use log_info_event or other leveled functions)
# Arguments:
#   $1: Prefix (e.g., emoji or script name)
#   $2: Message string
log_event() {
    # Calls the updated log_info_event, which now also goes to stderr.
    log_info_event "$1" "[DEPRECATED log_event] $2"
}

# SCRIPT-SPECIFIC LOGGING SETUP HELPERS
#-------------------------------------------------

# Function: create_script_loggers
# Description: Creates standardized local logging functions for a script
# Parameters:
#   $1: Script prefix for log messages (e.g., "[MAGNET_HANDLER]")
#   $2: (Optional) Options string:
#       - "exit_on_error": Makes log_error() exit with code 1
#       - "file_logging": Uses _log_to_file_and_console if available
#       - "custom_names:PREFIX": Uses PREFIX_info instead of log_info, etc.
# Returns: None (creates functions in the caller's scope)
# Side Effects: Defines log_debug(), log_info(), log_warn(), log_error() functions
create_script_loggers() {
    local script_prefix="$1"
    local options="${2:-}"
    local exit_on_error=false
    local custom_name_prefix=""
    
    # Parse options
    if [[ "$options" == *"exit_on_error"* ]]; then
        exit_on_error=true
    fi

    if [[ "$options" == *"custom_names:"* ]]; then
        custom_name_prefix=$(echo "$options" | grep -o 'custom_names:[^[:space:]]*' | cut -d':' -f2)
    fi
    
    # Function name prefixes
    local fn_prefix
    if [[ -n "$custom_name_prefix" ]]; then
        fn_prefix="${custom_name_prefix}_"
    else
        fn_prefix="log_"
    fi
    
    # Create the debug logger
    eval "${fn_prefix}debug() { 
        local msg=\"\$*\"
        log_debug_event \"$script_prefix\" \"\$msg\"; 
    }"
    
    # Create the info logger
    eval "${fn_prefix}info() { 
        local msg=\"\$*\"
        log_info_event \"$script_prefix\" \"\$msg\"; 
    }"
    
    # Create the warning logger
    eval "${fn_prefix}warn() { 
        local msg=\"\$*\"
        log_warn_event \"$script_prefix\" \"\$msg\"; 
    }"
    
    # Create the error logger
    local error_exit_code=""
    if [[ "$exit_on_error" == "true" ]]; then
        error_exit_code="exit 1"
    fi
    
    eval "${fn_prefix}error() { 
        local msg=\"\$*\"
        log_error_event \"$script_prefix\" \"\$msg\"; 
        $error_exit_code
    }"
}