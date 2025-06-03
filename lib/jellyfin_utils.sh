#!/bin/bash

# lib/jellyfin_utils.sh
# Contains utility functions for interacting with Jellyfin.
# Assumes log_info_event() and log_error_event() are defined from logging_utils.sh.
# Assumes JELLYFIN_SERVER, JELLYFIN_API_KEY are available from sourced config.
# Assumes 'curl' is available (checked by health check in main script).

#==============================================================================
# JELLYFIN API INTEGRATION FUNCTIONS
#==============================================================================

# Function: trigger_jellyfin_library_scan
# Description: Triggers a library refresh scan on the configured Jellyfin server
# Parameters:
#   $1 - Item category (e.g., "Movies", "Shows", "YouTube") for logging purposes
# Returns:
#   0 - Library scan triggered successfully
#   1 - Failure (missing config, network error, or HTTP error response)
# Side Effects: Makes HTTP POST request to Jellyfin API, logs results
trigger_jellyfin_library_scan() {
    local item_category_for_log="$1"
    local http_status_code
    local curl_exit_status

    # Ensure essential variables are set
    if [[ -z "$JELLYFIN_SERVER" ]]; then
        log_error_event "Jellyfin" "JELLYFIN_SERVER is not set. Cannot trigger scan."
        return 1
    fi
    if [[ -z "$JELLYFIN_API_KEY" ]]; then
        log_error_event "Jellyfin" "JELLYFIN_API_KEY is not set. Cannot trigger scan."
        return 1
    fi

    # Ensure curl is available (this is a good defensive check within the util itself)
    if ! command -v curl &>/dev/null; then
        log_error_event "Jellyfin" "'curl' command not found. Cannot trigger scan."
        return 1
    fi

    log_user_progress "Jellyfin" "📺 Scanning $item_category_for_log library..."
    log_debug_event "Jellyfin" "HTTP POST to $JELLYFIN_SERVER/Library/Refresh for $item_category_for_log"

    # The /Library/Refresh endpoint typically does not require a request body for a general scan.
    # -s: Silent mode
    # -w "%{http_code}": Write out the HTTP status code
    # -o /dev/null: Discard the actual response body
    # -X POST: HTTP POST request
    # -H "X-Emby-Token: $JELLYFIN_API_KEY": Use header-based authentication
    # --connect-timeout 10: Timeout for connection establishment
    # --max-time 30: Maximum time for the whole operation
    
    set +e # Temporarily disable exit on error to capture curl's exit status
    http_status_code=$(curl -s -w "%{http_code}" -o /dev/null \
        -X POST \
        -H "X-Emby-Token: $JELLYFIN_API_KEY" \
        --connect-timeout 10 \
        --max-time 30 \
        "$JELLYFIN_SERVER/Library/Refresh")
    curl_exit_status=$?
    set -e # Re-enable exit on error

    if [[ "$curl_exit_status" -ne 0 ]]; then
        log_error_event "Jellyfin" "❌ curl command failed to execute for '$item_category_for_log'. Exit code: $curl_exit_status. Check network or JELLYFIN_SERVER address."
        return 1
    fi

    log_debug_event "Jellyfin" "Received HTTP $http_status_code from Jellyfin API"

    case "$http_status_code" in
        "204")
            log_user_complete "Jellyfin" "📺 Library scan complete"
            return 0
            ;;
        "400")
            log_error_event "Jellyfin" "❌ Failed to trigger library scan for '$item_category_for_log'. Server responded with HTTP $http_status_code Bad Request."
            ;;
        "401")
            log_error_event "Jellyfin" "❌ Failed to trigger library scan for '$item_category_for_log'. Server responded with HTTP $http_status_code Unauthorized. Check JELLYFIN_API_KEY."
            ;;
        "403")
            log_error_event "Jellyfin" "❌ Failed to trigger library scan for '$item_category_for_log'. Server responded with HTTP $http_status_code Forbidden. API key may lack permissions."
            ;;
        "404")
            log_error_event "Jellyfin" "❌ Failed to trigger library scan for '$item_category_for_log'. Server responded with HTTP $http_status_code Not Found. Ensure the Jellyfin API endpoint ('$JELLYFIN_SERVER/Library/Refresh') is correct."
            ;;
        "500")
            log_error_event "Jellyfin" "❌ Failed to trigger library scan for '$item_category_for_log'. Server responded with HTTP $http_status_code Internal Server Error. Check Jellyfin server logs."
            ;;
        *)
            if [[ "$http_status_code" =~ ^2[0-9]{2}$ ]]; then # Other 2xx success codes
                 log_user_info "Jellyfin" "Jellyfin Library scan triggered successfully"
                 return 0
            elif [[ "$http_status_code" =~ ^[45][0-9]{2}$ ]]; then # Other 4xx or 5xx error codes
                 log_error_event "Jellyfin" "❌ Failed to trigger library scan for '$item_category_for_log'. Server responded with unexpected error HTTP $http_status_code."
            else 
                 log_error_event "Jellyfin" "❌ Failed to trigger library scan for '$item_category_for_log'. Received unusual HTTP status: '$http_status_code'. Check connection and server health."
            fi
            ;;
    esac
    return 1 # Indicate failure if not explicitly returned 0
}
