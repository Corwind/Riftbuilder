# Architecture

## Authority boundaries

CardNexus owns catalogue products, inventory lines, quantities, and physical locations. RiftBuilder never flattens CardNexus lines during synchronization: each remote line is stored by its opaque inventory ID, and global totals are derived by grouping those rows.

RiftBuilder owns deck definitions, ruleset versions, local location classifications, and optional links between a CardNexus location name and an assembled deck. The local CardNexus cache can be recreated without losing deck data.

## Modules

- `RiftBuilderCore/Domain`: value types and repository/service contracts with no UI dependency.
- `RiftBuilderCore/CardNexus`: bearer-authenticated API client, DTO mapping, pagination, catalogue feed ingestion, and Keychain credential storage.
- `RiftBuilderCore/Persistence`: GRDB migrations, records, repositories, synchronization transactions, grouped inventory queries, and location-aware availability.
- `RiftBuilderCore/Rules`: pure, versioned Riftbound deck validation.
- `RiftBuilderApp`: SwiftUI composition root and feature views.

## Inventory representation

An inventory line is a stock lot, not a card total. Quantities with different CardNexus inventory IDs or locations remain distinct. Queries expose totals at three levels: exact printing, same-name card identity, and location.

CardNexus locations are name-based, so RiftBuilder stores a normalized name for matching while retaining the original display name. Each observed location receives a local policy: `storage`, `deck`, or `unavailable`. Unclassified and absent locations default to available storage until the user changes that policy.

## Availability

For a new or merely planned deck, availability is the sum of quantities in locations whose policy is available. For an assembled target deck, its own linked location also counts toward that deck, while locations linked to all other decks remain unavailable.

A deck definition does not reserve cards simply by existing. Only physical CardNexus location, or a future explicit reservation feature, changes global availability.

## Synchronization

Inventory synchronization follows every cursor returned by `GET /v1/inventory?game=riftbound&limit=100`. Rows are written with a synchronization generation. Stale rows are deleted only after the complete cursor traversal succeeds, preventing a failed partial refresh from erasing cached inventory.

Catalogue synchronization compares the CardNexus feed checksum, downloads changed gzip NDJSON data, and replaces catalogue rows transactionally. API DTOs remain inside the CardNexus adapter.

## Dependency policy

GRDB is the only initial third-party runtime dependency. Networking, observation, security, and image loading use Apple frameworks. Additional dependencies require an architecture decision explaining why platform APIs are insufficient.
