#!/bin/bash
# Hydra Audio — Release automation.
#
# Two modes (you're asked at start, or pass one as an argument):
#   push   — stage, commit, and push to the current branch.
#   full   — push, build the .pkg locally, wrap it in a .dmg, (re)tag, and
#            publish a GitHub Release (via the gh CLI) with the .pkg, the .dmg
#            and the .pkg SHA-256 attached, using this version's CHANGELOG
#            section as the release notes.
#
# Usage:
#   bash release.sh           # interactive: asks which mode
#   bash release.sh push      # commit + push only
#   bash release.sh full      # complete release
#
# Verbose command output is hidden and written to a log; on failure the tail of
# that log is shown. Set RELEASE_VERBOSE=1 to stream everything live.

set -euo pipefail

# ── Run from the repo root ─────────────────────────────────────────────────
# This script lives in Scripts/, but every path below (Packaging/, CHANGELOG.md,
# dist/) and all git operations are relative to the repository root. Resolve it
# from the script's own location so it works no matter where it's invoked from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)"; then
    cd "$REPO_ROOT"
else
    cd "$SCRIPT_DIR/.."   # fallback: Scripts/ → repo root
fi

# ── Configuration ──────────────────────────────────────────────────────────
# The version is read from HydraConstants.swift (single source of truth), so the
# tag, title and artifact names always match the app — nothing to bump here.
VERSION="$(sed -nE 's/.*static let version = "([^"]+)".*/\1/p' Sources/HydraCore/HydraConstants.swift | head -1)"
[ -n "$VERSION" ] || VERSION="0.0.0"
TAG="v$VERSION"
TITLE="Hydra $VERSION"
COMMIT_MSG="Release $TAG"

# ── Styling ────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
    BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
    RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; CYAN=$'\033[36m'
else
    BOLD=; DIM=; RESET=; RED=; GREEN=; YELLOW=; CYAN=
fi

LOG_FILE="$(mktemp -t hydra-release.XXXXXX.log)"
VERBOSE="${RELEASE_VERBOSE:-0}"

cleanup() { rm -f "$LOG_FILE"; }
trap cleanup EXIT

fail() {
    printf '\n%s✗ %s%s\n' "$RED$BOLD" "$*" "$RESET" >&2
    exit 1
}

note() { printf '  %s•%s %s\n' "$DIM" "$RESET" "$*"; }

# run "Label" cmd args…  → one tidy line, with a spinner-free ✓/✗.
run() {
    local label="$1"; shift
    if [ "$VERBOSE" = "1" ]; then
        printf '%s▸ %s%s\n' "$CYAN" "$label" "$RESET"
        "$@" 2>&1 | tee -a "$LOG_FILE"
        return
    fi
    printf '  %s▸%s %s…' "$CYAN" "$RESET" "$label"
    if "$@" >>"$LOG_FILE" 2>&1; then
        printf '\r  %s✓%s %s   \n' "$GREEN" "$RESET" "$label"
    else
        printf '\r  %s✗%s %s   \n' "$RED" "$RESET" "$label"
        printf '\n%sLast output:%s\n' "$DIM" "$RESET"
        tail -n 25 "$LOG_FILE" | sed 's/^/    /'
        exit 1
    fi
}

header() {
    printf '\n%s  Hydra Release %s%s  %s%s\n\n' \
        "$BOLD$CYAN" "$VERSION" "$RESET" "$DIM($1)$RESET" ""
}

# ── Mode selection ─────────────────────────────────────────────────────────
MODE="${1:-}"
if [ -z "$MODE" ]; then
    if [ -t 0 ]; then
        printf '\n%s  Hydra Release %s%s\n\n' "$BOLD$CYAN" "$VERSION" "$RESET"
        printf '  What would you like to do?\n\n'
        printf '    %s1%s  Push only   %s— commit & push to the current branch%s\n' "$BOLD" "$RESET" "$DIM" "$RESET"
        printf '    %s2%s  Full release %s— build .pkg + .dmg, tag, and publish the GitHub Release%s\n\n' "$BOLD" "$RESET" "$DIM" "$RESET"
        printf '  Choose %s[1/2]%s: ' "$BOLD" "$RESET"
        read -r choice
        case "$choice" in
            1|push|p|P) MODE="push" ;;
            2|full|f|F) MODE="full" ;;
            *) fail "Invalid choice: '$choice'" ;;
        esac
    else
        fail "No terminal to prompt. Pass a mode: bash release.sh [push|full]"
    fi
else
    case "$MODE" in
        push|full) ;;
        *) fail "Unknown mode '$MODE' (use: push | full)" ;;
    esac
fi

# ── Preflight ──────────────────────────────────────────────────────────────
command -v git >/dev/null || fail "git is required but not installed."

CURRENT_BRANCH="$(git branch --show-current)"
header "$MODE"

# ── Full-release tooling + fresh project (before committing) ───────────────
# Verify everything a full release needs up front, and regenerate the Xcode
# project so the committed pbxproj matches the current sources + signing.
if [ "$MODE" = "full" ]; then
    command -v gh >/dev/null        || fail "GitHub CLI (gh) is required. Install it: brew install gh"
    gh auth status >/dev/null 2>&1  || fail "gh is not signed in. Run: gh auth login"
    command -v xcodebuild >/dev/null || fail "xcodebuild not found — install Xcode."
    command -v hdiutil >/dev/null    || fail "hdiutil not found (macOS is required)."
    ruby -e "require 'xcodeproj'" >/dev/null 2>&1 \
        || run "Install xcodeproj gem" gem install xcodeproj --no-document
    run "Generate Xcode project" ruby Scripts/generate_xcodeproj.rb
fi

# ── Commit & push (both modes) ─────────────────────────────────────────────
git add -A
if git diff --cached --quiet; then
    note "No changes to commit"
else
    run "Commit changes" git commit -m "$COMMIT_MSG"
fi
run "Push to origin/$CURRENT_BRANCH" git push origin "$CURRENT_BRANCH"

if [ "$MODE" = "push" ]; then
    printf '\n%s  ✓ Pushed to %s.%s\n\n' "$GREEN$BOLD" "$CURRENT_BRANCH" "$RESET"
    exit 0
fi

# ── Full release: build the installer, then publish to GitHub ──────────────
DIST="dist"
PKG="$DIST/Hydra-$VERSION.pkg"
DMG="$DIST/Hydra-$VERSION.dmg"
SHA="$PKG.sha256"
NOTES="$(mktemp -t hydra-notes.XXXXXX.md)"
trap 'rm -f "$LOG_FILE" "$NOTES"' EXIT

# Build the installer FIRST — a broken build must never leave an orphan tag.
run "Build .pkg installer" bash Packaging/build_pkg.sh
[ -f "$PKG" ] || fail "build did not produce $PKG"

checksum() { ( cd "$DIST" && shasum -a 256 "$(basename "$PKG")" > "$(basename "$SHA")" ); }
run "Compute SHA-256" checksum

# Wrap the .pkg inside a compressed .dmg (drag-to-install convenience).
make_dmg() {
    local stage; stage="$(mktemp -d)"
    cp "$PKG" "$stage/"
    rm -f "$DMG"
    hdiutil create -volname "$TITLE" -srcfolder "$stage" -ov -format UDZO "$DMG" >/dev/null
    rm -rf "$stage"
}
run "Wrap .pkg in .dmg" make_dmg

# Tag this commit and push it (re-pointing an existing tag is idempotent).
git tag -fd "$TAG" >/dev/null 2>&1 || true
run "Tag $TAG" git tag -fa "$TAG" -m "$TITLE"
run "Push tag $TAG" git push --force origin "$TAG"

# Release notes = this version's CHANGELOG section.
awk "/^## \\[$VERSION/{f=1;next} /^## \\[/{f=0} f" CHANGELOG.md > "$NOTES"
[ -s "$NOTES" ] || printf 'Hydra %s\n' "$VERSION" > "$NOTES"

# Create the release (or update it if re-cutting), then upload the assets.
publish() {
    if gh release view "$TAG" >/dev/null 2>&1; then
        gh release edit "$TAG" --title "$TITLE" --notes-file "$NOTES" --latest
    else
        gh release create "$TAG" --title "$TITLE" --notes-file "$NOTES" --latest
    fi
    gh release upload "$TAG" "$PKG" "$DMG" "$SHA" --clobber
}
run "Publish GitHub Release (.pkg + .dmg)" publish

REMOTE_URL="$(git remote get-url origin 2>/dev/null || true)"
REL_URL="$(printf '%s' "$REMOTE_URL" | sed -E 's#git@github.com:#https://github.com/#; s#\.git$##')/releases/tag/$TAG"
printf '\n%s  ✓ Release %s published — .pkg + .dmg + SHA-256 attached.%s\n' "$GREEN$BOLD" "$TAG" "$RESET"
printf '  %s%s%s\n\n' "$DIM" "$REL_URL" "$RESET"
