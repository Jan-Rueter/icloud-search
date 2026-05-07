#!/bin/bash
# iCloud Search – Installer
# https://github.com/janrueter/icloud-search

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$HOME/Library/Scripts/icloud-search"
INDEX_DIR="$HOME/.icloud_index"
AGENTS_DIR="$HOME/Library/LaunchAgents"
PORT=8742

echo ""
echo "=== iCloud Search – Installer ==="
echo ""

# ── 1. Create directories ─────────────────────────────────────────────────────
mkdir -p "$INSTALL_DIR"
mkdir -p "$INDEX_DIR"
mkdir -p "$AGENTS_DIR"

# ── 2. Install scripts ────────────────────────────────────────────────────────
cp "$SCRIPT_DIR/icloud_indexer.sh"          "$INSTALL_DIR/"
cp "$SCRIPT_DIR/icloud_fulltext_indexer.sh" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/icloud_server.py"           "$INSTALL_DIR/"
cp "$SCRIPT_DIR/icloud_search.html"         "$INDEX_DIR/"

chmod +x "$INSTALL_DIR/icloud_indexer.sh"
chmod +x "$INSTALL_DIR/icloud_fulltext_indexer.sh"
chmod +x "$INSTALL_DIR/icloud_server.py"

echo "✓ Scripts installed: $INSTALL_DIR"

# ── 3. Detect Python 3 ───────────────────────────────────────────────────────
PYTHON=""
for candidate in /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
    if [ -x "$candidate" ]; then
        PYTHON="$candidate"
        break
    fi
done

if [ -z "$PYTHON" ]; then
    echo "✗ Python 3 not found. Please install it via: brew install python3"
    exit 1
fi
echo "✓ Python 3 found: $PYTHON"

# ── 4. LaunchAgent: nightly indexer (02:00) ──────────────────────────────────
cat > "$AGENTS_DIR/com.icloud-search.indexer.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.icloud-search.indexer</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$INSTALL_DIR/icloud_indexer.sh</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key>
        <integer>2</integer>
        <key>Minute</key>
        <integer>0</integer>
    </dict>
    <key>StandardOutPath</key>
    <string>$INDEX_DIR/indexer.log</string>
    <key>StandardErrorPath</key>
    <string>$INDEX_DIR/indexer.log</string>
</dict>
</plist>
EOF

launchctl unload "$AGENTS_DIR/com.icloud-search.indexer.plist" 2>/dev/null || true
launchctl load   "$AGENTS_DIR/com.icloud-search.indexer.plist"
echo "✓ Nightly indexer installed (runs at 02:00)"

# ── 5. LaunchAgent: web server (always on) ───────────────────────────────────
cat > "$AGENTS_DIR/com.icloud-search.server.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.icloud-search.server</string>
    <key>ProgramArguments</key>
    <array>
        <string>$PYTHON</string>
        <string>$INSTALL_DIR/icloud_server.py</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$INDEX_DIR/server.log</string>
    <key>StandardErrorPath</key>
    <string>$INDEX_DIR/server_error.log</string>
</dict>
</plist>
EOF

launchctl unload "$AGENTS_DIR/com.icloud-search.server.plist" 2>/dev/null || true
launchctl load   "$AGENTS_DIR/com.icloud-search.server.plist"
echo "✓ Web server installed (always on, port $PORT)"

# ── 6. First metadata index ───────────────────────────────────────────────────
echo ""
echo "Running first metadata index …"
bash "$INSTALL_DIR/icloud_indexer.sh"

# ── 7. Done ───────────────────────────────────────────────────────────────────
echo ""
echo "=== Installation complete ==="
echo ""
echo "Open search:  http://127.0.0.1:$PORT/icloud_search.html"
echo ""
echo "Next step (optional but recommended):"
echo "  Build full-text index (may take a while on first run):"
echo "  bash $INSTALL_DIR/icloud_fulltext_indexer.sh"
echo ""
