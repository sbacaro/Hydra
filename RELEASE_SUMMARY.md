# Hydra Audio 0.15.1 beta — Release Summary

**Status:** ✅ **READY FOR DISTRIBUTION**  
**Release Date:** June 14, 2026  
**Git Tag:** `v0.15.1-beta`  
**Repository:** https://github.com/sbacaro/Hydra

---

## 📦 What's Ready

### Build Artifacts (in `dist/`)
```
HydraApp                    11 MB   SwiftUI application (universal binary)
HydraApp.app/               —       macOS app bundle (ready to launch)
hydrad                      4.6 MB  Background daemon (universal binary)
HydraVirtualSoundcard.driver —      256×256 virtual audio backplane
install.sh                  2.1 KB  Automated installation script
uninstall.sh                988 B   Uninstallation script
README.txt                  1.3 KB  User guide
BUILD_INFO.txt              236 B   Build metadata
```

### Release Package
- **Hydra-0.15.1-beta.zip** — 6.9 MB, ready for GitHub release

### Documentation
- **RELEASE_NOTES_0.15.1.md** — Complete release notes (copy to GitHub)
- **RELEASE_INSTRUCTIONS.md** — Step-by-step distribution guide
- **create_release.py** — Automated release tool (Python 3)

---

## 🚀 How to Publish

### Quick Path (Recommended)
1. Create GitHub Personal Access Token:
   - Go to https://github.com/settings/tokens
   - Generate new token (classic), scope: `repo`
   - Copy token

2. Run automated release:
   ```bash
   export GITHUB_TOKEN="ghp_your_token_here"
   python3 create_release.py
   ```

3. Verify at: https://github.com/sbacaro/Hydra/releases/tag/v0.15.1-beta

### Manual Path (via GitHub Web UI)
1. Go to https://github.com/sbacaro/Hydra/releases
2. Click "Draft a new release"
3. Select tag: `v0.15.1-beta` (already created ✓)
4. Title: `Hydra Audio 0.15.1 beta`
5. Description: Copy from `RELEASE_NOTES_0.15.1.md`
6. Mark as **Pre-release**
7. Upload: `Hydra-0.15.1-beta.zip`
8. Publish

---

## ✅ Verification Checklist

### Before Publishing
- [x] All source code committed to GitHub
- [x] Git tag `v0.15.1-beta` created and pushed
- [x] Binaries compiled (arm64 + x86_64 universal)
- [x] Installation scripts tested
- [x] Release notes written
- [x] ZIP package created (6.9 MB)

### After Publishing
- [ ] Release visible on GitHub
- [ ] ZIP file downloadable
- [ ] Release notes render correctly
- [ ] Download and test on clean macOS VM
- [ ] Verify `install.sh` works
- [ ] Test basic functionality (Phase 2)

---

## 📋 Installation Verification

### Test on Clean System
```bash
# Download release
unzip Hydra-0.15.1-beta.zip
cd Hydra-0.15.1-beta

# Install
sudo bash install.sh

# Verify
/usr/local/hydra/hydrad &
open -a Hydra

# Test Phase 2 (basic routing)
# 1. Set app output to "Hydra Virtual Soundcard"
# 2. Play audio
# 3. In Hydra, patch In 1 → Out 3
# 4. Verify audio appears at Out 3
```

---

## 📊 Release Metrics

| Metric | Value |
|--------|-------|
| Total Size (ZIP) | 6.9 MB |
| Binaries (universal) | arm64 + x86_64 |
| Minimum macOS | 26.0 (Tahoe) |
| License | GPL-3.0 |
| Dependencies Bundled | BlackHole (customized) |
| Dependencies Loaded at Runtime | NDI (optional) |
| Supported Architectures | 2 |
| Build Time | ~5 minutes |

---

## 📝 Git History

```
92a0559 Release: v0.15.1 beta - Prepare for distribution
199eee9 Fix: Add HydraModuleABI target to Package.swift
793135a Merge remote-tracking branch 'origin/main'
3754d3a Initial commit: Hydra Audio
277044a Initial commit

Tag: v0.15.1-beta → 793135a (initial full release)
```

---

## 🎯 Features in This Release

### Phase 2: Grid Engine ✓
- 256×256 virtual soundcard backplane
- Per-connection gain control
- Atomic scene switching
- Real-time metering

### Phase 2b: Physical Devices ✓
- Automatic device discovery
- Drift correction (ASRC)
- Multi-clock support
- Auto-rebinding on reconnect

### Phase 3: Per-App Capture ✓
- Core Audio process taps (macOS 14.4+)
- Automatic app detection
- Per-app routing
- TCC permission handling

### Phase 4: AES67 RX ✓
- SAP/SDP discovery
- RTP stream reception
- Multicast support
- Auto-rebinding

### Phase 6: VST3 ✓
- Plugin hosting
- Channel strips (insert + trim)
- Live parameter editing
- Plugin scanning

### Phase 7: Polish ✓
- Scenes (save/load/recall)
- Disk recording (WAV)
- OSC remote control
- Event logging
- Feedback protection

---

## 🔧 Technical Details

### Build Configuration
- **Swift:** 5.9+
- **Xcode:** 26.5
- **C++:** C++23 (cxx2b)
- **macOS SDK:** 26.5
- **Deployment Target:** macOS 26.0

### Binaries
- **HydraApp:** SwiftUI executable (11 MB)
- **hydrad:** Swift daemon (4.6 MB)
- **HydraVirtualSoundcard.driver:** AudioServerPlugIn (customized BlackHole)

### Installation Locations
- Binaries: `/usr/local/hydra/`
- Driver: `/Library/Audio/Plug-Ins/HAL/`
- Daemon: LaunchDaemon at `/Library/LaunchDaemons/com.hydra.audio.daemon.plist`
- User Data: `~/Library/Application Support/Hydra/`

---

## 📚 Documentation Included

1. **README.md** — Project overview and quick start
2. **CHANGELOG.md** — Complete version history
3. **PROJETO_HYDRA_FUNDACAO.md** — Complete architecture document (Portuguese)
4. **THIRD_PARTY_NOTICES.md** — Licenses and credits
5. **LICENSE** — Full GPL-3.0 text

---

## 🎉 Ready to Ship

Everything is prepared for distribution:

✅ **Code** — All source on GitHub  
✅ **Binaries** — Compiled universal (arm64 + x86_64)  
✅ **Installer** — Automated `install.sh`  
✅ **Documentation** — Complete and accurate  
✅ **License** — GPL-3.0 compliant  
✅ **Release Notes** — Written and formatted  
✅ **Git Tag** — Created and pushed  
✅ **ZIP Package** — Ready for upload  

**Next Step:** Publish the release using one of the methods in `RELEASE_INSTRUCTIONS.md`

---

## 📞 Support Resources

- **Repository:** https://github.com/sbacaro/Hydra
- **Issues:** https://github.com/sbacaro/Hydra/issues
- **Discussions:** https://github.com/sbacaro/Hydra/discussions
- **License:** GPL-3.0 (https://www.gnu.org/licenses/gpl-3.0.html)

---

**Release prepared by:** Lume (AI Assistant)  
**Date:** June 14, 2026  
**Status:** Ready for distribution ✅
