#!/usr/bin/env bash
set -euo pipefail

SOURCE_EDITOR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 "$SOURCE_EDITOR_ROOT/script/bootstrap.py" "$@"
