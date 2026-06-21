# Security Policy

## Supported Versions

Only the latest release version of Hydra is supported for security updates.

| Version | Supported |
| ------- | --------- |
| v0.21.0+ | :white_check_mark: |
| < v0.21.0 | :x: |

## Reporting a Vulnerability

We take the security of Hydra seriously. If you find a security vulnerability, please do not report it via public GitHub issues. Instead, send an email to the maintainers at `samuelbacaro@gmail.com`.

We will acknowledge your report within 48 hours and work with you to resolve the issue as quickly as possible.

## Update integrity & trust model

Hydra updates itself in-app (see `Sources/HydraApp/Updater.swift`): on launch and
every 24 h it queries the latest GitHub Release, downloads the `.pkg`, and
**verifies it against the published `Hydra-X.Y.Z.pkg.sha256` checksum before
installing** (the install runs via a single macOS admin prompt). There is no
third-party update framework.

Because Hydra is **not distributed with an Apple Developer ID** (no code
signing / notarization), the update channel's integrity does **not** come from an
Apple signature. It comes from:

1. The **SHA-256 checksum**, generated in a clean-room CI environment
   (`.github/workflows/release.yml`) and attached to the GitHub Release.
2. The **GitHub release itself** — i.e. whoever controls the repository's
   releases controls what installs. The trust root is therefore the GitHub
   account and repository, not a private signing key.

This means protecting the GitHub account/repo *is* protecting Hydra's users.

### Maintainer hardening checklist

- **2FA** enabled on the maintainer GitHub account (ideally a hardware key).
- **Branch protection** on `main`: require pull-request review, disallow
  force-pushes and deletions.
- **Protected tags** for `v*` so only maintainers can push release tags.
- **Restrict who can publish releases** (repo → Settings → Actions / Roles).
- Releases are built and published **only** by `release.yml`, which is gated to
  the canonical repository (`if: github.repository == …`) so a fork can't
  publish an installer the updater would fetch.
- Workflows run with **least privilege** (`permissions: contents: read` for CI;
  `contents: write` only on the release workflow).
- GitHub Actions are **pinned to commit SHAs** (with the version in a trailing
  comment), so a compromised action *tag* can't silently change what runs. When
  bumping an action, update the SHA and the comment together.

### What the app does NOT do

- It never installs an update whose SHA-256 doesn't match the published checksum.
- It never silently elevates privileges — every install goes through the system
  authorization prompt.
