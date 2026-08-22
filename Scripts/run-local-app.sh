#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
app_path=$($project_dir/Scripts/build-local-app.sh | tail -n 1)

exec "$app_path/Contents/MacOS/RiftBuilder"
