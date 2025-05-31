# JellyMac
## Your Mac's New Personal Media Assistant

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

To begin, open the Terminal app, you can copy and paste (Cmd+C and Cmd+V) the following commands one at a time.

### Step 1: Install Homebrew and Git
Visit [brew.sh](https://brew.sh) for instructions:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
brew install git
```

### Step 2: Clone and setup JellyMac

```bash
git clone https://github.com/Mtn-Man/JellyMac.git JellyMac
cd JellyMac
chmod +x jellymac.sh bin/*.sh
```

### Step 3: Copy the configuration file

```bash
cd lib
cp jellymac_config.example.sh jellymac_config.sh
cd ..
```

### Step 4: Run JellyMac - that's it!

```bash
./jellymac.sh
```

### Interactive Setup Wizard

The interactive setup wizard takes over from here:
- Guides you through installing any missing dependencies (yt-dlp, transmission-cli, ffmpeg, etc.)
- Creates all necessary folders with sensible defaults
- Configures Transmission for magnet link automation
- Guides you through any optional settings


### What Happens Next?
After installation, you'll see the professional JellyMac banner and guided setup. The whole process takes just a few minutes, and you'll be automating your media workflow immediately.


### Zero-Config Setup

Default settings work great for local media storage and organization.
- Your movies go to `~/Movies/Movies`
- Your TV shows to `~/Movies/Shows` 
- Your Drop folder is `~/Downloads/JellyDrop`

Just press Enter through the setup and you're good to go!

### Network Setup (Optional)
You can easily configure network shares by editing the config file to add their paths before running the script.

---

When finished using JellyMac, just press `control+c` to quit, or simply close your terminal.

## REQUIREMENTS

- macOS (macOS Ventura or newer - older versions may still work, but without official homebrew support)
- Homebrew for easy dependency management
- A few minutes for the guided setup process
- [Optional] Media server (Jellyfin, Plex, etc.) for streaming organized content

Dependencies like yt-dlp, ffmpeg, transmission-cli, and flock install automatically during setup.

## DOCUMENTATION

See [`Getting_Started.txt`](Getting_Started.txt) for detailed setup instructions, configuration options, and troubleshooting guidance.

---

## IMPORTANT DISCLAIMERS

**Legal Responsibility:** Users must ensure compliance with all applicable local laws and platform terms of service. Kindly use this tool only with media you have legal rights to access and manage.

**Beta Software:** JellyMac is still in development. Always maintain backups of important media files before use.

---

## ROADMAP

Planned features include:

- **Season pack handling** - Automatically extract and organize multi-episode archives
- **Movie series detection** - Intelligently group franchises and sequels into collections  
- **Better title cleaning** - Enhanced parsing for complex release naming patterns
- **Archive extraction** - Seamlessly unpack compressed media files

Feature requests and bug reports welcome!

## CONTRIBUTORS

Eli Sher (Mtn-Man) - elisher@duck.com

## VERSION

BETA 0.2.0

## LICENSE

MIT License - See LICENSE.txt