#!/bin/bash
set -e # Exit immediately if a command exits with a non-zero status.

# --- Environment Variable Parsing for Uninstall and Automated Acceptance ---
AUTO_YES=${JELLYMAC_AUTO_YES:-0}
UNINSTALL=${JELLYMAC_UNINSTALL:-0}

# --- Configuration ---
# The URL for your JellyMac GitHub repository.
# Ensure this is correct for your project's main branch.
JELLYMAC_REPO_URL="https://github.com/Mtn-Man/JellyMac.git"
# The directory where JellyMac will be installed within the user's home folder.
INSTALL_DIR="$HOME/JellyMac" 


# --- Uninstall Option ---
if [[ $UNINSTALL -eq 1 ]]; then
    echo "Uninstalling JellyMac from $INSTALL_DIR..."
    rm -rf "$INSTALL_DIR"
    echo "✅ JellyMac has been uninstalled."
    exit 0
fi

# --- Pre-flight Checks (Run first, before any interactive prompts) ---
# Verify this is running on macOS
if [[ "$(uname)" != "Darwin" ]]; then
    echo "Error: This installer is for macOS only."
    echo "Detected OS: $(uname)"
    exit 1
fi

# Check internet connectivity
if ! ping -c 1 github.com &> /dev/null; then
    echo "Error: Internet connection required for installation."
    echo "Please check your network connection and try again."
    exit 1
fi

# --- Main Installation Flow ---

# Check for existing installation and offer choices
if [[ -d "$INSTALL_DIR" ]] && [[ -f "$INSTALL_DIR/jellymac.sh" ]]; then
    echo ""
    echo "          Existing JellyMac Installation Detected!"
    echo ""
    echo "Found JellyMac installation at: $INSTALL_DIR"
    echo ""
    if [[ $AUTO_YES -eq 1 ]]; then
        update_choice="u"
    else
        read -r -p "Quick update (preserves config), full reinstall, or quit? (U/r/q): " update_choice
    fi
    case "$(echo "$update_choice" | tr '[:upper:]' '[:lower:]')" in
        ""|u|update)
            echo "Performing quick update..."
            cd "$INSTALL_DIR" || { echo "Error: Failed to navigate to directory '$INSTALL_DIR'. Exiting."; exit 1; }
            echo "Pulling latest changes from GitHub..."
            git pull || { echo "Error: Failed to update JellyMac repository. Check internet or Git configuration. Exiting."; exit 1; }
            echo "Making JellyMac scripts executable..."
            chmod +x jellymac.sh bin/*.sh || { echo "Error: Failed to make scripts executable. Check permissions. Exiting."; exit 1; }
            echo ""
            echo "                Quick Update Complete!"
            echo ""
            echo "✅ JellyMac updated successfully!"
            echo "✅ Your existing configuration (jellymac_config.sh) has been preserved."
            echo "✅ JellyMac is ready to use with your current settings."
            echo ""
            echo "To start JellyMac, navigate to its directory and run: cd $INSTALL_DIR && ./jellymac.sh"
            exit 0 # Exit after a successful quick update
            ;;
        r|reinstall)
            echo "You chose full reinstall. This will delete the existing JellyMac directory."
            if [[ $AUTO_YES -eq 1 ]]; then
                confirm_reinstall_choice="y"
            else
                read -r -p "Are you sure you want to proceed with a full reinstall? (Y/n): " confirm_reinstall_choice
            fi
            case "$(echo "$confirm_reinstall_choice" | tr '[:upper:]' '[:lower:]')" in
                y|yes)
                    echo "Deleting existing JellyMac installation at $INSTALL_DIR..."
                    rm -rf "$INSTALL_DIR" || { echo "Error: Failed to remove existing directory. Check permissions. Exiting."; exit 1; }
                    echo "✅ Existing JellyMac installation removed."
                    echo ""
                    ;;
                *)
                    echo "Full reinstall cancelled. Exiting."
                    exit 1
                    ;;
            esac
            ;;
        q|quit)
            echo "Installation cancelled. Exiting."
            exit 0 # Exit gracefully
            ;;
        *)
            echo "Invalid choice. Exiting installer."
            exit 1
            ;;
    esac
fi

# --- Prerequisite Check for Homebrew (New, early check) ---
# Ensure Homebrew is installed before proceeding with any JellyMac setup.
if ! command -v brew &> /dev/null; then
    echo "Error: Homebrew (macOS package manager) is not found."
    echo "Homebrew is a required prerequisite. Please install it manually before running this installer."
    echo "Refer to https://brew.sh for installation instructions." # Updated message
    exit 1
fi

# --- Detect Architecture and Determine Homebrew Path (Now happens after Homebrew check) ---
ARCH=$(uname -m) # Get the system's architecture (e.g., 'arm64' or 'x86_64').
HOMEBREW_BIN_PATH="" # Initialize variable for Homebrew's binary path.

if [[ "$ARCH" == "arm64" ]]; then
    HOMEBREW_BIN_PATH="/opt/homebrew/bin" # Standard path for Homebrew on Apple Silicon.
elif [[ "$ARCH" == "x86_64" ]]; then
    HOMEBREW_BIN_PATH="/usr/local/bin" # Standard path for Homebrew on Intel Macs.
else
    echo "Error: Unsupported architecture: $ARCH."
    echo "This script is designed for macOS (Intel or Apple Silicon) only. Exiting."
    exit 1 # Exit if the architecture is not recognized.
fi

# Ensure Homebrew's bin path is added to the PATH for the current script's execution.
# This is crucial so that 'brew' commands are found.
export PATH="$HOMEBREW_BIN_PATH:$PATH"


# --- Begin Fresh or Full Reinstall Process ---
echo ""
echo "            JellyMac Automated Installer for macOS"
echo ""
echo "   This script will perform the initial setup for JellyMac:"
echo "1. Detect your macOS architecture (Intel or Apple Silicon)."
echo "2. Install Git (version control program) via Homebrew if it's not already installed."
echo "3. Clone the JellyMac project from GitHub to: $INSTALL_DIR"
echo "4. Make necessary JellyMac program scripts executable."
echo "5. Launch JellyMac for guided first time setup."
echo ""
# Pause for user to read important information before proceeding with major installs.
if [[ $AUTO_YES -eq 1 ]]; then
    echo "Automated mode: Skipping prompt and proceeding with installation."
else
    read -r -p "Press Enter to start installation, or Ctrl+C to cancel..."
fi

# --- Install Git ---
# Check if Git is already installed by trying to find the 'git' command.
if ! command -v git &> /dev/null; then
    echo "Git not found. Installing Git via Homebrew..."
    brew install git || { echo "Error: Failed to install Git. Exiting."; exit 1; }
    echo "✅ Git installed successfully."
else
    # Git is already installed. Continue silently.
    true
fi

# --- Clone JellyMac Repository ---
# This block is now only for initial clone (or after a full reinstall)
if [[ ! -d "$INSTALL_DIR" ]]; then
    echo "Cloning JellyMac repository to $INSTALL_DIR..."
    git clone "$JELLYMAC_REPO_URL" "$INSTALL_DIR" || { echo "Error: Failed to clone JellyMac repository. Exiting."; exit 1; }
    echo "✅ JellyMac repository cloned successfully."
else
    # This case should only be hit if user chose 'reinstall' and rm -rf failed
    # or if for some reason the directory was not removed.
    echo "Warning: Directory '$INSTALL_DIR' still exists unexpectedly. Attempting to proceed."
    cd "$INSTALL_DIR" || { echo "Failed to navigate to $INSTALL_DIR. Check permissions. Exiting."; exit 1; }
fi

# --- Navigate to Project Directory and Make Scripts Executable ---
# Verify the installation directory exists before proceeding.
if [[ ! -d "$INSTALL_DIR" ]]; then
    echo "Error: JellyMac installation directory ($INSTALL_DIR) not found after cloning attempt. Exiting."
    exit 1
fi

echo "Navigating to $INSTALL_DIR..."
cd "$INSTALL_DIR" || { echo "Failed to navigate to $INSTALL_DIR. Check permissions. Exiting."; exit 1; }

echo "Making JellyMac scripts executable..."
# Make the main script and all scripts in the 'bin' directory executable.
chmod +x jellymac.sh bin/*.sh || { echo "Error: Failed to make scripts executable. Check permissions. Exiting."; exit 1; }
echo "✅ JellyMac scripts are now executable."

echo ""
echo "JellyMac Installation Complete!"
echo ""
echo "Starting JellyMac setup..."
echo ""
echo ""

# Small delay to ensure terminal is ready
sleep 1

# --- Start JellyMac ---
# Restore stdin and execute JellyMac interactively
exec ./jellymac.sh < /dev/tty