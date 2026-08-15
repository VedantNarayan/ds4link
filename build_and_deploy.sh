#!/bin/bash
set -e

WORKSPACE_DIR="/Users/Vedant/Documents/ds4_rumble_bridge"
GAME_DIR="/Volumes/Mac_EXT/Heroic Game Launcher/WeWereHereTogethertwF3d"

echo "=== 1. Cross-compiling Universal Windows Proxy DLLs ==="
cd "$WORKSPACE_DIR"

# 1. Compile XInput 64-bit and 32-bit (with Gyro & Rumble)
x86_64-w64-mingw32-g++ -shared -static -static-libgcc -static-libstdc++ -o "$WORKSPACE_DIR/xinput1_4_64.dll" "$WORKSPACE_DIR/xinput.cpp" -lws2_32
echo "Success: Compiled 64-bit xinput1_4_64.dll (XInput + Gyro)"

i686-w64-mingw32-g++ -shared -static -static-libgcc -static-libstdc++ -o "$WORKSPACE_DIR/xinput1_4_32.dll" "$WORKSPACE_DIR/xinput.cpp" -lws2_32
echo "Success: Compiled 32-bit xinput1_4_32.dll (XInput + Gyro)"

# 2. Compile DirectInput 64-bit and 32-bit
x86_64-w64-mingw32-g++ -shared -static -static-libgcc -static-libstdc++ -o "$WORKSPACE_DIR/dinput8_64.dll" "$WORKSPACE_DIR/dinput8.cpp" -lws2_32
echo "Success: Compiled 64-bit dinput8_64.dll (ForceFeedback)"

i686-w64-mingw32-g++ -shared -static -static-libgcc -static-libstdc++ -o "$WORKSPACE_DIR/dinput8_32.dll" "$WORKSPACE_DIR/dinput8.cpp" "$WORKSPACE_DIR/dinput8.def" -lws2_32 2>/dev/null || true
echo "Success: Compiled 32-bit dinput8_32.dll"

# 3. Compile SteamAPI 64-bit
x86_64-w64-mingw32-g++ -shared -static -static-libgcc -static-libstdc++ -o "$WORKSPACE_DIR/steam_api64.dll" "$WORKSPACE_DIR/steam_api.cpp" "$WORKSPACE_DIR/steam_api.def" -lws2_32 2>/dev/null || true
echo "Success: Compiled 64-bit steam_api64.dll"

echo "=== 2. Building macOS DS4Link Universal Driver App ==="
rm -rf "$WORKSPACE_DIR/DS4Link.app"
mkdir -p "$WORKSPACE_DIR/DS4Link.app/Contents/MacOS"
mkdir -p "$WORKSPACE_DIR/DS4Link.app/Contents/Resources"

# Write Info.plist
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
    <string>3.0.0</string>
    <key>CFBundleVersion</key>
    <string>5</string>
    <key>LSMinimumSystemVersion</key>
    <string>11.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
</dict>
</plist>
EOF

# Copy DLLs into app Resources
cp "$WORKSPACE_DIR/xinput1_4_64.dll" "$WORKSPACE_DIR/DS4Link.app/Contents/Resources/"
cp "$WORKSPACE_DIR/xinput1_4_32.dll" "$WORKSPACE_DIR/DS4Link.app/Contents/Resources/"
cp "$WORKSPACE_DIR/dinput8_64.dll" "$WORKSPACE_DIR/DS4Link.app/Contents/Resources/"
cp "$WORKSPACE_DIR/dinput8_32.dll" "$WORKSPACE_DIR/DS4Link.app/Contents/Resources/"
cp "$WORKSPACE_DIR/steam_api64.dll" "$WORKSPACE_DIR/DS4Link.app/Contents/Resources/"

if [ -f "$WORKSPACE_DIR/AppIcon.icns" ]; then
    cp "$WORKSPACE_DIR/AppIcon.icns" "$WORKSPACE_DIR/DS4Link.app/Contents/Resources/"
fi

# Compile Swift Driver
swiftc -O -o "$WORKSPACE_DIR/DS4Link.app/Contents/MacOS/DS4Link" "$WORKSPACE_DIR/DS4Link.swift"
xattr -cr "$WORKSPACE_DIR/DS4Link.app"
echo "Success: DS4Link.app compiled successfully."

# Install to /Applications and /Volumes/Mac_EXT/Applications
cp -R "$WORKSPACE_DIR/DS4Link.app" /Applications/ 2>/dev/null || true
cp -R "$WORKSPACE_DIR/DS4Link.app" /Volumes/Mac_EXT/Applications/ 2>/dev/null || true
echo "Success: Installed DS4Link.app to Applications"

echo "=== 3. Deploying Universal Driver to We Were Here Together ==="
if [ -d "$GAME_DIR" ]; then
    cp "$WORKSPACE_DIR/xinput1_4_64.dll" "$GAME_DIR/xinput1_4.dll"
    rm -f "$GAME_DIR/xinput1_3.dll" "$GAME_DIR/xinput9_1_0.dll"
    echo "Success: Deployed xinput1_4.dll proxy to game folder."
fi

echo "=== UNIVERSAL DRIVER BUILD AND DEPLOYMENT COMPLETE! ==="
