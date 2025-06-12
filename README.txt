┌─────────────────────────────────────────────────────────────┐
│                     J E L L Y M A C                         │
│          Automated Media Assistant for macOS                │
└─────────────────────────────────────────────────────────────┘

Transform media chaos into organized bliss with just a copy or a drop.

JellyMac is a simple but powerful automation suite that makes media management 
easier. Copy a YouTube URL to your clipboard, copy a magnet link, 
or drop a file in your designated folder - then walk away. Your media 
appears in your library, perfectly organized, without lifting another 
finger.


THE MAGIC
---------
Copy. Drop. Done.

• Copy a YouTube URL to your clipboard -> Video downloads and organizes automatically
• Copy a magnet link to your clipboard -> Torrent starts downloading via Transmission  
• Drop or download media files to your drop folder -> Movies and TV shows get sorted with a clean name
• Intelligent duplicate prevention -> Never waste bandwidth on already-downloaded content
• Zero manual work -> Everything goes to the right place with proper names, server is updated
  

KEY FEATURES
------------
• Intelligent duplicate prevention - Cross-session memory prevents re-downloading content
• Complete automation chains - Magnet -> Download -> Organization -> Library integration
• Clipboard monitoring - YouTube/magnet links processed automatically from clipboard
• Network-resilient transfers - Smart retry logic and connection validation
• Associated file handling - Subtitles, metadata, and extras automatically organized
• Production-ready logging - Comprehensive audit trails and debugging capabilities
• Direct media server integration - Jellyfin, Plex auto-scanning with granular controls
• Native macOS notifications - Visual and audio feedback for all operations


PERFECT FOR
-----------
• Media enthusiasts tired of manual file organization
• YouTube content creators downloading their own videos
• Torrent users wanting seamless download integration
• Jellyfin/Plex users seeking effortless library management
• Mac users just looking for an easy way to organize or transfer their existing Movies and Shows


COMPATIBILITY
-------------
Your Mac runs JellyMac, but your media server can be anywhere - 
Linux, Windows, NAS, cloud instance. As long as your Mac can reach 
the media folders over your network, you're golden. No server-side 
installation required.


SMART AUTOMATION
----------------
Duplicate Prevention:
• Cross-session memory - Remembers downloads across restarts and system reboots
• Bandwidth optimization - Never re-downloads the same YouTube videos or torrents
• Archive persistence - Tracks video IDs and torrent hashes automatically

Network Intelligence:
• Auto-mount detection - Validates network share availability before transfers
• Retry logic - Handles temporary network issues and connection drops gracefully
• Path validation - Ensures destinations are accessible before processing begins

Complete Media Pipeline:
• File stability checking - Waits for downloads to complete fully before processing
• Associated file handling - Moves subtitles, NFO files, and extras together automatically
• Format standardization - Cleans filenames for optimal media server compatibility
• Background processing - Non-blocking operations let you continue working


INSTALLATION
------------
To get started with JellyMac, open your Terminal app (or shell of choice). 
You can copy and paste (Cmd+C and Cmd+V) the following commands one at
a time.

Step 1: Install Homebrew (if you don't have it) and Git

First, install Homebrew by pasting this command and
following the on-screen instructions:

    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

Important: After Homebrew installs, it will show you commands to add it to your PATH. 
Copy and run those exact commands before continuing.

Then, install Git using Homebrew:

    brew install git

Step 2: Download and Prepare JellyMac

Clone the JellyMac repository from GitHub:

    git clone https://github.com/Mtn-Man/JellyMac.git

Navigate into the JellyMac directory and make the
necessary scripts executable:

    cd JellyMac && chmod +x jellymac.sh bin/*.sh

Step 3: Run JellyMac for the First Time

Now, start JellyMac:

    ./jellymac.sh

On its first run, JellyMac initiates an interactive setup
wizard that will:
• Smart dependency management - Choose permanent auto-install or one-time setup
• Complete Transmission integration -
    Background service + automatic download folder configuration for seamless magnet -> library workflow
• Media player optimization - IINA setup for enhanced codec support
• Network path validation - Ensures media server connections work properly
• Automatic directory creation - Sets up all required folders with proper permissions

Step 4: Configure Your Setup

After the initial setup, JellyMac creates lib/jellymac_config.sh and offers two options:

Option 1: Edit Configuration Now
- Choose this if you use a media server, NAS, or custom library locations
- JellyMac opens the config file in TextEdit for immediate customization
- Save your changes and restart JellyMac to use your custom settings

Option 2: Use Default Local Setup
- Choose this for simple local media organization on your Mac
- Uses standard paths: ~/Movies/Movies, ~/Movies/Shows, ~/Downloads/JellyDrop
- You can always edit lib/jellymac_config.sh later if your needs change

Refer to Getting_Started.txt or Configuration_Guide.txt for details on all configuration options.

When finished using JellyMac, press Ctrl+C in the Terminal
window where it's running, or simply close the Terminal window.


REQUIREMENTS
------------
• macOS (macOS Ventura or newer - older versions will likely still work, but without official homebrew support)
• Homebrew for easy dependency management
• A few minutes for the guided setup process
• [Optional] Media server (Jellyfin, Plex, etc.) for streaming 
  organized content

Dependencies like yt-dlp, ffmpeg, transmission-cli, and flock will be offered to be installed automatically during setup,
if they're not already installed.


DOCUMENTATION
-------------
• Getting_Started.txt - Detailed setup and configuration
• Quick_Reference.txt - Common tasks and commands
• Configuration_Guide.txt - Advanced customization options


=================================================================

IMPORTANT DISCLAIMERS
---------------------
Legal Responsibility: Users must ensure compliance with all applicable local
laws and platform terms of service. Kindly use this tool only with media you have legal 
rights to access and manage.

Beta Software: JellyMac is still in development. Always maintain backups
of important media files before use.

=================================================================

ROADMAP
-------
Planned features include:

• Movie/TV Show season/collection/pack handling - Automatically extract and organize multi-episode archives into the correct structure
• YouTube playlist support - Download and organize entire playlists automatically
• Enhanced metadata extraction - Better parsing and organization of media information
• Improved file recognition and filtering - More accurate identification of media types
• GUI version - User-friendly graphical interface for configuration and monitoring
• Archive extraction - Seamlessly unpack compressed media files without manual intervention

Feature requests and bug reports welcome!

CONTRIBUTORS
------------
Eli Sher (Mtn-Man) - elisher@duck.com

VERSION
-------
BETA v0.2.4

LICENSE
-------
MIT License - See LICENSE.txt