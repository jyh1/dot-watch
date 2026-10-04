#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_ARGS=()
if [ -n "${DOTWATCH_CONFIG:-}" ]; then CONFIG_ARGS=(--config "$DOTWATCH_CONFIG"); fi
python3 "$ROOT/Tools/configure.py" "${CONFIG_ARGS[@]}"
xcodegen generate --spec "$ROOT/project.yml" --project "$ROOT"
xcodebuild -project "$ROOT/DotWatch.xcodeproj" -scheme DotWatchPhone -configuration "${DOTWATCH_CONFIGURATION:-Release}" -destination 'generic/platform=iOS' -derivedDataPath "${DOTWATCH_BUILD_DIR:-$ROOT/work/build}" build "$@"
