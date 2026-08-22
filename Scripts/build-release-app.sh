#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"

version=$("$project_dir/Scripts/validate-release.sh")
swift build --configuration release --disable-sandbox
binary_dir=$(swift build --configuration release --show-bin-path)
package_dir="$project_dir/.build/release-package"
app_path="$package_dir/RiftBuilder.app"
archive_path="$package_dir/RiftBuilder-v$version-unsigned.zip"
contents_path="$app_path/Contents"

case "$package_dir" in
    "$project_dir"/.build/release-package) ;;
    *)
        echo "Refusing to replace an unexpected release directory: $package_dir" >&2
        exit 1
        ;;
esac

if [ -d "$package_dir" ]; then
    rm -rf "$package_dir"
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

ditto -c -k --sequesterRsrc --keepParent "$app_path" "$archive_path"
"$project_dir/Scripts/changelog-notes.sh" > "$package_dir/release-notes.md"

printf '%s\n' "$archive_path"
