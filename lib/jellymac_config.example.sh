#!/bin/bash

#==============================================================================
# JELLYMAC CONFIGURATION
#==============================================================================

################################################################################
# QUICK START: Configure these essential paths first
################################################################################

# === REQUIRED PATHS (Must be configured before first run) ===
# Note: Only edit the sections between the "===" below (e.g. "$HOME/Movies/Movies" -> "/Volumes/Media/Movies")

DROP_FOLDER="$HOME/Downloads/JellyDrop"                 # Watch folder for Movies and TV Shows
DEST_DIR_MOVIES="$HOME/Movies/Movies"                   # Your  Movies library folder (if using a separate server, set to your network share drive library e.g. /Volumes/Media/Movies)
DEST_DIR_SHOWS="$HOME/Movies/Shows"                     # Your   Shows library folder (if using a separate server, set to your network share drive library e.g. /Volumes/Media/Shows) 
DEST_DIR_YOUTUBE="$HOME/Movies/YouTube"                 # Your YouTube library folder

# === JELLYFIN SERVER (Optional - leave blank to disable) ===
JELLYFIN_SERVER=""                                      # Your Jellyfin server URL (e.g. "http://your-jellyfin-server-ip:8096" or http://localhost:8096)
JELLYFIN_API_KEY="your-jellyfin-api-key-here"           # Generate in Jellyfin Settings → API Keys

# === FEATURES ===
ENABLE_TORRENT_AUTOMATION="true"                        # Process magnet links automatically? (true/false)
ENABLE_CLIPBOARD_MAGNET="true"                          # Watch clipboard for magnet links? (true/false)
ENABLE_CLIPBOARD_YOUTUBE="true"                         # Watch clipboard for YouTube links? (true/false)
SOUND_NOTIFICATION="true"                               # Play sounds for events? (true/false)
SHOW_STARTUP_BANNER="true"                              # Display ASCII art banner on startup? (true/false)

################################################################################
# SYSTEM CONFIGURATION (Works well with defaults - modify only if needed)
################################################################################

# === CRITICAL EARLY-LOADING VARIABLES (DO NOT MOVE) ===
CONFIG_FILE_OWN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
JELLYMAC_PROJECT_ROOT="$(cd "${CONFIG_FILE_OWN_DIR}/.." && pwd)"

# === CORE SYSTEM SETTINGS ===
LOG_DIR="${JELLYMAC_PROJECT_ROOT}/logs"
AUTO_INSTALL_DEPENDENCIES="false"
MAIN_LOOP_SLEEP_INTERVAL=2                               # Seconds between input checks
AUTO_CREATE_MISSING_DIRS="true"
MAX_CONCURRENT_PROCESSORS="2"  
ERROR_DIR="${JELLYMAC_PROJECT_ROOT}/_error_quarantine_files"
STATE_DIR="${JELLYMAC_PROJECT_ROOT}/.state"                          # Maximum number of concurrent media processors (1-4 recoommended for most systems)

#==============================================================================
# USER INTERFACE
#==============================================================================

ENABLE_DESKTOP_NOTIFICATIONS="true"                            # Show macOS notifications
SOUND_INPUT_DETECTED_FILE="/System/Library/Sounds/Funk.aiff"   # Sound for new input (links or files detected)
SOUND_TASK_SUCCESS_FILE="/System/Library/Sounds/Glass.aiff"    # Sound for task success
SOUND_TASK_ERROR_FILE="/System/Library/Sounds/Basso.aiff"      # Sound for errors

#==============================================================================
# LOGGING & HISTORY
#==============================================================================

LOG_LEVEL="INFO"                                         # DEBUG, INFO, WARN, ERROR
LOG_ROTATION_ENABLED="true"                              # Enable daily log rotation
LOG_FILE_BASENAME="jellymac_log"                         # Base name for log files
LOG_RETENTION_DAYS="7"                                   # Days to keep old log files
HISTORY_FILE="${JELLYMAC_PROJECT_ROOT}/.jellymac_history.log"

#==============================================================================
# YOUTUBE PROCESSING
#==============================================================================

LOCAL_DIR_YOUTUBE="${JELLYMAC_PROJECT_ROOT}/.temp_youtube"                            # Temporary staging download folder for YouTube videos
DOWNLOAD_ARCHIVE_YOUTUBE="${JELLYMAC_PROJECT_ROOT}/.yt_download_archive.txt"          # Prevents re-downloading
COOKIES_ENABLED="false"                                                               # Enable for age-restricted/private videos
COOKIES_FILE="/path/to/your/cookies.txt"                                              # Export from browser if cookies enabled
YOUTUBE_CREATE_SUBFOLDER_PER_VIDEO="false"                                            # Create subfolder for each video (true/false)
YTDLP_FORMAT="bv[height<=1080][vcodec=hevc]+ba[acodec=aac]/bv[height<=1080]+ba/best"  # Video quality preference (default is 1080p for quality/file size balance) (configure to your needs)
# For older macOS versions without good HEVC hardware decoding, consider changing "[vcodec=hevc]" above to the older standard "[vcodec=h264]"
YTDLP_OPTS=(                                                                          
    --no-playlist                    # Download single video only, not entire playlist
    --merge-output-format mp4        # Combine video/audio into .mp4 container
    --embed-metadata                 # Include video title, description in file
    --embed-thumbnail                # Embed video thumbnail as cover art
    --restrict-filenames             # Use only safe characters in filenames
 #  --sponsorblock-remove all        # Remove sponsored segments automatically
 #  --write-subs                     # Download subtitles if available (creates separate .srt or .vtt files)
 #  --sub-langs "en.*,en,es"         # Preferred subtitle languages (e.g., all English variants, then Spanish)
 #  --write-auto-subs                # Download automatic (generated) subtitles if no human-made ones are available
 #  --convert-subs srt               # Convert subtitles to SRT format if downloaded in another format
 #  --ppa "EmbedSubtitle"            # Attempts to embed downloaded subtitles into the file (experimental for mp4, works well with mkv)
)
# Add custom yt-dlp options above. See: https://github.com/yt-dlp/yt-dlp#usage-and-options

#==============================================================================
# MEDIA PROCESSING
#==============================================================================

# File Extensions
MAIN_MEDIA_EXTENSIONS=(".mkv" ".mp4" ".avi" ".mov" ".wmv" ".flv" ".webm")
ASSOCIATED_FILE_EXTENSIONS=(".srt" ".sub" ".ass" ".idx" ".vtt" ".nfo")

# Filename Cleaning
# To add new tags: separate with | (pipe character). Example: "newtag|anothertag"
# To customize: modify the list below, keeping existing tags or removing unwanted ones
# Ensure tags are lowercase for compatibility.
MEDIA_TAG_BLACKLIST="2160p|1080p|720p|480p|web[- ]?dl|webrip|bluray|brrip|hdrip|ddp5?\\.1|aac|ac3|x265|x264|hevc|h\\.264|h\\.265|remux|neonoir|sdrip|re-encoded"

# Transfer Settings
PERFORM_POST_TRANSFER_DELETE="true"  # Delete source files after successful transfer to destination
POST_TRANSFER_DELETE_DELAY=30        # Wait time (seconds) before deleting source files
RSYNC_TIMEOUT=600                    # Network transfer timeout in seconds

# File Stability Detection
# These settings prevent processing files that are still being written/transferred
STABLE_CHECKS_DROP_FOLDER="3"           # Number of checks to verify file isn't growing
STABLE_SLEEP_INTERVAL_DROP_FOLDER="10"  # Seconds between stability checks

#==============================================================================
# JELLYFIN INTEGRATION
#==============================================================================
# These settings control automatic library scanning after media is processed
# Set to "false" to disable scanning for specific media types (enable if using Jellyfin)

ENABLE_JELLYFIN_SCAN_SHOWS="false"       # Sync Jellyfin   Shows library after adding new shows 
ENABLE_JELLYFIN_SCAN_MOVIES="false"      # Sync Jellyfin  Movies library after adding new movies 
ENABLE_JELLYFIN_SCAN_YOUTUBE="false"     # Sync Jellyfin YouTube library after adding new videos

#==============================================================================
# TORRENT AUTOMATION
#==============================================================================
# Configure connection to Transmission for automatic torrent processing

TORRENT_CLIENT_CLI_PATH="/opt/homebrew/bin/transmission-remote"     # Path to transmission-remote (Intel Macs might use /usr/local/bin/transmission-remote)
TRANSMISSION_REMOTE_HOST="localhost:9091"                           # Host:port of transmission daemon
TRANSMISSION_REMOTE_AUTH=""                                         # Leave blank if no auth required
                                                                    # Format: "username:password" if needed
TRANSMISSION_AUTO_CLEANUP="true"                                    # Remove completed downloads from Transmission list