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

## GitHub releases

A merged pull request triggers a release only when that pull request changed `CHANGELOG.md`. Before opening the pull request, add a new release above the existing entries using `## [MAJOR.MINOR.PATCH] - YYYY-MM-DD`, include at least one bullet describing a main change, set `CFBundleShortVersionString` in `Support/Info.plist` to the same version, and increment the positive integer `CFBundleVersion`. Pull-request CI rejects malformed SemVer, missing change bullets, bundle-version mismatches, and versions whose `vMAJOR.MINOR.PATCH` tag already exists.

The release workflow builds the merged revision in release mode and packages the executable, Info.plist, and SwiftPM resource bundles as a conventional `.app`. Signing runs in a separate job that never checks out or executes repository code. The app is placed in a versioned DMG beside an Applications shortcut for drag-and-drop installation. The completed DMG and SHA-256 checksum are retained as workflow artifacts and attached to a GitHub Release whose notes come from the newest changelog entry.

If no Apple signing secrets exist, the workflow applies an ad-hoc signature and marks the release as unnotarized. This requires no Apple Account, but Gatekeeper does not treat it as an identified-developer download. Conventional distribution requires the repository owner to join the paid Apple Developer Program and configure Developer ID signing and notarization.

To enable identified-developer releases:

1. In the Apple Developer portal, create a **Developer ID Application** certificate, install it with its private key, export both as a password-protected `.p12`, and Base64-encode that file.
2. Create an app-specific password for the Apple Account used for notarization and note the Apple Developer Team ID.
3. In the GitHub repository, create an environment named `release`. Protect it with required reviewers if release approval should be explicit.
4. Add `MACOS_CERTIFICATE_BASE64`, `MACOS_CERTIFICATE_PASSWORD`, `APPLE_ID`, `APPLE_TEAM_ID`, and `APPLE_APP_SPECIFIC_PASSWORD` as secrets on that environment.

The workflow refuses partial signing configuration. With all five secrets present, it imports the certificate into a random-password ephemeral keychain, discovers the Developer ID identity without printing its name, signs the app with the hardened runtime and a trusted timestamp, creates and signs the DMG, submits it through `notarytool`, staples and validates Apple’s ticket, and removes the certificate and temporary keychain. Neither the signing identity nor any credential is stored in Git history or committed files.
