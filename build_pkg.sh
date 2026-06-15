#!/bin/bash

# Build Hydra .pkg installer
# Creates a proper macOS installer package

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/dist"
PKG_DIR="$SCRIPT_DIR/pkg_root"
VERSION="0.15.1"

echo "🔨 Building Hydra macOS installer package..."

# Clean previous builds
rm -rf "$PKG_DIR"
mkdir -p "$PKG_DIR"

# Create package structure
mkdir -p "$PKG_DIR/usr/local/hydra"
mkdir -p "$PKG_DIR/Library/Audio/Plug-Ins/HAL"
mkdir -p "$PKG_DIR/Library/LaunchDaemons"
mkdir -p "$PKG_DIR/Applications"

# Copy binaries
if [ ! -f "$BUILD_DIR/hydrad" ]; then
    echo "❌ hydrad not found in dist/ - Run build first"
    exit 1
fi

if [ ! -d "$BUILD_DIR/HydraApp.app" ]; then
    echo "❌ HydraApp.app not found in dist/ - Run build first"
    exit 1
fi

if [ ! -d "$BUILD_DIR/HydraVirtualSoundcard.driver" ]; then
    echo "❌ HydraVirtualSoundcard.driver not found in dist/ - Run build first"
    exit 1
fi

echo "📦 Copying files to package root..."

# Copy daemon and app
cp -R "$BUILD_DIR/hydrad" "$PKG_DIR/usr/local/hydra/"
cp -R "$BUILD_DIR/HydraApp.app" "$PKG_DIR/Applications/"

# Copy driver
cp -R "$BUILD_DIR/HydraVirtualSoundcard.driver" "$PKG_DIR/Library/Audio/Plug-Ins/HAL/"

# Create LaunchDaemon plist
cat > "$PKG_DIR/Library/LaunchDaemons/com.hydra.audio.daemon.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.hydra.audio.daemon</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/hydra/hydrad</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/var/log/hydrad.log</string>
    <key>StandardErrorPath</key>
    <string>/var/log/hydrad_error.log</string>
    <key>UserName</key>
    <string>root</string>
    <key>GroupName</key>
    <string>wheel</string>
</dict>
</plist>
EOF

# Create post-install script
cat > "$PKG_DIR/post_install" << 'EOF'
#!/bin/bash

# Post-install script for Hydra
echo "🔧 Configuring Hydra Audio..."

# Restart Core Audio to load the driver
echo "Restarting Core Audio..."
sudo launchctl unload /System/Library/LaunchDaemons/com.apple.audio.coreaudiod.plist 2>/dev/null || true
sudo launchctl load /System/Library/LaunchDaemons/com.apple.audio.coreaudiod.plist 2>/dev/null || true
sleep 2

# Load the LaunchDaemon
echo "Loading Hydra daemon..."
sudo launchctl load -w /Library/LaunchDaemons/com.hydra.audio.daemon.plist

# Set permissions
echo "Setting permissions..."
sudo chown -R root:wheel /Library/Audio/Plug-Ins/HAL/HydraVirtualSoundcard.driver
sudo chmod -R 755 /Library/Audio/Plug-Ins/HAL/HydraVirtualSoundcard.driver
sudo chown -R root:wheel /usr/local/hydra
sudo chmod -R 755 /usr/local/hydra

echo "✅ Hydra Audio installation complete!"
echo "   Launch Hydra from Applications folder"
EOF

chmod +x "$PKG_DIR/post_install"

# Create pre-install script
cat > "$PKG_DIR/pre_install" << 'EOF'
#!/bin/bash

# Pre-install script for Hydra
echo "🔧 Preparing Hydra Audio installation..."

# Stop existing daemon if running
sudo launchctl unload /Library/LaunchDaemons/com.hydra.audio.daemon.plist 2>/dev/null || true
pkill -f hydrad 2>/dev/null || true

echo "✅ Pre-install checks complete"
EOF

chmod +x "$PKG_DIR/pre_install"

# Create distribution file for pkgbuild
cat > "$SCRIPT_DIR/Distribution.xml" << EOF
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="1">
    <title>Hydra Audio</title>
    <organization>Hydra Audio Project</organization>
    <identifier>com.hydra.audio.installer</identifier>
    <version>$VERSION</version>
    
    <options rootVolumeOnly="true" customize="never" allow-external-scripts="no"/>
    
    <background file="background.png" alignment="bottomleft" scaling="proportional"/>
    <welcome file="Welcome.txt"/>
    <license file="LICENSE"/>
    <conclusion file="Conclusion.txt"/>
    
    <choices-outline>
        <line choice="default"/>
    </choices-outline>
    
    <choice id="default" title="Hydra Audio" description="Professional audio patch bay for macOS">
        <pkg-ref id="com.hydra.audio.core"/>
    </choice>
    
    <pkg-ref id="com.hydra.audio.core" version="$VERSION" onConclusion="none">HydraAudio.pkg</pkg-ref>
</installer-gui-script>
EOF

# Create welcome text
cat > "$SCRIPT_DIR/Welcome.txt" << 'EOF'
Welcome to Hydra Audio

Hydra Audio is a professional-grade audio patch bay for macOS that brings together:
• 256×256 virtual soundcard backplane
• Per-app audio capture
• AES67/Dante interoperability
• VST3 plugin hosting
• NDI audio streaming
• Scene management and recording

This installer will place:
• HydraApp in your Applications folder
• Audio driver in /Library/Audio/Plug-Ins/HAL
• Daemon in /usr/local/hydra
• Launch service for automatic startup

Administrator privileges are required for audio driver installation.
EOF

# Create conclusion text
cat > "$SCRIPT_DIR/Conclusion.txt" << 'EOF'
Installation Complete!

Hydra Audio has been successfully installed on your Mac.

To get started:
1. Open Hydra from your Applications folder
2. Grant microphone permissions when prompted
3. Configure your audio routing in the grid

The Hydra daemon will start automatically and run in the background.

For documentation and support:
• GitHub: https://github.com/sbacaro/Hydra
• Documentation: https://github.com/sbacaro/Hydra/blob/main/README.md

Thank you for using Hydra Audio!
EOF

# Build the package
echo "📦 Building .pkg package..."

pkgbuild \
    --root "$PKG_DIR" \
    --identifier com.hydra.audio.core \
    --version "$VERSION" \
    --install-location "/" \
    --scripts "$PKG_DIR" \
    --ownership preserve \
    "$SCRIPT_DIR/HydraAudio.pkg"

# Build the final installer with productbuild
echo "📦 Building final installer..."
productbuild \
    --distribution "$SCRIPT_DIR/Distribution.xml" \
    --package-path "$SCRIPT_DIR" \
    --resources "$SCRIPT_DIR" \
    "$SCRIPT_DIR/Hydra-$VERSION.pkg"

# Clean up temporary files
rm -f "$SCRIPT_DIR/HydraAudio.pkg"
rm -rf "$PKG_DIR"

echo "✅ Package created successfully: Hydra-$VERSION.pkg"
echo "   Size: $(du -h "$SCRIPT_DIR/Hydra-$VERSION.pkg" | cut -f1)"

# Verify package
echo "🔍 Verifying package..."
pkgutil --check-signature "$SCRIPT_DIR/Hydra-$VERSION.pkg" || true

echo "🎉 Hydra installer ready for distribution!"