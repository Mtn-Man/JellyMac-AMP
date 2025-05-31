=================================================================
                       JellyMac
        Your Mac's New Personal Media Assistant
=================================================================

Transform media chaos into organized bliss with just a copy or a drop.

JellyMac is the automation suite that makes media management 
easier. Copy a YouTube URL to your clipboard, copy a magnet link, 
or drop a file in your designated folder - then walk away. Your media 
appears in your library, perfectly organized, without lifting another 
finger.

THE MAGIC
---------
Copy. Drop. Done.

• Copy a YouTube URL to your clipboard -> Video downloads and organizes automatically
• Copy a magnet link to your clipboard -> Torrent starts downloading via Transmission  
• Drop or download media files to your designated folder -> Movies and TV shows get sorted with a clean name
• Zero manual work -> Everything goes to the right place with proper names, server is updated
  
KEY FEATURES
------------
• Clipboard monitoring for YouTube/magnet links
• Automatic file organization and naming
• Network-resilient transfers with retry logic  
• Direct media server integration (Jellyfin, Plex, etc.)
• Native macOS notifications and feedback

PERFECT FOR
-----------
• Media enthusiasts tired of manual file organization
• YouTube content creators downloading their own videos 
• Torrent users wanting seamless download integration
• Jellyfin/Plex users seeking effortless library management
• Anyone who believes technology should work invisibly and reliably

COMPATIBILITY
-------------
Your Mac runs JellyMac, but your media server can be anywhere - 
Linux, Windows, NAS, cloud instance. As long as your Mac can reach 
the media folders over your network, you're golden. No server-side 
installation required.

INSTALLATION
------------
To begin, open the Terminal app, you can copy and paste (Cmd+C and Cmd+V) the following commands one at a time.

Step 1: Install Homebrew and Git (visit brew.sh for instructions):

    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    brew install git

Step 2: Clone and setup JellyMac:

    git clone https://github.com/Mtn-Man/JellyMac-AMP.git JellyMac
    cd JellyMac
    chmod +x jellymac.sh bin/*.sh

Step 3: Copy the configuration file:

    cd lib
    cp jellymac_config.example.sh jellymac_config.sh
    cd ..

Step 4: Run JellyMac - that's it!

    ./jellymac.sh

The interactive setup wizard takes over from here:
• Guides you through installing any missing dependencies (yt-dlp, transmission-cli, ffmpeg, etc.)
• Creates all necessary folders with sensible defaults
• Configures Transmission for magnet link automation
• Guides you through any optional settings

Zero-Config: Default settings work perfectly for local media 
storage. Your movies go to ~/Movies/Movies, TV shows to ~/Movies/Shows, 
your Drop folder is ~/Downloads/JellyDrop. Just press Enter through the setup 
and you're ready to go!

Network Setup (Optional):You can easily configure network 
shares by editing the config file to add their paths before running the script.


When finished, just press control+c to exit or close your terminal

REQUIREMENTS
------------
• macOS (macOS Ventura or newer - older versions may still work, but without official homebrew support)
• Homebrew for easy dependency management
• A few minutes for the guided setup process
• [Optional] Media server (Jellyfin, Plex, etc.) for streaming 
  organized content

Dependencies like yt-dlp, transmission-cli, and flock install 
automatically during setup.

DOCUMENTATION
-------------
See Getting_Started.txt for detailed setup instructions, configuration 
options, and troubleshooting guidance.

=================================================================

IMPORTANT DISCLAIMERS
---------------------
Legal Responsibility: Users must ensure compliance with all applicable 
laws and platform terms of service. Use this tool only with media you have legal 
rights to access and manage.

Beta Software: JellyMac is still in development. Always maintain backups
of important media files.

=================================================================

CONTRIBUTOR(S)
------------
Eli Sher

LISENCE
-------
MIT License - See LICENSE.txt