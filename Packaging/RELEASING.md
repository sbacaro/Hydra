# Releasing Hydra & the auto-update system

Hydra updates itself in-app with a small built-in updater (no third-party
framework — see `Sources/HydraApp/Updater.swift`). It polls the latest GitHub
Release on launch and every 24 h; when a newer version is found it downloads the
`.pkg`, verifies it against the published **SHA-256**, and installs it via a
single macOS admin password prompt, then relaunches. The `.pkg` installs both
the app and the HAL **driver**, so everything stays in sync in one step.

```
new tag ──► GitHub Actions (release.yml) ──► builds Hydra-X.Y.Z.pkg (app + driver)
                                          ├─ shasum -a 256 → Hydra-X.Y.Z.pkg.sha256
                                          └─ attaches both to the GitHub Release
app (Updater.swift) ──► GET /releases/latest ──► downloads .pkg, checks SHA-256,
                                                 installs via admin prompt
```

Integrity comes from the SHA-256 sidecar published next to the `.pkg`. There are
no signing keys to manage for the update channel (Developer ID signing is still
optional, for Gatekeeper on *first* install — see below).

---

## Cutting a release

1. Bump the version in `Scripts/generate_xcodeproj.rb` (`MARKETING` / `BUILD_NUM`)
   and in `Sources/HydraCore/HydraConstants.swift` (`Hydra.version`). Commit.
2. Use the helper (asks push-only vs. full), or tag manually:

   ```bash
   bash Scripts/release.sh        # choose "Full release"
   # or:
   git tag v0.21.0 && git push origin v0.21.0
   ```

3. `release.yml` runs on the tag: it builds `Hydra-X.Y.Z.pkg`, computes
   `Hydra-X.Y.Z.pkg.sha256`, and publishes a GitHub Release named `Hydra X.Y.Z`
   with **both** files attached (release notes auto-generated).

That's it — installed copies update within a day, or immediately via
**Hydra ▸ Check for Updates…**.

> The updater finds the repo automatically from `Hydra.sourceURL`
> (`HydraConstants.swift`). If you fork/rename, update that URL.

---

## How it behaves in the app

- **Checks:** on launch and every 24 h (toggle in **Settings ▸ General ▸
  Updates**; persisted in `UserDefaults`).
- **Install:** fully automatic — downloads in the background, verifies the
  SHA-256, then shows the **system password prompt** (the only interaction) and
  installs + relaunches. One attempt per launch; if the user cancels the prompt,
  the menu bar / Settings keep offering a manual retry.
- **Surfacing:** the available version drives the in-app banner, the menu-bar
  "Update to vX…" button, and **Settings ▸ General ▸ Updates**.
- **Driver + daemon:** updated by the `.pkg` itself (app → /Applications, driver
  → /Library/Audio/Plug-Ins/HAL, postinstall restarts coreaudiod). No separate
  driver-refresh step is needed for an in-app update.

## Security note

The admin password prompt is unavoidable for a system install — macOS always
asks. Integrity of the download is enforced by the SHA-256 check **before** the
installer runs; a download that doesn't match its published checksum is discarded
and never installed.

## Optional: Developer ID signing (Gatekeeper, first install)

The SHA-256 channel does not require signing. But for a smooth **first** install
on other Macs (no Gatekeeper warning), sign + notarize the `.pkg`. Set these
GitHub Actions secrets and `build_pkg.sh` will sign:

- `APP_SIGN_ID` — `Developer ID Application: NAME (TEAMID)`
- `INSTALLER_SIGN_ID` — `Developer ID Installer: NAME (TEAMID)`

See `Packaging/README.md` for notarization.
