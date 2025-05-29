#!/bin/bash

# lib/doctor_utils.sh
# Contains utility functions specific to the JellyMac.sh watcher script,
# primarily for performing system health checks.
# This script should be sourced by JellyMac.sh AFTER
# logging_utils.sh, combined.conf.sh, and common_utils.sh have been sourced,
# and SCRIPT_CURRENT_LOG_LEVEL is set.

# Function: install_missing_dependency
# Description: Checks if homebrew is available and installs missing dependencies
# Parameters:
#   $1: Package name to install
# Returns: 0 if dependency was installed, 1 if not
# Side Effects: May modify system by installing packages
install_missing_dependency() {
    local package_name="$1"
    local log_prefix="Doctor"
    
    # Early exit if auto-installation is disabled
    if [[ "${AUTO_INSTALL_DEPENDENCIES:-false}" != "true" ]]; then
        log_debug_event "$log_prefix" "Auto-install is disabled. Set AUTO_INSTALL_DEPENDENCIES=true in config to enable."
        return 1
    fi
    
    # Check if Homebrew is installed
    if ! command -v brew >/dev/null 2>&1; then
        log_warn_event "$log_prefix" "Homebrew not found. Cannot auto-install programs."
        log_warn_event "$log_prefix" "Please install Homebrew from https://brew.sh/ to enable auto-installation."
        return 1
    fi
    
    log_user_info "$log_prefix" "🍺 Auto-installing program: $package_name"
    
    # Attempt to install the package
    if brew install "$package_name"; then
        log_user_info "$log_prefix" "✅ Successfully installed: $package_name"
        return 0
    else
        log_error_event "$log_prefix" "❌ Failed to install: $package_name"
        return 1
    fi
}

# Define required dependencies for the application
# These will be checked during system health checks
REQUIRED_DEPENDENCIES=(
    "flock"
    "rsync"
    "curl"
)

# Define optional dependencies based on features enabled in config
# Will be populated during runtime in collect_missing_dependencies

# Function: install_missing_dependencies
# Description: Installs multiple missing dependencies at once
# Parameters:
#   $@: Array of package names to install
# Returns: 0 if all dependencies were installed, 1 if any failed
# Side Effects: May modify system by installing packages
install_missing_dependencies() {
    local deps=("$@")
    local all_succeeded=true
    
    for dep in "${deps[@]}"; do
        if ! install_missing_dependency "$dep"; then
            all_succeeded=false
        fi
    done
    
    if [[ "$all_succeeded" == "true" ]]; then
        return 0
    else
        return 1
    fi
}

# Function: collect_missing_dependencies
# Description: Gathers a list of all missing dependencies based on enabled features
# Parameters: None
# Returns: Echoes names of missing dependencies, one per line
# Side Effects: None
collect_missing_dependencies() {
    local missing_deps=()
    local log_prefix="Doctor" # Added for consistency if any logging is needed here
    
    # Check core dependencies
    for dep in "${REQUIRED_DEPENDENCIES[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            missing_deps[${#missing_deps[@]}]="$dep"
        fi
    done
    
    # Check feature-specific dependencies
    if [[ "${ENABLE_CLIPBOARD_YOUTUBE:-false}" == "true" ]]; then
        if ! command -v "yt-dlp" >/dev/null 2>&1; then
            missing_deps[${#missing_deps[@]}]="yt-dlp"
        fi
        # Add ffmpeg as a dependency if YouTube downloads are enabled
        if ! command -v "ffmpeg" >/dev/null 2>&1; then
            missing_deps[${#missing_deps[@]}]="ffmpeg"
        fi
    fi
    
    if [[ "${ENABLE_TORRENT_AUTOMATION:-false}" == "true" ]]; then
        local torrent_client_exe
        torrent_client_exe=$(basename "${TORRENT_CLIENT_CLI_PATH:-transmission-remote}")
        
        if [[ ! -x "${TORRENT_CLIENT_CLI_PATH:-}" ]] && ! command -v "$torrent_client_exe" >/dev/null 2>&1; then
            missing_deps[${#missing_deps[@]}]="transmission-cli"
        fi
    fi
    
    # Return the collected missing dependencies
    for dep in "${missing_deps[@]}"; do
        echo "$dep"
    done
}

# Function: handle_missing_dependencies_interactively
# Description: Presents user with options for installing missing dependencies
# Parameters:
#   $@: Array of missing dependency names
# Returns: 0 on success, 1 on failure or user chose to exit
# Side Effects: May modify system by installing packages or updating config
handle_missing_dependencies_interactively() {
    local missing_deps=("$@")
    local missing_count=${#missing_deps[@]}
    local log_prefix="Doctor" # Define log_prefix for this function

    if [[ $missing_count -eq 0 ]]; then
        return 0  # No missing dependencies
    fi
    
    # Clear screen for better presentation
    clear
    
    # Print welcome header with colorful border
    echo -e "\033[36m+--------------------------------------------------------+\033[0m"
    echo -e "\033[36m|\033[0m       \033[1m\033[33mWelcome to JellyMac AMP - First Time Setup\033[0m       \033[36m|\033[0m"
    echo -e "\033[36m+--------------------------------------------------------+\033[0m"
    echo
    echo -e "\033[1mWe noticed this is your first time running JellyMac AMP.\033[0m"
    echo "Before we can start automating your media library, we need to set up a few things."
    echo
    echo -e "\033[33mMissing Programs:\033[0m"
    
    # Print each missing dependency with package info
    for ((i=0; i<${#missing_deps[@]}; i++)); do
        local dep="${missing_deps[$i]}"
        echo -e "  \033[31m•\033[0m $dep"
    done
    
    echo
    echo "These helper programs are needed for JellyMac AMP to work properly with your media files."
    echo
    
    # Present options
    echo -e "\033[1mHow would you like to proceed?\033[0m"
    echo -e "  \033[32m1)\033[0m Install missing programs now (just this once)"
    echo -e "  \033[32m2)\033[0m Automatically install missing programs in the future (recommended)"
    echo -e "  \033[32m3)\033[0m Skip and continue anyway (some features may not work)"
    echo -e "  \033[32m4)\033[0m Exit and read the Getting Started guide first"
    echo
    
    # Get user input
    local selection
    read -r -p "Select an option [1-4]: " selection
    
    case "$selection" in
        1)  # Install dependencies now (one-time)
            echo -e "\033[1mInstalling programs for this run only...\033[0m"
            AUTO_INSTALL_DEPENDENCIES="true"
            install_missing_dependencies "${missing_deps[@]}"
            local install_status=$?
            AUTO_INSTALL_DEPENDENCIES="false"  # Reset to false after this run
            
            if [[ $install_status -eq 0 ]]; then
                echo
                echo -e "\033[32m✓\033[0m Successfully installed all programs!"
                echo "JellyMac AMP will now continue with startup..."
                echo
                sleep 2
            fi
            
            return $install_status
            ;;
            
        2)  # Enable automatic installation (permanent)
            echo -e "\033[1mEnabling automatic program installation...\033[0m"
            
            # Determine the directory of the currently executing script (doctor_utils.sh)
            local script_dir
            script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
            local config_file="${script_dir}/jellymac_config.sh"
            
            log_user_info "$log_prefix" "Attempting to update config file: '$config_file'"

            if [[ -f "$config_file" && -w "$config_file" ]]; then
                # Create a backup of the config file first
                cp "$config_file" "${config_file}.bak"
                log_user_info "$log_prefix" "Created backup of config file: '${config_file}.bak'"
                
                # Use macOS-compatible sed syntax with a more robust pattern
                local sed_pattern='s/^[[:space:]]*AUTO_INSTALL_DEPENDENCIES[[:space:]]*=[[:space:]]*"false".*/AUTO_INSTALL_DEPENDENCIES="true"/'
                if [[ "$(uname)" == "Darwin" ]]; then
                    sed -i '' "$sed_pattern" "$config_file"
                else
                    # Linux/other systems
                    sed -i "$sed_pattern" "$config_file"
                fi
                
                # Verify that the change was successful
                if grep -q '^[[:space:]]*AUTO_INSTALL_DEPENDENCIES[[:space:]]*=[[:space:]]*"true"' "$config_file"; then
                    log_user_info "$log_prefix" "✅ Config updated: AUTO_INSTALL_DEPENDENCIES set to true in '$config_file'"
                else
                    log_error_event "$log_prefix" "❌ Failed to verify update of AUTO_INSTALL_DEPENDENCIES to true in '$config_file'."
                    log_user_info "$log_prefix" "The line might not have matched or sed command failed. Original setting may persist."
                    # Attempt to proceed with installation as user intended to enable it.
                fi
                echo # For spacing in terminal output
                
                # Try installation with new setting
                AUTO_INSTALL_DEPENDENCIES="true"
                install_missing_dependencies "${missing_deps[@]}"
                local install_status=$?
                
                if [[ $install_status -eq 0 ]]; then
                    echo
                    echo -e "\033[32m✓\033[0m Successfully installed all programs!"
                    echo "JellyMac AMP will now continue with startup..."
                    echo
                    echo "In the future, any missing programs will be installed automatically."
                    sleep 2
                fi
                
                return $install_status
            else
                log_user_info "$log_prefix" "❌ Could not update config file '$config_file'. File not found or not writable."
                log_user_info "$log_prefix" "Please ensure '$config_file' exists, has write permissions, and then set AUTO_INSTALL_DEPENDENCIES=\"true\" manually."
                return 1
            fi
            ;;
            
        3)  # Skip and continue
            log_user_info "$log_prefix" "⚠️  Continuing without required programs. Some features may not work correctly."
            echo "You can install the missing programs later by running:"
            echo "  brew install ${missing_deps[*]}"
            echo
            sleep 2
            return 0
            ;;
            
        4)  # Exit and read guide
            log_user_info "$log_prefix" "Exiting JellyMac AMP setup."
            echo
            echo "To get started, please read the Getting Started guide:"
            echo -e "  \033[36m$JELLYMAC_PROJECT_ROOT/JellyMac_Getting_Started.txt\033[0m"
            echo
            echo "This guide will walk you through:"
            echo "  • Setting up all required programs for JellyMac AMP to work properly"
            echo "  • Configuring your media folders"
            echo "  • Connecting to your Jellyfin server"
            echo "  • And more!"
            echo
            echo "Once you're ready, run ./jellymac.sh again to start the setup."
            echo
            exit 1
            ;;
            
        *)  # Invalid selection
            log_user_info "$log_prefix" "Invalid selection. Exiting."
            exit 1
            ;;
    esac
}

# Improved volume checking function
is_volume_mounted() {
    local path="$1"
    local volume_name
    
    # Extract volume name from path (/Volumes/VOLUMENAME/...)
    if [[ "$path" =~ ^/Volumes/([^/]+) ]]; then
        volume_name="${BASH_REMATCH[1]}"
        if [[ -d "/Volumes/$volume_name" ]]; then
            return 0 # Volume is mounted
        else
            return 1 # Volume is not mounted
        fi
    fi
    
    # Not a /Volumes path
    return 0 
}

# Function: validate_config_filepaths
# Description: Checks if essential directories exist and are writable
# Parameters: None
# Returns:
#   0 if all validations pass
#   1 if any validation fails
# Side Effects: May create directories if AUTO_CREATE_MISSING_DIRS is true

# Main validation function, updated with volume mount checks
validate_config_filepaths() {
    local log_prefix="Doctor"
    log_user_info "$log_prefix" "🔍 Validating configuration filepaths, this may take a moment..."
    local validation_failed=false
    
    # --- Required Directories ---
    # These must exist for the system to function
    local required_dirs=(
        "$DROP_FOLDER"              "Drop folder for media scanning"
        "$DEST_DIR_MOVIES"          "Destination folder for movies"
        "$DEST_DIR_SHOWS"           "Destination folder for TV shows"
        "$ERROR_DIR"                "Error/quarantine folder for problematic files"
    )
    
    # --- Optional Directories ---
    # These can be empty or missing, but if specified must be valid
    local optional_dirs=(
        "${DEST_DIR_YOUTUBE:-}"     "Destination folder for YouTube downloads (optional)"
        "${TEMP_DIR:-}"             "Temporary processing folder (optional)"
    )
    
    # Check each required directory
    for ((i=0; i<${#required_dirs[@]}; i+=2)); do
        local dir="${required_dirs[i]}"
        local description="${required_dirs[i+1]}"
        
        if [[ -z "$dir" ]]; then
            log_error_event "$log_prefix" "❌ Required folder path is empty: $description"
            log_user_info "$log_prefix" "Please set this path in your jellymac_config.sh file."
            validation_failed=true
            continue
        fi
        
        # Check if this is a path on a volume that needs mounting
        if [[ "$dir" == /Volumes/* ]] && ! is_volume_mounted "$dir"; then
            local volume_name
            [[ "$dir" =~ ^/Volumes/([^/]+) ]] && volume_name="${BASH_REMATCH[1]}"
            log_error_event "$log_prefix" "❌ Network folder '$volume_name' is not connected for: $dir ($description)"
            log_user_info "$log_prefix" "To connect: Open Finder → Go menu → Connect to Server (⌘K)"
            log_user_info "$log_prefix" "Or check if '$volume_name' appears in Finder's sidebar under 'Network'."
            validation_failed=true
            continue
        fi
        
        if [[ ! -d "$dir" ]]; then
            # Only attempt to create directories if NOT in /Volumes or if volume is mounted
            if [[ "$dir" != "/Volumes/"* ]] || is_volume_mounted "$dir"; then
                if [[ "${AUTO_CREATE_MISSING_DIRS:-false}" == "true" ]]; then
                    log_warn_event "$log_prefix" "⚠️ Folder does not exist, creating: $dir ($description)"
                    if ! mkdir -p "$dir"; then
                        log_error_event "$log_prefix" "❌ Could not create folder: $dir"
                        if [[ "$dir" == /Volumes/* ]]; then
                            log_user_info "$log_prefix" "This might be due to permission settings on the network folder."
                            log_user_info "$log_prefix" "Try creating the folder manually in Finder first."
                        else
                            log_user_info "$log_prefix" "This might happen if:"
                            log_user_info "$log_prefix" "  • You don't have permission to create folders here"
                            log_user_info "$log_prefix" "  • The parent folder doesn't exist"
                            log_user_info "$log_prefix" "Try creating the folder manually in Finder first."
                        fi
                        validation_failed=true
                    fi
                else
                    log_error_event "$log_prefix" "❌ Folder does not exist: $dir ($description)"
                    log_user_info "$log_prefix" "Create this folder manually in Finder or set AUTO_CREATE_MISSING_DIRS=true in config."
                    validation_failed=true
                fi
            fi
        elif [[ ! -w "$dir" ]]; then
            log_error_event "$log_prefix" "❌ folder is not writable: $dir ($description)"
            log_user_info "$log_prefix" "Please check permissions on this folder."
            validation_failed=true
        fi
    done
    
    # Check each optional directory (only if they're specified)
    for ((i=0; i<${#optional_dirs[@]}; i+=2)); do
        local dir="${optional_dirs[i]}"
        local description="${optional_dirs[i+1]}"
        
        # Skip empty optional paths
        if [[ -z "$dir" ]]; then
            log_debug_event "$log_prefix" "Optional folder not configured: $description"
            continue
        fi
        
        # Check if this is a path on a volume that needs mounting
        if [[ "$dir" == /Volumes/* ]] && ! is_volume_mounted "$dir"; then
            local volume_name
            [[ "$dir" =~ ^/Volumes/([^/]+) ]] && volume_name="${BASH_REMATCH[1]}"
            log_warn_event "$log_prefix" "⚠️ Network folder '$volume_name' is not connected for optional feature: $dir ($description)"
            log_user_info "$log_prefix" "Connect '$volume_name' in Finder if you want to use this feature."
            # Don't mark as failure for optional dirs, just warn
            continue
        fi
        
        if [[ ! -d "$dir" ]]; then
            # Only attempt to create directories if NOT in /Volumes or if volume is mounted
            if ! [[ "$dir" =~ ^/Volumes/ ]] || is_volume_mounted "$dir"; then
                if [[ "${AUTO_CREATE_MISSING_DIRS:-false}" == "true" ]]; then
                    log_warn_event "$log_prefix" "⚠️ Optional folder does not exist, creating: $dir ($description)"
                    if ! mkdir -p "$dir"; then
                        log_error_event "$log_prefix" "❌ Failed to create optional folder: $dir"
                        if [[ "$dir" == /Volumes/* ]]; then
                            log_user_info "$log_prefix" "This may be due to permissions on the network folder. Check the folder's access rights."
                        fi
                        validation_failed=true
                    fi
                else
                    log_warn_event "$log_prefix" "⚠️ Optional folder does not exist: $dir ($description)"
                    log_user_info "$log_prefix" "Create this folder manually or set AUTO_CREATE_MISSING_DIRS=true in config."
                    # Don't mark as failure for optional dirs
                fi
            fi
        elif [[ ! -w "$dir" ]]; then
            log_error_event "$log_prefix" "❌ Optional folder is not writable: $dir ($description)"
            log_user_info "$log_prefix" "Please check permissions on this folder."
            validation_failed=true
        fi
    done
    
    # ... rest of the function remains the same
    
    # Final validation result
    if [[ "$validation_failed" == "true" ]]; then
        log_error_event "$log_prefix" "❌ Configuration validation failed. Please fix the issues above."
        return 1
    else
        log_user_info "$log_prefix" "✅ All configuration filepaths validated successfully."
        return 0
    fi
}

# Function: check_transmission_daemon
# Description: Tests if the Transmission daemon is running and responsive
# Parameters: None
# Returns:
#   0 if daemon is running or magnet handling is disabled
#   1 if daemon is not running and magnet handling is enabled
check_transmission_daemon() {
    local log_prefix="Doctor"
    
    # Skip check if magnet handling is disabled
    if [[ "${ENABLE_CLIPBOARD_MAGNET:-false}" != "true" ]]; then
        return 0
    fi
    
    local transmission_cli="${TORRENT_CLIENT_CLI_PATH:-transmission-remote}"
    local transmission_host="${TRANSMISSION_REMOTE_HOST:-localhost:9091}"
    
    log_debug_event "$log_prefix" "Checking if Transmission background service is running..."
    
    # Try to connect to Transmission daemon
    if ! "$transmission_cli" "$transmission_host" --list >/dev/null 2>&1; then
        log_warn_event "$log_prefix" "⚠️ Transmission background service appears to be offline."
        
        # Verify that transmission is actually installed before offering to enable it
        if command -v transmission-daemon >/dev/null 2>&1 || brew list transmission >/dev/null 2>&1; then
            offer_transmission_service_enablement
            return $?
        else
            log_user_info "$log_prefix" "Transmission not found. Install with: brew install transmission"
            log_user_info "$log_prefix" "Magnet link handling will be unavailable until Transmission is installed and running."
            return 1
        fi
    else
        log_debug_event "$log_prefix" "✅ Transmission background service is running and accessible."
        return 0
    fi
}

# Function: offer_transmission_service_enablement
# Description: Interactively prompts the user to enable Transmission service
# Parameters: None
# Returns:
#   0 if service was successfully started or user declined
#   1 if service failed to start
# Side Effects: May start Transmission service
offer_transmission_service_enablement() {
    local log_prefix="Doctor"
    
    echo
    echo -e "\033[33m⚠️  Transmission background service is not running\033[0m"
    echo "Magnet link handling requires the Transmission background service to be active."
    echo
    echo -e "\033[1mWould you like to enable Transmission as a background service?\033[0m"
    echo "This will allow Transmission to start automatically on login."
    echo
    
    # Get user input
    local response
    read -r -p "Enable Transmission service? (y/n): " response
    
    # Convert to lowercase for easier matching (Bash 3.2 compatible)
    response=$(echo "$response" | tr '[:upper:]' '[:lower:]')
    
    case "$response" in
        y|yes)
            log_user_info "$log_prefix" "🚀 Starting Transmission as a background service..."
            
            # Start the service
            if brew services start transmission; then
                log_user_info "$log_prefix" "✅ Transmission service started successfully"
                echo -e "\033[32m✓\033[0m Transmission service has been started and will run automatically on login."
                echo -e "\033[33m!\033[0m Note: You can manage the service with 'brew services stop transmission' if needed."
                log_user_info "$log_prefix" "Waiting 3 seconds for service to initialize..."
                sleep 3
                
                # Verify it's actually running now
                local transmission_cli="${TORRENT_CLIENT_CLI_PATH:-transmission-remote}"
                local transmission_host="${TRANSMISSION_REMOTE_HOST:-localhost:9091}"
                
                # Give it a moment to fully initialize
                sleep 2
                
                if "$transmission_cli" "$transmission_host" --list >/dev/null 2>&1; then
                    log_user_info "$log_prefix" "✅ Transmission background service is now accessible"
                    log_user_info "" # Add a blank line for spacing
                    log_user_info "$log_prefix" "⚙️ IMPORTANT: Configure Transmission's Download Location!"
                    local web_portal_url="http://${transmission_host}"
                    log_user_info "$log_prefix" "   1. Click this link to open Transmission: ${web_portal_url}"
                    log_user_info "$log_prefix" "   2. Click the hamburger menu (≡) at the top right"
                    log_user_info "$log_prefix" "   3. Select 'Edit Preferences' from the menu"
                    log_user_info "$log_prefix" "   4. In the Downloads section, set Download location to:"
                    log_user_info "$log_prefix" "   ${DROP_FOLDER}"
                    log_user_info "$log_prefix" "   5. When done, you can safely close the Transmission window"
                    log_user_info "$log_prefix" "   This allows JellyMac to automatically process your downloads!"
                    log_user_info "$log_prefix" "   See 'JellyMac_Getting_Started.txt' for advanced options."
                    return 0
                else
                    log_warn_event "$log_prefix" "⚠️ Transmission service started but background service is still not accessible"
                    echo -e "\033[33m⚠️  Transmission service was started but may need more time to initialize\033[0m"
                    echo "Please check its status manually in a few moments."
                    return 1
                fi
            else
                log_error_event "$log_prefix" "❌ Failed to start Transmission service"
                echo -e "\033[31m✗\033[0m Failed to start Transmission service. Please try manually:"
                echo "  brew services start transmission"
                return 1
            fi
            ;;
            
        *)  # Any other input is considered "no"
            log_user_info "$log_prefix" "User declined to start Transmission service"
            log_warn_event "$log_prefix" "⚠️ Magnet link handling will be unavailable until Transmission is running"
            log_user_info "$log_prefix" "You can start it manually later with: brew services start transmission"
            log_user_info "$log_prefix" ""
            log_user_info "$log_prefix" "⚙️ REMINDER: When Transmission is running, configure its download location!"
            local web_portal_url="http://${transmission_host}"
            log_user_info "$log_prefix" "   1. Click this link to open Transmission: ${web_portal_url}"
            log_user_info "$log_prefix" "   2. Click the hamburger menu (≡) at the top right"
            log_user_info "$log_prefix" "   3. Select 'Edit Preferences' from the menu"
            log_user_info "$log_prefix" "   4. In the Downloads section, set the Download location to:"
            log_user_info "$log_prefix" "   ${DROP_FOLDER}"
            log_user_info "$log_prefix" "   5. Once added, you can safely close the Transmission window"
            log_user_info "$log_prefix" "   This enables full end-to-end automation for torrents."
            log_user_info "$log_prefix" "   See 'JellyMac_Getting_Started.txt' for more details on configuration."
            return 1
            ;;
    esac
}

# Function: perform_system_health_checks
# Description: Performs health checks for required and optional commands
# Parameters: None
# Returns:
#   0 if all checks pass (critical and optional)
#   2 if critical checks pass but optional ones are missing
# Side Effects: Exits with code 1 if any critical command is missing
perform_system_health_checks() {
    local log_prefix="Doctor"
    log_user_info "$log_prefix" "💊 Performing system health checks..."
    local any_optional_missing=false

    # Collect all missing dependencies (using Bash 3.2 compatible approach)
    local missing_deps=()
    local IFS=$'\n'
    while read -r dep; do
        # Skip empty lines
        if [[ -n "$dep" ]]; then
            missing_deps+=("$dep")
        fi
    done < <(collect_missing_dependencies)
    
    local missing_count=${#missing_deps[@]}
    
    # If we have missing dependencies, handle them interactively
    if [[ $missing_count -gt 0 ]]; then
        handle_missing_dependencies_interactively "${missing_deps[@]}"
        
        # Re-check dependencies after interactive handling (using Bash 3.2 compatible approach)
        missing_deps=()
        local IFS=$'\n'
        while read -r dep; do
            # Skip empty lines
            if [[ -n "$dep" ]]; then
                missing_deps[${#missing_deps[@]}]="$dep"
            fi
        done < <(collect_missing_dependencies)
        
        missing_count=${#missing_deps[@]}
        
        # If still missing dependencies, determine if any are critical
        local critical_failure_detected=false
        if [[ $missing_count -gt 0 ]]; then
            log_user_info "$log_prefix" "Verifying critical dependencies after installation attempts..."
            for dep in "${missing_deps[@]}"; do
                local is_this_dep_critical=false
                local critical_reason=""

                # Check core required dependencies
                for core_req_dep in "${REQUIRED_DEPENDENCIES[@]}"; do
                    if [[ "$dep" == "$core_req_dep" ]]; then
                        is_this_dep_critical=true
                        critical_reason=" (core requirement)"
                        break 
                    fi
                done

                # Check YouTube dependencies
                if [[ "${ENABLE_CLIPBOARD_YOUTUBE:-false}" == "true" ]]; then
                    if [[ "$dep" == "yt-dlp" ]]; then
                        is_this_dep_critical=true
                        critical_reason=" (for YouTube)"
                    elif [[ "$dep" == "ffmpeg" ]]; then
                        is_this_dep_critical=true
                        critical_reason=" (for YouTube media processing)"
                    fi
                fi
                
                # Check Torrent dependencies
                if [[ "${ENABLE_TORRENT_AUTOMATION:-false}" == "true" ]]; then
                    # Assuming collect_missing_dependencies uses "transmission-cli" 
                    # as the placeholder name for the torrent client.
                    if [[ "$dep" == "transmission-cli" ]]; then 
                        is_this_dep_critical=true
                        critical_reason=" (for Torrents)"
                    fi
                fi

                if [[ "$is_this_dep_critical" == "true" ]]; then
                    log_error_event "$log_prefix" "CRITICAL program '$dep'$critical_reason is still missing."
                    critical_failure_detected=true
                fi
            done # End of loop through missing_deps

            if [[ "$critical_failure_detected" == "true" ]]; then
                log_error_event "$log_prefix" "One or more critical programs are missing. JellyMac AMP cannot continue."
                log_user_info "$log_prefix" "Please review the errors above, install the missing programs (e.g., using 'brew install <program>'), or ensure AUTO_INSTALL_DEPENDENCIES is enabled in your config."
                return 1 
            else
                # If we are here, missing_count > 0 but no critical failures were detected.
                log_warn_event "$log_prefix" "Some optional programs are still missing. Certain non-critical features may not work."
                any_optional_missing=true
            fi
        fi
    fi

    # Check if auto-installation is enabled and Homebrew is available
    if [[ "${AUTO_INSTALL_DEPENDENCIES:-false}" == "true" ]]; then
        if command -v brew >/dev/null 2>&1; then
            log_user_info "$log_prefix" "Automatic program installation is enabled and Homebrew is available."
        else
            log_warn_event "$log_prefix" "Automatic program installation is enabled but Homebrew is not found."
            log_warn_event "$log_prefix" "Please install Homebrew from https://brew.sh/ to enable auto-installation."
        fi
    fi

    # --- Check Core macOS Tools ---
    if [[ "$(uname)" == "Darwin" ]]; then
        log_debug_event "$log_prefix" "Checking core macOS tools..."
        
        # Define core macOS tools based on enabled features
        local core_tools=()
        
        # Always check these core tools
        core_tools[${#core_tools[@]}]="rsync"
        core_tools[${#core_tools[@]}]="curl"
        
        # Add clipboard tools if needed
        if [[ "${ENABLE_CLIPBOARD_YOUTUBE:-false}" == "true" || "${ENABLE_CLIPBOARD_MAGNET:-false}" == "true" ]]; then
            core_tools[${#core_tools[@]}]="pbpaste"
        fi
        
        # Add other macOS-specific tools
        core_tools[${#core_tools[@]}]="caffeinate"
        
        if [[ "${ENABLE_DESKTOP_NOTIFICATIONS:-false}" == "true" ]]; then
            core_tools[${#core_tools[@]}]="osascript"
        fi
        
        # Check all core tools
        for core_tool in "${core_tools[@]}"; do
            if ! command -v "$core_tool" >/dev/null 2>&1; then
                log_error_event "$log_prefix" "❌ Core macOS tool '$core_tool' is missing. This indicates a corrupted system."
                log_error_event "$log_prefix" "Please repair your macOS installation before using JellyMac AMP."
                exit 1
            fi
        done
        log_debug_event "$log_prefix" "✅ All core macOS tools available."
    fi
    
    # --- Check Transmission Daemon Status ---
    # Verify daemon is running if magnet link handling is enabled
    if [[ "${ENABLE_CLIPBOARD_MAGNET:-false}" == "true" ]]; then
        log_debug_event "$log_prefix" "Checking Transmission background service status..."
        if ! check_transmission_daemon; then
            log_warn_event "$log_prefix" "Magnet link handling is enabled, but the Transmission background service is not running."
            any_optional_missing=true
        fi
    fi
    
    log_user_info "$log_prefix" "✅ System health checks passed."
    
    if [[ "$any_optional_missing" == "true" ]]; then
        log_warn_event "$log_prefix" "🩺 Some optional system health checks failed. Review warnings above."
        return 2
    else
        log_debug_event "$log_prefix" "🩺 All optional command checks also passed or were not applicable."
        return 0
    fi
}

