#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="${VERSION:-0.1.0}"
COMMIT="${COMMIT:-$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || printf unknown)}"
BUILD_DATE="${BUILD_DATE:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
OUT="${OUT:-$ROOT/dist/bionova}"
BUILD_DIR="$ROOT/.build"
SCRIPT="$ROOT/assets/bioinfo-server-init.sh"

if [[ "${1:-}" == "--sync" ]]; then
  "$ROOT/scripts/sync-script.sh"
fi

[[ -f "$SCRIPT" ]] || {
  echo "Missing embedded script: $SCRIPT" >&2
  exit 1
}

bash -n "$SCRIPT"
mkdir -p "$BUILD_DIR" "$(dirname "$OUT")"

SCRIPT_SHA="$(sha256sum "$SCRIPT" | awk '{print $1}')"

python3 - "$SCRIPT" "$BUILD_DIR/embedded_script.h" <<'PY'
from pathlib import Path
import sys

src = Path(sys.argv[1]).read_bytes()
out = Path(sys.argv[2])
with out.open("w", encoding="ascii") as fh:
    fh.write("#ifndef BIONOVA_EMBEDDED_SCRIPT_H\n")
    fh.write("#define BIONOVA_EMBEDDED_SCRIPT_H\n")
    fh.write("#include <stddef.h>\n")
    fh.write("static const unsigned char embedded_script[] = {\n")
    for i in range(0, len(src), 16):
        chunk = src[i:i+16]
        fh.write("    " + ", ".join(f"0x{b:02x}" for b in chunk) + ",\n")
    fh.write("};\n")
    fh.write(f"static const size_t embedded_script_len = {len(src)};\n")
    fh.write("#endif\n")
PY

COMMON_FLAGS=(
  -std=c11
  -O2
  -Wall
  -Wextra
  -Werror
  -I"$BUILD_DIR"
  "-DBIONOVA_VERSION=\"$VERSION\""
  "-DBIONOVA_COMMIT=\"$COMMIT\""
  "-DBIONOVA_BUILD_DATE=\"$BUILD_DATE\""
  "-DBIONOVA_SCRIPT_SHA256=\"$SCRIPT_SHA\""
)

build_with_gcc() {
  if gcc "${COMMON_FLAGS[@]}" -static -s "$ROOT/main.c" -o "$OUT" 2>"$BUILD_DIR/static.err"; then
    echo "Built static ELF."
  else
    echo "Static link unavailable; falling back to dynamic ELF." >&2
    cat "$BUILD_DIR/static.err" >&2
    gcc "${COMMON_FLAGS[@]}" -s "$ROOT/main.c" -o "$OUT"
  fi
}

if command -v gcc >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  build_with_gcc
elif command -v docker >/dev/null 2>&1; then
  BUILD_IMAGE="${BUILD_IMAGE:-}"
  if [[ -z "$BUILD_IMAGE" ]]; then
    if docker image inspect mineru:4 >/dev/null 2>&1; then
      BUILD_IMAGE="mineru:4"
    else
      BUILD_IMAGE="ubuntu:24.04"
    fi
  fi

  docker run --rm \
    -v "$ROOT:/src" \
    -w /src \
    -e VERSION="$VERSION" \
    -e COMMIT="$COMMIT" \
    -e BUILD_DATE="$BUILD_DATE" \
    "$BUILD_IMAGE" \
    bash -lc 'set -e; apt-get update -qq; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq build-essential python3 file >/dev/null; ./build.sh'
  exit 0
else
  echo "Build requires gcc+python3 or Docker." >&2
  exit 1
fi

chmod 0755 "$OUT"
sha256sum "$OUT" | tee "$OUT.sha256"
file "$OUT"
"$OUT" --version

echo "Built: $OUT"
