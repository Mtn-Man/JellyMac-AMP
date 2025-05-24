#!/bin/bash

# lib/logging_utils.sh
# Contains common logging functions for the Media Automator project.

#===============================================================================
# Log Level Definitions
# Description: Numeric representations of log levels. Lower numbers are more verbose.
#===============================================================================
LOG_LEVEL_DEBUG=0
LOG_LEVEL_INFO=1
LOG_LEVEL_WARN=2
LOG_LEVEL_ERROR=3

#===============================================================================
# Global Variable for Script's Current Log Level
# Description: Sets the current log level for the script sourcing this library.
# Parameters: None
# Returns: Defaults to INFO if not set by the calling script.
#===============================================================================
: "${SCRIPT_CURRENT_LOG_LEVEL:=$LOG_LEVEL_INFO}"

#===============================================================================
# Function: _log_event_if_level_met
# Description: Internal helper function to check level and print message.
# Parameters:
#   $1: Required numeric level for this message (e.g., LOG_LEVEL_DEBUG)
#   $2: Prefix string (e.g., emoji or script name)
#   $3: Message string
#   $4: (Optional) Output stream override. If set to ">&1", forces stdout.
# Returns: None
#===============================================================================
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

#===============================================================================
# Function: log_debug_event
# Description: Logs a DEBUG message.
# Parameters:
#   $1: Prefix (e.g., emoji or script name)
#   $2: Message string
# Returns: None
#===============================================================================
log_debug_event() {
    _log_event_if_level_met "$LOG_LEVEL_DEBUG" "🐛 DEBUG: $1" "$2"
}

#===============================================================================
# Function: log_info_event
# Description: Logs an INFO message.
# Parameters:
#   $1: Prefix (e.g., emoji or script name)
#   $2: Message string
# Returns: None
#===============================================================================
log_info_event() {
    _log_event_if_level_met "$LOG_LEVEL_INFO" "$1" "$2"
}

#===============================================================================
# Function: log_warn_event
# Description: Logs a WARN message.
# Parameters:
#   $1: Prefix (e.g., emoji or script name)
#   $2: Message string
# Returns: None
#===============================================================================
log_warn_event() {
    _log_event_if_level_met "$LOG_LEVEL_WARN" "⚠️ WARN: $1" "$2"
}

#===============================================================================
# Function: log_error_event
# Description: Logs an ERROR message.
# Parameters:
#   $1: Prefix (e.g., emoji or script name)
#   $2: Message string
# Returns: None
#===============================================================================
log_error_event() {
    _log_event_if_level_met "$LOG_LEVEL_ERROR" "❌ ERROR: $1" "$2"
}

#===============================================================================
# Function: log_event (DEPRECATED)
# Description: Generic log message function for backward compatibility.
# Parameters:
#   $1: Prefix (e.g., emoji or script name)
#   $2: Message string
# Returns: None
#===============================================================================
log_event() {
    log_info_event "$1" "[DEPRECATED log_event] $2"
}

#===============================================================================
# Function: create_script_loggers
# Description: Creates standardized local logging functions for a script.
# Parameters:
#   $1: Script prefix for log messages (e.g., "[MAGNET_HANDLER]")
#   $2: (Optional) Options string:
#       - "exit_on_error": Makes log_error() exit with code 1
#       - "file_logging": Uses _log_to_file_and_console if available
#       - "custom_names:PREFIX": Uses PREFIX_info instead of log_info, etc.
# Returns: None (creates functions in the caller's scope)
#===============================================================================
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