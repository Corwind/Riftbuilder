# Changelog

All notable changes to RiftBuilder are recorded in this file. RiftBuilder follows [Semantic Versioning](https://semver.org/).

## [0.3.0] - 2026-08-28

### Added

- Added an inventory edit mode for changing each card's quantity by location, including moving, adding, and removing copies through reconciled CardNexus bulk updates.
- Added a Force catalogue sync setting for downloading and rebuilding local catalogue data even when the remote checksum has not changed.

### Fixed

- Merged card tags across catalogue printings so deck-building eligibility and card metadata remain complete regardless of which printing supplies the preferred image.
- Made empty CardNexus location deletion idempotent and compatible with successful empty response bodies, with clearer location-creation labeling.

## [0.2.2] - 2026-08-26

### Added

- Added an opt-in CardNexus HTTP debug view with credential-safe request and response logging, highlighted search results, and previous and next match navigation.

## [0.2.1] - 2026-08-23

### Added

- Added a validation checkmark beside legal deck names in the deck library.

### Fixed

- Prevented card category changes, including Chosen Champion and Main Deck transitions, from producing storage movements when the deck's physical card quantity is unchanged.

## [0.2.0] - 2026-08-23

### Added

- Added legality-aware card selection for each deck zone, including Legend-domain Champion filtering and per-zone card type and quantity limits.
- Added persistent deck editing sessions that track inventory movements, source locations, removed cards, and return destinations until changes are saved.
- Added automatic CardNexus deck-location creation and batch inventory movements when saving a deck, with a review step showing where to collect and return cards.
- Added deck disbanding that returns cards to their previous locations by default while allowing those destinations to be changed.
- Added independent settings that treat Runes and Battlefields as always available without requiring them to be scanned into inventory.
- Added deck creation from CardNexus locations classified as Deck, with one-to-one location linking and automatic reconstruction of deck contents.
- Added pending imports for incomplete location decks that can still be completed into legal decks, while rejecting structural legality violations.

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
