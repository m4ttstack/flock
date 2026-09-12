#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

Scripts/libghostty.sh --check
xcodegen
xcodebuild -scheme Paddock -configuration Debug -skipPackagePluginValidation build
