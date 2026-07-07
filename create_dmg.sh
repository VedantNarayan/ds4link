#!/bin/bash
set -e

WORKSPACE_DIR="/Users/Vedant/Documents/ds4_rumble_bridge"
TEMP_DIR="$WORKSPACE_DIR/dmg_temp"
DMG_NAME="$WORKSPACE_DIR/DS4Link.dmg"

echo "=== Packaging DS4Link into DMG ==="
rm -rf "$TEMP_DIR"
rm -f "$DMG_NAME"
mkdir -p "$TEMP_DIR"

# Copy App to temp folder
cp -R "$WORKSPACE_DIR/DS4Link.app" "$TEMP_DIR/"

# Create symlink to /Applications
ln -s /Applications "$TEMP_DIR/Applications"

# Create the DMG
hdiutil create -volname "DS4Link Installation" -srcfolder "$TEMP_DIR" -ov -format UDZO "$DMG_NAME"

rm -rf "$TEMP_DIR"
echo "=== Success: DMG created successfully at $DMG_NAME ==="
