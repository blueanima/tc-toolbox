# tc-toolbox — AirPort Time Capsule 静态命令工具箱（可复刻仓库）

为 **AirPort Time Capsule**（内核 NetBSD 6.0 / `evbarm` / `earmv4`，**内核无动态链接器，只能跑静态 ELF**）补齐的一套静态命令工具箱，附带**完整可复刻**的构建环境与部署/开机自启方案。

本仓库包含三类内容，便于"快捷复刻"：

1. **成品**：`bin/` 下 53 个预编译静态二进制（48 个核心 + `nc`/`diff`/`od`/`hexdump` + 原样保留的 `rsync`），**无需重新构建**即可直接部署。
2. **部署与开机自启**：`deploy.sh`、`tc-files/`（PATH 钩子 + boot 重注脚本 + 开机注入器）。
3. **构建环境**：`Dockerfile` + 交叉编译脚本（`fetch_src.sh` / `build_toolbox.sh` / `build_extra.sh` / `run.sh` / `build/`），可随时重新生成成品。

---

## 一、快捷复刻（推荐，免编译）

仅需一台能 SSH 到 TC 的机器，以及本仓库。

```sh
# 1) 克隆
git clone <this-repo> tc-toolbox && cd tc-toolbox

# 2) 部署二进制 + PATH 钩子 + boot 重注脚本到 TC
#    TC_HOST 默认为 root@192.168.31.44，按需修改
TC_HOST=root@192.168.31.44 ./deploy.sh

# 3) 让工具箱在每次开机后自动生效（向 /mnt/Flash/boot.sh 注入重注钩子，幂等）
TC_HOST=root@192.168.31.44 AUTO_BOOT=1 ./deploy.sh

# 4) 重启 TC 验证（可选但推荐）
ssh root@192.168.31.44 reboot
# 重连后登录即自带工具箱；或：
ssh root@192.168.31.44 'export PATH=/Volumes/dk2/.tc_tools/bin:$PATH; nc -h; diff --version; od -c /dev/null'
```

> `deploy.sh` 使用 `scp -O`（legacy SCP 协议），因为 TC 的 sshd **没有 SFTP 子系统**，现代 `scp` 默认走 SFTP 会失败。

不想要开机自启，可跳过第 3 步；之后每次登录手动 `source /mnt/Flash/setenv.sh` 也能用。

---

## 二、仓库布局

```
tc-toolbox/
├── README.md                 # 本文件
├── .gitignore                # 排除 buildroot/ 等大型中间产物
├── Dockerfile                # 构建镜像：debian:bookworm + gcc-12 包装器
├── run.sh                    # 起容器跑构建（自包含；EXTRA=1 顺带编 nc/diff/od）
├── fetch_src.sh              # 拉取并解包 NetBSD 7 源码（幂等）
├── build_toolbox.sh          # 构建交叉工具链 + 48 个核心静态工具（容器内）
├── build_extra.sh            # 构建 nc / diff / od / hexdump（容器内）
├── deploy.sh                 # 部署到 TC（可移植；AUTO_BOOT=1 注入开机钩子）
├── build/                    # 构建资产（使重建自包含）
│   ├── env.sh                # NetBSD7 SDK 环境（源自 TimeCapsuleSMB 项目，附副本）
│   ├── config.guess          # 现代 autoconf 探测脚本（注入 src 树）
│   └── config.sub
├── tc-files/                 # 落盘到 /mnt/Flash 的文件
│   ├── setenv.sh             # PATH 钩子（把 .tc_tools/bin 加进 PATH）
│   ├── seed_profile.sh       # 开机时重注 /.profile（纯 shell，按构造幂等）
│   └── inject_boot.sh        # 在 TC 本地把重注钩子插入 boot.sh（幂等）
├── bin/                      # ★ 成品：53 个静态二进制（直接可部署）
└── docs/
    ├── constraints.md        # 设备约束、容器/部署坑点（务必先读）
    └── rebuild.md            # 从零重新构建的完整步骤
```

---

## 三、从零重新构建（可选）

仅在你需要改动/新增某个工具时才需要。前置：macOS + Docker（推荐 OrbStack）。

```sh
./run.sh          # 构建 48 个核心静态工具
EXTRA=1 ./run.sh  # 额外构建 nc / diff / od / hexdump
cp buildroot/stage/bin/* bin/
```

详见 [`docs/rebuild.md`](docs/rebuild.md)。构建容器与脚本的关键约束见 [`docs/constraints.md`](docs/constraints.md)。

---

## 四、验证清单（已在实机通过）

- [x] 53 个二进制均为静态链接（`objdump -p` 无 `INTERP`/`DYNAMIC`）。
- [x] `nc -h`、`diff`（差异返回 rc=2）、`od -c`、`hexdump -C` 在 TC 上实机正常。
- [x] **真实重启**后 `.profile` 被 `boot.sh` 自动重注，恰好 1 个工具箱块；`/Volumes/dk2` 正常挂载；登录即带工具箱。
- [x] `seed_profile.sh` 重写式幂等：2 块 → 1 块，连跑多次恒为 1 块，且 Apple 出厂内容完整保留。

---

## 五、来源与署名

- 交叉编译基于 **NetBSD 7.2_STABLE** 源码树（`gcc 4.8` 工具链，目标 `armv4--netbsdelf-eabi`）。
- `build/env.sh` 源自 **TimeCapsuleSMB** 项目的 SDK 环境脚本（本仓库附副本，便于自包含重建）。
- `bin/rsync` 为 TimeCapsuleSMB 项目早先产出的 earmv4 静态 3.4.4，原样保留以保证与设备现状一致。
- `nc` 取自 NetBSD `netbsd-10` 分支；`od` 由 `hexdump` 的 `LINKS` 别名产出；`diff` 来自 `gnu/usr.bin/diffutils`。
