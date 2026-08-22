#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
changelog_path="$project_dir/CHANGELOG.md"
info_plist_path="$project_dir/Support/Info.plist"

if [ ! -f "$changelog_path" ]; then
    echo "Missing CHANGELOG.md." >&2
    exit 1
fi

release_heading=$(grep -m 1 '^## \[' "$changelog_path" || true)
version=$(printf '%s\n' "$release_heading" | sed -nE 's/^## \[([^]]+)\] - [0-9]{4}-[0-9]{2}-[0-9]{2}$/\1/p')

if [ -z "$version" ]; then
    echo "The first changelog release must use: ## [MAJOR.MINOR.PATCH] - YYYY-MM-DD" >&2
    exit 1
fi

semver_pattern='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$'
if ! printf '%s\n' "$version" | grep -Eq "$semver_pattern"; then
    echo "Changelog version '$version' is not valid SemVer." >&2
    exit 1
fi

version_without_build=${version%%+*}
case "$version_without_build" in
    *-*)
        prerelease=${version_without_build#*-}
        if ! printf '%s\n' "$prerelease" | awk -F. '{ for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+$/ && length($i) > 1 && substr($i, 1, 1) == "0") exit 1 }'; then
            echo "Numeric SemVer prerelease identifiers cannot have leading zeroes." >&2
            exit 1
        fi
        ;;
esac

change_count=$(awk '
    /^## \[/ {
        if (in_release) exit
        in_release = 1
        next
    }
    in_release && /^- / { count++ }
    END { print count + 0 }
' "$changelog_path")

if [ "$change_count" -eq 0 ]; then
    echo "Changelog release $version must contain at least one main-change list item." >&2
    exit 1
fi

bundle_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist_path")
if [ "$bundle_version" != "$version" ]; then
    echo "CHANGELOG.md version $version does not match CFBundleShortVersionString $bundle_version." >&2
    exit 1
fi

build_number=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info_plist_path")
case "$build_number" in
    ''|*[!0-9]*|0)
        echo "CFBundleVersion must be a positive integer." >&2
        exit 1
        ;;
esac

printf '%s\n' "$version"
