=================================================================
                       JellyMac AMP
                Your Mac's Personal Media Assistant
=================================================================

Transform media chaos into organized bliss with just a copy or a drop.

JellyMac AMP is the automation suite that makes media management 
invisible. Copy a YouTube URL to your clipboard, copy a magnet link, 
or drop a file in your designated folder - then walk away. Your media 
appears in your library, perfectly organized, without lifting another 
finger.

THE MAGIC
---------
Copy. Drop. Done.

* Copy a YouTube URL to your clipboard -> Video downloads and organizes automatically
  
* Copy a magnet link to your clipboard -> Torrent starts downloading via Transmission  
  
* Drop or download media files to your designated folder -> Movies and TV shows get sorted and renamed
  
* Zero manual work -> Everything goes to the right place with proper names, server is updated

  
WHAT MAKES IT SPECIAL
---------------------

Intelligent Automation
Your Mac watches your clipboard and designated drop folder. Copy a 
link anywhere on your Mac, and JellyMac AMP springs into action. No 
buttons to click, no interfaces to manage - just seamless background 
magic.

Network-Smart Operations
Your Mac runs JellyMac AMP, but your media server can be anywhere - 
Linux, Windows, NAS, cloud instance. As long as your Mac can reach 
the media folders over your network, you're golden. No server-side 
installation required. Built for the real world where WiFi hiccups 
and network shares occasionally disconnect. Automatic retries, resume 
capability, and graceful handling of network issues mean your 
transfers complete reliably.

Media Server Ready
Works beautifully with Jellyfin, Plex, Emby, and others. Files appear 
properly named and organized, with automatic library updates so your 
content is immediately streamable.

macOS Native Experience
Desktop notifications, sound feedback, and clipboard integration that 
feels like it belongs on your Mac. No clunky cross-platform 
compromises.

PERFECT FOR
-----------
* Media enthusiasts tired of manual file organization
* YouTube content creators downloading their own videos 
* Torrent users wanting seamless download integration
* Jellyfin/Plex users seeking effortless library management
* Anyone who believes technology should work invisibly and reliably

COMPATIBILITY
-------------
Your Mac runs JellyMac AMP, but your media server can be anywhere - 
Linux, Windows, NAS, cloud instance. As long as your Mac can reach 
the media folders over your network, you're golden. No server-side 
installation required.

INSTALLATION
------------

Step 1: Install Homebrew and Git (visit brew.sh for instructions then) run:

    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

    brew install git

Step 2: Clone and setup JellyMac AMP, run:

    git clone https://github.com/Mtn-Man/JellyMac-AMP.git JellyMac_AMP
    
    cd JellyMac_AMP

    chmod +x jellymac.sh bin/*.sh

Step 3: Configure your paths:

Copy lib/jellymac_config.example.sh to jellymac_config.sh and edit it 
with your media folder locations (Movies, TV Shows, and Drop Folder 
paths).

Step 4: Launch and enjoy! run:

    ./jellymac.sh

The friendly setup wizard handles dependency installation and walks you 
through first-time configuration. Within minutes, you'll have your 
personal media assistant running in the background.

Step 5 (optional): When finished, just press control+c to exit or close your terminal

REQUIREMENTS
------------
* macOS (any recent version)
* Homebrew for easy dependency management
* A few minutes for the guided setup process
* [Optional] Media server (Jellyfin, Plex, etc.) for streaming 
  organized content

Dependencies like yt-dlp, transmission-cli, and flock install 
automatically during setup.

DOCUMENTATION
-------------
See Getting_Started.txt for detailed setup instructions, configuration 
options, and troubleshooting guidance.

THE BOTTOM LINE
---------------
JellyMac AMP transforms media management from a chore into an invisible 
background process. It's sophisticated enough for power users but 
simple enough for anyone who just wants their media library to "just 
work."

Because life's too short to have to manually organize files.

=================================================================

IMPORTANT DISCLAIMERS
---------------------
Legal Responsibility: Users must ensure compliance with all applicable 
laws and platform terms of service. Use only with media you have legal 
rights to access and manage.

Beta Software: JellyMac AMP is still in early development. Always maintain 
backups of important media files.

=================================================================

Created by Eli Sher, May 2025
MIT License - See LICENSE.txt