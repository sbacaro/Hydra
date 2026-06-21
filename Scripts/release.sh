#!/bin/bash
# Hydra Audio — Release automation.
#
# Two modes (you're asked at start, or pass one as an argument):
#   push   — stage, commit, and push to the current branch.
#   full   — push, then (re)tag, build the .pkg, and publish a GitHub release.
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
VERSION="0.20.0"
TAG="v$VERSION"
TITLE="Hydra $VERSION beta"
COMMIT_MSG="Release $TAG: Modernization, Concurrency, and UI Polishing"

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
        printf '    %s2%s  Full release %s— push, tag, build .pkg, publish on GitHub%s\n\n' "$BOLD" "$RESET" "$DIM" "$RESET"
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

if [ "$MODE" = "full" ]; then
    if command -v gh >/dev/null; then
        GH_BIN="gh"
    elif [ -f "/opt/homebrew/bin/gh" ]; then
        GH_BIN="/opt/homebrew/bin/gh"
    else
        fail "gh (GitHub CLI) is required for a full release. Install: brew install gh"
    fi
    $GH_BIN auth status >/dev/null 2>&1 || fail "Authenticate first: $GH_BIN auth login"
fi

CURRENT_BRANCH="$(git branch --show-current)"
header "$MODE"

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

# ── Tagging (full only) ────────────────────────────────────────────────────
git tag -d "$TAG" >/dev/null 2>&1 || true
git push origin :refs/tags/"$TAG" >/dev/null 2>&1 || true
run "Tag $TAG" git tag -a "$TAG" -m "$TITLE"
run "Push tag $TAG" git push origin "$TAG"

# ── Package (full only) ────────────────────────────────────────────────────
run "Build installer (.pkg)" bash Packaging/build_pkg.sh
PKG_PATH="dist/Hydra-$VERSION.pkg"
[ -f "$PKG_PATH" ] || fail "Package build succeeded but $PKG_PATH is missing."

# ── Release notes (from CHANGELOG) ─────────────────────────────────────────
NOTES_FILE="build/release_notes.md"
mkdir -p build
awk '/^## \[0.20.0/ {flag=1; next} /^## \[/ {flag=0} flag' CHANGELOG.md > "$NOTES_FILE"
[ -s "$NOTES_FILE" ] || echo "Release $TITLE." > "$NOTES_FILE"

# ── Publish (full only) ────────────────────────────────────────────────────
run "Publish GitHub release" \
    "$GH_BIN" release create "$TAG" --title "$TITLE" --notes-file "$NOTES_FILE" "$PKG_PATH"

URL="$($GH_BIN release view "$TAG" --json url -q .url 2>/dev/null || true)"
printf '\n%s  ✓ Released %s%s\n' "$GREEN$BOLD" "$TAG" "$RESET"
[ -n "$URL" ] && printf '  %s%s%s\n' "$DIM" "$URL" "$RESET"
printf '\n'
