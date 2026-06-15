# Releasing Hydra & the auto-update system

Hydra updates itself in-app via [Sparkle](https://sparkle-project.org). It checks
GitHub on launch and every 24 h; when a new release appears the user is notified
(an in-app banner + Sparkle's standard update window) and the new version installs
on confirmation. The HAL **driver** is refreshed automatically on the next launch
when its version changes — so updates ship as a plain app zip, not a `.pkg`.

```
new tag ──► GitHub Actions (release.yml) ──► builds Hydra.app (universal)
                                          ├─ zips it  → Hydra-X.Y.Z.zip
                                          ├─ EdDSA-signs the zip
                                          ├─ generate_appcast → appcast.xml
                                          └─ attaches both to the GitHub Release
app (SUFeedURL = releases/latest/download/appcast.xml) ──► sees the update
```

The `.pkg` (built with `Packaging/build_pkg.sh`) is only the **first-time
installer**; updates after that go through Sparkle.

---

## One-time setup (do this once)

Sparkle verifies every update with an **EdDSA signature** (this is independent of
Apple notarization — it works for an unsigned/ad-hoc app).

1. **Fetch the Sparkle tools** (also done automatically by the project generator):

   ```bash
   bash Scripts/fetch_sparkle.sh
   ```

2. **Generate the key pair:**

   ```bash
   ./ThirdParty/Sparkle/bin/generate_keys
   ```

   This stores the **private** key in your login Keychain and prints the
   **public** key (a base64 string).

3. **Paste the public key into the app.** In `Sources/HydraApp/Info.plist`,
   replace `REPLACE_WITH_SPARKLE_PUBLIC_ED_KEY` (key `SUPublicEDKey`) with it,
   then regenerate the project:

   ```bash
   ruby Scripts/generate_xcodeproj.rb
   ```

4. **Export the private key and store it as a CI secret.**

   ```bash
   ./ThirdParty/Sparkle/bin/generate_keys -x sparkle_private_key.txt
   ```

   In GitHub → **Settings → Secrets and variables → Actions → New repository
   secret**, name it **`SPARKLE_ED_PRIVATE_KEY`** and paste the file's contents.
   Then delete the file — it must never be committed (it's git-ignored, but still).

> The `SUFeedURL` in `Info.plist` is set to
> `https://github.com/sbacaro/Hydra/releases/latest/download/appcast.xml`.
> If you fork/rename the repo, update that URL.

---

## Cutting a release

1. Bump the version in `Scripts/generate_xcodeproj.rb` (`MARKETING` / `BUILD_NUM`)
   and regenerate (`ruby Scripts/generate_xcodeproj.rb`). Commit.
2. Tag and push:

   ```bash
   git tag v0.20.0
   git push origin v0.20.0
   ```

3. `release.yml` runs on the tag: it builds the universal app, zips and
   EdDSA-signs it, generates `appcast.xml`, and publishes a GitHub Release named
   `Hydra X.Y.Z` with `Hydra-X.Y.Z.zip` + `appcast.xml` attached.

That's it — installed copies will offer the update within a day (or immediately
via **Hydra ▸ Check for Updates…**).

### Attaching the `.pkg` (optional, for new users)

The release workflow ships only the update artifacts. To give first-time users an
installer on the same release page, build and upload the `.pkg` manually:

```bash
bash Packaging/build_pkg.sh
gh release upload v0.20.0 "dist/Hydra-0.20.0.pkg"
```

---

## How it behaves in the app

- **Checks:** on launch and every 24 h (`SUEnableAutomaticChecks`,
  `SUScheduledCheckInterval` in `Info.plist`).
- **Notification:** Sparkle's standard window + an in-app banner; also surfaced in
  the menu bar ("Update to vX…") and **Settings ▸ General ▸ Updates**.
- **Install:** with the user's confirmation (no silent installs —
  `SUAutomaticallyUpdate` is `false`).
- **Driver:** on the next launch, if the driver bundled in the updated app is
  newer than the one in `/Library/Audio/Plug-Ins/HAL`, Hydra reinstalls it (one
  admin prompt, only when it actually changed) — see
  `InstallManager.refreshDriverIfOutdated()`.

## Notes & gotchas

- The app and the embedded `Sparkle.xcframework` are **ad-hoc signed** in CI
  (`CODE_SIGN_IDENTITY="-"`), which is enough for Sparkle's helper XPC services to
  run. Trust comes from the EdDSA signature, not Apple notarization.
- Don't lose the private key. If it leaks or is lost you must generate a new pair
  and ship an update signed with the old key that carries the new public key
  (Sparkle's key-rotation flow).
- `ThirdParty/Sparkle/` and `appcast.xml` are git-ignored; the framework is
  re-fetched by `Scripts/fetch_sparkle.sh` (pinned version + sha256).
