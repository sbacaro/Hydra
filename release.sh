#!/bin/bash
# Hydra Audio — Release automation script.
#
# This script:
#   1. Stages all changes and commits them with a release message.
#   2. Pushes the commit to the current branch on origin.
#   3. Deletes any existing local/remote tag of the same version to avoid conflicts (optional/override).
#   4. Creates a new git tag and pushes it.
#   5. Runs the packaging script to build the release .pkg installer.
#   6. Uses the GitHub CLI (gh) to create the release and upload the installer.
#
# Usage:
#   bash release.sh

set -euo pipefail

# 1. Configuration
VERSION="0.20.0"
TAG="v$VERSION"
TITLE="Hydra $VERSION beta"
COMMIT_MSG="Release $TAG: Modernization, Concurrency, and UI Polishing"

log() { printf '\033[1;36m[release]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[release] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# Check dependencies
command -v git >/dev/null || fail "git is required but not installed."
command -v gh >/dev/null || fail "gh (GitHub CLI) is required. Install with: brew install gh"

# Check GitHub auth status
gh auth status >/dev/null || fail "You must be authenticated with the GitHub CLI (run: gh auth login)."

# 2. Git Commit and Push
log "Staging all changes..."
git add -A

log "Committing changes..."
if git commit -m "$COMMIT_MSG"; then
    log "Committed: $COMMIT_MSG"
else
    log "No changes to commit or commit failed."
fi

CURRENT_BRANCH=$(git branch --show-current)
log "Pushing changes to origin/$CURRENT_BRANCH..."
git push origin "$CURRENT_BRANCH"

# 3. Handle Tagging
log "Recreating local and remote tag $TAG..."
git tag -d "$TAG" 2>/dev/null || true
git push origin :refs/tags/"$TAG" 2>/dev/null || true

log "Creating tag $TAG..."
git tag -a "$TAG" -m "$TITLE"

log "Pushing tag $TAG..."
git push origin "$TAG"

# 4. Build Packaging
log "Building release package (.pkg)..."
bash Packaging/build_pkg.sh

PKG_PATH="dist/Hydra-$VERSION.pkg"
[ -f "$PKG_PATH" ] || fail "Package build failed, file not found at $PKG_PATH"

# 5. Create GitHub Release and Upload Artifact
log "Creating GitHub Release $TAG and uploading $PKG_PATH..."

# We extract the latest release notes from CHANGELOG.md for this release.
# Extracts everything between the ## [0.20.0 beta] header and the next header.
NOTES_FILE="build/release_notes.md"
mkdir -p build
awk '/^## \[0.20.0/ {flag=1; next} /^## \[/ {flag=0} flag' CHANGELOG.md > "$NOTES_FILE"

# If release notes were not found, use a fallback message
if [ ! -s "$NOTES_FILE" ]; then
    echo "Release $TITLE: Modernization, Concurrency, and UI Polishing." > "$NOTES_FILE"
fi

# Create the release and upload the .pkg
gh release create "$TAG" \
  --title "$TITLE" \
  --notes-file "$NOTES_FILE" \
  "$PKG_PATH"

log "Release $TAG successfully published on GitHub!"
log "Release page: $(gh release view "$TAG" --json url -q .url)"
