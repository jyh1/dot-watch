#!/bin/bash
set -euo pipefail
TASK_NETEQ_TOOLS="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$TASK_NETEQ_TOOLS/build_neteq.py" "$@"
