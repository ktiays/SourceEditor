#!/usr/bin/env bash
set -euo pipefail
SOURCE_EDITOR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SOURCE_EDITOR_ROOT"
case "${1:-all}" in
    all|--core-only)
        ;;
    *)
        echo "usage: $0 [--core-only]" >&2
        exit 2
        ;;
esac
if [[ "${1:-all}" == "--core-only" ]]; then
    export SOURCE_EDITOR_CORE_ONLY=1
else
    export SOURCE_EDITOR_CORE_ONLY=0
fi
swift run SourceEditorChecks
if [[ "${1:-all}" != "--core-only" ]]; then
    swift run SourceEditorTreeSitterChecks
fi
