#!/bin/bash
# Hydra Audio Package Builder — GPL-3.0

set -euo pipefail

# Configuration
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="0.15.1"
IDENTIFIER="com.hydra.audio.pkg"
PKG_NAME="Hydra-${VERSION}.pkg"
STAGING_DIR="${PROJECT_DIR}/release-staging"
PKG_ROOT="${STAGING_DIR}/pkg-root"

log() { printf '\033[1;35m[PKG Build]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[PKG Build] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# Clean previous builds
log "Cleaning previous builds..."
rm -rf "$STAGING_DIR"
rm -f "${PROJECT_DIR}/${PKG_NAME}"

# Create staging directory structure
log "Creating package structure..."
mkdir -p "$PKG_ROOT/usr/local/hydra"
mkdir -p "$PKG_ROOT/Library/Audio/Plug-Ins/HAL"
mkdir -p "$STAGING_DIR/scripts"

# Copy binaries
if [[ -d "${PROJECT_DIR}/dist" ]]; then
    log "Copying binaries..."
    cp -R "${PROJECT_DIR}/dist/HydraApp" "$PKG_ROOT/usr/local/hydra/"
    cp "${PROJECT_DIR}/dist/hydrad" "$PKG_ROOT/usr/local/hydra/"
    
    # Create app symlink
    ln -sf "/usr/local/hydra/HydraApp/HydraApp.app" "$PKG_ROOT/usr/local/hydra/Hydra.app"
    
    # Copy driver if exists
    if [[ -d "${PROJECT_DIR}/dist/HydraVirtualSoundcard.driver" ]]; then
        cp -R "${PROJECT_DIR}/dist/HydraVirtualSoundcard.driver" "$PKG_ROOT/Library/Audio/Plug-Ins/HAL/"
    fi
else
    fail "Build artifacts not found in dist/. Run build first."
fi

# Copy postinstall script
log "Adding post-install script..."
cp "${PROJECT_DIR}/Scripts/postinstall" "$STAGING_DIR/scripts/"
chmod +x "$STAGING_DIR/scripts/postinstall"

# Create distribution file
log "Creating distribution definition..."
cat > "$STAGING_DIR/distribution.xml" << 'EOF'
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="1">
    <title>Hydra Audio</title>
    <organization>com.hydra.audio</organization>
    <identifier>com.hydra.audio.pkg</identifier>
    <version>0.15.1</version>
    
    <background file="background.png" alignment="bottomleft" scaling="proportional"/>
    <welcome file="welcome.txt"/>
    <license file="LICENSE"/>
    <conclusion file="conclusion.txt"/>
    
    <options requireAdmin="true" customize="never"/>
    
    <choices-outline>
        <line choice="default"/>
    </choices-outline>
    
    <choice id="default" title="Hydra Audio" description="Professional audio patch bay for macOS">
        <pkg-ref id="com.hydra.audio.pkg"/>
    </choice>
    
    <pkg-ref id="com.hydra.audio.pkg" version="0.15.1" onConclusion="none">#hydra.pkg</pkg-ref>
</installer-gui-script>
EOF

# Create welcome text
cat > "$STAGING_DIR/welcome.txt" << 'EOF'
Welcome to Hydra Audio

Hydra Audio is a professional-grade audio patch bay for macOS that brings together:
• 256×256 virtual soundcard backplane
• Per-app audio capture
• AES67/Dante interoperability
• VST3 plugin hosting
• Network audio streaming (NDI)
• Scene management and recording

System Requirements:
• macOS 26.0 (Tahoe) or later
• Administrator access
• 100 MB free disk space

Click Continue to proceed with the installation.
EOF

# Create conclusion text
cat > "$STAGING_DIR/conclusion.txt" << 'EOF'
Installation Complete!

Hydra Audio has been successfully installed on your system.

What's been installed:
• Hydra application in /usr/local/hydra/
• Audio driver in /Library/Audio/Plug-Ins/HAL/
• Background daemon (auto-starts)

Getting Started:
1. Open Hydra from Applications or run: open -a Hydra
2. Grant audio capture permissions when prompted
3. Start routing audio between apps, devices, and networks

Documentation:
• Visit https://github.com/sbacaro/Hydra for full documentation
• Check README.txt in /usr/local/hydra/ for quick start

Thank you for installing Hydra Audio!
EOF

# Copy LICENSE if exists
if [[ -f "${PROJECT_DIR}/LICENSE" ]]; then
    cp "${PROJECT_DIR}/LICENSE" "$STAGING_DIR/"
fi

# Build the package
log "Building package..."
cd "$STAGING_DIR"

pkgbuild \
    --root "$PKG_ROOT" \
    --identifier "$IDENTIFIER" \
    --version "$VERSION" \
    --install-location "/" \
    --scripts "$STAGING_DIR/scripts" \
    --ownership recommended \
    "${STAGING_DIR}/hydra.pkg"

productbuild \
    --distribution "$STAGING_DIR/distribution.xml" \
    --resources "$STAGING_DIR" \
    --package-path "$STAGING_DIR" \
    "${PROJECT_DIR}/${PKG_NAME}"

# Verify package
if [[ -f "${PROJECT_DIR}/${PKG_NAME}" ]]; then
    PKG_SIZE=$(du -h "${PROJECT_DIR}/${PKG_NAME}" | cut -f1)
    log "✓ Package created successfully!"
    log "  File: ${PROJECT_DIR}/${PKG_NAME}"
    log "  Size: $PKG_SIZE"
else
    fail "Package creation failed!"
fi

# Clean staging
log "Cleaning staging files..."
rm -rf "$STAGING_DIR"

log "✓ Package build complete!"
EOF
