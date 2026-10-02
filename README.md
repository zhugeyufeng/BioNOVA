# BioNOVA

BioNOVA 将 bioinfo-server-init.sh 内嵌为单个 Linux 可执行程序 bionova，用于 Ubuntu 生物信息服务器的一键开局、用户管理、生信环境和数据库部署。

## 直接运行

~~~bash
./bionova --dry-run
./bionova
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
- 运行时需要 bash
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
- root / 普通用户 micromamba
- Miniconda 仅作为 micromamba 自动前置
- RNASeq / ChIPSeq / WGS / scRNASeq
- metaWRAP
- metaWRAP 数据库（root 缓存 / 普通用户本地复制）
- MetaCAT 官方 GitHub 最新 Release
- MetaCAT 数据库（CheckM2 v1.1.0 / GTDB-Tk R232，支持 root 缓存）
- Root SSH 仅公钥登录
- 服务器健康检查

## MetaCAT

MetaCAT 安装不固定版本号。

运行时查询：

~~~text
https://api.github.com/repos/liu-congcong/MetaCAT/releases/latest
~~~

解析 latest Release 中的官方 wheel：

~~~text
metacat-*-py3-none-any.whl
~~~

然后在 Python 3.12 的独立 MetaCAT 环境中执行 pip upgrade。

为兼容清华 Conda 镜像，micromamba 会设置 `use_sharded_repodata: false`，避免 shard index 缺失时的 fallback 告警。MetaCAT 版本校验也避免使用会提前关闭上游管道的 `awk ... exit` 写法，从而规避 rc=120。

数据库管理采用 root 本地缓存模式：root 可先下载 `~/data_HD/metawrap_db` 与 `~/data_HD/metacat_db`；普通用户安装相同数据库时会优先从 `/root/data_HD/...` 本地复制并自动修复 owner、`config-metawrap`、`CHECKM2DB` 和 `GTDBTK_DATA_PATH`。

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

本机构建需要：

~~~text
gcc
python3
bash
~~~

执行：

~~~bash
./build.sh
~~~

输出：

~~~text
bionova
bionova.sha256
dist/bionova
dist/bionova.sha256
~~~

如果本机缺少 gcc，但安装了 Docker，build.sh 会优先使用本地已有 mineru:4 镜像；否则使用 ubuntu:24.04 构建镜像。

也可以指定：

~~~bash
BUILD_IMAGE=ubuntu:24.04 ./build.sh
~~~

版本号：

~~~bash
VERSION=0.2.0 ./build.sh --sync
~~~

## 二进制工作方式

构建阶段：

~~~text
bioinfo-server-init.sh
        ↓
生成 C 字节数组
        ↓
编译进 bionova ELF
~~~

运行阶段：

~~~text
bionova
  ↓
安全写入临时目录
  ↓
bash 执行内嵌脚本
  ↓
退出后删除临时文件
~~~

因此最终用户只需要一个 bionova 文件。

## 开发流程

建议修改流程：

~~~bash
# 1. 修改父目录 Bash 源码
bash -n ../bioinfo-server-init.sh

# 2. 同步
./scripts/sync-script.sh

# 3. 构建
./build.sh

# 4. 验证
./bionova --version
./bionova --dry-run
~~~

## License

MIT
