# RiftBuilder implementation plan

## 1. Product definition

RiftBuilder is a native macOS collection browser and Riftbound deck builder. It synchronizes the user's CardNexus inventory, preserves every physical stock lot and its location, groups those lots into useful global totals, and prevents cards located in assembled decks from being presented as available to other decks.

The first release is a personal, single-account desktop application. It works offline after a successful synchronization. It does not require a custom backend and does not accept CardNexus webhooks.

### 1.1 Primary workflows

1. The user enters a CardNexus API key and verifies connectivity.
2. The app downloads the Riftbound catalogue and inventory into a local cache.
3. The user classifies discovered locations as storage, deck, or unavailable.
4. The inventory screen shows same-card totals with exact printing and per-location breakdowns.
5. The user creates a planned deck, selects its legend and chosen champion, and adds main deck, rune, battlefield, and sideboard entries.
6. The editor continuously reports legality, total ownership, storage availability, quantities already in the target deck, quantities in other decks, and missing quantities.
7. The user exports or imports a deck definition.
8. A later write-enabled workflow assembles a deck by moving partial CardNexus inventory lines to a linked deck location.

### 1.2 Explicit non-goals for the first release

- Card scanning or image recognition.
- Marketplace sales, purchases, pricing, or order fulfillment.
- Multi-user accounts or a hosted backend.
- Automatic webhook delivery to a desktop process.
- iOS, Windows, or web clients.
- Automatic rule scraping from Riot web pages.
- Treating unassembled deck plans as physical reservations.

## 2. Release milestones

### Milestone 0: Foundation

- Create a Swift 6 package with native macOS executable and core library targets.
- Pin GRDB and establish module directories.
- Add repository documentation, ignore rules, and command-line build/test instructions.
- Define Sendable domain types and service/repository boundaries.
- Add deterministic fixtures and a test database factory.
- Acceptance: `swift build` and an empty `swift test` pass on the supported toolchain.

### Milestone 1: CardNexus read integration

- Implement bearer-authenticated requests against `https://public-api.cardnexus.com/v1`.
- Model the documented error envelope and response request ID.
- Implement 401, 403, 429, retry-after, transient network, and bounded 5xx retry behavior.
- Implement `GET /inventory` with `game=riftbound`, `limit=100`, and complete cursor traversal.
- Implement `GET /inventory/locations`.
- Implement catalogue-feed metadata retrieval and checksum comparison.
- Implement gzip NDJSON catalogue parsing or a clearly isolated decompression adapter.
- Keep game-specific `attributes` as open JSON while mapping required Riftbound fields defensively.
- Implement Keychain save, load, replace, and delete operations for the API key.
- Add URL protocol/session injection so tests never call production.
- Acceptance: fixtures prove multi-page inventory retrieval, error mapping, cancellation, and catalogue parsing.

### Milestone 2: Persistence and synchronization

- Add versioned GRDB migrations for application metadata, card identity, printing, inventory line, observed location, location policy, deck, and deck entry.
- Enforce remote ID and deck-entry uniqueness constraints.
- Add indexes for product ID, name slug, normalized location, deck ID, zone, and updated time.
- Implement catalogue replacement in one transaction.
- Implement generation-based inventory upsert and stale-row deletion only after a complete sweep.
- Preserve line-level product, finish, language, condition, graded data, quantity, location, tags, listing state, and timestamps.
- Reconcile location names case-insensitively and preserve display spelling.
- Automatically create a default storage policy for newly observed or absent locations.
- Preserve user location classification across inventory refreshes.
- Acceptance: a failed partial refresh leaves the previous snapshot usable; a successful refresh updates, inserts, and deletes the correct lines without changing decks or policies.

### Milestone 3: Aggregation and availability

- Group catalogue printings by CardNexus `nameSlug` for same-named deck rules.
- Expose exact-printing inventory totals.
- Expose card-identity totals across printings.
- Expose a per-location breakdown for every result.
- Compute `totalOwned`, `availableInStorage`, `inTargetDeck`, `inOtherDecks`, `otherwiseUnavailable`, and `missing` values.
- Count a linked assembled deck's own location toward that deck only.
- Never count other deck locations toward a target deck.
- Add database observation for live UI refreshes.
- Acceptance: tests cover the same card across multiple printings, boxes, null locations, the target deck, and other decks.

### Milestone 4: Deck domain and rules

- Model planned and assembled deck states.
- Model legend, chosen champion, main, rune, battlefield, and sideboard zones.
- Store entries by same-name card identity with an optional preferred exact printing, finish, and language.
- Implement quantity editing, zone movement, duplicate-entry coalescing, cloning, deletion, and timestamps.
- Implement a pure rules engine returning structured errors and warnings.
- Validate exactly 40 constructed main-deck cards including the chosen champion, one legend, twelve runes, three uniquely named battlefields, same-name copy limits, domain identity, champion tag matching, signature restrictions, sideboard limits, legal sets, and banned names.
- Bundle a versioned ruleset resource with source URL and effective date metadata.
- Keep rules evaluation independent from persistence and SwiftUI.
- Acceptance: table-driven tests exercise each rule independently and several complete valid/invalid decks.

### Milestone 5: SwiftUI application shell and settings

- Compose dependencies once at application launch.
- Create a native `NavigationSplitView` with Inventory, Decks, Locations, and Settings destinations.
- Add application commands for synchronize, new deck, import, export, and search focus.
- Build API-key onboarding with masked entry, Keychain persistence, verification feedback, and revoke/replace controls.
- Add sync state, last-success timestamp, progress, retry, offline, and actionable error presentation.
- Ensure no secret value is logged or rendered after storage.
- Acceptance: the app can launch without credentials, store a credential, synchronize, relaunch, and show cached data offline.

### Milestone 6: Inventory and locations UI

- Build searchable inventory table and card-grid modes.
- Filter by owned/available state, location, expansion, card type, domain, rarity, finish, and language.
- Present total, available, in-deck, and unavailable badges.
- Add an expandable per-location and exact-printing breakdown.
- Build a location classification screen with storage/deck/unavailable choices and optional local-deck linking.
- Warn when a CardNexus location rename causes an unclassified replacement.
- Provide empty, loading, failure, and stale-cache states.
- Acceptance: the example of one card split across two boxes and two decks displays one global card row with a correct, inspectable breakdown.

### Milestone 7: Deck library and editor UI

- Build deck creation, rename, duplicate, delete, planned/assembled state, and ruleset selection.
- Use separate sections for legend, champion, battlefields, runes, main deck, and sideboard.
- Add a searchable catalogue/inventory card picker.
- Support keyboard-first quantity editing and native drag-and-drop where reliable.
- Show energy curve, domain distribution, card-type distribution, main-deck count, and validation status.
- Show each entry's owned, storage-available, in-this-deck, in-other-decks, and missing quantities.
- Offer filters for owned-only and currently available-only without preventing users from planning missing cards.
- Acceptance: a user can construct, persist, close, reopen, validate, and inspect ownership for a complete deck.

### Milestone 8: Import, export, and physical assembly

- Define a versioned `.riftdeck` JSON schema using same-name identity plus optional printing preferences.
- Export human-readable text to the clipboard.
- Import JSON with validation and unresolved-card reporting.
- Add write scope only when physical assembly is enabled.
- Create or select a CardNexus deck location.
- Build a deterministic allocation proposal preferring explicit printing preferences, then matching available copies.
- Present every planned movement before execution.
- Move partial quantities using CardNexus line update `count` plus `location`, allowing CardNexus to split lines.
- Batch up to 200 distinct line movements through CardNexus bulk update, use one stable idempotency key per batch, and correlate each indexed per-item result back to its stable local movement ID.
- Resynchronize after the operation and report partial failures without pretending the operation was atomic.
- Disassembly requires an explicit destination storage location.
- Acceptance: assembling two of three copies from one box leaves one in the box and two in the deck location after reconciliation.

### Milestone 9: Quality and delivery

- Add accessibility labels, scalable layout, keyboard navigation, VoiceOver order, and reduced-motion behavior.
- Add performance fixtures large enough to expose N+1 queries and slow grouping.
- Add privacy-safe structured logging with CardNexus request IDs but no bearer tokens.
- Run formatting, compilation, unit tests, and targeted UI tests.
- Document API-key creation, scopes, first sync, location classification, backup/export, and troubleshooting.
- Configure application sandbox outgoing network and Keychain entitlements in the Xcode app target.
- Define signing, notarization, and release archive steps.
- Acceptance: clean checkout builds and tests; the signed app completes the primary workflows on macOS 15+.

## 3. Database schema

### 3.1 `app_metadata`

- `key TEXT PRIMARY KEY`
- `value TEXT NOT NULL`
- Stores feed checksum, last successful sync date, active ruleset, and schema-independent flags.

### 3.2 `card_identity`

- `name_slug TEXT PRIMARY KEY`
- `game_id TEXT NOT NULL`
- `display_name TEXT NOT NULL`
- `card_type TEXT`
- `super_type TEXT`
- `domains_json TEXT NOT NULL`
- `tags_json TEXT NOT NULL`
- `energy_cost INTEGER`
- `might_cost INTEGER`
- `attributes_json TEXT NOT NULL`
- Uniqueness is scoped to Riftbound in release one; add `(game_id, name_slug)` if multi-game support is introduced.

### 3.3 `card_printing`

- `product_id INTEGER PRIMARY KEY`
- `name_slug TEXT NOT NULL REFERENCES card_identity`
- `printing_slug TEXT NOT NULL UNIQUE`
- `expansion_id INTEGER`
- `expansion_slug TEXT`
- `print_number TEXT`
- `variant TEXT`
- `rarity TEXT`
- `finishes_json TEXT NOT NULL`
- `languages_json TEXT NOT NULL`
- `image_url TEXT`
- `image_back_url TEXT`
- `attributes_json TEXT NOT NULL`

### 3.4 `inventory_line`

- `inventory_id TEXT PRIMARY KEY`
- `product_id INTEGER NOT NULL REFERENCES card_printing`
- `custom_id TEXT`
- `finish TEXT NOT NULL`
- `condition TEXT`
- `language TEXT`
- `quantity INTEGER NOT NULL CHECK quantity >= 0`
- `graded_json TEXT`
- `location_key TEXT NOT NULL`
- `location_display_name TEXT`
- `tags_json TEXT NOT NULL`
- `comment TEXT`
- `notes TEXT`
- `for_sale INTEGER NOT NULL`
- `listing_json TEXT`
- `remote_updated_at TEXT NOT NULL`
- `sync_generation TEXT NOT NULL`

### 3.5 `location_policy`

- `location_key TEXT PRIMARY KEY`
- `display_name TEXT NOT NULL`
- `kind TEXT NOT NULL CHECK kind IN ('storage', 'deck', 'unavailable')`
- `counts_as_available INTEGER NOT NULL`
- `linked_deck_id TEXT REFERENCES deck(id)`
- `last_seen_at TEXT`
- The empty CardNexus location uses a reserved key and a user-editable display name.

### 3.6 `deck`

- `id TEXT PRIMARY KEY`
- `name TEXT NOT NULL`
- `state TEXT NOT NULL CHECK state IN ('planned', 'assembled')`
- `ruleset_id TEXT NOT NULL`
- `created_at TEXT NOT NULL`
- `updated_at TEXT NOT NULL`

### 3.7 `deck_entry`

- `id TEXT PRIMARY KEY`
- `deck_id TEXT NOT NULL REFERENCES deck ON DELETE CASCADE`
- `zone TEXT NOT NULL`
- `name_slug TEXT NOT NULL REFERENCES card_identity`
- `quantity INTEGER NOT NULL CHECK quantity > 0`
- `preferred_product_id INTEGER REFERENCES card_printing`
- `preferred_finish TEXT`
- `preferred_language TEXT`
- Unique logical constraint on deck, zone, identity, and preference tuple.

## 4. Core query contracts

- `inventoryCards(search:filters:targetDeckID:)` returns grouped identity summaries and never remote lines directly to list UI.
- `inventoryBreakdown(nameSlug:targetDeckID:)` returns exact printing and location rows.
- `availability(nameSlug:targetDeckID:)` returns all ownership buckets, not a single ambiguous quantity.
- `deckSnapshot(id:)` returns a persistence-independent value consumed by validation.
- `validate(snapshot:ruleset:)` is synchronous and deterministic.
- `synchronizeInventory()` changes cached inventory only after full remote traversal.

## 5. Synchronization failure rules

- Cancellation leaves the prior successful snapshot intact.
- A failure before the final cursor never deletes stale rows.
- Catalogue feed checksum changes are applied transactionally.
- Unknown JSON fields are ignored and preserved where useful.
- Unknown enum values are stored as strings and displayed safely.
- A missing catalogue product prevents that inventory line from becoming visible only after a diagnostic is recorded; it must not crash the whole sync.
- HTTP 429 waits according to `Retry-After` when reasonable and remains cancellable.
- Retried writes reuse the same idempotency key.

## 6. Security and privacy checklist

- Store the bearer token in Keychain with an application-specific service name.
- Request `inventory:read` for read-only releases and add `inventory:write` only for assembly.
- Never persist the token in SQLite, process arguments, logs, crash metadata, fixtures, or screenshots.
- Redact authorization headers in networking diagnostics.
- Validate HTTPS and use default platform trust evaluation.
- Display CardNexus request IDs on actionable server errors.

## 7. Test matrix

### Networking

- One-page and multi-page cursor responses.
- Empty inventory.
- Malformed payload and unknown enum values.
- 401 invalid/revoked key, 403 missing scope, 429 retry, 500 bounded retry, cancellation, and offline errors.
- Catalogue unchanged checksum and changed checksum.
- NDJSON with blank lines and one malformed record.

### Persistence and synchronization

- First import, repeated idempotent import, quantity update, remote deletion, and remote line split.
- Same product and same-name identity in several locations.
- Same name across several products/printings.
- Location policy survives refresh and case-only spelling changes.
- Failed sweep preserves prior rows.
- Deck deletion cascades entries and clears/rejects location links safely.

### Availability

- Two boxes are available.
- Other deck locations are unavailable.
- Target deck's linked location counts only for itself.
- Unavailable/trade/quarantine location is excluded.
- Null location follows its configurable policy.
- Preferred printing shortage can fall back to another printing when allowed.

### Rules

- Every count boundary and zone requirement.
- Same-name copy count across printings and sideboard.
- Domain subset/superset cases.
- Champion tag match and mismatch.
- Signature aggregate maximum.
- Duplicate battlefield names.
- Banned names and set legality.

### UI

- Credential onboarding and redaction.
- Empty/cache/loading/error states.
- Global row location expansion.
- Location policy editing.
- Deck persistence and validation rendering.
- Keyboard commands and accessibility identifiers.

## 8. Definition of done

The project is complete for its first release when a clean checkout can build and test, a user can securely connect CardNexus, synchronize and browse their location-aware Riftbound inventory, classify physical locations, create and persist decks, receive current constructed legality feedback, and see correct card availability excluding all other assembled decks. Documentation must explain setup and any write-disabled limitation without requiring knowledge of the implementation.
