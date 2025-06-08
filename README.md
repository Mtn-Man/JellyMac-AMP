# 🪼 JellyMac

### Automated Media Assistant for macOS

Transform media chaos into organized bliss with just a copy or a drop.

JellyMac is a simple but powerful automation suite that makes media management easier. Copy a YouTube URL to your clipboard, copy a magnet link, or drop a file in your designated folder - then walk away. Your media appears in your library, perfectly organized, without lifting another finger.

## THE MAGIC

**Copy. Drop. Done.**

- **Copy a YouTube URL** to your clipboard → Video downloads and organizes automatically
- **Copy a magnet link** to your clipboard → Torrent starts downloading via Transmission  
- **Drop or download media files** to your drop folder → Movies and TV shows get sorted with a clean name
- **Zero manual work** → Everything goes to the right place with proper names, server is updated

## KEY FEATURES

- Clipboard monitoring for YouTube/magnet links
- Automatic file organization and naming
- Network-resilient transfers with retry logic  
- Direct media server integration (Jellyfin, Plex, etc.)
- Native macOS notifications and feedback

## PERFECT FOR

- Media enthusiasts tired of manual file organization
- YouTube content creators downloading their own videos
- Torrent users wanting seamless download integration
- Jellyfin/Plex users seeking effortless library management
- Mac users just looking for an easy way to organize or transfer their existing Movies and Shows

## COMPATIBILITY

Your Mac runs JellyMac, but your media server can be anywhere - Linux, Windows, NAS, cloud instance. As long as your Mac can reach the media folders over your network, you're golden. **No server-side installation required.**

## INSTALLATION

To get started with JellyMac, open your Terminal app. You can copy and paste (Cmd+C and Cmd+V) the following commands one at a time.

### Step 1: Install Homebrew (if you don't have it) and Git

First, install Homebrew by pasting this command and following the on-screen instructions:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

Then, install Git using Homebrew:

```bash
brew install git
```

### Step 2: Download and Prepare JellyMac

Clone the JellyMac repository from GitHub:

```bash
git clone https://github.com/Mtn-Man/JellyMac.git JellyMac
```

Navigate into the JellyMac directory and make the necessary scripts executable:

```bash
cd JellyMac && chmod +x jellymac.sh bin/*.sh
```

### Step 3: Run JellyMac for the First Time

Now, start JellyMac:

```bash
./jellymac.sh
```

On its first run, JellyMac initiates an interactive setup wizard that will:
- Offer to create a default configuration file (lib/jellymac_config.sh) if it's missing
- Guide you through installing any missing helper programs (like yt-dlp, transmission-cli, ffmpeg, or flock)
- Create necessary operational folders with sensible defaults
- Offer to automatically configure Transmission for seamless magnet link automation

### Step 4: Customize Your Configuration (Recommended)

After the initial setup, JellyMac creates lib/jellymac_config.sh. It's highly recommended to edit this file to match your setup, especially if you use a media server or network storage.

To edit:
1. Navigate to the lib folder inside your JellyMac directory
2. Open lib/jellymac_config.sh with a text editor (e.g., nano, TextEdit)
3. Key paths to update include:
   - DEST_DIR_MOVIES: Your main movies library folder
   - DEST_DIR_SHOWS: Your main TV shows library folder
   - DEST_DIR_YOUTUBE: Where YouTube downloads should go
   - DROP_FOLDER: The folder JellyMac will monitor
   
   Refer to Getting_Started.txt or Configuration_Guide.txt for details on all options
4. Save the file. JellyMac will use these new settings the next time it runs or processes media

### Zero-Config Setup (for Local Use)

If you're using JellyMac only for local media on your Mac and don't have a separate media server, the default paths created by the setup wizard often work out of the box:
- Movies are typically organized in `~/Movies/Movies`
- TV shows in `~/Movies/Shows` 
- The drop folder is usually `~/Downloads/JellyDrop`

You can often press Enter through most setup prompts for this scenario.

---

When finished using JellyMac, press `Ctrl+C` in the Terminal window where it's running, or simply close the Terminal window.

## REQUIREMENTS

- macOS (macOS Ventura or newer - older versions may still work, but without official homebrew support)
- Homebrew for easy dependency management
- A few minutes for the guided setup process
- [Optional] Media server (Jellyfin, Plex, etc.) for streaming organized content

Dependencies like yt-dlp, ffmpeg, transmission-cli, and flock will be offered to be installed automatically during setup if they're not already installed.

## DOCUMENTATION

See [`Getting_Started.txt`](Getting_Started.txt) for detailed setup instructions, configuration options, and troubleshooting guidance.

---

## IMPORTANT DISCLAIMERS

**Legal Responsibility:** Users must ensure compliance with all applicable local laws and platform terms of service. Kindly use this tool only with media you have legal rights to access and manage.

**Beta Software:** JellyMac is still in development. Always maintain backups of important media files before use.

---

## ROADMAP

Planned features include:

- **Movie/TV Show season/collection/pack handling** - Automatically extract and organize multi-episode archives into the correct structure
- **YouTube playlist support** - Download and organize entire playlists automatically
- **Enhanced metadata extraction** - Better parsing and organization of media information
- **Improved file recognition and filtering** - More accurate identification of media types
- **GUI version** - User-friendly graphical interface for configuration and monitoring
- **Archive extraction** - Seamlessly unpack compressed media files without manual intervention

Feature requests and bug reports welcome!

## CONTRIBUTORS

Eli Sher (Mtn-Man) - elisher@duck.com

## VERSION

BETA 0.2.3

## LICENSE

MIT License - See LICENSE.txt