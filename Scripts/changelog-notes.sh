#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
changelog_path="$project_dir/CHANGELOG.md"

"$project_dir/Scripts/validate-release.sh" >/dev/null

awk '
    /^## \[/ {
        if (in_release) exit
        in_release = 1
        next
    }
    in_release {
        if (!started && $0 == "") next
        started = 1
        print
    }
' "$changelog_path"
