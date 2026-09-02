# RiftBuilder

[![CI](https://github.com/Corwind/Riftbuilder/actions/workflows/ci.yml/badge.svg)](https://github.com/Corwind/Riftbuilder/actions/workflows/ci.yml)
[![Release](https://github.com/Corwind/Riftbuilder/actions/workflows/release.yml/badge.svg)](https://github.com/Corwind/Riftbuilder/actions/workflows/release.yml)

RiftBuilder is a native macOS application for browsing the complete Riftbound catalogue, managing a CardNexus-backed collection, and building decks from the cards that are physically available.

![RiftBuilder inventory showing a location-filtered grid of Riftbound cards](docs/images/inventory.png)

## Highlights

- Synchronizes the Riftbound catalogue, inventory lines, quantities, locations, and location colors from CardNexus.
- Preserves every remote inventory line, then groups copies by card and location for accurate owned and available totals.
- Treats cards in storage boxes as available, cards in assembled deck locations as unavailable to other decks, and locally disabled locations as hidden from the rest of the app.
- Imports RiftDeck text exports, including punctuation variants such as `Ezreal, Prodigy` and `Ezreal - Prodigy`.
- Reports which deck cards are available in storage, already committed to another deck, or missing; basic runes are treated as unlimited.
- Supports deck naming and renaming, legality checks, card-type organization, catalogue search, location filtering, list and grid layouts, and detailed card previews.
- Searches card names, rules text, domains, and types, so queries such as `empower` find cards by ability text.
- Caches catalogue data, inventory data, deck definitions, and card artwork locally for fast navigation and offline browsing.
- Offers light, dark, and system appearances with single-color or dual-color gradient themes and adjustable frosted-glass transparency.

## Deck building

Create a deck manually or import a RiftDeck text export. RiftBuilder resolves each entry against the catalogue, validates the deck, compares its requirements with location-aware availability, and keeps Legend, Champion, Main Deck, Battlefields, Rune Pool, and Sideboard sections distinct.

![RiftBuilder deck view showing an Ezreal deck, legality summary, domains, and card grid](docs/images/decks.png)

A local deck definition does not reserve inventory by itself. Physical availability changes only when cards move between CardNexus locations. Explicit assembly and disassembly actions use CardNexus inventory batch updates to move or split the corresponding inventory lines.

## Inventory availability

CardNexus remains authoritative for owned quantities and physical locations. RiftBuilder never flattens distinct remote inventory lines during synchronization.

| Location policy | Available to a new deck? | Behavior |
| --- | --- | --- |
| Storage | Yes | Boxes and other storage locations contribute to free quantities. |
| Deck | No | Cards are committed to the linked assembled deck; that deck may still count its own copies. |
| Unavailable | No | Trade stock, loans, sale inventory, and other excluded locations are hidden elsewhere in the app. |

## Appearance and synchronization

The Settings view controls appearance, theme colors, frosted transparency, CardNexus credentials, synchronization, and local-cache status.

![RiftBuilder settings showing a dual-color theme, transparency control, stored API-key status, and synchronization details](docs/images/settings.png)

The CardNexus API key is stored in the macOS login Keychain. RiftBuilder requires Touch ID before its first read, retains the credential only in process memory for up to 24 hours, and never displays the saved value again. Inventory writes occur only after an explicit physical move is confirmed.

## Requirements

- macOS 15 or later
- Swift 6.2 or later
- Full Xcode for running the SwiftUI app, executing XCTest, and producing a conventional signed `.app` archive
- A CardNexus API key with exactly `inventory:read` and `inventory:write`

No Apple Account or paid Apple Developer Program membership is required to use RiftBuilder or run a local build. A paid membership is needed only by someone distributing a conventional Developer ID-signed and notarized build or publishing through the Mac App Store.

## Run locally

Open `Package.swift` in Xcode, select the `RiftBuilder` scheme, and run it on **My Mac**.

For a stable command-line app bundle, create the persistent user-scoped local signing identity once, then build and launch RiftBuilder:

```sh
./Scripts/setup-local-signing.sh
./Scripts/run-local-app.sh
```

The local signing identity requires no Apple Account and prevents rebuilds from invalidating the Keychain item’s code-signing trust.

With a full Xcode installation selected, command-line verification uses:

```sh
swift build --disable-sandbox
swift test --disable-sandbox
```

## One-shot Cardmarket import

The scraper-specific Cardmarket importer is a separate command-line target and is not linked into the RiftBuilder app:

```sh
swift run --disable-sandbox riftbuilder-cardmarket-import --input /tmp/products.jsonl
```

It uses `~/Library/Application Support/RiftBuilder/riftbuilder.sqlite` by default. Pass `--database <path>` to target another database or `--dry-run` to inspect associations without writing listings. Dry runs still apply pending database schema migrations.

The importer only associates records when expansion, collector number, and normalized card name agree. Ambiguous variants, missing catalogue printings, and conflicting source records are reported and skipped. Cardmarket links are retained for matched records regardless of scrape currency, while only EUR price observations are stored.

### Input JSONL schema

The input is newline-delimited JSON: each non-empty line must contain one complete product object. Additional fields are ignored. The importer expects this structure:

```json
{
  "source": {
    "url": "https://www.cardmarket.com/en/Riftbound/Products/Singles/Origins/Card-Name",
    "scrapedAt": "2026-08-29T12:03:21.736Z"
  },
  "identity": {
    "displayName": "Card Name Origins - Singles",
    "expansionName": "Origins",
    "expansionCode": "OGN",
    "collectorNumber": "299*"
  },
  "prices": {
    "currency": "EUR",
    "trend": {
      "raw": "1,97 €",
      "value": 1.97
    },
    "average7Days": {
      "raw": null,
      "value": null
    },
    "average30Days": {
      "raw": null,
      "value": null
    }
  },
  "attributes": {
    "Number": "299*",
    "7-days average price": "1,82 €",
    "30-days average price": "1,63 €"
  }
}
```

`source.url` and `source.scrapedAt`; all four `identity` strings; the `prices` object with `trend`, `average7Days`, and `average30Days` price-point objects; and the string-to-string `attributes` object are required. `prices.currency`, plus each price point's `raw` string and numeric `value`, may be absent or `null`.

`identity.expansionCode` must be one of `OGN`, `OGNX`, `OGS`, `PROK`, `SFD`, `SFDX`, `SGN`, `T1X`, `UNL`, `UNLX`, `VEN`, or `VENX`. Matching is always constrained to the corresponding local expansion before collector number and normalized card name are compared.

`attributes.Number` is used as the authoritative collector number when present, otherwise `identity.collectorNumber` is used. Slash-separated numbers are tried individually. For a trailing `*`, both the original form and a trailing-`S` alias are tried within the same expansion.

Only numeric prices whose `prices.currency` is `EUR` are retained. Selection priority is `trend.value`, `average7Days.value`, then `average30Days.value`; when a structured average is absent, the importer can parse the euro-formatted `7-days average price` or `30-days average price` attribute.

## Releases

Every release starts in [`CHANGELOG.md`](CHANGELOG.md). Add a new top-level release with a SemVer version, date, and bullet list of the main changes; set `CFBundleShortVersionString` in `Support/Info.plist` to the same version and increment `CFBundleVersion`. When that pull request is merged into `main`, GitHub Actions builds the release app, signs it, publishes a downloadable DMG and SHA-256 checksum as workflow artifacts, creates the matching `vMAJOR.MINOR.PATCH` tag, and publishes a GitHub Release using the changelog entry as its notes. The mounted DMG contains RiftBuilder and an Applications shortcut for drag-and-drop installation.

Without Apple credentials, the workflow produces an ad-hoc-signed, unnotarized build. To enable conventional distribution, create a protected GitHub environment named `release` and configure `MACOS_CERTIFICATE_BASE64`, `MACOS_CERTIFICATE_PASSWORD`, `APPLE_ID`, `APPLE_TEAM_ID`, and `APPLE_APP_SPECIFIC_PASSWORD` as environment secrets. The certificate secret must contain a Base64-encoded Developer ID Application `.p12`; GitHub imports it into an ephemeral keychain, signs the app and DMG, submits the DMG to Apple, staples the notarization ticket, and deletes the temporary keychain before publishing.

## Documentation

- [Setup guide](docs/SETUP.md)
- [Architecture decisions](docs/ARCHITECTURE.md)
- [Implementation plan](docs/IMPLEMENTATION_PLAN.md)
