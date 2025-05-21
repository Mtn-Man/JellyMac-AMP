#!/bin/bash

# lib/jellyfin_utils.sh
# Contains utility functions for interacting with Jellyfin.
# Assumes log_info_event() and log_error_event() are defined from logging_utils.sh.
# Assumes JELLYFIN_SERVER, JELLYFIN_API_KEY are available from sourced config.
# Assumes 'curl' is available (checked by health check in main script).

# Trigger Jellyfin library scan function
# Arguments:
#   $1: Item category (e.g., "Movies", "Shows", "YouTube") for logging
trigger_jellyfin_library_scan() {
    local item_category_for_log="$1"
    local http_status_code
    local curl_exit_status
    local log_prefix_jellyfin="JELLYFIN_UTILS" # Define a prefix for this utility

    # Ensure essential variables are set
    if [[ -z "$JELLYFIN_SERVER" ]]; then
        log_error_event "$log_prefix_jellyfin" "JELLYFIN_SERVER is not set. Cannot trigger scan."
        return 1
    fi
    if [[ -z "$JELLYFIN_API_KEY" ]]; then
        log_error_event "$log_prefix_jellyfin" "JELLYFIN_API_KEY is not set. Cannot trigger scan."
        return 1
    fi

    # Ensure curl is available (this is a good defensive check within the util itself)
    if ! command -v curl &>/dev/null; then
        log_error_event "$log_prefix_jellyfin" "'curl' command not found. Cannot trigger scan."
        return 1
    fi

    log_info_event "$log_prefix_jellyfin" "Triggering library scan for '$item_category_for_log' on server '$JELLYFIN_SERVER'..."

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
        log_error_event "$log_prefix_jellyfin" "❌ curl command failed to execute for '$item_category_for_log'. Exit code: $curl_exit_status. Check network or JELLYFIN_SERVER address."
        return 1
    fi

    case "$http_status_code" in
        "204")
            log_info_event "$log_prefix_jellyfin" "✅ Library scan triggered successfully for '$item_category_for_log' (HTTP Status: $http_status_code No Content)."
            return 0
            ;;
        "400")
            log_error_event "$log_prefix_jellyfin" "❌ Failed to trigger library scan for '$item_category_for_log'. Server responded with HTTP $http_status_code Bad Request."
            ;;
        "401")
            log_error_event "$log_prefix_jellyfin" "❌ Failed to trigger library scan for '$item_category_for_log'. Server responded with HTTP $http_status_code Unauthorized. Check JELLYFIN_API_KEY."
            ;;
        "403")
            log_error_event "$log_prefix_jellyfin" "❌ Failed to trigger library scan for '$item_category_for_log'. Server responded with HTTP $http_status_code Forbidden. API key may lack permissions."
            ;;
        "404")
            log_error_event "$log_prefix_jellyfin" "❌ Failed to trigger library scan for '$item_category_for_log'. Server responded with HTTP $http_status_code Not Found. Ensure the Jellyfin API endpoint ('$JELLYFIN_SERVER/Library/Refresh') is correct."
            ;;
        "500")
            log_error_event "$log_prefix_jellyfin" "❌ Failed to trigger library scan for '$item_category_for_log'. Server responded with HTTP $http_status_code Internal Server Error. Check Jellyfin server logs."
            ;;
        *)
            if [[ "$http_status_code" =~ ^2[0-9]{2}$ ]]; then # Other 2xx success codes
                 log_info_event "$log_prefix_jellyfin" "✅ Library scan triggered for '$item_category_for_log'. Server responded with HTTP $http_status_code (Success)."
                 return 0
            elif [[ "$http_status_code" =~ ^[45][0-9]{2}$ ]]; then # Other 4xx or 5xx error codes
                 log_error_event "$log_prefix_jellyfin" "❌ Failed to trigger library scan for '$item_category_for_log'. Server responded with unexpected error HTTP $http_status_code."
            else 
                 log_error_event "$log_prefix_jellyfin" "❌ Failed to trigger library scan for '$item_category_for_log'. Received unusual HTTP status: '$http_status_code'. Check connection and server health."
            fi
            ;;
    esac
    return 1 # Indicate failure if not explicitly returned 0
}
