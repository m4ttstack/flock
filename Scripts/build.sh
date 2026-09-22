#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

Scripts/libghostty.sh --check
Scripts/fetch-sparkle.sh
xcodegen
xcodebuild -scheme Flock -configuration Debug -skipPackagePluginValidation build
