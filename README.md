# BioNOVA

BioNOVA 将 bioinfo-server-init.sh 内嵌为单个 Linux 可执行程序 bionova，用于 Ubuntu 生物信息服务器的一键开局、用户管理、生信环境和数据库部署。

## 下载

二进制不再提交到仓库，由 GitHub Actions 编译：

- 正式版本：仓库 Releases 页面（推送 `v*` tag 时自动发布 `bionova` 与 `bionova.sha256`）
- 任意分支的最新构建：Actions → build → 对应运行的 `bionova-linux-x86_64` artifact

下载后校验：

~~~bash
sha256sum -c bionova.sha256
chmod +x bionova
~~~

## 直接运行

~~~bash
sudo ./bionova --dry-run
sudo ./bionova
~~~

版本信息：

~~~bash
./bionova --version
~~~

查看内嵌脚本 SHA256：

~~~bash
./bionova --script-sha256
~~~

当前构建目标：

- Linux x86_64
- 静态 ELF
- Ubuntu 22.04 / 24.04
- 运行时需要 /bin/bash
- 无需分发旁边的 .sh 文件

## 主要功能

- 一键服务器开局
- R release 或指定版本安装
- RStudio Server
- Docker
- XFS 数据盘 + quota
- UFW
- 固定用户组
- 一键新增用户
- root / 普通用户 micromamba（官方静态二进制，sha256 校验）
- RNASeq / ChIPSeq / WGS / scRNASeq
- metaWRAP
- metaWRAP 数据库（root 缓存 / 普通用户本地复制）
- MetaCAT 官方 GitHub 最新 Release
- MetaCAT 数据库（CheckM2 v1.1.0 / GTDB-Tk R232，支持 root 缓存）
- Root SSH 仅公钥登录
- 服务器健康检查

## 用户组

| 组 | GID |
| --- | --- |
| bioadmin | 30001 |
| sharevip | 30002 |
| primevip | 30003 |
| coursevip | 30004 |
| labvip | 30005 |

旧版本使用的 `admin`（GID 110）已废弃：Ubuntu 默认 `/etc/sudoers` 含 `%admin ALL=(ALL) ALL`，以 admin 为主组的用户会直接获得 sudo。已有服务器上执行「初始化固定用户组」或健康检查时会提示；确认这些用户不需要 sudo 后迁移：

~~~bash
sudo usermod -g bioadmin <用户>
~~~

创建用户时如果所选主组在 sudoers 中有 `%组名` 规则，会额外要求确认。

## Root SSH 公钥

程序不内置任何公钥。配置 root 公钥登录时需要粘贴你自己的公钥，或指定一个只包含一行公钥的文件；菜单默认选项是取消。健康检查会列出 root 已授权公钥的指纹，请确认均为可信公钥。

## Conda 环境

- micromamba 是独立可执行文件，从 `mamba-org/micromamba-releases` 官方 Release 下载，并按 GitHub 提供的 sha256 digest 校验；不再安装 Miniconda 作为“前置”。
- 旧版本已创建在 `~/data_HD/miniconda3` 中的 metaWRAP 等环境会被自动识别并继续使用。
- 镜像只配置清华 conda-forge + bioconda；不再写入 `pkgs/main`、`pkgs/r`（Anaconda defaults 镜像，受 Anaconda 服务条款约束）。metaWRAP 1.3.2 因上游依赖仍在创建命令中显式使用这两个频道。
- RNASeq / ChIPSeq / WGS / scRNASeq 使用 `--strict-channel-priority`、Python 3.11，cufflinks / macs2 分别替换为 stringtie / macs3。
- 每个环境创建后导出锁定文件到 `~/.config/bioinfo-setup/env-locks/<环境>-<时间>.yml`，可在其他服务器上 `micromamba env create -f` 复现。

## MetaCAT

MetaCAT 安装不固定版本号。运行时通过 GitHub API 查询 `liu-congcong/MetaCAT` 的 latest Release，解析其中的官方 wheel `metacat-*-py3-none-any.whl`，以目标用户身份下载到 `~/.cache/bioinfo-setup/` 并按 GitHub digest 校验 sha256，再在 Python 3.12 的独立 MetaCAT 环境中 pip 安装。

为兼容清华 Conda 镜像，micromamba 会设置 `use_sharded_repodata: false`，避免 shard index 缺失时的 fallback 告警。

数据库管理采用 root 本地缓存模式：root 可先下载 `~/data_HD/metawrap_db` 与 `~/data_HD/metacat_db`；普通用户安装相同数据库时会优先从 `/root/data_HD/...` 本地复制。复制时 root 只负责读取缓存，写入端以目标用户身份运行，文件直接归该用户所有，不再对用户目录执行 root 的 `rsync` / `chown -R`。复制后自动配置 `config-metawrap`、`CHECKM2DB` 和 `GTDBTK_DATA_PATH`。

## 安全与健壮性

- 所有下载使用 0700 私有临时目录或目标用户自己的目录，不再使用 `/tmp` 下可被其他用户抢占的固定文件名。
- Miniforge、micromamba、MetaCAT 均按 GitHub digest 校验 sha256；CheckM2 / GTDB-Tk 数据库按官方 md5 校验。
- 菜单中的每个操作在独立子 shell 中执行：操作内部任何命令失败都会立即中止该操作，但只会返回菜单，不会退出整个程序；输入错误同样只返回菜单。
- 日志位于 `/var/log/bioinfo-setup/`，目录 0750、文件 0600。
- `--dry-run` 不修改系统；以普通用户运行时，需要 root 的只读检查使用 `sudo -n`，不会停下来索要密码。

## 同步 Bash 源码

BioNOVA/assets/bioinfo-server-init.sh 是编译进二进制的快照。

从父目录同步最新脚本：

~~~bash
./scripts/sync-script.sh
~~~

或在构建时同步：

~~~bash
./build.sh --sync
~~~

## 构建

推荐直接推送到 GitHub，由 Actions 完成 lint（`bash -n` + shellcheck）、静态编译和 Ubuntu 22.04 / 24.04 冒烟测试。

本机构建需要：

~~~text
gcc（含 libc6-dev 静态库）
python3
bash
~~~

执行：

~~~bash
./build.sh
~~~

输出：

~~~text
dist/bionova
dist/bionova.sha256
~~~

默认只接受静态 ELF；静态链接失败会直接报错。确实需要动态 ELF 时：

~~~bash
ALLOW_DYNAMIC=1 ./build.sh
~~~

如果本机缺少 gcc 但安装了 Docker，build.sh 使用 `ubuntu:24.04` 容器构建，也可以指定镜像：

~~~bash
BUILD_IMAGE=ubuntu:24.04 ./build.sh
~~~

版本号（推送 `v0.2.0` 这样的 tag 时 CI 自动使用 tag 作为版本号）：

~~~bash
VERSION=0.2.0 ./build.sh --sync
~~~

构建时间默认取最近一次提交时间（或 `SOURCE_DATE_EPOCH`），同一提交重复构建得到相同的版本信息。

## 二进制工作方式

构建阶段：

~~~text
bioinfo-server-init.sh
        ↓
生成 C 字节数组
        ↓
编译进 bionova 静态 ELF
~~~

运行阶段：

~~~text
bionova
  ↓
脚本写入匿名内存文件 memfd（只读密封，不落盘）
  ↓
exec /bin/bash 执行内嵌脚本（bionova 进程直接被 bash 替换）
~~~

不使用 PATH 查找 bash；Ctrl+C、SSH 断线等信号直接到达 bash，不会残留临时文件。内核不支持 memfd 时退回 0700 临时目录，父进程忽略 SIGINT/SIGQUIT、转发 SIGHUP/SIGTERM，并在退出后清理。

因此最终用户只需要一个 bionova 文件。

## 开发流程

建议修改流程：

~~~bash
# 1. 修改父目录 Bash 源码
bash -n ../bioinfo-server-init.sh

# 2. 同步
./scripts/sync-script.sh

# 3. 构建（或直接 push，由 GitHub Actions 构建）
./build.sh

# 4. 验证
dist/bionova --version
dist/bionova --dry-run
~~~

## License

MIT
