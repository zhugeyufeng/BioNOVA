#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="${VERSION:-0.2.0}"
VERSION="${VERSION#v}"
COMMIT="${COMMIT:-$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || printf unknown)}"
# 可复现构建：优先 SOURCE_DATE_EPOCH，其次最近一次提交时间，最后才用当前时间。
if [[ -z "${BUILD_DATE:-}" ]]; then
  if [[ -n "${SOURCE_DATE_EPOCH:-}" ]]; then
    BUILD_DATE="$(date -u -d "@$SOURCE_DATE_EPOCH" +%Y-%m-%dT%H:%M:%SZ)"
  else
    BUILD_DATE="$(TZ=UTC git -C "$ROOT" log -1 --format=%cd --date=format-local:%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
      || date -u +%Y-%m-%dT%H:%M:%SZ)"
  fi
fi
OUT="${OUT:-$ROOT/dist/bionova}"
BUILD_DIR="$ROOT/.build"
SCRIPT="$ROOT/assets/bioinfo-server-init.sh"
# 默认只接受静态 ELF；确实需要动态链接时显式设置 ALLOW_DYNAMIC=1。
ALLOW_DYNAMIC="${ALLOW_DYNAMIC:-0}"

if [[ "${1:-}" == "--sync" ]]; then
  "$ROOT/scripts/sync-script.sh"
fi

[[ -f "$SCRIPT" ]] || {
  echo "Missing embedded script: $SCRIPT" >&2
  exit 1
}

if grep -q $'\r' "$SCRIPT"; then
  echo "Embedded script contains CRLF line endings: $SCRIPT" >&2
  exit 1
fi
bash -n "$SCRIPT"
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -S error "$SCRIPT"
fi

build_local() {
  mkdir -p "$BUILD_DIR" "$(dirname "$OUT")"

  local script_sha
  script_sha="$(sha256sum "$SCRIPT" | awk '{print $1}')"

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

  local -a flags=(
    -std=c11
    -O2
    -Wall
    -Wextra
    -Werror
    -I"$BUILD_DIR"
    "-DBIONOVA_VERSION=\"$VERSION\""
    "-DBIONOVA_COMMIT=\"$COMMIT\""
    "-DBIONOVA_BUILD_DATE=\"$BUILD_DATE\""
    "-DBIONOVA_SCRIPT_SHA256=\"$script_sha\""
  )

  if gcc "${flags[@]}" -static -s "$ROOT/main.c" -o "$OUT" 2>"$BUILD_DIR/static.err"; then
    echo "Built static ELF."
  elif [[ "$ALLOW_DYNAMIC" == "1" ]]; then
    echo "Static link unavailable; ALLOW_DYNAMIC=1, building dynamic ELF." >&2
    cat "$BUILD_DIR/static.err" >&2
    gcc "${flags[@]}" -s "$ROOT/main.c" -o "$OUT"
  else
    cat "$BUILD_DIR/static.err" >&2
    echo "Static link failed (install libc6-dev, or set ALLOW_DYNAMIC=1 to accept a dynamic ELF)." >&2
    exit 1
  fi

  chmod 0755 "$OUT"
  # 校验文件只写文件名，用户在下载目录执行 sha256sum -c 即可。
  (cd "$(dirname "$OUT")" && sha256sum "$(basename "$OUT")" > "$(basename "$OUT").sha256")
  cat "$OUT.sha256"
  file "$OUT" 2>/dev/null || true
  "$OUT" --version
  echo "Built: $OUT"
}

if command -v gcc >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  build_local
elif command -v docker >/dev/null 2>&1; then
  BUILD_IMAGE="${BUILD_IMAGE:-ubuntu:24.04}"
  docker run --rm \
    -v "$ROOT:/src" \
    -w /src \
    -e VERSION="$VERSION" \
    -e COMMIT="$COMMIT" \
    -e BUILD_DATE="$BUILD_DATE" \
    -e ALLOW_DYNAMIC="$ALLOW_DYNAMIC" \
    -e HOST_UID="$(id -u)" \
    -e HOST_GID="$(id -g)" \
    "$BUILD_IMAGE" \
    bash -c 'set -e
      apt-get update -qq
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq build-essential python3 file >/dev/null
      ./build.sh
      chown -R "$HOST_UID:$HOST_GID" dist .build'
else
  echo "Build requires gcc+python3 or Docker." >&2
  exit 1
fi
