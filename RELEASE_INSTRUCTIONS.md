# Hydra Audio 0.15.1 Release Instructions

## Status

✅ **Build Complete** — All binaries compiled and staged in `dist/`
✅ **Git Tag Created** — `v0.15.1-beta` pushed to GitHub
✅ **Release Package Ready** — `Hydra-0.15.1-beta.zip` (6.9 MB) ready for upload

## What's Ready

```
dist/
├── HydraApp                          (11 MB, universal binary)
├── HydraApp.app/                     (macOS app bundle)
├── hydrad                            (4.6 MB, universal binary)
├── HydraVirtualSoundcard.driver/     (audio driver)
├── install.sh                        (installation script)
├── uninstall.sh                      (uninstallation script)
├── README.txt                        (user guide)
└── BUILD_INFO.txt                    (build metadata)

Hydra-0.15.1-beta.zip                 (6.9 MB, ready to upload)
RELEASE_NOTES_0.15.1.md               (release notes)
create_release.py                     (automated release tool)
```

## Option 1: Automated Release (Recommended)

### Prerequisites
1. Create a GitHub Personal Access Token:
   - Go to https://github.com/settings/tokens
   - Click "Generate new token" → "Generate new token (classic)"
   - Scopes: Select `repo` (full control of private repositories)
   - Copy the token (you'll only see it once)

2. Set the token as environment variable:
   ```bash
   export GITHUB_TOKEN="ghp_your_token_here"
   ```

### Create Release
```bash
cd /path/to/Hydra
python3 create_release.py
```

This will:
- Create the release on GitHub
- Upload the ZIP file as an asset
- Make it visible at: https://github.com/sbacaro/Hydra/releases/tag/v0.15.1-beta

## Option 2: Manual Release (via GitHub Web UI)

1. Go to https://github.com/sbacaro/Hydra/releases
2. Click "Draft a new release"
3. Choose tag: `v0.15.1-beta` (already created)
4. Release title: `Hydra Audio 0.15.1 beta`
5. Paste the contents of `RELEASE_NOTES_0.15.1.md` into the description
6. Set as **Pre-release** (checkbox)
7. Drag & drop `Hydra-0.15.1-beta.zip` into the assets area
8. Click "Publish release"

## Option 3: Manual Upload via curl

```bash
export GITHUB_TOKEN="ghp_your_token_here"
export REPO="sbacaro/Hydra"
export TAG="v0.15.1-beta"

# Get release ID
RELEASE_ID=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
  "https://api.github.com/repos/$REPO/releases/tags/$TAG" \
  | grep -o '"id": [0-9]*' | head -1 | grep -o '[0-9]*')

echo "Release ID: $RELEASE_ID"

# Upload asset
curl -X POST \
  -H "Authorization: token $GITHUB_TOKEN" \
  -H "Content-Type: application/zip" \
  --data-binary @Hydra-0.15.1-beta.zip \
  "https://uploads.github.com/repos/$REPO/releases/$RELEASE_ID/assets?name=Hydra-0.15.1-beta.zip"
```

## Verification Checklist

After release is published:

- [ ] Release visible at https://github.com/sbacaro/Hydra/releases/tag/v0.15.1-beta
- [ ] ZIP file downloadable from release page
- [ ] Release notes display correctly (Markdown formatting)
- [ ] Tag `v0.15.1-beta` exists in git history
- [ ] Main branch is up-to-date with latest commit

## Post-Release

### Update Documentation
- [ ] Add release announcement to README.md (if applicable)
- [ ] Update CHANGELOG.md with release date
- [ ] Pin release in GitHub (optional, for visibility)

### Testing
- [ ] Download ZIP from release
- [ ] Test installation on clean macOS VM
- [ ] Verify daemon starts automatically
- [ ] Test basic grid routing (Phase 2)

### Announce
- [ ] Share release link on relevant channels
- [ ] Update project website (if applicable)

## Troubleshooting

### Token Issues
- Token expired? Create a new one at https://github.com/settings/tokens
- Token wrong format? Should start with `ghp_`
- Permission denied? Token needs `repo` scope

### Upload Issues
- File too large? GitHub has a 2GB limit per file (we're at 6.9 MB, no problem)
- Network timeout? Retry the upload command
- Asset already exists? Delete the old one and re-upload

### Git Tag Issues
- Tag already exists locally? `git tag -d v0.15.1-beta` then retry
- Tag not showing on GitHub? `git push origin v0.15.1-beta`

## Files Included in Release

| File | Purpose | Size |
|------|---------|------|
| HydraApp | SwiftUI application binary | 11 MB |
| HydraApp.app | macOS app bundle (ready to run) | — |
| hydrad | Background daemon binary | 4.6 MB |
| HydraVirtualSoundcard.driver | Audio driver (256×256 backplane) | — |
| install.sh | Automated installer | 2.1 KB |
| uninstall.sh | Uninstaller | 988 B |
| README.txt | Installation & usage guide | 1.3 KB |
| BUILD_INFO.txt | Build metadata | 236 B |

## System Requirements (from Release)

- macOS 26.0 (Tahoe) or later
- Apple Silicon (arm64) or Intel (x86_64)
- Administrator access for installation
- SIP can remain enabled

## License Reminder

This release is distributed under **GPL-3.0**.

Users receive:
- Full source code (https://github.com/sbacaro/Hydra)
- GPL-3.0 license text
- Third-party credits (BlackHole, VST3 SDK, NDI runtime)
- Right to modify and redistribute under GPL terms

---

**Next Steps:**
1. Choose release method (automated recommended)
2. Set up GitHub token if using automated method
3. Run release command or use web UI
4. Verify release is live
5. Test installation on clean system
