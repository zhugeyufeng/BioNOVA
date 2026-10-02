#!/usr/bin/env bash
set -Eeuo pipefail

# Bioinformatics server bootstrap helper for Ubuntu 22.04/24.04.
# Consolidated from the historical setup/account scripts in this directory.
#
# Usage:
#   bash bioinfo-server-init.sh
#   bash bioinfo-server-init.sh --dry-run
#
# Notes:
# - Destructive storage formatting is never automatic and requires typing the
#   exact device name.
# - Existing /bin/sh is intentionally left untouched.
# - System files are only appended when the requested entry is not present.

SCRIPT_NAME="$(basename "$0")"
DRY_RUN=0
TIMEZONE_DEFAULT="Asia/Shanghai"
DATA_MOUNT_DEFAULT="/data_disk"
DATA_DEVICE_DEFAULT="/dev/sdb"
MINIFORGE_DEFAULT="/opt/miniforge3"
MINICONDA_SYSTEM_DEFAULT="/opt/miniconda3"
MINICONDA_PREREQ_BIN=""
MICROMAMBA_SYSTEM_BIN="/usr/local/bin/micromamba"
URSKY_CHANNEL="https://conda.anaconda.org/ursky"
TUNA_MAIN_CHANNEL="https://mirrors.tuna.tsinghua.edu.cn/anaconda/pkgs/main"
TUNA_R_CHANNEL="https://mirrors.tuna.tsinghua.edu.cn/anaconda/pkgs/r"
TUNA_CONDA_FORGE_CHANNEL="https://mirrors.tuna.tsinghua.edu.cn/anaconda/cloud/conda-forge"
TUNA_BIOCONDA_CHANNEL="https://mirrors.tuna.tsinghua.edu.cn/anaconda/cloud/bioconda"
METACAT_RELEASE_API="https://api.github.com/repos/liu-congcong/MetaCAT/releases/latest"
METACAT_LATEST_TAG=""
METACAT_LATEST_VERSION=""
METACAT_LATEST_WHEEL=""
DEFAULT_ROOT_SSH_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJ5Ro/DSSqp52+GxXhMcf+3YaCK5ajt/Kq/viulNkh5a admin@noc.im"
LOG_DIR="/var/log/bioinfo-setup"
LOG_FILE=""
CURRENT_ACTION="startup"
LAST_CREATED_USER=""

if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=1
elif [[ -n "${1:-}" ]]; then
  printf 'Usage: %s [--dry-run]\n' "$SCRIPT_NAME" >&2
  exit 2
fi

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
info() { printf '\033[1;34m[i]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

on_error() {
  local rc=$?
  local line="${BASH_LINENO[0]:-unknown}"
  local cmd="${BASH_COMMAND:-unknown}"
  printf '\033[1;31m[x]\033[0m action=%s rc=%s line=%s command=%q\n'     "${CURRENT_ACTION:-unknown}" "$rc" "$line" "$cmd" >&2
  return "$rc"
}

trap on_error ERR

init_logging() {
  local user
  user="$(login_user)"

  if (( DRY_RUN )); then
    LOG_FILE="/tmp/bioinfo-setup-dry-run-${user}-$(date +%Y%m%d-%H%M%S)-$$.log"
  else
    if (( EUID == 0 )); then
      mkdir -p "$LOG_DIR"
      LOG_FILE="$LOG_DIR/setup-$(date +%Y%m%d-%H%M%S)-$$.log"
      touch "$LOG_FILE"
    else
      command -v sudo >/dev/null 2>&1 || die "需要 sudo 创建日志目录 $LOG_DIR。"
      sudo mkdir -p "$LOG_DIR"
      LOG_FILE="$LOG_DIR/setup-$(date +%Y%m%d-%H%M%S)-$$.log"
      sudo touch "$LOG_FILE"
      sudo chown "$user:$(id -gn "$user")" "$LOG_FILE"
    fi
  fi

  [[ -n "$LOG_FILE" ]] || die "无法初始化日志文件。"
  exec > >(tee -a "$LOG_FILE") 2>&1
  info "日志文件: $LOG_FILE"
}

backup_file() {
  local file="$1"
  local backup
  [[ -e "$file" ]] || return 0
  backup="${file}.bak.$(date +%Y%m%d-%H%M%S)"

  if (( DRY_RUN )); then
    printf '[dry-run] backup %q -> %q\n' "$file" "$backup"
    return 0
  fi

  as_root cp -a "$file" "$backup"
  info "已备份: $backup"
}

pause() {
  read -r -p "按 Enter 返回菜单..." _
}

confirm() {
  local prompt="$1"
  local default="${2:-N}"
  local answer
  local hint="[y/N]"
  [[ "$default" == "Y" ]] && hint="[Y/n]"
  read -r -p "$prompt $hint " answer
  answer="${answer:-$default}"
  [[ "$answer" =~ ^[Yy]$ ]]
}

run() {
  if (( DRY_RUN )); then
    printf '[dry-run]'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi
  "$@"
}

as_root() {
  if (( EUID == 0 )); then
    run "$@"
  else
    command -v sudo >/dev/null 2>&1 || die "需要 root 权限，但系统未安装 sudo。"
    run sudo "$@"
  fi
}

login_user() {
  printf '%s' "${SUDO_USER:-${USER:-$(id -un)}}"
}

login_home() {
  local user
  user="$(login_user)"
  getent passwd "$user" | cut -d: -f6
}

as_login_user() {
  local user home
  user="$(login_user)"
  home="$(login_home)"
  [[ -n "$home" ]] || { warn "无法读取登录用户 $user 的 home。"; return 1; }

  if (( EUID == 0 )) && [[ "$user" != "root" ]]; then
    run sudo -u "$user" -H env HOME="$home" bash -c 'cd "$HOME" && exec "$@"' bash "$@"
  else
    run env HOME="$home" bash -c 'cd "$HOME" && exec "$@"' bash "$@"
  fi
}


as_named_user() {
  local user="$1"
  shift
  local home
  home="$(getent passwd "$user" 2>/dev/null | cut -d: -f6 || true)"
  if [[ -z "$home" ]] && (( DRY_RUN )) && [[ "$user" == "$LAST_CREATED_USER" ]]; then
    home="/home/$user"
  fi
  [[ -n "$home" ]] || { warn "找不到用户 $user 的 home。"; return 1; }

  if [[ "$(id -un)" == "$user" ]]; then
    run env HOME="$home" bash -c 'cd "$HOME" && exec "$@"' bash "$@"
  elif (( EUID == 0 )); then
    command -v runuser >/dev/null 2>&1 || die "缺少 runuser，无法以用户 $user 身份执行命令。"
    run runuser -u "$user" -- env HOME="$home" bash -c 'cd "$HOME" && exec "$@"' bash "$@"
  else
    command -v sudo >/dev/null 2>&1 || die "需要 sudo 才能为其他用户执行安装。"
    run sudo -u "$user" -H env HOME="$home" bash -c 'cd "$HOME" && exec "$@"' bash "$@"
  fi
}

as_named_user_in_dir() {
  local user="$1"
  local dir="$2"
  shift 2
  as_named_user "$user" bash -c 'cd "$1" && shift && exec "$@"' _ "$dir" "$@"
}

append_named_user_line_once() {
  local user="$1"
  local file="$2"
  local line="$3"

  if grep -Fqx -- "$line" "$file" 2>/dev/null; then
    info "$file 已存在: $line"
    return 0
  fi

  if (( DRY_RUN )); then
    printf '[dry-run] append %q to %q as %q\n' "$line" "$file" "$user"
    return 0
  fi

  as_named_user "$user" touch "$file"
  if (( EUID == 0 )); then
    printf '%s\n' "$line" | runuser -u "$user" -- tee -a "$file" >/dev/null
  elif [[ "$(id -un)" == "$user" ]]; then
    printf '%s\n' "$line" >> "$file"
  else
    printf '%s\n' "$line" | sudo -u "$user" -H tee -a "$file" >/dev/null
  fi
}

write_named_user_file() {
  local user="$1"
  local file="$2"
  local content="$3"

  if (( DRY_RUN )); then
    printf '[dry-run] write %q as %q\n' "$file" "$user"
    printf '%s\n' "$content"
    return 0
  fi

  as_named_user "$user" touch "$file"
  if (( EUID == 0 )); then
    printf '%s\n' "$content" | runuser -u "$user" -- tee "$file" >/dev/null
  elif [[ "$(id -un)" == "$user" ]]; then
    printf '%s\n' "$content" > "$file"
  else
    printf '%s\n' "$content" | sudo -u "$user" -H tee "$file" >/dev/null
  fi
}

append_user_line_once() {
  local file="$1"
  local line="$2"
  local user
  user="$(login_user)"

  if grep -Fqx -- "$line" "$file" 2>/dev/null; then
    info "$file 已存在: $line"
    return 0
  fi

  if (( DRY_RUN )); then
    printf '[dry-run] append %q to %q as %q\n' "$line" "$file" "$user"
    return 0
  fi

  if (( EUID == 0 )) && [[ "$user" != "root" ]]; then
    printf '%s\n' "$line" | sudo -u "$user" tee -a "$file" >/dev/null
  else
    printf '%s\n' "$line" >> "$file"
  fi
}

write_user_file() {
  local file="$1"
  local content="$2"
  local user
  user="$(login_user)"

  if (( DRY_RUN )); then
    printf '[dry-run] write %q as %q\n' "$file" "$user"
    printf '%s\n' "$content"
    return 0
  fi

  if (( EUID == 0 )) && [[ "$user" != "root" ]]; then
    printf '%s\n' "$content" | sudo -u "$user" tee "$file" >/dev/null
  else
    printf '%s\n' "$content" > "$file"
  fi
}

write_root_file() {
  local file="$1"
  local content="$2"

  if (( DRY_RUN )); then
    printf '[dry-run] write %q as root\n' "$file"
    printf '%s\n' "$content"
    return 0
  fi

  if (( EUID == 0 )); then
    printf '%s\n' "$content" > "$file"
  else
    printf '%s\n' "$content" | sudo tee "$file" >/dev/null
  fi
}

require_ubuntu() {
  [[ -r /etc/os-release ]] || die "找不到 /etc/os-release。"
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] || die "当前脚本仅针对 Ubuntu；检测到: ${PRETTY_NAME:-unknown}"
}

validate_simple_name() {
  [[ "$1" =~ ^[a-z_][a-z0-9_-]*$ ]]
}

validate_quota() {
  [[ "$1" =~ ^[0-9]+([KMGTP]i?[Bb]?|[KMGTP])?$ ]]
}


expected_bioinfo_group_gid() {
  case "$1" in
    admin) printf '110' ;;
    sharevip) printf '30002' ;;
    primevip) printf '30003' ;;
    coursevip) printf '30004' ;;
    labvip) printf '30005' ;;
    *) return 1 ;;
  esac
}

append_line_once() {
  local file="$1"
  local line="$2"
  if grep -Fqx -- "$line" "$file" 2>/dev/null; then
    info "$file 已存在: $line"
    return 0
  fi
  if (( DRY_RUN )); then
    printf '[dry-run] append %q to %q\n' "$line" "$file"
    return 0
  fi
  if (( EUID == 0 )); then
    printf '%s\n' "$line" >> "$file"
  else
    printf '%s\n' "$line" | sudo tee -a "$file" >/dev/null
  fi
}

set_root_config_value() {
  local file="$1"
  local key="$2"
  local value="$3"

  as_root mkdir -p "$(dirname "$file")"

  if grep -Eq "^${key}=" "$file" 2>/dev/null; then
    if (( DRY_RUN )); then
      printf '[dry-run] set %s=%q in %q\n' "$key" "$value" "$file"
    elif (( EUID == 0 )); then
      sed -i -E "s|^${key}=.*|${key}=${value}|" "$file"
    else
      sudo sed -i -E "s|^${key}=.*|${key}=${value}|" "$file"
    fi
  else
    append_line_once "$file" "$key=$value"
  fi
}

preflight() {
  require_ubuntu
  printf '\n=== 系统检查 ===\n'
  printf '主机名:       %s\n' "$(hostname)"
  printf '系统:         %s\n' "${PRETTY_NAME:-unknown}"
  printf '内核:         %s\n' "$(uname -r)"
  printf '架构:         %s\n' "$(uname -m)"
  printf 'CPU:          %s 核\n' "$(nproc)"
  printf '内存:         %s\n' "$(free -h | awk '/^Mem:/ {print $2}')"
  printf '根分区:       %s\n' "$(df -hP / | awk 'NR==2 {print $2 " total, " $4 " free"}')"
  printf '\n--- 磁盘 ---\n'
  lsblk -o NAME,SIZE,FSTYPE,FSVER,MOUNTPOINTS,UUID
  printf '\n--- 网络 ---\n'
  ip -brief address 2>/dev/null || true
  printf '\n--- 关键命令 ---\n'
  for cmd in curl git xfs_quota docker R rig conda mamba micromamba; do
    if command -v "$cmd" >/dev/null 2>&1; then
      printf '%-12s %s\n' "$cmd" "$(command -v "$cmd")"
    else
      printf '%-12s %s\n' "$cmd" "未安装"
    fi
  done
}

configure_time() {
  local timezone
  read -r -p "时区 [$TIMEZONE_DEFAULT]: " timezone
  timezone="${timezone:-$TIMEZONE_DEFAULT}"
  [[ -e "/usr/share/zoneinfo/$timezone" ]] || { warn "无效时区: $timezone"; return 1; }

  as_root timedatectl set-timezone "$timezone"
  as_root timedatectl set-ntp true
  log "时区已设置为 $timezone，并启用系统 NTP。"
}

install_base_packages() {
  require_ubuntu
  local packages=(
    vim wget curl ca-certificates gnupg lsb-release software-properties-common
    screen tmux rsync htop tree unzip zip jq
    lvm2 xfsprogs quota ufw
  )
  as_root apt-get update
  as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
  log "基础管理与磁盘工具安装完成。"
}

device_has_mounted_children() {
  local device="$1"
  lsblk -nrpo NAME,MOUNTPOINTS "$device" 2>/dev/null     | awk 'NF > 1 {for (i=2; i<=NF; i++) if ($i != "") {found=1}} END {exit !found}'
}

device_is_swap_or_parent_of_swap() {
  local device="$1"
  local swapdev node
  while read -r swapdev; do
    [[ -n "$swapdev" ]] || continue
    while read -r node; do
      [[ "$node" == "$device" ]] && return 0
    done < <(lsblk -srnpo NAME "$swapdev" 2>/dev/null || true)
  done < <(swapon --noheadings --raw --output NAME 2>/dev/null || true)
  return 1
}

device_is_root_or_parent() {
  local device="$1"
  local root_source node
  root_source="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
  [[ -n "$root_source" ]] || return 1

  while read -r node; do
    [[ "$node" == "$device" ]] && return 0
  done < <(lsblk -srnpo NAME "$root_source" 2>/dev/null || true)
  return 1
}

device_is_lvm_or_raid_member() {
  local device="$1"
  local type pv
  while read -r type; do
    case "$type" in
      lvm|raid*|md) return 0 ;;
    esac
  done < <(lsblk -nrpo TYPE "$device" 2>/dev/null || true)

  if command -v pvs >/dev/null 2>&1; then
    while read -r pv; do
      pv="$(printf '%s' "$pv" | xargs)"
      [[ -n "$pv" ]] || continue
      [[ "$pv" == "$device" ]] && return 0
    done < <(pvs --noheadings -o pv_name 2>/dev/null || true)
  fi
  return 1
}

device_has_child_partitions() {
  local device="$1"
  local count
  count="$(lsblk -nrpo NAME "$device" 2>/dev/null | wc -l)"
  (( count > 1 ))
}

device_has_partition_table() {
  local device="$1"
  local pttype
  pttype="$(lsblk -dn -o PTTYPE "$device" 2>/dev/null | xargs || true)"
  [[ -n "$pttype" ]]
}

assert_safe_to_format() {
  local device="$1"

  device="$(readlink -f "$device")"
  if [[ ! -b "$device" ]]; then
    if (( DRY_RUN )); then
      warn "dry-run：$device 当前不是可见块设备，仅演示格式化流程。"
      return 0
    fi
    warn "$device 不是块设备。"
    return 1
  fi

  if device_is_root_or_parent "$device"; then
    warn "拒绝格式化：$device 是系统根文件系统所在设备或其上级设备。"
    return 1
  fi
  if device_has_mounted_children "$device"; then
    warn "拒绝格式化：$device 或其子设备当前存在挂载点。"
    lsblk -o NAME,SIZE,FSTYPE,TYPE,MOUNTPOINTS "$device"
    return 1
  fi
  if device_is_swap_or_parent_of_swap "$device"; then
    warn "拒绝格式化：$device 正被 swap 使用，或是 swap 所在设备的上级设备。"
    return 1
  fi
  if device_is_lvm_or_raid_member "$device"; then
    warn "拒绝格式化：检测到 $device 属于 LVM/RAID 结构。"
    return 1
  fi
  if device_has_child_partitions "$device" || device_has_partition_table "$device"; then
    warn "$device 已存在分区/子设备或分区表；允许自动清理后整盘格式化，但必须通过三次确认。"
    lsblk -o NAME,SIZE,FSTYPE,TYPE,PTTYPE,MOUNTPOINTS "$device"
  fi

  return 0
}

confirm_destructive_format_three_times() {
  local device="$1"
  local answer phrase
  local device_info

  if [[ -b "$device" ]]; then
    device_info="$(lsblk -dn -o NAME,SIZE,MODEL,SERIAL,TYPE "$device" 2>/dev/null || true)"
  else
    device_info="$device (dry-run)"
  fi

  printf '\n============================================================\n'
  printf ' 高风险操作：即将清空并格式化设备\n'
  printf '============================================================\n'
  printf '目标设备: %s\n' "$device"
  printf '设备信息: %s\n' "$device_info"
  printf '目标格式: XFS\n'
  printf '结果: 该设备现有文件系统、分区表和数据将不可恢复。\n'
  if [[ -b "$device" ]] && { device_has_child_partitions "$device" || device_has_partition_table "$device"; }; then
    printf '\n当前分区/分区表：\n'
    lsblk -o NAME,SIZE,FSTYPE,TYPE,PTTYPE,MOUNTPOINTS "$device"
    printf '\n脚本将自动清理现有分区的文件系统签名和整盘分区表。\n'
  fi
  printf '============================================================\n'

  if ! confirm "【确认 1/3】我确认目标设备无需要保留的数据，并继续清空 $device？"; then
    warn "第 1 次确认未通过，已取消格式化。"
    return 1
  fi

  read -r -p "【确认 2/3】请输入完整设备名 '$device': " answer
  if [[ "$answer" != "$device" ]]; then
    warn "第 2 次确认不匹配，已取消格式化。"
    return 1
  fi

  phrase="ERASE $device"
  read -r -p "【确认 3/3】请输入 '$phrase' 才会真正执行: " answer
  if [[ "$answer" != "$phrase" ]]; then
    warn "第 3 次确认不匹配，已取消格式化。"
    return 1
  fi

  return 0
}

wipe_device_layout_if_needed() {
  local device="$1"
  local child

  if [[ ! -b "$device" ]] && (( DRY_RUN )); then
    printf '[dry-run] wipe filesystem/partition signatures on %q if present\n' "$device"
    return 0
  fi

  if device_has_child_partitions "$device" || device_has_partition_table "$device"; then
    info "检测到现有分区或分区表，开始自动清理文件系统签名和分区表..."

    while read -r child; do
      [[ -n "$child" ]] || continue
      as_root wipefs -a "$child"
    done < <(lsblk -nrpo NAME,TYPE "$device" 2>/dev/null | awk '$2=="part" {print $1}')

    if command -v partx >/dev/null 2>&1; then
      as_root partx -d "$device" || warn "partx 未能立即移除全部内核分区映射，继续尝试重读分区表。"
    fi

    as_root wipefs -a "$device"

    if command -v blockdev >/dev/null 2>&1; then
      as_root blockdev --rereadpt "$device" || warn "blockdev 无法重读分区表，继续尝试 partprobe。"
    fi
    if command -v partprobe >/dev/null 2>&1; then
      as_root partprobe "$device" || warn "partprobe 无法立即刷新内核分区表。"
    fi
    if command -v udevadm >/dev/null 2>&1; then
      as_root udevadm settle || true
    fi

    if device_has_partition_table "$device"; then
      warn "自动清理后 $device 仍检测到分区表，拒绝继续 mkfs.xfs。"
      return 1
    fi
    if device_has_child_partitions "$device"; then
      warn "自动清理后内核仍保留 $device 的子分区映射，拒绝继续 mkfs.xfs。"
      warn "请重新扫描磁盘、重新插拔设备或重启后再运行。"
      lsblk -o NAME,SIZE,FSTYPE,TYPE,PTTYPE,MOUNTPOINTS "$device"
      return 1
    fi

    log "$device 的旧分区表和分区映射已清理完成。"
  else
    info "$device 无子分区/分区表，直接创建 XFS 文件系统。"
  fi
}

storage_wizard() {
  local device mountpoint fs_type uuid

  printf '\n当前块设备：\n'
  lsblk -o NAME,SIZE,FSTYPE,FSVER,MOUNTPOINTS,UUID

  read -r -p "数据盘设备 [$DATA_DEVICE_DEFAULT]: " device
  device="${device:-$DATA_DEVICE_DEFAULT}"
  [[ -b "$device" ]] || {
    if (( DRY_RUN )); then
      warn "dry-run：$device 当前不是可见块设备，继续展示计划。"
    else
      warn "$device 不是块设备。"
      return 1
    fi
  }

  read -r -p "挂载目录 [$DATA_MOUNT_DEFAULT]: " mountpoint
  mountpoint="${mountpoint:-$DATA_MOUNT_DEFAULT}"
  [[ "$mountpoint" == /* ]] || { warn "挂载目录必须是绝对路径。"; return 1; }

  fs_type="$(blkid -s TYPE -o value "$device" 2>/dev/null || true)"
  if [[ "$fs_type" != "xfs" ]]; then
    warn "$device 当前文件系统: ${fs_type:-未格式化/未知}。quota 方案按 XFS 设计。"
    assert_safe_to_format "$device" || return 1

    if ! confirm_destructive_format_three_times "$device"; then
      warn "三次确认未全部通过，已取消存储初始化。"
      return 0
    fi

    wipe_device_layout_if_needed "$device"
    as_root mkfs.xfs -f "$device"
    fs_type="xfs"
  fi

  as_root mkdir -p "$mountpoint"

  if ! mountpoint -q "$mountpoint"; then
    as_root mount -o uquota,gquota "$device" "$mountpoint"
  else
    info "$mountpoint 已挂载，未重复 mount。"
  fi

  uuid="$(blkid -s UUID -o value "$device" 2>/dev/null || true)"
  if [[ -z "$uuid" ]] && (( DRY_RUN == 0 )); then
    warn "无法读取 $device UUID，跳过 /etc/fstab。"
  else
    [[ -n "$uuid" ]] || uuid="<DEVICE_UUID>"
    local fstab_line="UUID=$uuid $mountpoint xfs defaults,uquota,gquota 0 2"
    if grep -Eq "^[^#].*[[:space:]]${mountpoint}[[:space:]]" /etc/fstab 2>/dev/null; then
      warn "/etc/fstab 已有 $mountpoint 条目，请确认其中包含 uquota,gquota；脚本不覆盖现有配置。"
    else
      backup_file /etc/fstab
      append_line_once /etc/fstab "$fstab_line"
      if command -v findmnt >/dev/null 2>&1; then
        if ! as_root findmnt --verify --tab-file /etc/fstab; then
          warn "/etc/fstab 校验失败，请使用刚才生成的备份恢复。"
          return 1
        fi
      fi
    fi
  fi

  as_root mkdir -p "$mountpoint/user"
  if ! mountpoint -q "$mountpoint"; then
    if (( DRY_RUN )); then
      info "dry-run：假定 $mountpoint 挂载成功，继续展示后续流程。"
    else
      warn "$mountpoint 当前不是独立挂载点，停止后续 quota 配置。"
      return 1
    fi
  fi
  log "数据盘初始化完成。建议执行 xfs_quota -x -c 'report -ubih' '$mountpoint' 验证 quota。"
}

configure_firewall() {
  local ports_raw port
  read -r -p "允许 TCP 端口（空格分隔）[22 8787 8000]: " ports_raw
  ports_raw="${ports_raw:-22 8787 8000}"

  as_root apt-get update
  as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y ufw

  for port in $ports_raw; do
    if [[ ! "$port" =~ ^[0-9]{1,5}$ ]] || (( port < 1 || port > 65535 )); then
      warn "非法端口: $port"
      return 1
    fi
    as_root ufw allow "$port/tcp"
  done

  if confirm "启用 UFW？请确认 SSH 端口已包含在允许列表中。"; then
    as_root ufw --force enable
    as_root ufw reload
  else
    warn "规则已写入，但未启用 UFW。"
  fi
  as_root ufw status verbose
}

install_dev_tools() {
  require_ubuntu
  local packages=(
    build-essential gcc g++ gfortran make cmake pkg-config
    git default-jdk
    python3 python3-pip python3-venv python-is-python3
    libcurl4-openssl-dev libssl-dev libxml2-dev libgit2-dev
    libfontconfig1-dev libharfbuzz-dev libfribidi-dev
    libfreetype6-dev libpng-dev libtiff-dev libjpeg-dev
  )
  as_root apt-get update
  as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"

  if confirm "安装 Qt5 开发工具？"; then
    as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y       qtbase5-dev qtchooser qt5-qmake qtbase5-dev-tools qtcreator
  fi
  log "开发环境安装完成。"
}

install_docker() {
  require_ubuntu
  local arch codename
  arch="$(dpkg --print-architecture)"
  codename="$(. /etc/os-release && printf '%s' "$VERSION_CODENAME")"
  [[ -n "$codename" ]] || die "无法读取 Ubuntu VERSION_CODENAME。"

  as_root apt-get update
  as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y     ca-certificates curl gnupg
  as_root install -m 0755 -d /etc/apt/keyrings

  if (( DRY_RUN )); then
    printf '[dry-run] install Docker GPG key -> /etc/apt/keyrings/docker.gpg\n'
  else
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg       | gpg --dearmor       | if (( EUID == 0 )); then cat > /etc/apt/keyrings/docker.gpg; else sudo tee /etc/apt/keyrings/docker.gpg >/dev/null; fi
    as_root chmod a+r /etc/apt/keyrings/docker.gpg
  fi

  local repo="deb [arch=$arch signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $codename stable"
  if (( DRY_RUN )); then
    printf '[dry-run] write %q to /etc/apt/sources.list.d/docker.list\n' "$repo"
  elif (( EUID == 0 )); then
    printf '%s\n' "$repo" > /etc/apt/sources.list.d/docker.list
  else
    printf '%s\n' "$repo" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  fi

  as_root apt-get update
  as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y     docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  as_root systemctl enable --now docker

  local login_user="${SUDO_USER:-${USER:-$(id -un)}}"
  if [[ "$login_user" != "root" ]] && confirm "将当前登录用户 $login_user 加入 docker 组？"; then
    as_root usermod -aG docker "$login_user"
    warn "docker 组权限需重新登录后生效。"
  fi
  log "Docker 安装完成。"
}

install_rig_manager() {
  local key_tmp="/tmp/rig.gpg"
  local repo='deb https://rig.r-pkg.org/deb rig main'

  as_root apt-get update
  as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates

  if (( DRY_RUN )); then
    printf '[dry-run] curl -fL https://rig.r-pkg.org/deb/rig.gpg -o %q\n' "$key_tmp"
  else
    curl -fL https://rig.r-pkg.org/deb/rig.gpg -o "$key_tmp"
  fi
  as_root install -m 0644 "$key_tmp" /etc/apt/trusted.gpg.d/rig.gpg
  write_root_file /etc/apt/sources.list.d/rig.list "$repo"

  as_root apt-get update
  as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y r-rig

  if (( DRY_RUN == 0 )); then
    rig --version
  fi
  log "R Installation Manager (rig) 已安装/更新。"
}

ensure_rig() {
  if command -v rig >/dev/null 2>&1; then
    return 0
  fi
  warn "尚未安装 rig。"
  if confirm "现在安装 rig？" "Y"; then
    install_rig_manager
  else
    return 1
  fi
}

sync_rstudio_r_path() {
  local r_bin
  r_bin="$(command -v R 2>/dev/null || true)"
  if [[ -z "$r_bin" ]] && (( DRY_RUN )); then
    r_bin="/usr/local/bin/R"
    info "dry-run：假定 rig 默认 R 链接为 $r_bin。"
  fi
  [[ -n "$r_bin" ]] || { warn "找不到当前默认 R，无法同步 RStudio。"; return 1; }

  if dpkg-query -W -f='${Status}' rstudio-server 2>/dev/null | grep -Fq 'install ok installed'; then
    backup_file /etc/rstudio/rserver.conf
    set_root_config_value /etc/rstudio/rserver.conf "rsession-which-r" "$r_bin"
    if confirm "R 默认版本已变化，是否重启 RStudio Server 使其生效？" "Y"; then
      as_root systemctl restart rstudio-server
    fi
    log "RStudio Server 已指向: $r_bin"
  fi
}

install_common_r_packages() {
  local data_mount lib_dir r_mm
  command -v Rscript >/dev/null 2>&1 || { warn "当前没有默认 Rscript。"; return 1; }

  read -r -p "共享 R library 根目录 [$DATA_MOUNT_DEFAULT/R_Lib]: " data_mount
  [[ -n "$data_mount" ]] || data_mount="$DATA_MOUNT_DEFAULT/R_Lib"

  r_mm="$(Rscript -e 'cat(paste(R.version$major, strsplit(R.version$minor, "\\.")[[1]][1], sep="."))')"
  lib_dir="$data_mount/$r_mm"
  as_root mkdir -p "$lib_dir"

  local r_expr
  r_expr=".libPaths(c('$lib_dir', .libPaths())); options(repos=c(CRAN='https://cloud.r-project.org')); install.packages(c('BiocManager','tidyverse','devtools','Seurat','SeuratObject','harmony','patchwork'), lib='$lib_dir'); BiocManager::install(c('DESeq2','edgeR','DiffBind','BSgenome','clusterProfiler','GSVA','pheatmap','ComplexHeatmap','SingleCellExperiment','HDF5Array','limma','S4Vectors','SingleR','TCGAbiolinks'), lib='$lib_dir', ask=FALSE, update=FALSE)"
  as_root Rscript -e "$r_expr"
  log "常用 R/Bioconductor 包已安装到 $lib_dir"
}

install_r_for_bootstrap() {
  local target="${1:-release}"
  CURRENT_ACTION="bootstrap R $target"

  if ! command -v rig >/dev/null 2>&1; then
    install_rig_manager
  fi

  info "一键开局安装 R：目标版本=$target"
  as_root rig add "$target"
  as_root rig default "$target"

  if (( DRY_RUN == 0 )); then
    command -v R >/dev/null 2>&1 || { warn "R 安装后仍找不到 R 命令。"; return 1; }
    log "R 默认版本已设置：$(R --version 2>/dev/null | head -1)"
  else
    log "dry-run：将安装并设为默认 R $target"
  fi
}

install_r() {
  local choice target current

  while true; do
    current="$(R --version 2>/dev/null | head -1 || true)"
    printf '\n============================================================\n'
    printf ' R 多版本管理（rig）\n'
    printf ' 当前默认: %s\n' "${current:-未安装}"
    printf '============================================================\n'
    printf '1) 安装 / 更新 rig\n'
    printf '2) 查看已安装 R 版本\n'
    printf '3) 查看可安装 R 版本\n'
    printf '4) 安装指定 R 版本 / 别名\n'
    printf '5) 切换默认 R 版本\n'
    printf '6) 删除指定 R 版本\n'
    printf '7) 安装当前默认 R 的常用 CRAN/Bioconductor 包\n'
    printf '0) 返回主菜单\n'
    read -r -p "选择: " choice

    case "$choice" in
      1)
        CURRENT_ACTION="R: install rig"
        install_rig_manager
        ;;
      2)
        CURRENT_ACTION="R: list installed"
        ensure_rig || continue
        as_root rig list
        ;;
      3)
        CURRENT_ACTION="R: list available"
        ensure_rig || continue
        rig available
        ;;
      4)
        CURRENT_ACTION="R: add version"
        ensure_rig || continue
        printf '可输入 release / oldrel / devel / next，或精确版本如 4.5.1。\n'
        read -r -p "要安装的 R 版本 [release]: " target
        [[ -n "$target" ]] || target="release"
        as_root rig add "$target"
        if confirm "将 $target 设为默认 R？" "Y"; then
          as_root rig default "$target"
          sync_rstudio_r_path
        fi
        ;;
      5)
        CURRENT_ACTION="R: set default"
        ensure_rig || continue
        as_root rig list
        read -r -p "设为默认的版本号/别名: " target
        [[ -n "$target" ]] || { warn "版本不能为空。"; continue; }
        as_root rig default "$target"
        sync_rstudio_r_path
        ;;
      6)
        CURRENT_ACTION="R: remove version"
        ensure_rig || continue
        as_root rig list
        read -r -p "要删除的版本号: " target
        [[ -n "$target" ]] || { warn "版本不能为空。"; continue; }
        confirm "确认删除 R $target？" || continue
        as_root rig rm "$target"
        ;;
      7)
        CURRENT_ACTION="R: common packages"
        install_common_r_packages
        ;;
      0)
        CURRENT_ACTION="main menu"
        return 0
        ;;
      *)
        warn "无效选择: $choice"
        ;;
    esac
  done
}

install_rstudio() {
  local releases_url="https://dailies.rstudio.com/release/"
  local download_base="https://download2.rstudio.org/server/jammy/amd64"
  local tmp="/tmp/rstudio-server.deb"
  local current_version target_version file_version url action choice manual_version r_bin
  local backup_dir="" installed=0
  local -a versions=()

  [[ "$(uname -m)" == "x86_64" ]] || {
    warn "当前 RStudio Server 安装器按 Ubuntu amd64/x86_64 设计；检测到架构: $(uname -m)"
    return 1
  }

  as_root apt-get update
  as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates

  if dpkg-query -W -f='${Status}' rstudio-server 2>/dev/null | grep -Fq "install ok installed"; then
    current_version="$(dpkg-query -W -f='${Version}' rstudio-server 2>/dev/null || true)"
    installed=1
    info "当前已安装 RStudio Server: $current_version"
  else
    current_version=""
    info "当前未安装 RStudio Server。"
  fi

  if (( DRY_RUN )); then
    info "正在读取 Posit 官方稳定版本列表（dry-run 仍会联网读取版本元数据）。"
  else
    info "正在读取 Posit 官方稳定版本列表..."
  fi

  mapfile -t versions < <(
    curl -fsSL "$releases_url" 2>/dev/null \
      | grep -oE '/version/[0-9]{4}\.[0-9]{2}\.[0-9]+&#43;[0-9]+\.pro[0-9]+' \
      | sed -E 's#^/version/##; s/&#43;/+/; s/\.pro[0-9]+$//' \
      | awk '!seen[$0]++'
  ) || true

  if (( ${#versions[@]} > 0 )); then
    local i version series selected_series series_choice version_choice
    local current_series=""
    local -a series_list=() series_versions=()
    declare -A seen_series=()

    if [[ "$current_version" =~ ^([0-9]{4}\.[0-9]{2})\. ]]; then
      current_series="${BASH_REMATCH[1]}"
    fi

    for version in "${versions[@]}"; do
      series="${version%.*}"
      if [[ -z "${seen_series[$series]:-}" ]]; then
        series_list+=("$series")
        seen_series["$series"]=1
      fi
    done

    printf '\nRStudio Server 大版本系列：\n'
    for i in "${!series_list[@]}"; do
      if [[ "${series_list[$i]}" == "$current_series" ]]; then
        printf '%2d) %-10s [当前版本系列]\n' "$((i + 1))" "${series_list[$i]}"
      else
        printf '%2d) %s\n' "$((i + 1))" "${series_list[$i]}"
      fi
    done
    printf '%2d) 直接指定完整版本号\n' "$((${#series_list[@]} + 1))"

    read -r -p "选择大版本系列 [1]: " series_choice
    series_choice="${series_choice:-1}"

    if [[ "$series_choice" =~ ^[0-9]+$ ]] && (( series_choice >= 1 && series_choice <= ${#series_list[@]} )); then
      selected_series="${series_list[$((series_choice - 1))]}"

      for version in "${versions[@]}"; do
        if [[ "$version" == "$selected_series."* ]]; then
          series_versions+=("$version")
        fi
      done

      printf '\n%s 系列可用版本：\n' "$selected_series"
      for i in "${!series_versions[@]}"; do
        if [[ "${series_versions[$i]}" == "$current_version" ]]; then
          printf '%2d) %-20s [当前版本]\n' "$((i + 1))" "${series_versions[$i]}"
        else
          printf '%2d) %s\n' "$((i + 1))" "${series_versions[$i]}"
        fi
      done
      printf '%2d) 直接指定完整版本号\n' "$((${#series_versions[@]} + 1))"

      read -r -p "选择具体版本 [1]: " version_choice
      version_choice="${version_choice:-1}"

      if [[ "$version_choice" =~ ^[0-9]+$ ]] && (( version_choice >= 1 && version_choice <= ${#series_versions[@]} )); then
        target_version="${series_versions[$((version_choice - 1))]}"
      elif [[ "$version_choice" =~ ^[0-9]+$ ]] && (( version_choice == ${#series_versions[@]} + 1 )); then
        read -r -p "输入完整版本号，例如 2025.05.1+513: " manual_version
        target_version="$manual_version"
      else
        warn "无效具体版本选择。"
        return 1
      fi
    elif [[ "$series_choice" =~ ^[0-9]+$ ]] && (( series_choice == ${#series_list[@]} + 1 )); then
      read -r -p "输入完整版本号，例如 2025.05.1+513: " manual_version
      target_version="$manual_version"
    else
      warn "无效大版本选择。"
      return 1
    fi
  else
    warn "无法从 Posit 获取版本列表；可直接指定完整版本号。"
    read -r -p "目标版本，例如 2025.05.1+513: " target_version
  fi

  [[ "$target_version" =~ ^[0-9]{4}\.[0-9]{2}\.[0-9]+\+[0-9]+$ ]] || {
    warn "版本号格式不正确，应类似 2026.09.0+174。"
    return 1
  }

  file_version="${target_version/+/-}"
  url="$download_base/rstudio-server-${file_version}-amd64.deb"

  if (( installed )); then
    if dpkg --compare-versions "$target_version" gt "$current_version"; then
      action="升级"
    elif dpkg --compare-versions "$target_version" lt "$current_version"; then
      action="降级"
    else
      action="重装"
    fi
  else
    action="安装"
  fi

  printf '\nRStudio Server 操作确认：\n'
  printf '  当前版本: %s\n' "${current_version:-未安装}"
  printf '  目标版本: %s\n' "$target_version"
  printf '  操作类型: %s\n' "$action"
  printf '  下载地址: %s\n' "$url"

  if [[ "$action" == "降级" ]]; then
    warn "你正在降级 RStudio Server。旧版本可能不支持当前 R 版本或现有配置。"
  fi

  if (( DRY_RUN == 0 )); then
    info "检查目标安装包是否存在..."
    if ! curl -fIsSL --max-time 20 "$url" >/dev/null; then
      warn "Posit 官方下载地址不存在或暂时不可访问：$url"
      warn "请选择其他稳定版本，或确认该版本是否提供 Ubuntu 22/24 amd64 构建。"
      return 1
    fi
  else
    printf '[dry-run] curl -fIsSL --max-time 20 %q\n' "$url"
  fi

  confirm "确认执行 RStudio Server $action？" || {
    warn "已取消。"
    return 0
  }

  if (( installed )) && [[ -d /etc/rstudio ]]; then
    backup_dir="/var/backups/rstudio-server/$(date +%Y%m%d-%H%M%S)-$current_version"
    as_root mkdir -p "$backup_dir"
    as_root cp -a /etc/rstudio/. "$backup_dir/"
    log "RStudio 配置已备份到 $backup_dir"
  fi

  if (( DRY_RUN )); then
    printf '[dry-run] curl -fL %q -o %q\n' "$url" "$tmp"
  else
    curl -fL "$url" -o "$tmp"
  fi

  if (( installed )); then
    if command -v rstudio-server >/dev/null 2>&1; then
      as_root rstudio-server suspend-all || true
    fi
    as_root systemctl stop rstudio-server || true
  fi

  if ! as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y --allow-downgrades "$tmp"; then
    warn "RStudio Server $action失败。"
    if (( installed )); then
      warn "尝试重新启动现有 rstudio-server 服务。"
      as_root systemctl start rstudio-server || true
    fi
    return 1
  fi

  as_root mkdir -p /etc/rstudio
  r_bin="$(command -v R 2>/dev/null || true)"
  if [[ -n "$r_bin" ]]; then
    set_root_config_value /etc/rstudio/rserver.conf "rsession-which-r" "$r_bin"
  else
    warn "当前未找到 R；RStudio Server 安装后需要先安装 R，再同步 rsession-which-r。"
  fi
  set_root_config_value /etc/rstudio/rserver.conf "www-port" "8787"

  as_root systemctl enable --now rstudio-server
  as_root systemctl restart rstudio-server

  local installed_version
  installed_version="$(dpkg-query -W -f='${Version}' rstudio-server 2>/dev/null || true)"
  if [[ "$installed_version" != "$target_version" ]] && (( DRY_RUN == 0 )); then
    warn "安装后版本与目标版本不一致：目标=$target_version，实际=$installed_version"
    return 1
  fi

  if command -v rstudio-server >/dev/null 2>&1; then
    as_root rstudio-server verify-installation
  fi
  as_root systemctl --no-pager --full status rstudio-server

  log "RStudio Server $action完成：$target_version"
  [[ -n "$backup_dir" ]] && info "升级/降级前配置备份：$backup_dir"
}

install_miniforge() {
  local prefix arch url installer
  read -r -p "Miniforge 安装目录 [$MINIFORGE_DEFAULT]: " prefix
  prefix="${prefix:-$MINIFORGE_DEFAULT}"
  [[ "$prefix" == /* ]] || { warn "安装目录必须是绝对路径。"; return 1; }

  case "$(uname -m)" in
    x86_64) arch="x86_64" ;;
    aarch64|arm64) arch="aarch64" ;;
    *) warn "不支持的架构: $(uname -m)"; return 1 ;;
  esac

  url="https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-${arch}.sh"
  installer="/tmp/miniforge-installer.sh"

  if [[ -x "$prefix/bin/conda" ]]; then
    info "$prefix 已存在 conda，跳过安装。"
  else
    if (( DRY_RUN )); then
      printf '[dry-run] curl -fL %q -o %q\n' "$url" "$installer"
    else
      curl -fL "$url" -o "$installer"
    fi
    as_root bash "$installer" -b -p "$prefix"
  fi

  local profile_line="export PATH=\"$prefix/bin:\$PATH\""
  append_line_once /etc/profile.d/bioinfo-conda.sh "$profile_line"

  as_root "$prefix/bin/conda" config --system --set channel_priority strict
  as_root "$prefix/bin/conda" install -n base -y -c conda-forge mamba
  log "Miniforge/Mamba 安装完成: $prefix"
  warn "新 shell 登录后 PATH 自动生效；当前可直接使用 $prefix/bin/mamba。"
}

find_conda_config_manager() {
  local home candidate
  home="$(login_home)"
  for candidate in \
    "$home/data_HD/miniconda3/bin/conda" \
    "$MINICONDA_SYSTEM_DEFAULT/bin/conda" \
    "$MINIFORGE_DEFAULT/bin/conda" \
    "$home/data_HD/bin/micromamba" \
    "$MICROMAMBA_SYSTEM_BIN"
  do
    [[ -x "$candidate" ]] && { printf '%s' "$candidate"; return 0; }
  done
  return 1
}

configure_tuna_conda_mirrors() {
  local scope
  local home condarc manager manager_name channel
  local -a channels=(
    "https://mirrors.tuna.tsinghua.edu.cn/anaconda/pkgs/main"
    "https://mirrors.tuna.tsinghua.edu.cn/anaconda/pkgs/r"
    "https://mirrors.tuna.tsinghua.edu.cn/anaconda/pkgs/msys2"
    "https://mirrors.tuna.tsinghua.edu.cn/anaconda/cloud/conda-forge"
    "https://mirrors.tuna.tsinghua.edu.cn/anaconda/cloud/bioconda"
  )

  home="$(login_home)"

  printf '1) 当前登录用户 ~/.condarc\n'
  printf '2) 系统级 /etc/conda/condarc（sudo）\n'
  read -r -p "配置范围 [1]: " scope
  [[ -n "$scope" ]] || scope="1"

  case "$scope" in
    1|user)
      condarc="$home/.condarc"
      ;;
    2|system)
      as_root mkdir -p /etc/conda
      condarc="/etc/conda/condarc"
      ;;
    *)
      warn "无效选择。"
      return 1
      ;;
  esac

  if [[ -e "$condarc" ]]; then
    backup_file "$condarc"
  fi

  manager="$(find_conda_config_manager 2>/dev/null || true)"
  if [[ -z "$manager" ]]; then
    if [[ -e "$condarc" ]]; then
      warn "检测到已有 $condarc，但系统没有 conda/micromamba 可用于安全合并。"
      warn "已保留原文件并创建备份；请先安装 micromamba（会自动准备 Miniconda 前置）或 Miniforge 后重试。"
      return 1
    fi

    local content_new='show_channel_urls: true
channels:
  - https://mirrors.tuna.tsinghua.edu.cn/anaconda/pkgs/main
  - https://mirrors.tuna.tsinghua.edu.cn/anaconda/pkgs/r
  - https://mirrors.tuna.tsinghua.edu.cn/anaconda/pkgs/msys2
  - https://mirrors.tuna.tsinghua.edu.cn/anaconda/cloud/conda-forge
  - https://mirrors.tuna.tsinghua.edu.cn/anaconda/cloud/bioconda'
    if [[ "$scope" == "2" || "$scope" == "system" ]]; then
      write_root_file "$condarc" "$content_new"
    else
      write_user_file "$condarc" "$content_new"
    fi
    log "新建 Conda 配置: $condarc"
    return 0
  fi

  manager_name="$(basename "$manager")"
  info "使用 $manager_name 无损更新 $condarc"

  # micromamba/libmamba 在显式指定 CONDARC 且文件不存在时会直接中止。
  # 因此先创建空配置文件，再让配置管理器原地更新。
  if [[ ! -e "$condarc" ]]; then
    if [[ "$scope" == "2" || "$scope" == "system" ]]; then
      write_root_file "$condarc" ""
    else
      write_user_file "$condarc" ""
    fi
    info "已创建空 Conda 配置文件: $condarc"
  fi

  if [[ "$manager_name" == "micromamba" ]]; then
    local -a mm_prefix=()
    if [[ "$scope" == "2" ]]; then
      mm_prefix=(as_root)
    else
      mm_prefix=(as_login_user)
    fi

    "${mm_prefix[@]}" env CONDARC="$condarc" "$manager" config set show_channel_urls true
    "${mm_prefix[@]}" env CONDARC="$condarc" "$manager" config set use_sharded_repodata false
    for channel in "${channels[@]}"; do
      if ! "${mm_prefix[@]}" env CONDARC="$condarc" "$manager" config list 2>/dev/null | grep -Fq -- "$channel"; then
        "${mm_prefix[@]}" env CONDARC="$condarc" "$manager" config append channels "$channel"
      fi
    done
  else
    if [[ "$scope" == "2" || "$scope" == "system" ]]; then
      as_root "$manager" config --file "$condarc" --set show_channel_urls true
      for channel in "${channels[@]}"; do
        if ! "$manager" config --file "$condarc" --show channels 2>/dev/null | grep -Fq -- "$channel"; then
          as_root "$manager" config --file "$condarc" --append channels "$channel"
        fi
      done
    else
      as_login_user "$manager" config --file "$condarc" --set show_channel_urls true
      for channel in "${channels[@]}"; do
        if ! as_login_user "$manager" config --file "$condarc" --show channels 2>/dev/null | grep -Fq -- "$channel"; then
          as_login_user "$manager" config --file "$condarc" --append channels "$channel"
        fi
      done
    fi

    if grep -Eq '^[[:space:]]*-[[:space:]]*defaults[[:space:]]*$' "$condarc" 2>/dev/null; then
      if [[ "$scope" == "2" || "$scope" == "system" ]]; then
        as_root "$manager" config --file "$condarc" --remove channels defaults
      else
        as_login_user "$manager" config --file "$condarc" --remove channels defaults
      fi
      info "已从 $condarc 移除 defaults，避免访问 repo.anaconda.com 触发 ToS。"
    fi
  fi

  log "清华 Conda/Bioconda 源已无损合并到 $condarc"
}

find_named_user_miniconda() {
  local user="$1"
  local home candidate marker_prefix="" shell_conda="" base=""
  home="$(getent passwd "$user" 2>/dev/null | cut -d: -f6 || true)"
  [[ -n "$home" ]] || return 1

  if [[ -r "$home/.config/bioinfo-setup/miniconda.prefix" ]]; then
    marker_prefix="$(head -n1 "$home/.config/bioinfo-setup/miniconda.prefix" 2>/dev/null || true)"
  fi

  for candidate in \
    "${marker_prefix:+$marker_prefix/bin/conda}" \
    "$home/data_HD/miniconda3/bin/conda" \
    "$home/miniconda3/bin/conda" \
    "$home/.miniconda3/bin/conda" \
    "$([[ "$user" == "root" ]] && printf '%s' "$MINICONDA_SYSTEM_DEFAULT/bin/conda" || true)"
  do
    [[ -n "$candidate" ]] || continue
    if [[ -x "$candidate" ]] && { [[ "$candidate" == "$home/"* ]] || [[ "$user" == "root" && "$candidate" == "$MINICONDA_SYSTEM_DEFAULT/bin/conda" ]]; }; then
      printf '%s' "$candidate"
      return 0
    fi
  done

  if (( DRY_RUN == 0 )); then
    shell_conda="$(as_named_user "$user" bash -lc 'command -v conda 2>/dev/null || true' 2>/dev/null || true)"
    if [[ -n "$shell_conda" && -x "$shell_conda" ]]; then
      base="$(as_named_user "$user" "$shell_conda" info --base 2>/dev/null || true)"
      if [[ -n "$base" && "$base" == "$home/"* && "$(basename "$base")" == *miniconda* ]]; then
        printf '%s' "$shell_conda"
        return 0
      fi
    fi
  fi

  return 1
}

configure_tuna_for_named_user() {
  local user="$1"
  local conda_bin="$2"
  local home condarc channel
  local -a channels=(
    "https://mirrors.tuna.tsinghua.edu.cn/anaconda/pkgs/main"
    "https://mirrors.tuna.tsinghua.edu.cn/anaconda/pkgs/r"
    "https://mirrors.tuna.tsinghua.edu.cn/anaconda/pkgs/msys2"
    "https://mirrors.tuna.tsinghua.edu.cn/anaconda/cloud/conda-forge"
    "https://mirrors.tuna.tsinghua.edu.cn/anaconda/cloud/bioconda"
  )

  home="$(getent passwd "$user" 2>/dev/null | cut -d: -f6 || true)"
  if [[ -z "$home" ]] && (( DRY_RUN )) && [[ "$user" == "$LAST_CREATED_USER" ]]; then
    home="/home/$user"
  fi
  [[ -n "$home" ]] || { warn "无法读取用户 $user 的 home。"; return 1; }
  condarc="$home/.condarc"
  [[ -e "$condarc" ]] && backup_file "$condarc"
  as_named_user "$user" touch "$condarc"
  as_named_user "$user" "$conda_bin" config --file "$condarc" --set show_channel_urls true

  for channel in "${channels[@]}"; do
    if ! as_named_user "$user" "$conda_bin" config --file "$condarc" --show channels 2>/dev/null | grep -Fq -- "$channel"; then
      as_named_user "$user" "$conda_bin" config --file "$condarc" --append channels "$channel"
    fi
  done

  if grep -Eq '^[[:space:]]*-[[:space:]]*defaults[[:space:]]*$' "$condarc" 2>/dev/null; then
    as_named_user "$user" "$conda_bin" config --file "$condarc" --remove channels defaults
    info "已从 $condarc 移除 defaults，避免访问 repo.anaconda.com 触发 ToS。"
  fi

  log "已为用户 $user 配置清华 Conda/Bioconda 源。"
}

find_named_user_micromamba() {
  local user="$1" home candidate marker_bin="" shell_bin=""
  home="$(getent passwd "$user" 2>/dev/null | cut -d: -f6 || true)"
  [[ -n "$home" ]] || return 1

  if [[ -r "$home/.config/bioinfo-setup/micromamba.bin" ]]; then
    marker_bin="$(head -n1 "$home/.config/bioinfo-setup/micromamba.bin" 2>/dev/null || true)"
  fi

  for candidate in \
    "$marker_bin" \
    "$home/data_HD/bin/micromamba" \
    "$home/.local/bin/micromamba" \
    "$home/bin/micromamba"
  do
    [[ -n "$candidate" ]] || continue
    if [[ -x "$candidate" && "$candidate" == "$home/"* ]]; then
      printf '%s' "$candidate"
      return 0
    fi
  done

  if (( DRY_RUN == 0 )); then
    shell_bin="$(as_named_user "$user" bash -lc 'command -v micromamba 2>/dev/null || true' 2>/dev/null || true)"
    if [[ -n "$shell_bin" && -x "$shell_bin" && "$shell_bin" == "$home/"* ]]; then
      printf '%s' "$shell_bin"
      return 0
    fi
  fi

  return 1
}

install_miniconda_prerequisite_for_account() {
  local user="$1" home prefix arch url installer conda_bin existing=""
  MINICONDA_PREREQ_BIN=""

  validate_simple_name "$user" || { warn "用户名格式不合法。"; return 1; }
  if id "$user" >/dev/null 2>&1; then
    home="$(getent passwd "$user" 2>/dev/null | cut -d: -f6 || true)"
  elif (( DRY_RUN )) && [[ "$user" == "$LAST_CREATED_USER" ]]; then
    home="/home/$user"
  else
    warn "用户 $user 不存在。"
    return 1
  fi
  [[ -n "$home" ]] || { warn "无法读取用户 $user 的 home。"; return 1; }

  existing="$(find_named_user_miniconda "$user" 2>/dev/null || true)"
  if [[ -n "$existing" ]]; then
    info "Miniconda 前置条件已满足: user=$user path=$existing"
    if (( DRY_RUN == 0 )); then
      info "Miniconda 版本: $("$existing" --version 2>/dev/null || true)"
    fi
    MINICONDA_PREREQ_BIN="$existing"
    return 0
  fi

  case "$(uname -m)" in
    x86_64) arch="x86_64" ;;
    aarch64|arm64) arch="aarch64" ;;
    *) warn "不支持的架构: $(uname -m)"; return 1 ;;
  esac

  prefix="$home/data_HD/miniconda3"
  url="https://mirrors.tuna.tsinghua.edu.cn/anaconda/miniconda/Miniconda3-latest-Linux-${arch}.sh"
  installer="/tmp/miniconda-prereq-${user}-${arch}.sh"

  info "未检测到 $user 的 Miniconda；作为 micromamba 前置条件自动安装到 $prefix"
  as_named_user "$user" mkdir -p "$home/data_HD"
  if (( DRY_RUN )); then
    printf '[dry-run] curl -fL %q -o %q\n' "$url" "$installer"
  else
    curl -fL "$url" -o "$installer"
    chmod 0755 "$installer"
  fi
  as_named_user "$user" bash "$installer" -b -p "$prefix"

  conda_bin="$prefix/bin/conda"
  append_named_user_line_once "$user" "$home/.bashrc" "export PATH=\"$prefix/bin:\$PATH\""
  as_named_user "$user" "$conda_bin" init bash
  configure_tuna_for_named_user "$user" "$conda_bin"
  as_named_user "$user" mkdir -p "$home/.config/bioinfo-setup"
  write_named_user_file "$user" "$home/.config/bioinfo-setup/miniconda.prefix" "$prefix"
  MINICONDA_PREREQ_BIN="$conda_bin"
  log "Miniconda 前置条件安装完成: user=$user prefix=$prefix"
}

install_micromamba_for_account() {
  local user="$1" home arch api_arch url archive tmpdir bin_dir binary root_prefix group existing="" conda_bin

  validate_simple_name "$user" || { warn "用户名格式不合法。"; return 1; }
  if id "$user" >/dev/null 2>&1; then
    home="$(getent passwd "$user" 2>/dev/null | cut -d: -f6 || true)"
    group="$(id -gn "$user" 2>/dev/null || printf '%s' "$user")"
  elif (( DRY_RUN )) && [[ "$user" == "$LAST_CREATED_USER" ]]; then
    home="/home/$user"
    group="sharevip"
  else
    warn "用户 $user 不存在。"
    return 1
  fi
  [[ -n "$home" ]] || { warn "无法读取用户 $user 的 home。"; return 1; }

  existing="$(find_named_user_micromamba "$user" 2>/dev/null || true)"
  if [[ -n "$existing" ]]; then
    printf '\n检测到 %s 已安装 micromamba：\n' "$user"
    printf '  路径: %s\n' "$existing"
    printf '  版本: %s\n' "$("$existing" --version 2>/dev/null || true)"
    if confirm "是否跳过 $user 的 micromamba 安装？" "Y"; then
      return 0
    fi
  fi

  install_miniconda_prerequisite_for_account "$user" || return 1
  conda_bin="$MINICONDA_PREREQ_BIN"
  [[ -n "$conda_bin" ]] || { warn "Miniconda 前置条件未满足。"; return 1; }

  case "$(uname -m)" in
    x86_64) api_arch="linux-64" ;;
    aarch64|arm64) api_arch="linux-aarch64" ;;
    *) warn "不支持的架构: $(uname -m)"; return 1 ;;
  esac

  url="https://micro.mamba.pm/api/micromamba/${api_arch}/latest"
  archive="/tmp/micromamba-${user}-${api_arch}.tar.bz2"
  tmpdir="/tmp/micromamba-${user}-extract-$$"
  bin_dir="$home/data_HD/bin"
  binary="$bin_dir/micromamba"
  root_prefix="$home/data_HD/micromamba"

  as_named_user "$user" mkdir -p "$bin_dir" "$root_prefix"
  if [[ ! -x "$binary" ]]; then
    if (( DRY_RUN )); then
      printf '[dry-run] curl -fL %q -o %q\n' "$url" "$archive"
      printf '[dry-run] extract bin/micromamba and install to %q as %q\n' "$binary" "$user"
    else
      curl -fL "$url" -o "$archive"
      rm -rf "$tmpdir"
      mkdir -p "$tmpdir"
      tar -xjf "$archive" -C "$tmpdir" bin/micromamba
      if [[ "$user" == "root" ]]; then
        install -m 0755 "$tmpdir/bin/micromamba" "$binary"
      else
        install -o "$user" -g "$group" -m 0755 "$tmpdir/bin/micromamba" "$binary"
      fi
      rm -rf "$tmpdir" "$archive"
    fi
  fi

  append_named_user_line_once "$user" "$home/.bashrc" 'export PATH="$HOME/data_HD/bin:$PATH"'
  as_named_user "$user" env MAMBA_ROOT_PREFIX="$root_prefix" "$binary" shell init -s bash -r "$root_prefix"
  as_named_user "$user" env MAMBA_ROOT_PREFIX="$root_prefix" "$binary" config set use_sharded_repodata false
  as_named_user "$user" mkdir -p "$home/.config/bioinfo-setup"
  write_named_user_file "$user" "$home/.config/bioinfo-setup/micromamba.bin" "$binary"

  if (( DRY_RUN == 0 )); then
    as_named_user "$user" "$binary" --version
  fi
  log "micromamba 安装完成: user=$user binary=$binary"
}

install_micromamba_account_menu() {
  local choice user
  printf '\nmicromamba 安装对象：\n'
  printf '1) root 用户\n'
  printf '2) 指定普通用户\n'
  printf '0) 取消\n'
  read -r -p "选择 [1]: " choice
  choice="${choice:-1}"

  case "$choice" in
    1) user="root" ;;
    2)
      read -r -p "普通用户名: " user
      [[ "$user" != "root" ]] || { warn "普通用户入口不能填 root。"; return 1; }
      ;;
    0) return 0 ;;
    *) warn "无效选择。"; return 1 ;;
  esac

  install_micromamba_for_account "$user"
}

install_metawrap_for_user() {
  local user="${1:-}" home conda_bin env_name="metaWRAP"

  if [[ -z "$user" ]]; then
    read -r -p "安装 metaWRAP 的普通用户名: " user
  fi
  validate_simple_name "$user" || { warn "用户名格式不合法。"; return 1; }
  [[ "$user" != "root" ]] || { warn "普通用户 metaWRAP 入口不接受 root。"; return 1; }
  id "$user" >/dev/null 2>&1 || { warn "用户 $user 不存在。"; return 1; }

  home="$(getent passwd "$user" | cut -d: -f6)"
  conda_bin="$(find_named_user_miniconda "$user" 2>/dev/null || true)"
  if [[ -z "$conda_bin" ]]; then
    warn "用户 $user 尚未满足 micromamba 前置条件；先安装 micromamba（会自动安装 Miniconda 前置）。"
    install_micromamba_for_account "$user" || return 1
    if (( DRY_RUN )); then
      conda_bin="$home/data_HD/miniconda3/bin/conda"
    else
      conda_bin="$(find_named_user_miniconda "$user" 2>/dev/null || true)"
    fi
  fi
  [[ -n "$conda_bin" ]] || { warn "无法找到用户 $user 的 Miniconda conda。"; return 1; }

  if (( DRY_RUN == 0 )) && as_named_user "$user" "$conda_bin" env list 2>/dev/null | awk '{print $1}' | grep -Fxq "$env_name"; then
    info "用户 $user 的 $env_name 环境已存在，跳过创建。"
    return 0
  fi

  info "为普通用户 $user 创建 metaWRAP 1.3.2 独立环境。"
  info "按 metaWRAP 上游建议使用 ursky channel；数据库配置不在本步骤自动下载。"
  as_named_user "$user" "$conda_bin" create -y -n "$env_name" --override-channels \
    -c "$URSKY_CHANNEL" \
    -c "$TUNA_BIOCONDA_CHANNEL" \
    -c "$TUNA_CONDA_FORGE_CHANNEL" \
    -c "$TUNA_MAIN_CHANNEL" \
    -c "$TUNA_R_CHANNEL" \
    metawrap-mg=1.3.2 maxbin2=2.2.6
  as_named_user "$user" "$conda_bin" install -y -n "$env_name" --override-channels \
    -c "$TUNA_MAIN_CHANNEL" \
    -c "$TUNA_R_CHANNEL" \
    -c "$TUNA_CONDA_FORGE_CHANNEL" \
    blas=2.5=mkl

  if (( DRY_RUN == 0 )); then
    as_named_user "$user" "$conda_bin" run -n "$env_name" metawrap --help >/dev/null 2>&1 || {
      warn "metaWRAP 环境创建完成，但 metawrap --help 验证失败，请查看日志。"
      return 1
    }
  fi

  log "metaWRAP 安装完成: user=$user env=$env_name"
  info "用户登录后可执行: conda activate $env_name"
}

create_metawrap_for_login_user() {
  local manager_type="$1" manager_bin="$2" home="$3" root_prefix="$4" base_prefix="$5"
  local env_name="metaWRAP" env_exists=0

  if [[ "$manager_type" == "micromamba" ]]; then
    [[ -d "$root_prefix/envs/$env_name" ]] && env_exists=1
  else
    [[ -d "$base_prefix/envs/$env_name" || -d "$home/.conda/envs/$env_name" ]] && env_exists=1
  fi
  if (( env_exists )); then
    info "环境 $env_name 已存在，跳过。"
    return 0
  fi

  if [[ "$manager_type" == "micromamba" ]]; then
    as_login_user env MAMBA_ROOT_PREFIX="$root_prefix" "$manager_bin" create -y -n "$env_name" --override-channels \
      -c "$URSKY_CHANNEL" \
      -c "$TUNA_BIOCONDA_CHANNEL" \
      -c "$TUNA_CONDA_FORGE_CHANNEL" \
      -c "$TUNA_MAIN_CHANNEL" \
      -c "$TUNA_R_CHANNEL" \
      metawrap-mg=1.3.2 maxbin2=2.2.6
    as_login_user env MAMBA_ROOT_PREFIX="$root_prefix" "$manager_bin" install -y -n "$env_name" --override-channels \
      -c "$TUNA_MAIN_CHANNEL" \
      -c "$TUNA_R_CHANNEL" \
      -c "$TUNA_CONDA_FORGE_CHANNEL" \
      blas=2.5=mkl
  else
    as_login_user "$manager_bin" create -y -n "$env_name" --override-channels \
      -c "$URSKY_CHANNEL" \
      -c "$TUNA_BIOCONDA_CHANNEL" \
      -c "$TUNA_CONDA_FORGE_CHANNEL" \
      -c "$TUNA_MAIN_CHANNEL" \
      -c "$TUNA_R_CHANNEL" \
      metawrap-mg=1.3.2 maxbin2=2.2.6
    as_login_user "$manager_bin" install -y -n "$env_name" --override-channels \
      -c "$TUNA_MAIN_CHANNEL" \
      -c "$TUNA_R_CHANNEL" \
      -c "$TUNA_CONDA_FORGE_CHANNEL" \
      blas=2.5=mkl
  fi
  log "当前登录用户 metaWRAP 环境创建完成: $env_name"
}

metawrap_config_set_for_user() {
  local user="$1" conda_bin="$2" key="$3" value="$4"
  local config_file conda_prefix

  if (( DRY_RUN )); then
    conda_prefix="$(dirname "$(dirname "$conda_bin")")"
    config_file="$conda_prefix/envs/metaWRAP/bin/config-metawrap"
    printf '[dry-run] set %s=%q in %q as %q\n' "$key" "$value" "$config_file" "$user"
    return 0
  fi

  config_file="$(as_named_user "$user" "$conda_bin" run -n metaWRAP which config-metawrap 2>/dev/null || true)"
  [[ -n "$config_file" && -f "$config_file" ]] || {
    warn "找不到用户 $user 的 metaWRAP config-metawrap。"
    return 1
  }

  if grep -Eq "^${key}=" "$config_file" 2>/dev/null; then
    as_named_user "$user" sed -i -E "s|^${key}=.*|${key}=${value}|" "$config_file"
  else
    append_named_user_line_once "$user" "$config_file" "${key}=${value}"
  fi
  as_named_user "$user" chmod 0755 "$config_file"
  info "config-metawrap: $key=$value"
}

download_metawrap_checkm_db() {
  local user="$1" conda_bin="$2" db_root="$3"
  local dir="$db_root/CheckM" archive="$db_root/CheckM/checkm_data_2015_01_16.tar.gz"
  as_named_user "$user" mkdir -p "$dir"
  if [[ -e "$dir/.bioinfo-download-complete" ]]; then
    info "CheckM 数据库已存在，跳过下载: $dir"
  else
    as_named_user "$user" curl -fL --retry 3 --retry-delay 5 "https://data.ace.uq.edu.au/public/CheckM_databases/checkm_data_2015_01_16.tar.gz" -o "$archive"
    as_named_user "$user" tar -xzf "$archive" -C "$dir"
    as_named_user "$user" rm -f "$archive"
    as_named_user "$user" touch "$dir/.bioinfo-download-complete"
  fi
  as_named_user "$user" "$conda_bin" run -n metaWRAP checkm data setRoot "$dir"
  log "CheckM 数据库配置完成: $dir"
}

download_metawrap_kraken2_db() {
  local user="$1" conda_bin="$2" db_root="$3" threads="$4"
  local dir="$db_root/KRAKEN2"
  warn "Kraken2 standard 数据库需要大量磁盘和内存；官方 metaWRAP 文档给出的量级约 125GB，构建阶段资源需求较高。"
  confirm "确认下载并构建 Kraken2 standard 数据库？" || return 0
  as_named_user "$user" mkdir -p "$dir"
  if [[ ! -e "$dir/hash.k2d" || ! -e "$dir/opts.k2d" || ! -e "$dir/taxo.k2d" ]]; then
    as_named_user "$user" "$conda_bin" run -n metaWRAP kraken2-build --standard --threads "$threads" --db "$dir"
  else
    info "Kraken2 数据库核心文件已存在，跳过构建。"
  fi
  metawrap_config_set_for_user "$user" "$conda_bin" KRAKEN2_DB "$dir"
  log "Kraken2 数据库配置完成: $dir"
}

download_metawrap_ncbi_nt_db() {
  local user="$1" conda_bin="$2" db_root="$3"
  local dir="$db_root/NCBI_nt"
  warn "NCBI nt 是超大型、多卷且持续更新的数据库；请确保目标目录有充足可用空间。"
  confirm "确认下载/更新 NCBI nt BLAST 数据库？" || return 0
  as_named_user "$user" mkdir -p "$dir"
  if ! as_named_user "$user" "$conda_bin" run -n metaWRAP which update_blastdb.pl >/dev/null 2>&1; then
    warn "metaWRAP 环境中找不到 update_blastdb.pl，无法使用 NCBI 官方推荐下载方式。"
    return 1
  fi
  local blastdb_rc=0
  if as_named_user_in_dir "$user" "$dir" "$conda_bin" run -n metaWRAP update_blastdb.pl --decompress nt; then
    blastdb_rc=0
  else
    blastdb_rc=$?
    if (( blastdb_rc != 1 )); then
      warn "update_blastdb.pl 下载 nt 失败，退出码=$blastdb_rc"
      return "$blastdb_rc"
    fi
    info "update_blastdb.pl 返回 1：表示本次成功下载了数据库文件。"
  fi
  metawrap_config_set_for_user "$user" "$conda_bin" BLASTDB "$dir"
  log "NCBI nt 数据库配置完成: $dir"
}

download_metawrap_ncbi_tax_db() {
  local user="$1" conda_bin="$2" db_root="$3"
  local dir="$db_root/NCBI_tax" archive="$db_root/NCBI_tax/taxdump.tar.gz"
  as_named_user "$user" mkdir -p "$dir"
  as_named_user "$user" curl -fL --retry 3 --retry-delay 5 "https://ftp.ncbi.nlm.nih.gov/pub/taxonomy/taxdump.tar.gz" -o "$archive"
  as_named_user "$user" tar -xzf "$archive" -C "$dir"
  as_named_user "$user" rm -f "$archive"
  metawrap_config_set_for_user "$user" "$conda_bin" TAXDUMP "$dir"
  log "NCBI taxonomy 配置完成: $dir"
}

download_metawrap_bmtagger_db() {
  local user="$1" conda_bin="$2" db_root="$3"
  local dir="$db_root/BMTAGGER_INDEX"
  warn "hg38 BMTAGGER 索引下载与构建需要较大磁盘/内存；官方 metaWRAP 文档给出的索引量级约 20GB。"
  confirm "确认下载 hg38 并构建 BMTAGGER 索引？" || return 0
  as_named_user "$user" mkdir -p "$dir"
  if [[ ! -e "$dir/hg38.fa" ]]; then
    as_named_user_in_dir "$user" "$dir" wget -q -r -np -nd -A "chr*.fa.gz" "https://hgdownload.soe.ucsc.edu/goldenPath/hg38/chromosomes/"
    as_named_user_in_dir "$user" "$dir" bash -c 'for f in chr*.fa.gz; do gzip -df "$f"; done; cat chr*.fa > hg38.fa'
  fi
  if [[ ! -e "$dir/hg38.bitmask" ]]; then
    as_named_user "$user" "$conda_bin" run -n metaWRAP bmtool -d "$dir/hg38.fa" -o "$dir/hg38.bitmask"
  fi
  if [[ ! -e "$dir/hg38.srprism" ]]; then
    as_named_user "$user" "$conda_bin" run -n metaWRAP srprism mkindex -i "$dir/hg38.fa" -o "$dir/hg38.srprism" -M 100000
  fi
  metawrap_config_set_for_user "$user" "$conda_bin" BMTAGGER_DB "$dir"
  log "BMTAGGER hg38 索引配置完成: $dir"
}

download_metawrap_databases_for_user() {
  local user="" home conda_bin db_root choice threads free_space

  read -r -p "下载 metaWRAP 数据库的用户名: " user
  validate_simple_name "$user" || { warn "用户名格式不合法。"; return 1; }
  [[ "$user" != "root" ]] || { warn "该入口用于普通用户数据库目录，请选择非 root 用户。"; return 1; }
  id "$user" >/dev/null 2>&1 || { warn "用户 $user 不存在。"; return 1; }

  home="$(getent passwd "$user" | cut -d: -f6)"
  conda_bin="$(find_named_user_miniconda "$user" 2>/dev/null || true)"
  if [[ -z "$conda_bin" ]]; then
    warn "用户 $user 没有 Miniconda；先安装 micromamba（自动安装 Miniconda 前置）。"
    install_micromamba_for_account "$user" || return 1
    if (( DRY_RUN )); then
      conda_bin="$home/data_HD/miniconda3/bin/conda"
    else
      conda_bin="$(find_named_user_miniconda "$user" 2>/dev/null || true)"
    fi
  fi
  [[ -n "$conda_bin" ]] || { warn "无法找到 $user 的 Miniconda。"; return 1; }

  if (( DRY_RUN == 0 )) && ! as_named_user "$user" "$conda_bin" env list 2>/dev/null | awk '{print $1}' | grep -Fxq metaWRAP; then
    warn "用户 $user 尚未创建 metaWRAP 环境。"
    if confirm "现在先为 $user 安装 metaWRAP？" "Y"; then
      install_metawrap_for_user "$user" || return 1
    else
      return 0
    fi
  fi

  read -r -p "数据库根目录 [$home/data_HD/metawrap_db]: " db_root
  db_root="${db_root:-$home/data_HD/metawrap_db}"
  [[ "$db_root" == "$home/"* ]] || { warn "数据库目录必须位于用户 $user 的 home 下。"; return 1; }
  as_named_user "$user" mkdir -p "$db_root"
  free_space="$(df -hP "$(dirname "$db_root")" 2>/dev/null | awk 'NR==2 {print $4 " free of " $2}' || true)"
  info "数据库用户: $user"
  info "数据库目录: $db_root"
  info "可用空间: ${free_space:-未知}"

  threads="$(nproc)"
  read -r -p "数据库构建线程数 [$threads]: " choice
  if [[ -n "$choice" ]]; then
    threads="$choice"
  fi
  if [[ ! "$threads" =~ ^[0-9]+$ ]] || (( threads < 1 )); then
    warn "线程数必须为正整数。"
    return 1
  fi

  printf '\nmetaWRAP 数据库：\n'
  printf '1) CheckM\n'
  printf '2) Kraken2 standard\n'
  printf '3) NCBI nt\n'
  printf '4) NCBI taxonomy\n'
  printf '5) hg38 BMTAGGER index\n'
  printf '6) 全部\n'
  printf '0) 返回\n'
  read -r -p "选择: " choice

  as_root apt-get update
  as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y curl wget tar gzip

  case "$choice" in
    1) download_metawrap_checkm_db "$user" "$conda_bin" "$db_root" ;;
    2) download_metawrap_kraken2_db "$user" "$conda_bin" "$db_root" "$threads" ;;
    3) download_metawrap_ncbi_nt_db "$user" "$conda_bin" "$db_root" ;;
    4) download_metawrap_ncbi_tax_db "$user" "$conda_bin" "$db_root" ;;
    5) download_metawrap_bmtagger_db "$user" "$conda_bin" "$db_root" ;;
    6)
      warn "全部数据库可能占用数百 GB，并包含高内存构建步骤。"
      confirm "确认继续下载/构建全部数据库？" || return 0
      download_metawrap_checkm_db "$user" "$conda_bin" "$db_root"
      download_metawrap_kraken2_db "$user" "$conda_bin" "$db_root" "$threads"
      download_metawrap_ncbi_nt_db "$user" "$conda_bin" "$db_root"
      download_metawrap_ncbi_tax_db "$user" "$conda_bin" "$db_root"
      download_metawrap_bmtagger_db "$user" "$conda_bin" "$db_root"
      ;;
    0) return 0 ;;
    *) warn "无效选择。"; return 1 ;;
  esac
}

resolve_metacat_latest_release() {
  local tmp
  METACAT_LATEST_TAG=""
  METACAT_LATEST_VERSION=""
  METACAT_LATEST_WHEEL=""

  command -v curl >/dev/null 2>&1 || {
    as_root apt-get update
    as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y curl
  }
  command -v python3 >/dev/null 2>&1 || {
    as_root apt-get update
    as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y python3
  }

  tmp="/tmp/metacat-release-$$.json"
  if (( DRY_RUN )); then
    printf '[dry-run] query latest MetaCAT release from %s\n' "$METACAT_RELEASE_API"
  fi
  curl -fsSL --retry 3 --retry-delay 3 "$METACAT_RELEASE_API" -o "$tmp"

  read -r METACAT_LATEST_TAG METACAT_LATEST_VERSION METACAT_LATEST_WHEEL < <(
    python3 - "$tmp" <<'PY'
import json, re, sys
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as fh:
    data = json.load(fh)
tag = data.get("tag_name", "")
wheel = ""
version = ""
for asset in data.get("assets", []):
    name = asset.get("name", "")
    url = asset.get("browser_download_url", "")
    m = re.fullmatch(r"metacat-(.+)-py3-none-any\.whl", name)
    if m and url.startswith("https://github.com/liu-congcong/MetaCAT/releases/download/"):
        version = m.group(1)
        wheel = url
        break
if not (tag and version and wheel):
    sys.exit(2)
print(tag, version, wheel)
PY
  )
  rm -f "$tmp"

  [[ -n "$METACAT_LATEST_TAG" && -n "$METACAT_LATEST_VERSION" && -n "$METACAT_LATEST_WHEEL" ]] || {
    warn "无法从官方 GitHub latest release 解析 MetaCAT wheel。"
    return 1
  }

  info "MetaCAT 官方最新 Release: tag=$METACAT_LATEST_TAG version=$METACAT_LATEST_VERSION"
  info "MetaCAT wheel: $METACAT_LATEST_WHEEL"
}

install_metacat_for_user() {
  local user="" home mm root_prefix env_dir

  read -r -p "安装 MetaCAT 的普通用户名: " user
  validate_simple_name "$user" || { warn "用户名格式不合法。"; return 1; }
  [[ "$user" != "root" ]] || { warn "普通用户 MetaCAT 入口不接受 root。"; return 1; }
  id "$user" >/dev/null 2>&1 || { warn "用户 $user 不存在。"; return 1; }

  home="$(getent passwd "$user" 2>/dev/null | cut -d: -f6 || true)"
  [[ -n "$home" ]] || { warn "无法读取用户 $user 的 home。"; return 1; }

  install_micromamba_for_account "$user" || return 1
  mm="$home/data_HD/bin/micromamba"
  root_prefix="$home/data_HD/micromamba"
  env_dir="$root_prefix/envs/MetaCAT"

  resolve_metacat_latest_release || return 1

  if [[ ! -d "$env_dir" ]]; then
    as_named_user "$user" env MAMBA_ROOT_PREFIX="$root_prefix" "$mm" create -y -n MetaCAT --override-channels \
      -c "$TUNA_CONDA_FORGE_CHANNEL" \
      -c "$TUNA_MAIN_CHANNEL" \
      python=3.12 pip
  else
    info "用户 $user 的 MetaCAT 环境已存在，将升级到官方最新 Release。"
  fi

  as_named_user "$user" env MAMBA_ROOT_PREFIX="$root_prefix" "$mm" run -n MetaCAT \
    python -m pip install --upgrade "$METACAT_LATEST_WHEEL"

  if (( DRY_RUN == 0 )); then
    as_named_user "$user" env MAMBA_ROOT_PREFIX="$root_prefix" "$mm" run -n MetaCAT MetaCAT --help >/dev/null 2>&1 || {
      warn "MetaCAT 安装后验证失败。"
      return 1
    }
    local installed_version
    installed_version="$(as_named_user "$user" env MAMBA_ROOT_PREFIX="$root_prefix" "$mm" run -n MetaCAT python -m pip show metacat 2>/dev/null | awk '/^Version:/ {value=$2} END {print value}')"
    [[ "$installed_version" == "$METACAT_LATEST_VERSION" ]] || {
      warn "MetaCAT 版本校验失败：期望=$METACAT_LATEST_VERSION 实际=${installed_version:-unknown}"
      return 1
    }
  fi

  log "MetaCAT 安装完成: user=$user version=$METACAT_LATEST_VERSION env=MetaCAT"
  info "用户登录后可使用: micromamba activate MetaCAT"
}

create_metacat_for_login_user() {
  local manager_type="$1" manager_bin="$2" home="$3" root_prefix="$4" base_prefix="$5"
  local env_exists=0 installed_version=""

  resolve_metacat_latest_release || return 1

  if [[ "$manager_type" == "micromamba" ]]; then
    [[ -d "$root_prefix/envs/MetaCAT" ]] && env_exists=1
    if (( ! env_exists )); then
      as_login_user env MAMBA_ROOT_PREFIX="$root_prefix" "$manager_bin" create -y -n MetaCAT --override-channels \
        -c "$TUNA_CONDA_FORGE_CHANNEL" \
        -c "$TUNA_MAIN_CHANNEL" \
        python=3.12 pip
    fi
    as_login_user env MAMBA_ROOT_PREFIX="$root_prefix" "$manager_bin" run -n MetaCAT \
      python -m pip install --upgrade "$METACAT_LATEST_WHEEL"
    if (( DRY_RUN == 0 )); then
      as_login_user env MAMBA_ROOT_PREFIX="$root_prefix" "$manager_bin" run -n MetaCAT MetaCAT --help >/dev/null 2>&1 || return 1
      installed_version="$(as_login_user env MAMBA_ROOT_PREFIX="$root_prefix" "$manager_bin" run -n MetaCAT python -m pip show metacat 2>/dev/null | awk '/^Version:/ {value=$2} END {print value}')"
    fi
  else
    [[ -d "$base_prefix/envs/MetaCAT" || -d "$home/.conda/envs/MetaCAT" ]] && env_exists=1
    if (( ! env_exists )); then
      as_login_user "$manager_bin" create -y -n MetaCAT --override-channels \
        -c "$TUNA_CONDA_FORGE_CHANNEL" \
        -c "$TUNA_MAIN_CHANNEL" \
        python=3.12 pip
    fi
    as_login_user "$manager_bin" run -n MetaCAT python -m pip install --upgrade "$METACAT_LATEST_WHEEL"
    if (( DRY_RUN == 0 )); then
      as_login_user "$manager_bin" run -n MetaCAT MetaCAT --help >/dev/null 2>&1 || return 1
      installed_version="$(as_login_user "$manager_bin" run -n MetaCAT python -m pip show metacat 2>/dev/null | awk '/^Version:/ {value=$2} END {print value}')"
    fi
  fi

  if (( DRY_RUN == 0 )) && [[ "$installed_version" != "$METACAT_LATEST_VERSION" ]]; then
    warn "MetaCAT 版本校验失败：期望=$METACAT_LATEST_VERSION 实际=${installed_version:-unknown}"
    return 1
  fi

  log "MetaCAT 官方最新 Release 安装完成: version=$METACAT_LATEST_VERSION env=MetaCAT"
}

create_bioinfo_envs() {
  local manager_choice manager_type manager_bin choice home root_prefix base_prefix custom_type metawrap_target metacat_target
  home="$(login_home)"
  root_prefix="$home/data_HD/micromamba"

  printf '\n可创建环境：\n'
  printf '1) RNASeq\n'
  printf '2) ChIPSeq\n'
  printf '3) WGS\n'
  printf '4) scRNASeq\n'
  printf '5) metaWRAP\n'
  printf '6) MetaCAT（官方 GitHub 最新 Release）\n'
  printf '7) 全部（不含 metaWRAP / MetaCAT）\n'
  read -r -p "选择 [1]: " choice
  choice="${choice:-1}"

  if [[ "$choice" == "5" ]]; then
    printf '\nmetaWRAP 安装对象：\n'
    printf '1) 当前登录用户\n'
    printf '2) 指定普通用户\n'
    read -r -p "选择 [1]: " metawrap_target
    metawrap_target="${metawrap_target:-1}"
    if [[ "$metawrap_target" == "2" ]]; then
      install_metawrap_for_user
      return $?
    elif [[ "$metawrap_target" != "1" ]]; then
      warn "无效选择。"
      return 1
    fi
  elif [[ "$choice" == "6" ]]; then
    printf '\nMetaCAT 安装对象：\n'
    printf '1) 当前登录用户\n'
    printf '2) 指定普通用户\n'
    read -r -p "选择 [1]: " metacat_target
    metacat_target="${metacat_target:-1}"
    if [[ "$metacat_target" == "2" ]]; then
      install_metacat_for_user
      return $?
    elif [[ "$metacat_target" != "1" ]]; then
      warn "无效选择。"
      return 1
    fi
  fi

  printf '\n环境管理器：\n'
  printf '1) 自动检测（micromamba > mamba > conda）\n'
  printf '2) micromamba\n'
  printf '3) mamba\n'
  printf '4) conda\n'
  printf '5) 自定义可执行文件\n'
  read -r -p "选择 [1]: " manager_choice
  manager_choice="${manager_choice:-1}"

  resolve_first_existing() {
    local candidate
    for candidate in "$@"; do
      if [[ -x "$candidate" ]]; then
        printf '%s' "$candidate"
        return 0
      fi
    done
    return 1
  }

  case "$manager_choice" in
    1)
      manager_bin="$(resolve_first_existing         "$home/data_HD/bin/micromamba"         "$MICROMAMBA_SYSTEM_BIN"         "$MINIFORGE_DEFAULT/bin/mamba"         "$home/data_HD/miniconda3/bin/conda"         "$MINICONDA_SYSTEM_DEFAULT/bin/conda" 2>/dev/null || true)"
      if [[ -z "$manager_bin" ]]; then
        if (( DRY_RUN )); then
          manager_type="micromamba"
          manager_bin="$MICROMAMBA_SYSTEM_BIN"
        else
          warn "未找到 micromamba、mamba 或 conda，请先安装其中一个。"
          return 1
        fi
      elif [[ "$(basename "$manager_bin")" == "micromamba" ]]; then
        manager_type="micromamba"
      elif [[ "$(basename "$manager_bin")" == "mamba" ]]; then
        manager_type="mamba"
      else
        manager_type="conda"
      fi
      ;;
    2)
      manager_type="micromamba"
      manager_bin="$(resolve_first_existing "$home/data_HD/bin/micromamba" "$MICROMAMBA_SYSTEM_BIN" 2>/dev/null || true)"
      [[ -n "$manager_bin" ]] || manager_bin="$home/data_HD/bin/micromamba"
      ;;
    3)
      manager_type="mamba"
      manager_bin="$(resolve_first_existing "$MINIFORGE_DEFAULT/bin/mamba" 2>/dev/null || true)"
      [[ -n "$manager_bin" ]] || manager_bin="$MINIFORGE_DEFAULT/bin/mamba"
      ;;
    4)
      manager_type="conda"
      manager_bin="$(resolve_first_existing "$home/data_HD/miniconda3/bin/conda" "$MINICONDA_SYSTEM_DEFAULT/bin/conda" "$MINIFORGE_DEFAULT/bin/conda" 2>/dev/null || true)"
      [[ -n "$manager_bin" ]] || manager_bin="$home/data_HD/miniconda3/bin/conda"
      ;;
    5)
      read -r -p "管理器类型 [micromamba/mamba/conda]: " custom_type
      case "$custom_type" in
        micromamba|mamba|conda) manager_type="$custom_type" ;;
        *) warn "无效管理器类型。"; return 1 ;;
      esac
      read -r -p "可执行文件绝对路径: " manager_bin
      [[ "$manager_bin" == /* ]] || { warn "必须使用绝对路径。"; return 1; }
      ;;
    *)
      warn "无效选择。"
      return 1
      ;;
  esac

  if [[ ! -x "$manager_bin" ]] && (( DRY_RUN == 0 )); then
    warn "找不到可执行文件: $manager_bin"
    return 1
  fi

  info "使用 $manager_type: $manager_bin"

  if [[ "$manager_type" == "micromamba" ]]; then
    as_login_user mkdir -p "$root_prefix"
    as_login_user env MAMBA_ROOT_PREFIX="$root_prefix" "$manager_bin" config set use_sharded_repodata false
  else
    base_prefix="$(dirname "$(dirname "$manager_bin")")"
  fi

  create_env() {
    local name="$1"; shift
    local env_exists=0

    if [[ "$manager_type" == "micromamba" ]]; then
      [[ -d "$root_prefix/envs/$name" ]] && env_exists=1
    else
      [[ -d "$base_prefix/envs/$name" || -d "$home/.conda/envs/$name" ]] && env_exists=1
    fi

    if (( env_exists )); then
      info "环境 $name 已存在，跳过。"
      return 0
    fi

    if [[ "$manager_type" == "micromamba" ]]; then
      as_login_user env MAMBA_ROOT_PREFIX="$root_prefix" "$manager_bin" create -y -n "$name" -c conda-forge -c bioconda "$@"
    else
      as_login_user "$manager_bin" create -y -n "$name" -c conda-forge -c bioconda "$@"
    fi
  }

  case "$choice" in
    1) create_env RNASeq python=3 samtools fastqc multiqc cutadapt fastp bowtie bowtie2 bwa star hisat2 htseq subread cufflinks bedtools seqkit ;;
    2) create_env ChIPSeq python=3 samtools fastqc multiqc cutadapt fastp bowtie bowtie2 bwa star hisat2 htseq subread bedtools deeptools seqkit macs2 ;;
    3) create_env WGS python=3 samtools fastqc multiqc cutadapt fastp bowtie bowtie2 bwa minimap2 star hisat2 htseq subread bedtools deeptools seqkit bcftools ;;
    4) create_env scRNASeq python=3 samtools fastqc multiqc cutadapt fastp bowtie bowtie2 bwa star hisat2 htseq subread bedtools seqkit scanpy python-igraph leidenalg scvelo celltypist scrublet velocyto.py scirpy ;;
    5)
      create_metawrap_for_login_user "$manager_type" "$manager_bin" "$home" "$root_prefix" "${base_prefix:-}"
      ;;
    6)
      create_metacat_for_login_user "$manager_type" "$manager_bin" "$home" "$root_prefix" "${base_prefix:-}"
      ;;
    7)
      create_env RNASeq python=3 samtools fastqc multiqc cutadapt fastp bowtie bowtie2 bwa star hisat2 htseq subread cufflinks bedtools seqkit
      create_env ChIPSeq python=3 samtools fastqc multiqc cutadapt fastp bowtie bowtie2 bwa star hisat2 htseq subread bedtools deeptools seqkit macs2
      create_env WGS python=3 samtools fastqc multiqc cutadapt fastp bowtie bowtie2 bwa minimap2 star hisat2 htseq subread bedtools deeptools seqkit bcftools
      create_env scRNASeq python=3 samtools fastqc multiqc cutadapt fastp bowtie bowtie2 bwa star hisat2 htseq subread bedtools seqkit scanpy python-igraph leidenalg scvelo celltypist scrublet velocyto.py scirpy
      ;;
    *)
      warn "无效选择。"
      return 1
      ;;
  esac

  log "生信环境创建流程完成。"
}

init_groups() {
  local -a groups=(admin sharevip primevip coursevip labvip)
  local -a gids=(110 30002 30003 30004 30005)
  local group gid existing_gid used_by i

  printf '\n=== 用户组 GID 规划 ===\n'
  for i in "${!groups[@]}"; do
    group="${groups[$i]}"
    gid="${gids[$i]}"

    if getent group "$group" >/dev/null 2>&1; then
      existing_gid="$(getent group "$group" | cut -d: -f3)"
      if [[ "$existing_gid" != "$gid" ]]; then
        warn "组 $group 已存在，但 GID=$existing_gid；预期 GID=$gid。"
        warn "为避免改变现有文件属组，脚本不会自动修改该组 GID。"
        return 1
      fi
      printf '%-12s existing GID=%s\n' "$group" "$existing_gid"
    else
      used_by="$(getent group "$gid" 2>/dev/null | cut -d: -f1 || true)"
      if [[ -n "$used_by" ]]; then
        warn "计划 GID $gid 已被组 $used_by 使用，无法创建 $group。"
        return 1
      fi
      printf '%-12s create   GID=%s\n' "$group" "$gid"
    fi
  done

  confirm "确认按以上固定 GID 创建所有缺失组？" || { warn "已取消。"; return 0; }

  for i in "${!groups[@]}"; do
    group="${groups[$i]}"
    gid="${gids[$i]}"
    if getent group "$group" >/dev/null 2>&1; then
      info "组已存在: $group (GID=$gid)"
    else
      as_root groupadd -g "$gid" "$group"
    fi
  done

  log "用户组初始化完成：admin=110, sharevip=30002, primevip=30003, coursevip=30004, labvip=30005。"
}

rollback_user_creation() {
  local username="$1"
  local data_dir="$2"
  local home_fs="$3"
  local data_fs="$4"

  warn "创建用户失败，开始回滚 $username ..."

  if command -v xfs_quota >/dev/null 2>&1; then
    if [[ "$home_fs" == "xfs" ]]; then
      as_root xfs_quota -x -c "limit -u bsoft=0 bhard=0 $username" /home || true
    fi
    if [[ "$data_fs" == "xfs" ]]; then
      as_root xfs_quota -x -c "limit -u bsoft=0 bhard=0 $username" "$(dirname "$(dirname "$data_dir")")" || true
    fi
  fi

  if id "$username" >/dev/null 2>&1; then
    as_root userdel -r "$username" || true
  fi

  if [[ -d "$data_dir" ]]; then
    if [[ "$(basename "$(dirname "$data_dir")")" == "user" && "$(basename "$data_dir")" == "$username" ]]; then
      as_root rm -rf -- "$data_dir" || warn "数据目录回滚失败: $data_dir"
    else
      warn "数据目录路径不符合安全回滚规则，保留未删除: $data_dir"
    fi
  fi

  warn "回滚结束。请查看日志确认是否存在需要人工处理的残留。"
}

create_user() {
  local username user_type requested_uid expected_gid primary_gid
  local home_soft home_hard data_soft data_hard expiry data_mount
  local user_home data_dir r_ver rprofile_line home_fs data_fs actual_uid actual_gid q
  local -a useradd_args=(-m -s /bin/bash)

  read -r -p "新用户名: " username
  validate_simple_name "$username" || { warn "用户名格式不合法。"; return 1; }
  if id "$username" >/dev/null 2>&1; then
    warn "用户 $username 已存在。"
    return 1
  fi
  if [[ -e "/home/$username" ]]; then
    warn "/home/$username 已存在，但系统中没有同名用户；为避免接管未知目录，拒绝继续。"
    return 1
  fi

  printf '\n可选用户主组：\n'
  printf '  admin      (GID 110)\n'
  printf '  sharevip   (GID 30002)\n'
  printf '  primevip   (GID 30003)\n'
  printf '  coursevip  (GID 30004)\n'
  printf '  labvip     (GID 30005)\n'
  read -r -p "用户类型/主组 [sharevip]: " user_type
  [[ -n "$user_type" ]] || user_type="sharevip"

  case "$user_type" in
    admin|sharevip|primevip|coursevip|labvip) ;;
    *)
      warn "不支持的用户主组: $user_type"
      warn "仅允许：admin, sharevip, primevip, coursevip, labvip。"
      return 1
      ;;
  esac

  if getent group "$user_type" >/dev/null 2>&1; then
    primary_gid="$(getent group "$user_type" | cut -d: -f3)"
  elif (( DRY_RUN )); then
    primary_gid="$(expected_bioinfo_group_gid "$user_type")"
    info "dry-run：假定主组 $user_type 已按固定 GID=$primary_gid 创建。"
  else
    warn "主组 $user_type 不存在。请先运行「初始化用户组」。"
    return 1
  fi

  info "主组 $user_type 当前/计划 GID: $primary_gid"

  read -r -p "指定 UID（留空自动分配；集群建议显式指定）: " requested_uid
  if [[ -n "$requested_uid" ]]; then
    [[ "$requested_uid" =~ ^[0-9]+$ ]] || { warn "UID 必须是数字。"; return 1; }
    if getent passwd "$requested_uid" >/dev/null 2>&1; then
      warn "UID $requested_uid 已被占用。"
      return 1
    fi
    useradd_args+=(-u "$requested_uid")
  fi

  read -r -p "校验主组 GID [$primary_gid]: " expected_gid
  [[ -n "$expected_gid" ]] || expected_gid="$primary_gid"
  [[ "$expected_gid" =~ ^[0-9]+$ ]] || { warn "GID 必须是数字。"; return 1; }
  if [[ "$expected_gid" != "$primary_gid" ]]; then
    warn "GID 不一致：输入=$expected_gid，服务器上的 $user_type=$primary_gid。"
    warn "为避免用户组权限漂移，拒绝创建用户。"
    return 1
  fi

  read -r -p "home soft quota [30G]: " home_soft; [[ -n "$home_soft" ]] || home_soft="30G"
  read -r -p "home hard quota [40G]: " home_hard; [[ -n "$home_hard" ]] || home_hard="40G"
  read -r -p "data soft quota [2T]: " data_soft; [[ -n "$data_soft" ]] || data_soft="2T"
  read -r -p "data hard quota [2200G]: " data_hard; [[ -n "$data_hard" ]] || data_hard="2200G"
  for q in "$home_soft" "$home_hard" "$data_soft" "$data_hard"; do
    validate_quota "$q" || { warn "quota 格式不合法: $q"; return 1; }
  done

  read -r -p "账号到期日 YYYY-MM-DD（长期账号留空）: " expiry
  if [[ -n "$expiry" ]]; then
    [[ "$expiry" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { warn "到期日格式不合法。"; return 1; }
    date -d "$expiry" >/dev/null 2>&1 || { warn "到期日不是有效日期: $expiry"; return 1; }
  fi

  read -r -p "数据挂载目录 [$DATA_MOUNT_DEFAULT]: " data_mount
  [[ -n "$data_mount" ]] || data_mount="$DATA_MOUNT_DEFAULT"
  [[ "$data_mount" == /* ]] || { warn "数据挂载目录必须是绝对路径。"; return 1; }

  data_dir="$data_mount/user/$username"
  if [[ -e "$data_dir" ]]; then
    warn "$data_dir 已存在；为避免接管未知数据，拒绝继续。"
    return 1
  fi

  if (( DRY_RUN == 0 )); then
    mountpoint -q "$data_mount" || {
      warn "$data_mount 不是独立挂载点；请先初始化或挂载数据盘。"
      return 1
    }
  fi

  home_fs="$(findmnt -n -o FSTYPE --target /home 2>/dev/null || true)"
  data_fs="$(findmnt -n -o FSTYPE --target "$data_mount" 2>/dev/null || true)"
  [[ "$home_fs" == "xfs" ]] || warn "/home 是 ${home_fs:-未知}，不会设置 XFS home quota。"
  [[ "$data_fs" == "xfs" ]] || warn "$data_mount 是 ${data_fs:-未知}，不会设置 XFS data quota。"

  printf '\n=== 用户创建预检查 ===\n'
  printf '用户名:       %s\n' "$username"
  printf 'UID:          %s\n' "${requested_uid:-自动分配}"
  printf '主组:         %s (GID=%s)\n' "$user_type" "$primary_gid"
  printf 'home quota:   %s / %s\n' "$home_soft" "$home_hard"
  printf 'data quota:   %s / %s\n' "$data_soft" "$data_hard"
  printf '数据目录:     %s\n' "$data_dir"
  printf '到期日:       %s\n' "${expiry:-长期}"
  confirm "预检查通过，确认创建？" || { warn "已取消。"; return 0; }

  useradd_args+=(-g "$user_type" "$username")
  if ! as_root useradd "${useradd_args[@]}"; then
    warn "useradd 失败，系统未完成用户创建。"
    return 1
  fi

  user_home="$(getent passwd "$username" 2>/dev/null | cut -d: -f6 || true)"
  [[ -n "$user_home" ]] || user_home="/home/$username"

  if ! as_root mkdir -p "$data_dir" || ! as_root chown "$username:$user_type" "$data_dir"; then
    rollback_user_creation "$username" "$data_dir" "$home_fs" "$data_fs"
    return 1
  fi

  if command -v xfs_quota >/dev/null 2>&1; then
    if [[ "$home_fs" == "xfs" ]] && ! as_root xfs_quota -x -c "limit -u bsoft=$home_soft bhard=$home_hard $username" /home; then
      rollback_user_creation "$username" "$data_dir" "$home_fs" "$data_fs"
      return 1
    fi
    if [[ "$data_fs" == "xfs" ]] && ! as_root xfs_quota -x -c "limit -u bsoft=$data_soft bhard=$data_hard $username" "$data_mount"; then
      rollback_user_creation "$username" "$data_dir" "$home_fs" "$data_fs"
      return 1
    fi
  fi

  if [[ -n "$expiry" ]] && ! as_root chage -E "$expiry" "$username"; then
    rollback_user_creation "$username" "$data_dir" "$home_fs" "$data_fs"
    return 1
  fi

  if command -v Rscript >/dev/null 2>&1; then
    r_ver="$(Rscript -e 'cat(paste(R.version$major, strsplit(R.version$minor, "\\.")[[1]][1], sep="."))' 2>/dev/null || true)"
    if [[ -n "$r_ver" ]]; then
      if ! as_root mkdir -p "$data_dir/R_Lib_$r_ver" "$data_mount/R_Lib/$r_ver"; then
        rollback_user_creation "$username" "$data_dir" "$home_fs" "$data_fs"
        return 1
      fi
      as_root chown "$username:$user_type" "$data_dir/R_Lib_$r_ver"
      rprofile_line=".libPaths(c(\"$data_dir/R_Lib_$r_ver\", \"$data_mount/R_Lib/$r_ver\"))"
      if (( DRY_RUN )); then
        printf '[dry-run] append %q to %q\n' "$rprofile_line" "$user_home/.Rprofile"
      else
        as_root touch "$user_home/.Rprofile"
        if ! as_root grep -Fqx -- "$rprofile_line" "$user_home/.Rprofile"; then
          if (( EUID == 0 )); then
            printf '%s\n' "$rprofile_line" >> "$user_home/.Rprofile"
          else
            printf '%s\n' "$rprofile_line" | sudo tee -a "$user_home/.Rprofile" >/dev/null
          fi
        fi
        as_root chown "$username:$user_type" "$user_home/.Rprofile"
      fi
    fi
  fi

  if ! as_root ln -s "$data_dir" "$user_home/data_HD"; then
    rollback_user_creation "$username" "$data_dir" "$home_fs" "$data_fs"
    return 1
  fi
  as_root chown -h "$username:$user_type" "$user_home/data_HD"

  if (( DRY_RUN )); then
    actual_uid="${requested_uid:-<auto>}"
    actual_gid="$primary_gid"
  else
    actual_uid="$(id -u "$username" 2>/dev/null || true)"
    actual_gid="$(id -g "$username" 2>/dev/null || true)"
    if [[ -n "$requested_uid" && "$actual_uid" != "$requested_uid" ]] || [[ "$actual_gid" != "$primary_gid" ]]; then
      warn "创建后 UID/GID 校验失败：UID=$actual_uid GID=$actual_gid"
      rollback_user_creation "$username" "$data_dir" "$home_fs" "$data_fs"
      return 1
    fi
  fi

  if confirm "为 $username 设置密码？" "Y"; then
    as_root passwd "$username" || warn "密码设置失败，但核心用户创建已完成。"
  fi
  if confirm "授予 sudo 权限？"; then
    as_root usermod -aG sudo "$username" || warn "加入 sudo 组失败，请人工处理。"
  fi

  LAST_CREATED_USER="$username"
  log "用户 $username 创建完成：UID=$actual_uid GID=$actual_gid"
}

configure_root_ssh_key_login() {
  local key_choice public_key fingerprint
  local sshd_bin="/usr/sbin/sshd"
  local dropin="/etc/ssh/sshd_config.d/00-bioinfo-root-key.conf"
  local dropin_backup="" timestamp config_content
  local effective_root effective_pubkey
  local auth_keys="/root/.ssh/authorized_keys"
  local auth_backup="" auth_existed=0 key_added=0

  if ! command -v ssh-keygen >/dev/null 2>&1 || [[ ! -x "$sshd_bin" ]]; then
    as_root apt-get update
    as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server openssh-client
  fi

  printf '\nRoot SSH 公钥登录：\n'
  printf '1) 使用内置 admin@noc.im 公钥\n'
  printf '2) 手动输入其他公钥\n'
  printf '0) 取消\n'
  read -r -p "选择 [1]: " key_choice
  key_choice="${key_choice:-1}"

  case "$key_choice" in
    1)
      public_key="$DEFAULT_ROOT_SSH_KEY"
      ;;
    2)
      read -r -p "粘贴 SSH 公钥（单行）: " public_key
      ;;
    0)
      return 0
      ;;
    *)
      warn "无效选择。"
      return 1
      ;;
  esac

  [[ "$public_key" == ssh-* || "$public_key" == sk-ssh-* ]] || {
    warn "公钥格式不正确。"
    return 1
  }

  local key_tmp
  if command -v ssh-keygen >/dev/null 2>&1; then
    key_tmp="$(mktemp /tmp/bioinfo-root-key.XXXXXX)"
    chmod 600 "$key_tmp"
    printf '%s\n' "$public_key" > "$key_tmp"
    if ! fingerprint="$(ssh-keygen -lf "$key_tmp" 2>/dev/null)"; then
      rm -f "$key_tmp"
      warn "ssh-keygen 无法解析该公钥。"
      return 1
    fi
    rm -f "$key_tmp"
  elif (( DRY_RUN )); then
    fingerprint="<dry-run: ssh-keygen 尚未安装>"
  else
    warn "ssh-keygen 不可用，无法安全校验公钥。"
    return 1
  fi

  printf '\n即将启用 root 公钥登录：\n'
  printf '  公钥指纹: %s\n' "$fingerprint"
  printf '  authorized_keys: %s\n' "$auth_keys"
  printf '  SSH 策略: PermitRootLogin prohibit-password\n'
  printf '  root 密码登录: 禁止\n'
  confirm "确认继续？" || { warn "已取消。"; return 0; }

  as_root mkdir -p /etc/ssh/sshd_config.d
  timestamp="$(date +%Y%m%d-%H%M%S)"
  if [[ -e "$dropin" ]]; then
    dropin_backup="${dropin}.bak.${timestamp}"
    as_root cp -a "$dropin" "$dropin_backup"
    info "已备份 SSH drop-in: $dropin_backup"
  fi

  config_content='# Managed by bioinfo-server-init.sh
PubkeyAuthentication yes
PermitRootLogin prohibit-password'
  write_root_file "$dropin" "$config_content"
  as_root chmod 0644 "$dropin"
  as_root install -d -m 0755 /run/sshd

  if (( DRY_RUN )); then
    printf '[dry-run] %q -t -f /etc/ssh/sshd_config\n' "$sshd_bin"
    printf '[dry-run] %q -T -C user=root,host=localhost,addr=127.0.0.1\n' "$sshd_bin"
  else
    if ! "$sshd_bin" -t -f /etc/ssh/sshd_config; then
      warn "sshd 配置语法校验失败，恢复 SSH 配置。"
      if [[ -n "$dropin_backup" ]]; then
        as_root cp -a "$dropin_backup" "$dropin"
      else
        as_root rm -f "$dropin"
      fi
      return 1
    fi

    effective_root="$("$sshd_bin" -T -C user=root,host=localhost,addr=127.0.0.1 2>/dev/null | awk '$1=="permitrootlogin" {value=$2} END {print value}')"
    effective_pubkey="$("$sshd_bin" -T -C user=root,host=localhost,addr=127.0.0.1 2>/dev/null | awk '$1=="pubkeyauthentication" {value=$2} END {print value}')"

    case "$effective_root" in
      prohibit-password|without-password) ;;
      *)
        warn "SSH 有效配置没有允许 root 公钥登录：PermitRootLogin=$effective_root"
        warn "可能存在更高优先级的 sshd 配置；未写入 root authorized_keys。"
        if [[ -n "$dropin_backup" ]]; then
          as_root cp -a "$dropin_backup" "$dropin"
        else
          as_root rm -f "$dropin"
        fi
        return 1
        ;;
    esac

    if [[ "$effective_pubkey" != "yes" ]]; then
      warn "SSH 有效配置中 PubkeyAuthentication=$effective_pubkey，无法启用公钥登录。"
      if [[ -n "$dropin_backup" ]]; then
        as_root cp -a "$dropin_backup" "$dropin"
      else
        as_root rm -f "$dropin"
      fi
      return 1
    fi
  fi

  as_root install -d -m 0700 -o root -g root /root/.ssh
  if [[ -e "$auth_keys" ]]; then
    auth_existed=1
    auth_backup="${auth_keys}.bak.${timestamp}"
    as_root cp -a "$auth_keys" "$auth_backup"
    info "已备份 authorized_keys: $auth_backup"
  fi

  if grep -Fqx -- "$public_key" "$auth_keys" 2>/dev/null; then
    info "该公钥已存在于 $auth_keys，未重复添加。"
  elif (( DRY_RUN )); then
    printf '[dry-run] append root SSH public key to %q\n' "$auth_keys"
    key_added=1
  elif (( EUID == 0 )); then
    printf '%s\n' "$public_key" >> "$auth_keys"
    key_added=1
  else
    printf '%s\n' "$public_key" | sudo tee -a "$auth_keys" >/dev/null
    key_added=1
  fi

  as_root chown root:root "$auth_keys"
  as_root chmod 0600 "$auth_keys"

  if (( DRY_RUN )); then
    printf '[dry-run] systemctl reload ssh || systemctl enable --now ssh\n'
  else
    "$sshd_bin" -t -f /etc/ssh/sshd_config
    if systemctl is-active --quiet ssh 2>/dev/null; then
      if ! as_root systemctl reload ssh; then
        warn "SSH reload 失败，恢复刚才的配置。"
        if [[ -n "$dropin_backup" ]]; then
          as_root cp -a "$dropin_backup" "$dropin"
        else
          as_root rm -f "$dropin"
        fi
        if (( auth_existed )) && [[ -n "$auth_backup" ]]; then
          as_root cp -a "$auth_backup" "$auth_keys"
        elif (( key_added )); then
          as_root rm -f "$auth_keys"
        fi
        return 1
      fi
    else
      if ! as_root systemctl enable --now ssh; then
        warn "SSH 启动失败，恢复刚才的配置。"
        if [[ -n "$dropin_backup" ]]; then
          as_root cp -a "$dropin_backup" "$dropin"
        else
          as_root rm -f "$dropin"
        fi
        if (( auth_existed )) && [[ -n "$auth_backup" ]]; then
          as_root cp -a "$auth_backup" "$auth_keys"
        elif (( key_added )); then
          as_root rm -f "$auth_keys"
        fi
        return 1
      fi
    fi
  fi

  log "root SSH 公钥登录已启用；root 密码登录仍被禁止。"
  info "公钥指纹: $fingerprint"
  info "建议保持当前会话不退出，另开终端先测试 root 公钥登录成功后再关闭当前连接。"
}

health_status() {
  local label="$1"
  local state="$2"
  local detail="$3"
  printf '%-22s %-8s %s\n' "$label" "$state" "$detail"
}

health_check() {
  local data_fs data_opts docker_ver r_ver rstudio_ver rstudio_state rstudio_r current_r
  local home manager env_output group missing_groups=0 bad_groups=0 expected_gid actual_group_gid ssh_state ssh_root ssh_pubkey ssh_key_state

  printf '\n============================================================\n'
  printf ' 生信服务器健康检查\n'
  printf '============================================================\n'
  health_status "主机" "INFO" "$(hostname)"
  health_status "系统" "INFO" "$(. /etc/os-release; printf '%s' "$PRETTY_NAME")"
  health_status "内核" "INFO" "$(uname -r)"
  health_status "日志" "INFO" "$LOG_FILE"

  printf '\n--- 存储 / quota ---\n'
  if mountpoint -q "$DATA_MOUNT_DEFAULT"; then
    data_fs="$(findmnt -n -o FSTYPE --target "$DATA_MOUNT_DEFAULT")"
    data_opts="$(findmnt -n -o OPTIONS --target "$DATA_MOUNT_DEFAULT")"
    health_status "$DATA_MOUNT_DEFAULT" "OK" "$data_fs $data_opts"
    if [[ "$data_fs" == "xfs" && "$data_opts" =~ (uquota|usrquota) ]]; then
      health_status "data quota" "OK" "XFS user quota enabled"
    else
      health_status "data quota" "WARN" "未检测到 XFS user quota"
    fi
  else
    health_status "$DATA_MOUNT_DEFAULT" "FAIL" "未挂载"
  fi

  printf '\n--- 服务 ---\n'
  if command -v docker >/dev/null 2>&1; then
    docker_ver="$(docker --version 2>/dev/null || true)"
    if systemctl is-active --quiet docker 2>/dev/null; then
      health_status "Docker" "OK" "$docker_ver"
    else
      health_status "Docker" "WARN" "$docker_ver; service inactive"
    fi
  else
    health_status "Docker" "MISS" "未安装"
  fi

  r_ver="$(R --version 2>/dev/null | head -1 || true)"
  if [[ -n "$r_ver" ]]; then
    health_status "R default" "OK" "$r_ver"
  else
    health_status "R default" "MISS" "未安装"
  fi
  if command -v rig >/dev/null 2>&1; then
    health_status "rig" "OK" "$(rig --version 2>/dev/null | head -1)"
    rig list 2>/dev/null || true
  else
    health_status "rig" "MISS" "未安装"
  fi

  rstudio_ver="$(dpkg-query -W -f='${Version}' rstudio-server 2>/dev/null || true)"
  if [[ -n "$rstudio_ver" ]]; then
    rstudio_state="$(systemctl is-active rstudio-server 2>/dev/null || true)"
    if [[ "$rstudio_state" == "active" ]]; then
      health_status "RStudio Server" "OK" "$rstudio_ver; active"
    else
      health_status "RStudio Server" "WARN" "$rstudio_ver; $rstudio_state"
    fi
    if [[ -r /etc/rstudio/rserver.conf ]]; then
      grep -E '^(rsession-which-r|www-port)=' /etc/rstudio/rserver.conf || true
      rstudio_r="$(awk -F= '/^rsession-which-r=/ {print $2; exit}' /etc/rstudio/rserver.conf)"
      current_r="$(command -v R 2>/dev/null || true)"
      if [[ -n "$rstudio_r" && -n "$current_r" && "$rstudio_r" != "$current_r" ]]; then
        health_status "RStudio -> R" "WARN" "configured=$rstudio_r default=$current_r"
      elif [[ -n "$rstudio_r" ]]; then
        health_status "RStudio -> R" "OK" "$rstudio_r"
      fi
    fi
  else
    health_status "RStudio Server" "MISS" "未安装"
  fi

  printf '\n--- Conda / Mamba ---\n'
  home="$(login_home)"
  for manager in "$home/data_HD/bin/micromamba" "$MICROMAMBA_SYSTEM_BIN" "$MINIFORGE_DEFAULT/bin/mamba" "$home/data_HD/miniconda3/bin/conda" "$MINICONDA_SYSTEM_DEFAULT/bin/conda"; do
    if [[ -x "$manager" ]]; then
      health_status "$(basename "$manager")" "OK" "$manager :: $("$manager" --version 2>/dev/null | head -1)"
    fi
  done

  manager="$(find_conda_config_manager 2>/dev/null || true)"
  if [[ -n "$manager" ]]; then
    if [[ "$(basename "$manager")" == "micromamba" ]]; then
      env_output="$(MAMBA_ROOT_PREFIX="$home/data_HD/micromamba" "$manager" env list 2>/dev/null || true)"
    else
      env_output="$("$manager" env list 2>/dev/null || true)"
    fi
    printf '%s\n' "$env_output" | grep -E 'RNASeq|ChIPSeq|WGS|scRNASeq|metaWRAP|MetaCAT' || health_status "生信环境" "WARN" "未发现预设环境"
  else
    health_status "Conda manager" "MISS" "未安装"
  fi

  printf '\n--- 用户组 ---\n'
  for group in admin sharevip primevip coursevip labvip; do
    case "$group" in
      admin) expected_gid=110 ;;
      sharevip) expected_gid=30002 ;;
      primevip) expected_gid=30003 ;;
      coursevip) expected_gid=30004 ;;
      labvip) expected_gid=30005 ;;
    esac

    if getent group "$group" >/dev/null 2>&1; then
      actual_group_gid="$(getent group "$group" | cut -d: -f3)"
      if [[ "$actual_group_gid" == "$expected_gid" ]]; then
        printf '%-12s GID=%s OK\n' "$group" "$actual_group_gid"
      else
        printf '%-12s GID=%s EXPECTED=%s WARN\n' "$group" "$actual_group_gid" "$expected_gid"
        bad_groups=$((bad_groups + 1))
      fi
    else
      printf '%-12s MISSING EXPECTED=%s\n' "$group" "$expected_gid"
      missing_groups=$((missing_groups + 1))
    fi
  done

  if (( missing_groups == 0 && bad_groups == 0 )); then
    health_status "用户组" "OK" "5 个组均存在且 GID 正确"
  else
    health_status "用户组" "WARN" "缺失=$missing_groups GID错误=$bad_groups"
  fi

  printf '\n--- SSH ---\n'
  if [[ -x /usr/sbin/sshd ]]; then
    ssh_state="$(systemctl is-active ssh 2>/dev/null || true)"
    local ssh_effective=""
    ssh_effective="$(/usr/sbin/sshd -T -C user=root,host=localhost,addr=127.0.0.1 2>/dev/null || true)"
    ssh_root="$(printf '%s\n' "$ssh_effective" | awk '$1=="permitrootlogin" {value=$2} END {print value}')"
    ssh_pubkey="$(printf '%s\n' "$ssh_effective" | awk '$1=="pubkeyauthentication" {value=$2} END {print value}')"
    if [[ "$ssh_state" == "active" ]]; then
      health_status "SSH service" "OK" "active"
    else
      health_status "SSH service" "WARN" "${ssh_state:-unknown}"
    fi
    if [[ "$ssh_root" == "prohibit-password" || "$ssh_root" == "without-password" ]]; then
      health_status "root SSH policy" "OK" "PermitRootLogin=$ssh_root"
    else
      health_status "root SSH policy" "WARN" "PermitRootLogin=${ssh_root:-unknown}"
    fi
    health_status "SSH pubkey auth" "$([[ "$ssh_pubkey" == "yes" ]] && printf OK || printf WARN)" "PubkeyAuthentication=${ssh_pubkey:-unknown}"
    if (( DRY_RUN )); then
      ssh_key_state="未检查（dry-run）"
      health_status "admin@noc.im key" "INFO" "$ssh_key_state"
    elif as_root grep -Fqx -- "$DEFAULT_ROOT_SSH_KEY" /root/.ssh/authorized_keys 2>/dev/null; then
      health_status "admin@noc.im key" "OK" "已授权 root"
    else
      health_status "admin@noc.im key" "MISS" "未授权 root"
    fi
  else
    health_status "OpenSSH Server" "MISS" "未安装"
  fi

  printf '\n--- 防火墙 ---\n'
  if command -v ufw >/dev/null 2>&1; then
    as_root ufw status 2>/dev/null || true
  else
    health_status "UFW" "MISS" "未安装"
  fi
}

ensure_required_groups_fixed() {
  local -a groups=(admin sharevip primevip coursevip labvip)
  local -a gids=(110 30002 30003 30004 30005)
  local i group gid existing_gid used_by

  for i in "${!groups[@]}"; do
    group="${groups[$i]}"
    gid="${gids[$i]}"
    if getent group "$group" >/dev/null 2>&1; then
      existing_gid="$(getent group "$group" | cut -d: -f3)"
      [[ "$existing_gid" == "$gid" ]] || {
        warn "组 $group 的 GID=$existing_gid，预期=$gid；停止一键流程。"
        return 1
      }
    else
      used_by="$(getent group "$gid" 2>/dev/null | cut -d: -f1 || true)"
      [[ -z "$used_by" ]] || { warn "GID $gid 已被组 $used_by 占用。"; return 1; }
      as_root groupadd -g "$gid" "$group"
    fi
  done
  log "固定用户组检查完成。"
}

one_click_bootstrap() {
  local r_target conda_choice

  printf '\n============================================================\n'
  printf ' 一键服务器开局\n'
  printf '============================================================\n'
  printf '默认执行：时区/NTP、基础工具、开发环境、Docker、固定用户组、R。\n'
  printf 'R 默认安装最新正式版 release；也可以输入具体版本，例如 4.5.3。\n'
  printf 'metaWRAP 不会在一键开局中自动创建。\n'
  printf '数据盘、UFW、RStudio、Conda/Mamba、Root SSH 在流程中按需确认。\n'

  read -r -p "R 版本 [release]: " r_target
  r_target="${r_target:-release}"
  [[ "$r_target" =~ ^(release|oldrel|devel|next|[0-9]+\.[0-9]+(\.[0-9]+)?)$ ]] || {
    warn "R 版本格式不合法: $r_target"
    return 1
  }

  confirm "确认开始一键服务器开局？" || { warn "已取消。"; return 0; }

  CURRENT_ACTION="bootstrap time"
  configure_time
  CURRENT_ACTION="bootstrap base packages"
  install_base_packages
  CURRENT_ACTION="bootstrap dev tools"
  install_dev_tools
  CURRENT_ACTION="bootstrap docker"
  install_docker
  CURRENT_ACTION="bootstrap groups"
  ensure_required_groups_fixed
  CURRENT_ACTION="bootstrap R"
  install_r_for_bootstrap "$r_target"

  if confirm "现在初始化 /data_disk？"; then
    CURRENT_ACTION="bootstrap storage"
    storage_wizard
  fi
  if confirm "现在配置 UFW？"; then
    CURRENT_ACTION="bootstrap firewall"
    configure_firewall
  fi
  if confirm "现在安装 RStudio Server？" "Y"; then
    CURRENT_ACTION="bootstrap RStudio"
    install_rstudio
  fi

  printf '\nConda/Mamba 开局安装：\n'
  printf '1) 给 root 安装 micromamba（自动安装 Miniconda 前置，推荐）\n'
  printf '2) Miniforge/Mamba\n'
  printf '3) 跳过\n'
  read -r -p "选择 [1]: " conda_choice
  conda_choice="${conda_choice:-1}"
  case "$conda_choice" in
    1)
      CURRENT_ACTION="bootstrap root micromamba"
      install_micromamba_for_account root
      ;;
    2)
      CURRENT_ACTION="bootstrap Miniforge"
      install_miniforge
      ;;
    3) ;;
    *) warn "无效选择，跳过 Conda/Mamba。" ;;
  esac

  if confirm "现在配置 root SSH 公钥登录？" "Y"; then
    CURRENT_ACTION="bootstrap root ssh"
    configure_root_ssh_key_login
  fi

  CURRENT_ACTION="bootstrap health"
  health_check
  log "一键服务器开局完成。metaWRAP / MetaCAT 均未自动创建，可在[创建生信环境]中按需安装。"
}

one_click_add_user() {
  LAST_CREATED_USER=""
  CURRENT_ACTION="one-click groups"
  ensure_required_groups_fixed || return 1
  CURRENT_ACTION="one-click create user"
  create_user || return 1

  [[ -n "$LAST_CREATED_USER" ]] || { warn "没有新用户被创建。"; return 0; }
  if confirm "现在为新用户 $LAST_CREATED_USER 安装 micromamba？（Miniconda 自动作为前置）" "Y"; then
    CURRENT_ACTION="one-click user micromamba"
    install_micromamba_for_account "$LAST_CREATED_USER"
  fi
  info "metaWRAP / MetaCAT 不会自动安装；需要时请从[创建生信环境]菜单显式选择。"
  log "一键新增用户流程完成: $LAST_CREATED_USER"
}

show_menu() {
  local mode_label=""
  if (( DRY_RUN )); then
    mode_label="[DRY-RUN]"
  fi
  clear 2>/dev/null || true
  printf '============================================================\n'
  printf ' 生信服务器开局助手  %s\n' "$mode_label"
  printf '============================================================\n'
  printf ' 1) 一键服务器开局（R 默认 latest/release，可指定版本）\n'
  printf ' 2) 一键新增用户（可同时安装 micromamba，自动 Miniconda 前置）\n'
  printf ' 3) 给 root / 普通用户安装 micromamba（自动安装 Miniconda 前置）\n'
  printf ' 4) 创建生信环境（RNASeq/ChIPSeq/WGS/scRNASeq/metaWRAP/MetaCAT）\n'
  printf ' 5) metaWRAP 数据库下载 / 配置（选择用户和目录）\n'
  printf '%s\n' '------------------------------------------------------------'
  printf '10) 系统 / 磁盘 / 网络检查\n'
  printf '11) 设置时区与 NTP\n'
  printf '12) 安装基础管理工具\n'
  printf '13) 初始化 / 自动格式化 XFS 数据盘与 quota（三次确认）\n'
  printf '14) 配置 UFW 防火墙\n'
  printf '15) 安装编译 / Python / Java 开发环境\n'
  printf '16) 安装 Docker\n'
  printf '17) R 多版本管理（rig）\n'
  printf '18) 安装 / 升级 / 降级 RStudio Server\n'
  printf '19) 安装 Miniforge / Mamba\n'
  printf '20) 配置清华 Conda / Bioconda 源（无损合并）\n'
  printf '21) 初始化固定用户组\n'
  printf '22) 单独创建生信用户 + UID/GID + quota\n'
  printf '23) 服务器健康检查\n'
  printf '24) Root SSH 公钥登录（仅公钥，禁 root 密码）\n'
  printf ' 0) 退出\n'
  printf '============================================================\n'
}

main() {
  require_ubuntu
  init_logging
  if (( DRY_RUN )); then
    warn "当前为 --dry-run，仅打印高风险/修改命令，不应修改系统。"
  fi

  local choice
  while true; do
    show_menu
    read -r -p "请选择: " choice
    case "$choice" in
      1) CURRENT_ACTION="one-click bootstrap"; one_click_bootstrap; pause ;;
      2) CURRENT_ACTION="one-click add user"; one_click_add_user; pause ;;
      3) CURRENT_ACTION="account micromamba"; install_micromamba_account_menu; pause ;;
      4) CURRENT_ACTION="bioinfo envs"; create_bioinfo_envs; pause ;;
      5) CURRENT_ACTION="metaWRAP databases"; download_metawrap_databases_for_user; pause ;;
      10) CURRENT_ACTION="preflight"; preflight; pause ;;
      11) CURRENT_ACTION="time"; configure_time; pause ;;
      12) CURRENT_ACTION="base packages"; install_base_packages; pause ;;
      13) CURRENT_ACTION="storage"; storage_wizard; pause ;;
      14) CURRENT_ACTION="firewall"; configure_firewall; pause ;;
      15) CURRENT_ACTION="dev tools"; install_dev_tools; pause ;;
      16) CURRENT_ACTION="docker"; install_docker; pause ;;
      17) CURRENT_ACTION="R manager"; install_r; pause ;;
      18) CURRENT_ACTION="RStudio Server"; install_rstudio; pause ;;
      19) CURRENT_ACTION="Miniforge"; install_miniforge; pause ;;
      20) CURRENT_ACTION="condarc"; configure_tuna_conda_mirrors; pause ;;
      21) CURRENT_ACTION="groups"; init_groups; pause ;;
      22) CURRENT_ACTION="create user"; create_user; pause ;;
      23) CURRENT_ACTION="health check"; health_check; pause ;;
      24) CURRENT_ACTION="root ssh key"; configure_root_ssh_key_login; pause ;;
      0) exit 0 ;;
      *) warn "无效选择: $choice"; sleep 1 ;;
    esac
  done
}

main "$@"