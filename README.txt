┌─────────────────────────────────────────────────────────────┐
│                     J E L L Y M A C                         │
│           Automated Video Downloader for macOS              │
└─────────────────────────────────────────────────────────────┘

JellyMac is a lightweight tool that simplifies managing your media 
library. Whether you're downloading YouTube videos, organizing movies 
and TV shows, or automating torrent workflows, JellyMac handles it all 
with ease. Designed for macOS users, it integrates seamlessly with 
media servers like Jellyfin and Plex.


WHO THIS IS FOR
---------------

✓ Anyone who downloads YouTube videos and wants them organized automatically

✓ People who collect movies and TV shows and want seamless organization
 
✓ Mac users who want powerful automation that works reliably behind the scenes

✓ Content creators and researchers who need reliable video archiving
  
✓ Home media enthusiasts who want professional-quality organization
  

WHAT IT DOES
------------

Core Automation:

• Complete YouTube Workflow - Copy links → Download → Perfect 
  file names → Library → Server update (optional)

• Complete Magnet Workflow - Copy links → Transmission → 
  Download → Sort → Library → Server update (optional)

• Intelligent File Organization - Movies and TV shows 
  automatically sorted with clean names

• Background Processing - Everything happens automatically 
  while you work

Smart Features:

• Never Download Twice - Remembers what you've downloaded across restarts
  
• Progress Notifications - Desktop alerts when downloads complete
 
• Network Smart - Works well with local folders or with network drives/NAS

• Queue Management - Copy multiple links, they process automatically
 

Media Server Integration:

• Jellyfin Integration - Auto-scan libraries when new content arrives

• Plex Support - Works with Plex media servers

• No Server Installation - Your Mac runs JellyMac, media 
  server can be anywhere


QUICKSTART GUIDE
----------------

Step 1: Install Homebrew

If you don't already have Homebrew, install it by running this 
command in Terminal:

    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

Step 2: Install JellyMac

Run this command to download and set up JellyMac:

    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Mtn-Man/JellyMac/dev/install.sh)"

Step 3: Run JellyMac

Start JellyMac with:

    cd ~/JellyMac && ./jellymac.sh

Follow the interactive setup to configure your media folders and 
services. For detailed instructions, see the Getting_Started.txt 
file.


=================================================================

IMPORTANT DISCLAIMERS
---------------------
Beta Software: JellyMac is still in development. For extra safety, 
always maintain backups of important media files before use.

Legal Responsibility: Use this tool only with media you have the 
legal right to access and manage. Ensure compliance with local 
laws and platform terms of service.

=================================================================

LICENSE AND CONTACT
-------------------
License: MIT License - See LICENSE.txt
Contributor: Eli Sher (Mtn-Man) - elisher@duck.com