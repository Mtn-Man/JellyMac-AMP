=================================================================
                    JellyMac AMP
     Lightweight macOS Automated Media Pipeline
=================================================================

A free, lightweight automation suite that simplifies media management on macOS.
With just a clipboard copy of the link, download videos from YouTube or grab torrents 
via their magnet links. Automatically organize downloaded movies and TV shows into a 
clean library structure, with optional integration for Jellyfin, Plex and other 
media servers. This app is modular: you can use specific features independently 
or set up a complete end-to-end media pipeline - the choice is yours.

FEATURES
--------
* Interactive Onboarding: User-friendly first-time setup with automatic 
  dependency detection and installation options.
* Clipboard Monitoring: Auto-downloads YouTube videos and sends magnet
  links to Transmission for download.
* Drop Folder Automation: Sorts and organizes movies, TV shows, and
  their related files (e.g. info and subtitle files).
* File Stability Detection: Ensures files are completely transferred 
  before processing to prevent corruption.
* Jellyfin Integration: Cleans up filenames, moves files, and triggers
  library updates.
* macOS Native: Works with standard macOS functions and notifications.
* Robust Error Handling: Prevents race conditions and partial file processing.

COMPATIBILITY
-------------
JellyMac AMP runs on your Mac in the terminal app of your choice. 
Your Jellyfin server can be running on Linux, Windows, macOS, or even a NAS 
- as long as your Mac can access the  media folders via a 
network share (SMB, NFS, etc.), JellyMac AMP will work. 
No additional software needs to be installed on the server itself.

**DISCLAIMER**
---------------------------------------------------------------------
JellyMac AMP is a tool designed to automate media management tasks.

Users are responsible for ensuring that their use of this software
complies with all applicable laws, including copyright regulations,
and respects the terms of service of any third-party platforms
accessed.

This tool should be used only with media that you have the legal right
to access, download, and manage.

The developers of JellyMac AMP do not endorse or condone any form of
copyright infringement.

ALPHA SOFTWARE NOTICE: JellyMac AMP is in early development. While thoroughly
tested, there is always a risk of unintended data loss with software
that manages files. Users should ALWAYS maintain backups of important
media files.
---------------------------------------------------------------------

REQUIREMENTS
------------
* macOS (Bash 3.2)
* Homebrew (https://brew.sh)
* flock, yt-dlp, transmission-cli (install via Homebrew)
* [Optional] A Media server (Jellyfin, Plex, Emby, etc.) for streaming organized content

QUICK START
-----------
1. Install Homebrew (if not already installed):

       /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

2. Clone the repo and make scripts executable:

      git clone https://github.com/Mtn-Man/JellyMac-AMP.git JellyMac_AMP
      cd JellyMac_AMP
      chmod +x jellymac.sh bin/*.sh

3. Configure:
   
   For configuration, copy lib/jellymac_config.example.sh and rename the copy to jellymac_config.sh.
 Then, open the new jellymac_config.sh file and edit it to add your file paths - edit any other desired setting as 	well while you're there.
   (At minimum, please set your destination media folders -one for Shows, one for Movies-
   and DROP_FOLDER locations)

4. Run JellyMac AMP:

       ./jellymac.sh
   
   The interactive onboarding process will:
   - Detect any missing dependencies
   - Offer to install them for you
   - Guide you through first-time setup

DOCUMENTATION
-------------
See Getting_Started.txt for full setup, configuration, and
troubleshooting instructions.

ABOUT
-----
JellyMac AMP was created by Eli Sher, May 2025.

LICENSE
-------
MIT License - See LICENSE.txt