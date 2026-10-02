#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="${1:-$ROOT/../bioinfo-server-init.sh}"
TARGET="$ROOT/assets/bioinfo-server-init.sh"

[[ -f "$SOURCE" ]] || {
  echo "Source script not found: $SOURCE" >&2
  exit 1
}

bash -n "$SOURCE"
cp "$SOURCE" "$TARGET"
chmod 0644 "$TARGET"

echo "Synced:"
echo "  $SOURCE"
echo "  -> $TARGET"
sha256sum "$TARGET"
