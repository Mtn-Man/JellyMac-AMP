# Unix Philosophy Implementation Report for JellyMac

## Executive Summary

JellyMac is a well-designed media automation tool that already incorporates several Unix philosophy principles, particularly modularity and configuration-driven design. However, there are significant opportunities to better align with Unix philosophy through decomposition, improved composability, and enhanced focus on single responsibilities.

## Current State Analysis

### Strengths ✅

1. **Modular Library Structure**: Good separation in `lib/` directory with focused utility modules
2. **Configuration-Driven Design**: Externalized configuration through `jellymac_config.sh`
3. **Shell Script Foundation**: Uses the right tool (bash) for system automation
4. **Standard Tool Integration**: Leverages Unix tools like `find`, `grep`, `stat`, `flock`
5. **Logging Infrastructure**: Centralized logging with rotation and levels
6. **Helper Scripts**: Some functionality separated into `bin/` directory

### Areas for Improvement ⚠️

1. **Monolithic Main Script**: 1,366-line `jellymac.sh` violates "do one thing well"
2. **Mixed Concerns**: Single process handles clipboard monitoring, file watching, process management, notifications
3. **Complex State Management**: Shared global state across multiple responsibilities
4. **Large Configuration**: Single config file with unrelated settings
5. **Tight Coupling**: Components heavily dependent on shared state
6. **Process Orchestration**: Single script manages multiple concurrent processes

## Unix Philosophy Principles Analysis

### 1. Do One Thing and Do It Well

**Current State**: The main script handles multiple distinct responsibilities:
- Clipboard monitoring (YouTube/magnet links)
- File system watching 
- Process management and orchestration
- Desktop notifications
- Configuration validation
- Lock file management
- Caffeinate management

**Recommendation**: Decompose into focused, single-purpose tools.

### 2. Make Programs Composable

**Current State**: Components are tightly coupled through shared state and configuration.

**Recommendation**: Create independent tools that communicate through standard interfaces.

### 3. Build Simple, Transparent Tools

**Current State**: Complex internal state management makes behavior hard to predict.

**Recommendation**: Use simple, stateless components with clear inputs/outputs.

### 4. Use Shell Scripts to Leverage Other Tools

**Current State**: Good use of shell scripting, but could better leverage Unix pipeline philosophy.

**Recommendation**: Enable better pipeline integration and tool chaining.

## Detailed Recommendations

### 1. Decompose the Monolithic Watcher

**Current Architecture**:
```
jellymac.sh (1,366 lines)
├── Clipboard monitoring
├── File system watching
├── Process management
├── Notifications
└── Configuration management
```

**Proposed Architecture**:
```
jellymac-orchestrator (lightweight coordinator)
├── jellymac-clipboard-watcher
├── jellymac-folder-watcher  
├── jellymac-process-manager
├── jellymac-notifier
└── jellymac-config-validator
```

**Implementation**:

Create `bin/jellymac-clipboard-watcher`:
```bash
#!/bin/bash
# Watches clipboard for URLs and emits them to stdout
# Usage: jellymac-clipboard-watcher [--youtube] [--magnet]

while true; do
    if detect_youtube_url; then
        echo "youtube:$url"
    elif detect_magnet_url; then
        echo "magnet:$url"
    fi
    sleep "$CLIPBOARD_INTERVAL"
done
```

Create `bin/jellymac-folder-watcher`:
```bash
#!/bin/bash
# Watches folder for new files and emits events
# Usage: jellymac-folder-watcher /path/to/watch

fswatch "$WATCH_PATH" | while read -r file; do
    echo "file:$file"
done
```

### 2. Implement Event-Driven Communication

**Current**: Tight coupling through shared variables and function calls.

**Proposed**: Use Unix pipes and named pipes for inter-process communication.

**Implementation**:
```bash
# Create named pipe for events
mkfifo /tmp/jellymac-events

# Start watchers
jellymac-clipboard-watcher > /tmp/jellymac-events &
jellymac-folder-watcher "$DROP_FOLDER" > /tmp/jellymac-events &

# Process events
while IFS=: read -r event_type event_data < /tmp/jellymac-events; do
    case "$event_type" in
        youtube) jellymac-process-youtube "$event_data" ;;
        magnet)  jellymac-process-magnet "$event_data" ;;
        file)    jellymac-process-file "$event_data" ;;
    esac
done
```

### 3. Split Configuration by Concern

**Current**: Single large config file with mixed concerns.

**Proposed**: Separate configuration files by functional area.

**Implementation**:
```
config/
├── jellymac-core.conf      # Basic paths and behavior
├── jellymac-youtube.conf   # YouTube-specific settings
├── jellymac-torrent.conf   # Torrent automation settings
├── jellymac-jellyfin.conf  # Media server integration
└── jellymac-ui.conf        # Notifications and UI
```

### 4. Create Composable Processing Tools

**Current**: Monolithic processing scripts with embedded logic.

**Proposed**: Small, focused tools that can be composed.

**Implementation**:
```bash
# Individual focused tools
jellymac-youtube-download URL [OPTIONS]
jellymac-media-categorize FILE
jellymac-media-rename FILE
jellymac-media-transfer SOURCE DEST
jellymac-library-scan PATH TYPE

# Composable pipeline
echo "https://youtube.com/watch?v=..." | \
  jellymac-youtube-download --format=1440p | \
  jellymac-media-categorize | \
  jellymac-media-rename | \
  jellymac-media-transfer --dest="$YOUTUBE_LIBRARY" | \
  jellymac-library-scan --type=youtube
```

### 5. Implement Standard Unix Interfaces

**Enhance CLI Interface**:
```bash
# Make tools behave like standard Unix utilities
jellymac-youtube-download --help
jellymac-youtube-download --version
jellymac-youtube-download --quiet URL
jellymac-youtube-download --verbose URL
echo "URL" | jellymac-youtube-download --stdin
```

**Exit Codes**:
```bash
# Follow Unix conventions
0   - Success
1   - General error
2   - Misuse of shell command
130 - Terminated by Ctrl+C
```

**Standard Streams**:
```bash
# Separate concerns properly
jellymac-process-file file.mkv > /dev/null 2>errors.log
jellymac-process-file --progress file.mkv 2>&1 | tee process.log
```

### 6. Enable Pipeline Integration

**Current**: Self-contained processing with limited composability.

**Proposed**: Tools that work well in pipelines.

**Implementation**:
```bash
# Enable pipeline workflows
find "$DROP_FOLDER" -name "*.mkv" | \
  jellymac-media-categorize --stdin | \
  grep "^movie:" | \
  cut -d: -f2- | \
  jellymac-media-transfer --dest="$MOVIE_LIBRARY"

# Or for batch processing
cat urls.txt | \
  jellymac-youtube-download --batch | \
  jellymac-media-organize --youtube
```

### 7. Implement Better Logging and Observability

**Current**: Mixed logging throughout monolithic script.

**Proposed**: Structured logging with tool-specific logs.

**Implementation**:
```bash
# Each tool logs to its own stream
jellymac-clipboard-watcher 2>clipboard.log &
jellymac-folder-watcher 2>folder.log &

# Structured log format
2024-01-15T10:30:00Z INFO jellymac-youtube-download: Started download url=https://...
2024-01-15T10:30:05Z WARN jellymac-youtube-download: Rate limited, retrying in 5s
2024-01-15T10:35:00Z INFO jellymac-youtube-download: Complete size=1.2GB duration=5m
```

## Implementation Strategy

### Phase 1: Foundation (Week 1-2)
1. Create basic tool structure in `bin/`
2. Implement event communication system
3. Split configuration files
4. Create integration tests

### Phase 2: Core Tools (Week 3-4)
1. Implement clipboard watcher
2. Implement folder watcher
3. Create process manager
4. Add notification service

### Phase 3: Processing Pipeline (Week 5-6)
1. Decompose media processing
2. Implement pipeline interfaces
3. Add composability features
4. Create orchestration layer

### Phase 4: Polish (Week 7-8)
1. Add comprehensive CLI interfaces
2. Implement proper error handling
3. Add monitoring and observability
4. Create migration guide

## Expected Benefits

### 1. Maintainability
- **Focused Components**: Each tool has a single, clear responsibility
- **Isolated Testing**: Individual components can be tested independently
- **Simplified Debugging**: Issues isolated to specific tools

### 2. Composability
- **Pipeline Integration**: Tools work naturally in Unix pipelines
- **Custom Workflows**: Users can create custom automation workflows
- **Third-party Integration**: External tools can easily integrate

### 3. Reliability
- **Process Isolation**: Failure in one component doesn't crash entire system
- **Resource Management**: Better control over system resources
- **Graceful Degradation**: System continues working if non-critical components fail

### 4. Performance
- **Selective Execution**: Only run needed components
- **Parallel Processing**: Independent tools can run concurrently
- **Resource Efficiency**: Avoid unnecessary overhead

### 5. Extensibility
- **Plugin Architecture**: Easy to add new watchers or processors
- **Configuration Flexibility**: Granular control over behavior
- **Custom Tool Integration**: Users can add their own tools

## Migration Path

### Backward Compatibility
```bash
# Keep existing interface working
./jellymac.sh  # Uses new architecture internally

# Provide gradual migration
./jellymac.sh --new-mode  # Opt-in to new interface
```

### Configuration Migration
```bash
# Automatic config splitter
jellymac-migrate-config lib/jellymac_config.sh config/
```

### Gradual Adoption
1. Start with least critical components (notifications)
2. Move to file processing
3. Finally migrate clipboard monitoring
4. Remove old monolithic script

## Example: Proposed Tool Interfaces

### jellymac-youtube-download
```bash
#!/bin/bash
# Download YouTube videos with configurable options
# Usage: jellymac-youtube-download [OPTIONS] URL
# Options:
#   -f, --format FORMAT    Video format (default: 1440p)
#   -o, --output DIR       Output directory
#   -q, --quiet           Suppress progress output
#   -v, --verbose         Detailed logging
#   --archive FILE        Download archive file
#   --cookies FILE        Cookies file for authentication

jellymac-youtube-download \
  --format=1440p \
  --output="$YOUTUBE_TEMP" \
  --archive=~/.yt-archive \
  "https://youtube.com/watch?v=..."
```

### jellymac-media-categorize
```bash
#!/bin/bash
# Categorize media files by type and metadata
# Usage: jellymac-media-categorize [OPTIONS] FILE
# Output: category:path format for pipeline processing

jellymac-media-categorize "/tmp/video.mkv"
# Output: movie:/tmp/video.mkv

find . -name "*.mkv" | jellymac-media-categorize --stdin
# Output: 
# movie:./Action Movie (2023).mkv
# show:./TV Show S01E01.mkv
```

### jellymac-orchestrator
```bash
#!/bin/bash
# Lightweight coordinator that replaces monolithic jellymac.sh
# Starts appropriate watchers and manages their lifecycle

jellymac-orchestrator --config=config/jellymac-core.conf
```

## Conclusion

By implementing these Unix philosophy principles, JellyMac will become more maintainable, composable, and reliable while preserving its current functionality. The modular architecture will enable easier testing, debugging, and extension, while the pipeline-friendly interfaces will allow for more flexible automation workflows.

The proposed changes maintain backward compatibility while providing a clear migration path to a more Unix-philosophic architecture. This evolution will position JellyMac as a more robust and extensible media automation platform.