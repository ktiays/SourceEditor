#!/usr/bin/env bash
set -euo pipefail

SOURCE_EDITOR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SOURCE_EDITOR_ROOT"

case "${1:-format}" in
  format|--check)
    ;;
  *)
    echo "usage: $0 [--check]" >&2
    exit 2
    ;;
esac

if command -v clang-format >/dev/null 2>&1; then
  SOURCE_EDITOR_FORMATTER="$(command -v clang-format)"
else
  SOURCE_EDITOR_FORMATTER="$(xcrun --find clang-format)"
fi

SOURCE_EDITOR_FORMAT_FILES=()
while IFS= read -r -d '' SOURCE_EDITOR_FILE; do
  SOURCE_EDITOR_FORMAT_FILES+=("$SOURCE_EDITOR_FILE")
done < <(find Sources Tests -type f \( -name '*.h' -o -name '*.m' -o -name '*.mm' \) -print0)

if [[ "${1:-format}" == "--check" ]]; then
  "$SOURCE_EDITOR_FORMATTER" --style=file --dry-run --Werror "${SOURCE_EDITOR_FORMAT_FILES[@]}"
else
  "$SOURCE_EDITOR_FORMATTER" --style=file -i "${SOURCE_EDITOR_FORMAT_FILES[@]}"
fi
