#!/bin/bash
set -e

WORKSPACE_DIR="/Users/Vedant/Documents/ds4_rumble_bridge"
BOTTLE_STEAM_DIR="/Volumes/Mac_EXT/CrossOverData/CrossOver/Bottles/Steam/drive_c/Program Files (x86)/Steam"
GAME_DIR="$BOTTLE_STEAM_DIR/steamapps/common/Horizon Forbidden West Complete Edition"

echo "=== 1. Cross-compiling Windows Proxy DLLs ==="
# Compile 64-bit SteamAPI DLL for games
x86_64-w64-mingw32-g++ -shared -static -static-libgcc -static-libstdc++ -o "$WORKSPACE_DIR/steam_api64.dll" "$WORKSPACE_DIR/steam_api.cpp" "$WORKSPACE_DIR/steam_api.def" -lws2_32
echo "Success: Compiled 64-bit steam_api64.dll"

# Compile 32-bit DirectInput DLL for Steam client
i686-w64-mingw32-g++ -shared -static -static-libgcc -static-libstdc++ -o "$WORKSPACE_DIR/dinput8_32.dll" "$WORKSPACE_DIR/dinput8.cpp" "$WORKSPACE_DIR/dinput8.def" -lws2_32
echo "Success: Compiled 32-bit dinput8_32.dll"

echo "=== 2. Building macOS DS4Link App ==="
rm -rf "$WORKSPACE_DIR/DS4Link.app"
mkdir -p "$WORKSPACE_DIR/DS4Link.app/Contents/MacOS"
mkdir -p "$WORKSPACE_DIR/DS4Link.app/Contents/Resources"

# Write Info.plist with icon and name keys
cat << 'EOF' > "$WORKSPACE_DIR/DS4Link.app/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.antigravity.DS4Link</string>
    <key>CFBundleName</key>
    <string>DS4Link</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.1.0</string>
    <key>CFBundleVersion</key>
    <string>3</string>
    <key>LSMinimumSystemVersion</key>
    <string>11.0</string>
    <key>LSUIElement</key>
    <false/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
</dict>
</plist>
EOF

# Copy DLLs to app Resources
cp "$WORKSPACE_DIR/dinput8_32.dll" "$WORKSPACE_DIR/DS4Link.app/Contents/Resources/"
cp "$WORKSPACE_DIR/steam_api64.dll" "$WORKSPACE_DIR/DS4Link.app/Contents/Resources/"

# Copy AppIcon.icns to app Resources
if [ -f "$WORKSPACE_DIR/AppIcon.icns" ]; then
    cp "$WORKSPACE_DIR/AppIcon.icns" "$WORKSPACE_DIR/DS4Link.app/Contents/Resources/"
    echo "Success: Copied AppIcon.icns to app Resources"
else
    echo "Warning: AppIcon.icns not found, skipping icon copy"
fi

# Compile Swift app
swiftc -O -o "$WORKSPACE_DIR/DS4Link.app/Contents/MacOS/DS4Link" "$WORKSPACE_DIR/DS4Link.swift"
echo "Success: DS4Link.app compiled at $WORKSPACE_DIR/DS4Link.app"

echo "=== 3. Auto-Deploying to test bottle (for local verification) ==="
# Patch test registry (local)
python3 "$WORKSPACE_DIR/configure_bottle.py"

# Deploy DLLs (local)
if [ -d "$GAME_DIR" ]; then
    rm -f "$GAME_DIR/dxgi.dll"
    rm -f "$GAME_DIR/dxgi_original.dll"
    
    if [ -f "$GAME_DIR/steam_api64.dll" ] && [ ! -f "$GAME_DIR/steam_api64_original.dll" ]; then
        cp "$GAME_DIR/steam_api64.dll" "$GAME_DIR/steam_api64_original.dll"
        echo "Success: Created backup steam_api64_original.dll"
    fi
    cp "$WORKSPACE_DIR/steam_api64.dll" "$GAME_DIR/steam_api64.dll"
    echo "Success: Deployed 64-bit steam_api64.dll to game folder"
fi
if [ -d "$BOTTLE_STEAM_DIR" ]; then
    cp "$WORKSPACE_DIR/dinput8_32.dll" "$BOTTLE_STEAM_DIR/dinput8.dll"
    echo "Success: Deployed 32-bit dinput8.dll to Steam folder"
fi

echo "=== BUILD AND DEPLOYMENT COMPLETED SUCCESSFULLY! ==="
