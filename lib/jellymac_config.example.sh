#!/bin/bash

#==============================================================================
# JELLYMAC AMP CONFIGURATION
#==============================================================================
# This configuration file is sourced by JellyMac.sh and its helper scripts
# in the bin/ directory to define essential paths, settings, and parameters.

#==============================================================================
# CORE CONFIGURATION
#==============================================================================
# Core settings that control the general behavior of JellyMac AMP.
# These settings affect the entire application and should be configured carefully.

# [Project Root] - Automatically determines the project's installation directory
# This assumes jellymac_config.sh is in the 'lib' subdirectory of the project root.
CONFIG_FILE_OWN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
JELLYMAC_PROJECT_ROOT="$(cd "${CONFIG_FILE_OWN_DIR}/.." && pwd)" # Navigate one level up from lib/

# [Dependencies] - Controls automatic installation of missing dependencies
AUTO_INSTALL_DEPENDENCIES="false"  # [Values: true, false] [Default: false]
                                   # Set to true to automatically install missing tools via Homebrew on startup

# [Main Loop Interval] - Controls how frequently the main loop runs
MAIN_LOOP_SLEEP_INTERVAL=5  # [Units: seconds] [Range: 1-60] [Default: 5]
                            # Lower values = more responsive but higher CPU usage

# [Directory Creation] - Controls if missing directories should be created automatically
AUTO_CREATE_MISSING_DIRS="true"  # [Values: true, false] [Default: true]

# [Concurrent Processing] - Maximum number of simultaneous media processors
MAX_CONCURRENT_PROCESSORS="2"  # [Range: 1-5] [Default: 2]
                               # Controls how many files can be processed simultaneously

#==============================================================================
# MEDIA PATHS
#==============================================================================
# Defines all paths used for media sources, destinations, and error handling.
# These paths must exist or be creatable for the system to function correctly.

# [Drop Folder] - Main folder monitored for new media
DROP_FOLDER="/path/to/your/drop_folder"  # [Required] Primary source directory

# [Movie Library] - Final destination for processed movies
DEST_DIR_MOVIES="/path/to/your/movies_library"  # [Required] Must be writable

# [TV Shows Library] - Final destination for processed TV shows
DEST_DIR_SHOWS="/path/to/your/shows_library"  # [Required] Must be writable

# [YouTube Library] - Final destination for downloaded YouTube videos
DEST_DIR_YOUTUBE="/path/to/your/youtube_library"  # [Required if YouTube processing enabled]

# [YouTube Processing] - Temporary storage during YouTube downloads
LOCAL_DIR_YOUTUBE="/path/to/local/youtube_downloads"  # [Required if YouTube processing enabled]

# [Error Directory] - Storage for items that couldn't be processed
ERROR_DIR="${JELLYMAC_PROJECT_ROOT}/_error_quarantine_files"  # [Required] Created automatically if needed

#==============================================================================
# MEDIA PROCESSING SETTINGS
#==============================================================================
# Settings that control how media files are processed, renamed, and handled.
# These affect the core functionality of the media processing pipeline.

# --- File Extensions ---
# [Media Extensions] - File types recognized as primary media content
MAIN_MEDIA_EXTENSIONS=(
    ".mkv" ".mp4" ".avi" ".mov" ".wmv" ".flv" ".webm"  # Video formats
    ".ts"                                              # Transport Stream format
)  # [Required] Main media files that will be processed

# [Associated Extensions] - Additional files to process alongside media
ASSOCIATED_FILE_EXTENSIONS=(
    ".srt" ".sub" ".ass" ".idx" ".vtt"  # Subtitle formats
    ".nfo"                              # Media information files
)  # [Optional] These will be renamed to match the main media file

# --- Filename Cleaning ---
# [Tag Blacklist] - Tags to remove from filenames during processing
# Regex patterns separated by | (pipe), case insensitive - be careful any exact matches are removed
MEDIA_TAG_BLACKLIST="1080p|720p|480p|2160p|WEB[- ]?DL|WEBRip|BluRay|BRRip|HDRip|DDP5?\.1|AAC|AC3|x265|x264|HEVC|H\.264|H\.265|REMUX|NeoNoir"
# [Example] "1080p|720p|WEB-DL" would remove these quality tags from filenames

# --- Transfer Settings ---
# [Transfer Timeout] - Maximum time for rsync operations
RSYNC_TIMEOUT=300  # [Units: seconds] [Range: 30-1800] [Default: 300]
                  # Increase for very large files or slow network transfers

# --- File Stability Detection ---
# [Stability Checks] - Number of consecutive checks needed to consider a file stable
STABLE_CHECKS_DROP_FOLDER="3"  # [Range: 1-10] [Default: 3]
                              # Higher values ensure more complete file transfers

# [Stability Interval] - Time between stability checks
STABLE_SLEEP_INTERVAL_DROP_FOLDER="10"  # [Units: seconds] [Range: 1-60] [Default: 10]
                                       # How long to wait between file size/date checks

#==============================================================================
# JELLYFIN INTEGRATION
#==============================================================================
# Settings for integration with Jellyfin media server.
# These enable automatic library scanning after media processing.

# [Server URL] - The base URL of your Jellyfin server
JELLYFIN_SERVER="http://your-jellyfin-server-ip:8096"  # [Format: http(s)://hostname:port]
                                              # Must be accessible from this machine

# [API Key] - Authentication key for Jellyfin API access
JELLYFIN_API_KEY="your-jellyfin-api-key-here"  # [Required if server specified]
                                                     # Generate in Jellyfin Dashboard → API Keys

# [Movies Scan] - Enable Jellyfin library scan after processing movies
ENABLE_JELLYFIN_SCAN_MOVIES="true"  # [Values: true, false] [Default: true]

# [TV Shows Scan] - Enable Jellyfin library scan after processing TV shows
ENABLE_JELLYFIN_SCAN_SHOWS="true"  # [Values: true, false] [Default: true]

# [YouTube Scan] - Enable Jellyfin library scan after processing YouTube videos
ENABLE_JELLYFIN_SCAN_YOUTUBE="true"  # [Values: true, false] [Default: true]

#==============================================================================
# TORRENT AUTOMATION
#==============================================================================
# Settings for automating torrent downloads via Transmission.
# These control how JellyMac interacts with your torrent client.

# [Enable Automation] - Master switch for torrent automation features
ENABLE_TORRENT_AUTOMATION="true"  # [Values: true, false] [Default: true]
                                 # Controls all torrent-related functionality

# [Clipboard Monitoring] - Watch clipboard for magnet links
ENABLE_CLIPBOARD_MAGNET="true"  # [Values: true, false] [Default: true]
                               # Set to false to disable automatic detection of copied magnet links

# --- Transmission Client Settings ---
# [Client Path] - Path to transmission-remote command
TORRENT_CLIENT_CLI_PATH="/opt/homebrew/bin/transmission-remote"  # [Required if automation enabled]
                                                                # Must be installed and executable

# [Server Address] - Connection details for Transmission RPC
TRANSMISSION_REMOTE_HOST="localhost:9091"  # [Format: hostname:port]

# [Authentication] - Username/password for Transmission RPC (if required)
TRANSMISSION_REMOTE_AUTH=""  # [Format: username:password] [Default: empty (no auth)]
                            # Leave empty if Transmission doesn't require authentication (default)

# IMPORTANT: If desired you can configure Transmission to move completed files to DROP_FOLDER for additional data security
#==============================================================================
# YOUTUBE PROCESSING
#==============================================================================
# Settings for downloading and processing YouTube videos.
# These control how JellyMac interacts with yt-dlp and handles YouTube content.

# --- General Settings ---
# [Clipboard Monitoring] - Watch clipboard for YouTube links
ENABLE_CLIPBOARD_YOUTUBE="true"  # [Values: true, false] [Default: true]
                                # Set to false to disable automatic detection of copied YouTube links

# [Download Archive] - Track downloaded videos to prevent duplicates
DOWNLOAD_ARCHIVE_YOUTUBE="${JELLYMAC_PROJECT_ROOT}/.yt_download_archive.txt"  # [Required]
                                                                             # Path must be writable

# [Cookies Configuration for YouTube] - Enable/disable cookies support
COOKIES_ENABLED="false"  # [Values: true, false] [Default: false]
                        # Set to false to completely disable cookies for YouTube downloads
                        # Helpful when experiencing SABR streaming issues

# [Cookies file for YouTube.com] (only used when COOKIES_ENABLED=true)
COOKIES_FILE="/path/to/your/cookies.txt"  # [Optional] Used for age-restricted or private videos
                                       # Export from browser or create manually using firefox cookies.txt export extension

# --- Download Settings ---
# [Format Selection] - Resolution and codec preferences
YTDLP_FORMAT="bv[height<=1080][vcodec=vp9]+ba[acodec=opus]/bv[height<=1080]+ba/best"  # [Required]
# For more format options, see: https://github.com/yt-dlp/yt-dlp#format-selection

# [Command Line Options] - Additional options passed to yt-dlp
YTDLP_OPTS=(
    --no-playlist                # Process only the specific video, not playlists
    --merge-output-format mkv    # Final container format for videos
    --embed-metadata             # Include video metadata in the file
    --restrict-filenames         # Ensure safe filenames with no special characters
)  # [Required] Core options for processing YouTube videos

#==============================================================================
# USER INTERFACE
#==============================================================================
# Settings controlling the visual and interactive elements of JellyMac AMP.
# These affect how the application presents itself to the user.

# --- Notifications ---
# [Desktop Notifications] - Show system notifications on events
ENABLE_DESKTOP_NOTIFICATIONS="false"  # [Values: true, false] [Default: false]
                                     # Only works on macOS

# --- Startup Banner ---
# [Startup Banner] - Show ASCII art banner when JellyMac starts
ENABLE_STARTUP_BANNER="true"  # [Values: true, false] [Default: true]
                             # Set to false for a more minimal startup

# --- Sound Settings ---
# [Sound Master Switch] - Enable/disable all sound notifications
SOUND_NOTIFICATION="true"  # [Values: true, false] [Default: true]
                          # Master toggle for all sound effects

# [Sound Files] - Path to sound files for different events
SOUND_INPUT_DETECTED_FILE="/System/Library/Sounds/Funk.aiff"  # Played when new input is detected
SOUND_TASK_SUCCESS_FILE="/System/Library/Sounds/Glass.aiff"   # Played on successful task completion
SOUND_TASK_ERROR_FILE="/System/Library/Sounds/Basso.aiff"     # Played when an error occurs

#==============================================================================
# LOGGING & HISTORY
#==============================================================================
# Settings controlling log file generation, rotation, and history tracking.
# These help with troubleshooting and tracking processed media.

# --- Logging Settings ---
# [Log Level] - Controls verbosity of log messages
LOG_LEVEL="INFO"  # [Values: DEBUG, INFO, WARN, ERROR] [Default: INFO]
                 # DEBUG = Most verbose, ERROR = Least verbose

# [Log Rotation] - Enable automatic log file rotation
LOG_ROTATION_ENABLED="true"  # [Values: true, false] [Default: true]
                            # Prevents logs from growing too large on disk

# [Log Directory] - Where log files will be stored
LOG_DIR="${JELLYMAC_PROJECT_ROOT}/logs"  # [Required if rotation enabled]
                                        # Directory will be created if it doesn't exist

# [Log Filename] - Base name for log files
LOG_FILE_BASENAME="jellymac_automator_log"  # [Required if rotation enabled]
                                           # Date/time will be appended automatically

# [Log Retention] - How long to keep log files before deletion
LOG_RETENTION_DAYS="7"  # [Units: days] [Range: 1-365] [Default: 7]
                       # Older log files will be automatically deleted

# --- History File ---
# [History File] - Tracks all processed media items
HISTORY_FILE="${JELLYMAC_PROJECT_ROOT}/.jellymac_history.log"  # [Required]
                                                              # Set to /dev/null to disable history

#==============================================================================
# ADVANCED / CUSTOM TOOL PATHS
#==============================================================================
# Optional settings for overriding default tool paths.
# Uncomment and modify these only if your tools are in non-standard locations.

# [yt-dlp Path] - Override default path to yt-dlp executable
# YTDLP_PATH="/opt/homebrew/bin/yt-dlp"  # Uncomment and set if needed

# [Transmission Path] - Override default path to transmission-remote executable
# TORRENT_CLIENT_CLI_PATH="/opt/homebrew/bin/transmission-remote"  # Uncomment and set if needed

# [rsync Path] - Override default path to rsync executable
# RSYNC_PATH="/opt/homebrew/bin/rsync"  # Uncomment and set if needed

# [flock Path] - Override default path to flock executable (used for lock files)
# FLOCK_PATH="/opt/homebrew/bin/flock"  # Uncomment and set if needed

# [ffmpeg Path] - Override default path to ffmpeg executable (used for media processing)
# FFMPEG_PATH="/opt/homebrew/bin/ffmpeg"  # Uncomment and set if needed