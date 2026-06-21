# Contributing to Hydra

Thank you for your interest in contributing to Hydra! We welcome bug reports, feature requests, documentation improvements, and code contributions.

## How to Contribute

### 1. Reporting Bugs
- Search existing issues to see if the bug has already been reported.
- If not, create a new issue using the **Bug Report** template.
- Provide as much detail as possible, including your environment, steps to reproduce, and any relevant logs.

### 2. Suggesting Enhancements
- Search existing issues to see if the feature has already been suggested.
- If not, create a new issue using the **Feature Request** template.
- Explain the use case and why this feature would be valuable to the community.

### 3. Submitting Code Changes
- Fork the repository.
- Create a new branch for your feature or bugfix: `git checkout -b feature/my-cool-feature`.
- Make your changes, keeping style and safety in mind (e.g., Swift 6 Concurrency practices).
- Verify that unit tests pass: `xcodebuild test -scheme HydraCore`.
- Submit a Pull Request targeting the `main` branch.

## Development Environment Setup

Please see the build instructions in the [README.md](README.md) to set up your local development environment using the Xcode project generator script:

```bash
ruby Scripts/generate_xcodeproj.rb
```

## Code of Conduct

Please be respectful and constructive in all communication and collaboration.
