# RiftBuilder setup

## Apple requirements

You do not need an Apple Account or an Apple Developer Program membership to use RiftBuilder. A locally built macOS app can use **Sign to Run Locally**, and an app distributed by a developer does not require its users to have developer accounts.

For building from source, install the current full Xcode release, open `Package.swift`, select the `RiftBuilder` scheme, and run the app on **My Mac**. Apple’s normal Xcode download channels may require an Apple Account, but joining the paid developer program is unnecessary for local development. The standalone Command Line Tools can compile the package but do not include everything needed to run this project’s XCTest suite or create a conventional `.app` archive.

A paid Apple Developer Program membership belongs to the distributor, and is needed only if you later want to ship a standard Developer ID-signed and notarized build or publish through the Mac App Store. It is never an end-user requirement.

## Stable local signing

The command-line app bundle uses a persistent, user-scoped signing identity so macOS Keychain access survives rebuilds. Run the setup once from Terminal; macOS requires one password authorization to trust the self-signed certificate for code signing in your login Keychain:

```sh
./Scripts/setup-local-signing.sh
```

After setup, build and launch with `./Scripts/run-local-app.sh`. The certificate is named **RiftBuilder Local Development**, is not trusted system-wide, and requires no Apple account. The first launch after replacing the former ad-hoc signature may require one final **Always Allow** grant for the existing Keychain item. Future builds retain the same designated requirement.

## CardNexus API key

Create a dedicated key in CardNexus under **Settings → API keys** with exactly these scopes:

- `inventory:read` lets RiftBuilder synchronize your inventory lines and locations.
- `inventory:write` lets RiftBuilder create a deck location and move or split inventory lines when physically assembling or disassembling a deck.

No account, listings, sales, purchases, messaging, financial, or wildcard scope is needed. Catalogue feeds require a valid key but no additional scope.

Paste the key into RiftBuilder’s Settings screen. RiftBuilder verifies read access with an inventory endpoint and stores the key as a device-only macOS Keychain item protected by user presence. RiftBuilder requires Touch ID for credential access and does not offer the Mac login password as a fallback. RiftBuilder never displays the saved value again. Write access is exercised only when you explicitly confirm a physical move.

## First synchronization

Run **Synchronize Now** after saving the API key. RiftBuilder downloads the Riftbound catalogue when its checksum changes, then retrieves every CardNexus inventory page and stores each remote inventory line separately. It derives the global card rows by grouping those lines by same-name identity, printing, and location.

Open **Locations** and classify every discovered location:

- **Storage** means those copies are available to build decks.
- **Deck** means those copies are unavailable to other decks; link the CardNexus location to the matching local assembled deck.
- **Unavailable** excludes trade binders, sale stock, loans, or any other copies you do not want deck building to consume.

An assembled deck may use copies already present in its own linked CardNexus location. Copies in another deck location remain unavailable.

## Local command-line verification

With a full Xcode installation selected:

```sh
swift build --disable-sandbox
swift test --disable-sandbox
```

If `xcode-select` points at standalone Command Line Tools, select Xcode first:

```sh
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
```
