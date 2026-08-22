#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"

swift build --disable-sandbox
binary_dir=$(swift build --show-bin-path)
app_path="$project_dir/.build/local/RiftBuilder.app"
contents_path="$app_path/Contents"

if [ -d "$app_path" ]; then
    rm -rf "$app_path"
fi
mkdir -p "$contents_path/MacOS" "$contents_path/Resources"
install -m 755 "$binary_dir/RiftBuilder" "$contents_path/MacOS/RiftBuilder"
install -m 644 "$project_dir/Support/Info.plist" "$contents_path/Info.plist"
install -m 644 "$project_dir/Support/AppIcon/RiftBuilder.icns" "$contents_path/Resources/RiftBuilder.icns"

for resource_bundle in "$binary_dir"/*.bundle; do
    if [ -d "$resource_bundle" ]; then
        ditto "$resource_bundle" "$contents_path/Resources/$(basename "$resource_bundle")"
    fi
done

signing_identity=${RIFTBUILDER_SIGNING_IDENTITY:-"RiftBuilder Local Development"}
login_keychain=$(security login-keychain | xargs)
if ! security find-identity -v -p codesigning "$login_keychain" | grep -Fq "\"$signing_identity\""; then
    echo "Missing trusted local signing identity: $signing_identity" >&2
    echo "Run Scripts/setup-local-signing.sh once, then rebuild." >&2
    exit 1
fi

codesign --force --sign "$signing_identity" --identifier com.riftbuilder.app "$app_path"
codesign --verify --deep --strict "$app_path"

echo "$app_path"
