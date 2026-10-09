#!/bin/bash
set -euo pipefail
TASK_DOTWATCH_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec bash "$TASK_DOTWATCH_ROOT/DirectRTC/Tools/build-neteq.sh" "$@"
