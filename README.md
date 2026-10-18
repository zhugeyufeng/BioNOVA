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

## 全体用户共享 R 包

管理员安装一次，所有普通用户（包括 RStudio Server 会话）直接 `library()` 使用，不用每人重复安装。入口：主菜单 17 → R 菜单 7 / 8 / 9。

| R 菜单 | 作用 |
| --- | --- |
| 7 配置共享 R 包目录 | 为选定的（或全部）R 安装创建 `<根目录>/<R 主.次版本>`（默认 `/data_disk/R_Lib/4.6`，root 所有、0755，普通用户只读），并写入该 R 的 `R_HOME/etc/Renviron.site` |
| 8 管理员安装共享 R 包 | 预设组合（GO/KEGG 富集：clusterProfiler、enrichplot、DOSE、AnnotationDbi、org.Hs/Mm/Dr.eg.db；常用分析包）或自定义包名 / GitHub 仓库，用 `BiocManager::install(lib = 共享目录, ask = FALSE, update = FALSE)` 安装，装完以指定普通用户身份逐个加载验证 |
| 9 查看 / 验证 | 列出每个 R 的共享目录、权限、包数量，可选以普通用户身份验证可见性 |

`Renviron.site` 中写入的是一个由本程序管理的区块，重复配置只会替换这个区块，不会动文件里的其他内容：

~~~text
# >>> bioinfo-setup shared R library >>>
R_LIBS_SITE=/data_disk/R_Lib/4.6:${R_LIBS_SITE-/opt/R/4.6.1/lib/R/site-library}
# <<< bioinfo-setup shared R library <<<
~~~

- 共享目录属于站点库，排在用户个人库之后：用户自己安装的新版本仍然优先，用户的 `install.packages()` 也只写入个人库，不会改动共享库。
- `${R_LIBS_SITE-…}` 保留 R 原有的站点库（例如 Debian R 的 `/usr/local/lib/R/site-library`）。
- 每个 R 主.次版本有独立目录。用 rig 安装新版本 R 后，菜单会提示为新版本配置；旧版本编译的包不会被新 R 加载。
- 安装时 R 使用当前该 R 的 `repos` 配置（rig 默认的 Posit 二进制源会保留），也可以临时指定 CRAN 镜像和 Bioconductor 镜像（例如 `https://mirrors.tuna.tsinghua.edu.cn/bioconductor`）。Bioconductor 版本由 BiocManager 按 R 版本自动匹配。
- 安装进程屏蔽 root 的个人库，并使用 `umask 022`：避免 root 个人库里已有同名包导致 BiocManager 跳过安装、普通用户却看不到；安装出的文件对所有用户可读。
- 自定义安装支持 GitHub 包，写法为 `作者/仓库`、`作者/仓库/子目录` 或带版本的 `作者/仓库@tag|分支|提交`，可与普通包名混写，例如 `msigdbr YuLab-SMU/clusterProfiler@devel`。用 `remotes::install_github(lib = 共享目录, upgrade = "never")` 安装，依赖从 CRAN 和与当前 R 匹配的 Bioconductor 仓库解析；验证时使用 DESCRIPTION 中实际的包名。GitHub 上默认是开发版，Bioconductor 已收录的包建议直接写包名安装正式版。
- 安装 GitHub 包时可选填 GitHub token，避免匿名 API 每小时 60 次的限流。token 只写入 0600 临时文件供本次安装读取，装完即删除，不会出现在命令行、进程列表或日志中。
- 包名写错（例如把 `org.Hs.eg.db` 写成 `org.Hm.eg.db`）时，BiocManager 只给出警告；程序会在安装后逐个检查，把缺失的包列出来并判定为失败。
- RStudio Server 读取的是 `rsession-which-r` 指向的那个 R 的 `Renviron.site`；如果它没有配置共享库，菜单会给出提示。已打开的 RStudio 会话需要 Session → Restart R 才会生效。

新建用户时，个人 R 库改为写入 `~/.Renviron`：

~~~text
R_LIBS_USER=/data_disk/user/<用户>/R_Lib_%v
~~~

R 会把 `%v` 展开为主.次版本号，升级 R 后自动使用新版本目录。旧版本创建的用户在 `~/.Rprofile` 中写死了 `R_Lib_<版本>` 路径，升级 R 主.次版本前建议删除这行，改为上面的 `~/.Renviron` 写法。

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
