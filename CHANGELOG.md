# Changelog

All notable changes to RiftBuilder are recorded in this file. RiftBuilder follows [Semantic Versioning](https://semver.org/).

## [0.1.1] - 2026-08-22

### Added

- Added current screenshots and a complete product overview to the README.
- Added macOS pull-request CI for dependency resolution, release metadata validation, builds, and tests.
- Added automated DMG release packaging after a pull request that updates this changelog is merged into `main`.
- Added optional Developer ID signing and Apple notarization in GitHub Actions, with an ad-hoc-signed fallback until Apple credentials are configured.
- Added a custom RiftBuilder application icon with the six Riftbound domains.

## [0.1.0] - 2026-08-22

### Added

- Added CardNexus catalogue, inventory, inventory-line, and location synchronization with batch inventory movements.
- Added location-aware quantity grouping so copies in storage remain available while copies in decks remain reserved.
- Added manual deck creation, RiftDeck text import, deck naming and renaming, legality checks, and card availability reporting.
- Added inventory, catalogue, and deck list and grid views with locally cached card artwork and detailed card previews.
- Added search across card names, rules text, domains, and card types, plus location and availability filters.
- Added storage, deck, and unavailable location policies with CardNexus location colors.
- Added light, dark, and system appearances with single-color and dual-color gradient themes and adjustable frosted transparency.
- Added Touch ID-protected Keychain storage with a 24-hour in-memory credential lifetime.
