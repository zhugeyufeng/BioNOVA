#!/usr/bin/env bash
# 共享 R 包库端到端测试：配置 Renviron.site、管理员安装包、普通用户可见性。
# 会真实修改系统（安装 R、写 Renviron.site、创建用户），只允许在一次性容器或 CI 中运行。
# 用法: tests/r-shared-smoke.sh <dist/bionova 或 assets/bioinfo-server-init.sh>
set -Eeuo pipefail

TARGET="${1:?usage: tests/r-shared-smoke.sh <bionova binary or script>}"
if [[ ! -f /.dockerenv && -z "${CI:-}" ]]; then
  echo "refusing to run outside a disposable container or CI" >&2
  exit 2
fi
(( EUID == 0 )) || { echo "must run as root" >&2; exit 2; }

bionova() {
  if [[ "$TARGET" == *.sh ]]; then bash "$TARGET" "$@"; else "$TARGET" "$@"; fi
}

expect_no_failed_action() {
  if grep -q '操作未完成' "$1"; then
    echo "a menu action failed, see $1" >&2
    exit 1
  fi
}

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends r-base-core ca-certificates >/dev/null
id tester >/dev/null 2>&1 || useradd -m -s /bin/bash tester

root=/srv/R_Lib
ver="$(Rscript --vanilla -e 'cat(R.version$major, strsplit(R.version$minor, ".", fixed = TRUE)[[1]][1], sep = ".")')"
lib="$root/$ver"
renviron="$(R RHOME)/etc/Renviron.site"
user_paths() { runuser -u tester -- Rscript -e 'cat(.libPaths(), sep = "\n")'; }
before="$(user_paths)"
echo "== R $ver, tester .libPaths() before:"
printf '%s\n' "$before"

echo "== dry-run status does not modify anything"
printf '17\n9\n\n0\n0\n' | bionova --dry-run > /tmp/r-dry.log 2>&1
expect_no_failed_action /tmp/r-dry.log
grep -q '未配置共享库' /tmp/r-dry.log
if grep -q 'bioinfo-setup shared R library' "$renviron" 2>/dev/null; then
  echo "dry-run modified $renviron" >&2
  exit 1
fi

echo "== R menu 8: configure on demand, install BiocManager, verify as tester"
printf '17\n8\ny\n%s\n3\nBiocManager\n\n\nn\ny\ntester\n0\n0\n' "$root" | bionova 2>&1 | tee /tmp/r-install.log
expect_no_failed_action /tmp/r-install.log

echo "== Renviron.site block"
sed -n '/bioinfo-setup shared R library >>>/,/bioinfo-setup shared R library <<</p' "$renviron"
test "$(stat -c '%U %a' "$lib")" = "root 755"
test -f "$lib/BiocManager/DESCRIPTION"
test "$(stat -c '%a' "$lib/BiocManager/DESCRIPTION")" = "644"

after="$(user_paths)"
echo "== tester .libPaths() after:"
printf '%s\n' "$after"
grep -qx "$lib" <<<"$after"
# 原有的站点库与基础库全部保留
while read -r p; do
  grep -qxF "$p" <<<"$after" || { echo "lost library path: $p" >&2; exit 1; }
done <<<"$before"
# 共享库排在 R 基础库之前
awk -v lib="$lib" -v base="$(R RHOME)/library" '
  $0 == lib { l = NR } $0 == base { b = NR } END { exit !(l && b && l < b) }' <<<"$after"
runuser -u tester -- Rscript -e 'stopifnot(dirname(system.file(package = "BiocManager")) == commandArgs(TRUE)[1])' "$lib"

echo "== configure again is idempotent"
printf '17\n7\n%s\na\n0\n0\n' "$root" | bionova > /tmp/r-reconf.log 2>&1
expect_no_failed_action /tmp/r-reconf.log
test "$(grep -c 'bioinfo-setup shared R library >>>' "$renviron")" -eq 1
test "$(user_paths)" = "$after"

echo "== status shows the library and verifies as tester"
printf '17\n9\ntester\nBiocManager\n0\n0\n' | bionova 2>&1 | tee /tmp/r-status.log
expect_no_failed_action /tmp/r-status.log
grep -q "已安装 [1-9][0-9]* 个包" /tmp/r-status.log
grep -Eq 'BiocManager +OK' /tmp/r-status.log

echo "== health check reports the shared library"
printf '23\n\n0\n' | bionova 2>&1 | grep '共享 R 包库' | tee /tmp/r-health.log
grep -q "OK.*$lib" /tmp/r-health.log

echo "R shared library smoke test passed"
