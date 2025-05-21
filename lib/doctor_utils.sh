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
    local log_prefix="[DEPENDENCY_INSTALLER]"
    
    # Early exit if auto-installation is disabled
    if [[ "${AUTO_INSTALL_DEPENDENCIES:-false}" != "true" ]]; then
        log_debug_event "$log_prefix" "Auto-install is disabled. Set AUTO_INSTALL_DEPENDENCIES=true in config to enable."
        return 1
    fi
    
    # Check if Homebrew is installed
    if ! command -v brew &>/dev/null; then
        log_warn_event "$log_prefix" "Homebrew not found. Cannot auto-install dependencies."
        log_warn_event "$log_prefix" "Please install Homebrew from https://brew.sh/ to enable auto-installation."
        return 1
    fi
    
    log_info_event "$log_prefix" "🍺 Auto-installing dependency: $package_name"
    
    # Attempt to install the package
    if brew install "$package_name"; then
        log_info_event "$log_prefix" "✅ Successfully installed: $package_name"
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
    
    # Check core dependencies
    for dep in "${REQUIRED_DEPENDENCIES[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            missing_deps+=("$dep")
        fi
    done
    
    # Check feature-specific dependencies
    if [[ "${ENABLE_CLIPBOARD_YOUTUBE:-false}" == "true" ]]; then
        if ! command -v "yt-dlp" &>/dev/null; then
            missing_deps+=("yt-dlp")
        fi
    fi
    
    if [[ "${ENABLE_TORRENT_AUTOMATION:-false}" == "true" ]]; then
        local torrent_client_exe
        torrent_client_exe=$(basename "${TORRENT_CLIENT_CLI_PATH:-transmission-remote}")
        
        if [[ ! -x "${TORRENT_CLIENT_CLI_PATH:-}" ]] && ! command -v "$torrent_client_exe" &>/dev/null; then
            missing_deps+=("transmission-cli")
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
    
    if [[ $missing_count -eq 0 ]]; then
        return 0  # No missing dependencies
    fi
    
    # Clear screen for better presentation
    clear
    
    # Print welcome header with colorful border
    echo -e "\033[36m╔════════════════════════════════════════════════════════════╗\033[0m"
    echo -e "\033[36m║\033[0m       \033[1m\033[33mWelcome to JellyMac AMP - First Time Setup\033[0m       \033[36m║\033[0m"
    echo -e "\033[36m╚════════════════════════════════════════════════════════════╝\033[0m"
    echo
    echo -e "\033[1mWe noticed this is your first time running JellyMac AMP.\033[0m"
    echo "Before we can start automating your media library, we need to set up a few things."
    echo
    echo -e "\033[33mMissing Dependencies:\033[0m"
    
    # Print each missing dependency with package info
    for ((i=0; i<${#missing_deps[@]}; i++)); do
        local dep="${missing_deps[$i]}"
        echo -e "  \033[31m•\033[0m $dep"
    done
    
    echo
    echo "These tools are required for JellyMac AMP to work properly with your media files."
    echo
    
    # Present options
    echo -e "\033[1mHow would you like to proceed?\033[0m"
    echo -e "  \033[32m1)\033[0m Install dependencies now (one-time installation)"
    echo -e "  \033[32m2)\033[0m Enable automatic dependency installation (permanent)"
    echo -e "  \033[32m3)\033[0m Skip and continue anyway (some features may not work)"
    echo -e "  \033[32m4)\033[0m Exit and read the Getting Started guide first"
    echo
    
    # Get user input
    local selection
    read -r -p "Select an option [1-4]: " selection
    
    case "$selection" in
        1)  # Install dependencies now (one-time)
            echo -e "\033[1mInstalling dependencies for this run only...\033[0m"
            AUTO_INSTALL_DEPENDENCIES="true"
            install_missing_dependencies "${missing_deps[@]}"
            local install_status=$?
            AUTO_INSTALL_DEPENDENCIES="false"  # Reset to false after this run
            
            if [[ $install_status -eq 0 ]]; then
                echo
                echo -e "\033[32m✓\033[0m Successfully installed all dependencies!"
                echo "JellyMac AMP will now continue with startup..."
                echo
                sleep 2
            fi
            
            return $install_status
            ;;
            
        2)  # Enable automatic installation (permanent)
            echo -e "\033[1mEnabling automatic dependency installation...\033[0m"
            
            # Update the config file
            local config_file="${LIB_DIR}/jellymac_config.sh"
            if [[ -f "$config_file" && -w "$config_file" ]]; then
                # Create a backup of the config file first
                cp "$config_file" "${config_file}.bak"
                
                # Use macOS-compatible sed syntax
                if [[ "$(uname)" == "Darwin" ]]; then
                    sed -i '' 's/^AUTO_INSTALL_DEPENDENCIES="false"/AUTO_INSTALL_DEPENDENCIES="true"/' "$config_file"
                else
                    # Linux/other systems
                    sed -i 's/^AUTO_INSTALL_DEPENDENCIES="false"/AUTO_INSTALL_DEPENDENCIES="true"/' "$config_file"
                fi
                
                echo -e "\033[32m✓\033[0m Config updated: AUTO_INSTALL_DEPENDENCIES set to true"
                echo
                
                # Try installation with new setting
                AUTO_INSTALL_DEPENDENCIES="true"
                install_missing_dependencies "${missing_deps[@]}"
                local install_status=$?
                
                if [[ $install_status -eq 0 ]]; then
                    echo
                    echo -e "\033[32m✓\033[0m Successfully installed all dependencies!"
                    echo "JellyMac AMP will now continue with startup..."
                    echo
                    echo "In the future, any missing dependencies will be installed automatically."
                    sleep 2
                fi
                
                return $install_status
            else
                echo -e "\033[31m✗\033[0m Could not update config file. Please set AUTO_INSTALL_DEPENDENCIES=\"true\" manually."
                return 1
            fi
            ;;
            
        3)  # Skip and continue
            echo -e "\033[33m⚠️  Continuing without required dependencies. Some features may not work correctly.\033[0m"
            echo "You can install the missing dependencies later by running:"
            echo "  brew install ${missing_deps[*]}"
            echo
            sleep 2
            return 0
            ;;
            
        4)  # Exit and read guide
            echo -e "\033[1mExiting JellyMac AMP setup.\033[0m"
            echo
            echo "To get started, please read the Getting Started guide:"
            echo -e "  \033[36m$JELLYMAC_PROJECT_ROOT/JellyMac_Getting_Started.txt\033[0m"
            echo
            echo "This guide will walk you through:"
            echo "  • Setting up all required dependencies"
            echo "  • Configuring your media folders"
            echo "  • Connecting to your Jellyfin server"
            echo "  • And more!"
            echo
            echo "Once you're ready, run ./jellymac.sh again to start the setup."
            echo
            exit 1
            ;;
            
        *)  # Invalid selection
            echo -e "\033[31mInvalid selection. Exiting.\033[0m"
            exit 1
            ;;
    esac
}

# Function: validate_config_filepaths
# Description: Checks if essential directories exist and are writable
# Parameters: None
# Returns:
#   0 if all validations pass
#   1 if any validation fails
# Side Effects: May create directories if AUTO_CREATE_MISSING_DIRS is true
validate_config_filepaths() {
    local log_prefix="[CONFIG_VALIDATOR]"
    log_info_event "$log_prefix" "🔍 Validating configuration filepaths..."
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
        "${TEMP_DIR:-}"             "Temporary processing directory (optional)"
    )
    
    # Check each required directory
    for ((i=0; i<${#required_dirs[@]}; i+=2)); do
        local dir="${required_dirs[i]}"
        local description="${required_dirs[i+1]}"
        
        if [[ -z "$dir" ]]; then
            log_error_event "$log_prefix" "❌ Required directory path is empty: $description"
            log_info_event "$log_prefix" "Please set this path in your jellymac_config.sh file."
            validation_failed=true
            continue
        fi
        
        if [[ ! -d "$dir" ]]; then
            if [[ "${AUTO_CREATE_MISSING_DIRS:-false}" == "true" ]]; then
                log_warn_event "$log_prefix" "⚠️ Directory does not exist, creating: $dir ($description)"
                if ! mkdir -p "$dir"; then
                    log_error_event "$log_prefix" "❌ Failed to create directory: $dir"
                    validation_failed=true
                fi
            else
                log_error_event "$log_prefix" "❌ Directory does not exist: $dir ($description)"
                log_info_event "$log_prefix" "Create this directory manually or set AUTO_CREATE_MISSING_DIRS=true in config."
                validation_failed=true
            fi
        elif [[ ! -w "$dir" ]]; then
            log_error_event "$log_prefix" "❌ Directory is not writable: $dir ($description)"
            log_info_event "$log_prefix" "Please check permissions on this directory."
            validation_failed=true
        fi
    done
    
    # Check each optional directory (only if they're specified)
    for ((i=0; i<${#optional_dirs[@]}; i+=2)); do
        local dir="${optional_dirs[i]}"
        local description="${optional_dirs[i+1]}"
        
        # Skip empty optional paths
        if [[ -z "$dir" ]]; then
            log_debug_event "$log_prefix" "Optional directory not configured: $description"
            continue
        fi
        
        if [[ ! -d "$dir" ]]; then
            if [[ "${AUTO_CREATE_MISSING_DIRS:-false}" == "true" ]]; then
                log_warn_event "$log_prefix" "⚠️ Optional directory does not exist, creating: $dir ($description)"
                if ! mkdir -p "$dir"; then
                    log_error_event "$log_prefix" "❌ Failed to create optional directory: $dir"
                    validation_failed=true
                fi
            else
                log_warn_event "$log_prefix" "⚠️ Optional directory does not exist: $dir ($description)"
                log_info_event "$log_prefix" "Create this directory manually or set AUTO_CREATE_MISSING_DIRS=true in config."
                validation_failed=true
            fi
        elif [[ ! -w "$dir" ]]; then
            log_error_event "$log_prefix" "❌ Optional directory is not writable: $dir ($description)"
            log_info_event "$log_prefix" "Please check permissions on this directory."
            validation_failed=true
        fi
    done
    
    # Check Jellyfin Server URL if configured
    if [[ -n "${JELLYFIN_SERVER:-}" ]]; then
        if ! [[ "$JELLYFIN_SERVER" =~ ^https?://[^/]+.* ]]; then
            log_error_event "$log_prefix" "❌ Invalid Jellyfin server URL: $JELLYFIN_SERVER"
            log_info_event "$log_prefix" "URL should start with http:// or https:// followed by hostname/IP."
            validation_failed=true
        fi
        
        if [[ -n "${JELLYFIN_API_KEY:-}" ]]; then
            if [[ "${#JELLYFIN_API_KEY}" -lt 10 ]]; then
                log_warn_event "$log_prefix" "⚠️ Jellyfin API key looks suspiciously short: $JELLYFIN_API_KEY"
                log_info_event "$log_prefix" "API keys are usually longer. Please verify it's correct."
            fi
        else
            log_warn_event "$log_prefix" "⚠️ Jellyfin server specified but no API key provided."
            log_info_event "$log_prefix" "Library scanning will not work without an API key."
        fi
    fi
    
    # Final validation result
    if [[ "$validation_failed" == "true" ]]; then
        log_error_event "$log_prefix" "❌ Configuration validation failed. Please fix the issues above."
        return 1
    else
        log_info_event "$log_prefix" "✅ All configuration filepaths validated successfully."
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
    local log_prefix="[HEALTH_CHECK]"
    
    # Skip check if magnet handling is disabled
    if [[ "${ENABLE_CLIPBOARD_MAGNET:-false}" != "true" ]]; then
        return 0
    fi
    
    local transmission_cli="${TORRENT_CLIENT_CLI_PATH:-transmission-remote}"
    local transmission_host="${TRANSMISSION_REMOTE_HOST:-localhost:9091}"
    
    log_info_event "$log_prefix" "Checking if Transmission daemon is running..."
    
    # Try to connect to Transmission daemon
    if ! "$transmission_cli" "$transmission_host" --list &>/dev/null; then
        log_warn_event "$log_prefix" "⚠️ Transmission daemon appears to be offline."
        log_info_event "$log_prefix" "To start Transmission daemon: brew services start transmission"
        log_info_event "$log_prefix" "Magnet link handling will be unavailable until Transmission is running."
        return 1
    else
        log_info_event "$log_prefix" "✅ Transmission daemon is running and accessible."
        return 0
    fi
}

# Function: perform_system_health_checks
# Description: Performs health checks for required and optional commands
# Parameters: None
# Returns:
#   0 if all checks pass (critical and optional)
#   2 if critical checks pass but optional ones are missing
# Side Effects: Exits with code 1 if any critical command is missing
perform_system_health_checks() {
    local log_prefix="[HEALTH_CHECK]"
    log_info_event "$log_prefix" "🩺 Performing system health checks..."
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
                missing_deps+=("$dep")
            fi
        done < <(collect_missing_dependencies)
        
        missing_count=${#missing_deps[@]}
        
        # If still missing critical dependencies, exit
        if [[ $missing_count -gt 0 ]]; then
            for dep in "${missing_deps[@]}"; do
                if [[ " ${REQUIRED_DEPENDENCIES[*]} " == *" ${dep} "* ]]; then
                    log_error_event "$log_prefix" "Critical dependency '$dep' still missing. Exiting."
                    exit 1
                fi
            done
            # If we got here, only optional dependencies are missing
            log_warn_event "$log_prefix" "Some optional dependencies are still missing. Some features may not work."
            any_optional_missing=true
        fi
    fi

    # Check if auto-installation is enabled and Homebrew is available
    if [[ "${AUTO_INSTALL_DEPENDENCIES:-false}" == "true" ]]; then
        if command -v brew &>/dev/null; then
            log_info_event "$log_prefix" "Auto-dependency installation is enabled and Homebrew is available."
        else
            log_warn_event "$log_prefix" "Auto-dependency installation is enabled but Homebrew is not found."
            log_warn_event "$log_prefix" "Please install Homebrew from https://brew.sh/ to enable auto-installation."
        fi
    fi

    # --- Critical Commands ---
    # find_executable (from common_utils.sh) will log an error and exit if a command is not found.
    # So, if the script proceeds past these checks, the commands were found.

    # Check for flock and attempt to install it if missing
    log_info_event "$log_prefix" "Checking dependency: flock"
    if ! command -v flock &>/dev/null; then
        if [[ "${AUTO_INSTALL_DEPENDENCIES:-false}" == "true" ]]; then
            log_info_event "$log_prefix" "flock not found, attempting to install..."
            if install_missing_dependency "flock"; then
                log_info_event "$log_prefix" "Successfully installed flock"
            else
                log_error_event "$log_prefix" "Failed to install flock and it's a required dependency. Exiting."
                exit 1
            fi
        else
            log_error_event "$log_prefix" "flock not found. This is a required dependency. Install with: brew install flock"
            log_info_event "$log_prefix" "Or enable auto-install in config: AUTO_INSTALL_DEPENDENCIES=true"
            exit 1
        fi
    fi

    # Built-in/common tools use debug-level logging
    log_debug_event "$log_prefix" "Checking common system tool: rsync"
    find_executable "rsync" # Exits if not found

    if [[ "${ENABLE_CLIPBOARD_YOUTUBE:-false}" == "true" ]]; then
        log_info_event "$log_prefix" "Checking dependency for YouTube: yt-dlp"
        if ! command -v yt-dlp &>/dev/null; then
            if [[ "${AUTO_INSTALL_DEPENDENCIES:-false}" == "true" ]]; then
                log_info_event "$log_prefix" "yt-dlp not found, attempting to install..."
                if install_missing_dependency "yt-dlp"; then
                    log_info_event "$log_prefix" "Successfully installed yt-dlp"
                else
                    log_error_event "$log_prefix" "Failed to install yt-dlp and it's required for YouTube functionality. Exiting."
                    exit 1
                fi
            else
                log_error_event "$log_prefix" "yt-dlp not found. This is required for YouTube functionality. Install with: brew install yt-dlp"
                log_info_event "$log_prefix" "Or enable auto-install in config: AUTO_INSTALL_DEPENDENCIES=true"
                exit 1
            fi
        fi
    fi

    if [[ "${ENABLE_TORRENT_AUTOMATION:-false}" == "true" && -n "${TORRENT_CLIENT_CLI_PATH:-}" ]]; then
        local torrent_client_exe
        torrent_client_exe=$(basename "${TORRENT_CLIENT_CLI_PATH}")
        log_info_event "$log_prefix" "Checking dependency for Torrents: $torrent_client_exe (from TORRENT_CLIENT_CLI_PATH)"
        
        # Check if the transmission-remote executable exists
        if [[ ! -x "${TORRENT_CLIENT_CLI_PATH}" ]] && ! command -v "$torrent_client_exe" &>/dev/null; then
            if [[ "${AUTO_INSTALL_DEPENDENCIES:-false}" == "true" ]]; then
                log_info_event "$log_prefix" "Torrent client $torrent_client_exe not found, attempting to install..."
                # Always install transmission-cli regardless of the command name
                if install_missing_dependency "transmission-cli"; then
                    log_info_event "$log_prefix" "Successfully installed transmission-cli"
                else
                    log_error_event "$log_prefix" "Failed to install transmission-cli and it's required for torrent functionality. Exiting."
                    exit 1
                fi
            else
                log_error_event "$log_prefix" "$torrent_client_exe not found. This is required for torrent functionality. Install with: brew install transmission-cli"
                log_info_event "$log_prefix" "Or enable auto-install in config: AUTO_INSTALL_DEPENDENCIES=true"
                exit 1
            fi
        fi
    fi

    if [[ -n "${JELLYFIN_SERVER:-}" ]]; then
        log_debug_event "$log_prefix" "Checking common system tool: curl"
        find_executable "curl" # Exits if not found
    fi

    # If we reach here, all external dependency commands checked via find_executable were found.
    
    # --- Check Core macOS Tools ---
    if [[ "$(uname)" == "Darwin" ]]; then
        log_debug_event "$log_prefix" "Checking core macOS tools..."
        
        # Define core macOS tools based on enabled features
        local core_tools=()
        
        # Always check these core tools
        core_tools+=("rsync" "curl")
        
        # Add clipboard tools if needed
        if [[ "${ENABLE_CLIPBOARD_YOUTUBE:-false}" == "true" || "${ENABLE_CLIPBOARD_MAGNET:-false}" == "true" ]]; then
            core_tools+=("pbpaste")
        fi
        
        # Add other macOS-specific tools
        core_tools+=("caffeinate")
        
        if [[ "${ENABLE_DESKTOP_NOTIFICATIONS:-false}" == "true" ]]; then
            core_tools+=("osascript")
        fi
        
        # Check all core tools
for core_tool in "${core_tools[@]}"; do
    if ! command -v "$core_tool" &>/dev/null; then
        log_error_event "$log_prefix" "❌ Core macOS tool '$core_tool' is missing. This indicates a corrupted system."
        log_error_event "$log_prefix" "Please repair your macOS installation before using JellyMac AMP."
        exit 1
    fi
done
log_debug_event "$log_prefix" "✅ All core macOS tools available."
    fi  # <-- This closes the if [[ "$(uname)" == "Darwin" ]] statement
    
# --- Check Transmission Daemon Status ---
# Verify daemon is running if magnet link handling is enabled
if [[ "${ENABLE_CLIPBOARD_MAGNET:-false}" == "true" ]]; then
    log_debug_event "$log_prefix" "Checking Transmission daemon status..."
    if ! check_transmission_daemon; then
        log_warn_event "$log_prefix" "Magnet link handling is enabled, but Transmission daemon is not running."
        any_optional_missing=true
    fi
fi
    
    log_info_event "$log_prefix" "✅ All critical command checks passed successfully."
    
    # --- Optional Commands ---
    # None left - all important tools are now considered critical

    if [[ "$any_optional_missing" == "true" ]]; then
        log_warn_event "$log_prefix" "🩺 Some optional system health checks failed. Review warnings above."
        return 2 # Non-critical failure (only optional commands missing)
    else
        log_debug_event "$log_prefix" "🩺 All optional command checks also passed or were not applicable."
        return 0 # Success, all critical passed, and no optional were missing (or needed)
    fi
}

