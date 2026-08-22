# RiftBuilder

RiftBuilder is a native macOS application for browsing the complete Riftbound catalogue, managing a CardNexus-backed collection, and building legal decks from physically available cards.

CardNexus is authoritative for card catalogue data, owned quantities, and physical locations. RiftBuilder stores a replaceable local cache plus local deck definitions and location classifications. Inventory lines located in storage are available for new decks; lines located in assembled decks are unavailable to other decks.

## Requirements

- macOS 15 or later
- Swift 6.2 or later
- Full Xcode for running the SwiftUI app, executing XCTest, and producing a conventional signed `.app` archive
- A CardNexus API key with `inventory:read` and `inventory:write`

No Apple Account or paid developer membership is required to use RiftBuilder or run a local macOS build. You may need an Apple Account to obtain Xcode through Apple’s normal download channels. The developer who distributes a conventional notarized build needs a paid Apple Developer Program membership; the person using that build does not.

Open `Package.swift` in Xcode and run the `RiftBuilder` scheme on **My Mac**. Command-line verification uses:

```sh
swift build --disable-sandbox
swift test --disable-sandbox
```

For the local command-line app bundle, establish its persistent user-scoped signing identity once and then launch it with:

```sh
./Scripts/setup-local-signing.sh
./Scripts/run-local-app.sh
```

This local identity requires no Apple account and prevents macOS Keychain trust from being invalidated by every rebuild.

## Documentation

- [Setup guide](docs/SETUP.md)
- [Implementation plan](docs/IMPLEMENTATION_PLAN.md)
- [Architecture decisions](docs/ARCHITECTURE.md)
