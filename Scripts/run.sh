#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

Scripts/build.sh

build_settings=$(xcodebuild -scheme Flock -configuration Debug -showBuildSettings)
target_build_dir=$(echo "$build_settings" | awk -F'= ' '/ TARGET_BUILD_DIR /{print $2; exit}')
wrapper_name=$(echo "$build_settings" | awk -F'= ' '/ WRAPPER_NAME /{print $2; exit}')
executable_name=$(echo "$build_settings" | awk -F'= ' '/ EXECUTABLE_NAME /{print $2; exit}')

app_path="${target_build_dir}/${wrapper_name}"
binary_path="${app_path}/Contents/MacOS/${executable_name}"

exec "$binary_path" "$@"
