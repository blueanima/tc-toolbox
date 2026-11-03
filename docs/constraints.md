# 设备约束与踩坑记录（AirPort Time Capsule 静态工具箱）

本仓库面向的目标设备与一系列"反直觉"的约束，是反复试错换来的，复刻前务必通读。

## 1. 设备与核心约束
- **目标机**：AirPort Time Capsule，内核 **NetBSD 6.0**，`evbarm` / `earmv4`（ARMv4，无 Thumb/advanced SIMD）。
- **致命约束：内核没有 `ld.elf_so`（动态链接器）**，因此设备**只能执行纯静态链接的 ELF**。任何动态链接的二进制都会 `Exec format error`。
  - 推论：所有工具必须用 `LDSTATIC="-static"` + `MKPIC=no` 构建，产物经 `objdump -p` 确认无 `INTERP` / `DYNAMIC` 段。
- 交叉 SDK 用 **NetBSD 7.2_STABLE** 源码树（`__NetBSD_Version__ 702000000`），工具链 `gcc 4.8`；目标三元组 `armv4--netbsdelf-eabi`（即 `nbmake-evbarm`）。

## 2. 构建容器约束
- **必须使用大小写敏感的文件系统**承载 NetBSD src/obj/sysroot：NetBSD 源码树存在仅大小写不同的文件，宿主 APFS 绑定挂载是大小写**不**敏感的，会把构建弄坏。
  - 做法：容器内的 `/wb-build` 用独立的 Docker 卷（macOS 上创建时即大小写敏感）；仅最终成品 `stage/bin` 写回宿主 `/buildroot`（大小写不敏感无所谓）。
- **基础镜像用 `debian:bookworm`，不能用 bullseye/buster**：bullseye 已 EOL，其 security 池 `.deb` 已删除（404），导致基础镜像自带的 libc6 永远无法被任何 apt 源匹配；buster 同样失败。bookworm 是稳定版，归档完整自洽。
- **宿主编译器包装器**：bookworm 默认 `gcc-12` 的 `gnu++17` 默认标准会破坏 NetBSD 7 的 gcc-4.8 时代 C++ 源码（如 `bool++`）。`Dockerfile` 把 `g++/c++` 包装成每次调用追加 `-std=gnu++14 -fpermissive`（命令行最后一个 `-std` 生效），既不破坏现代宿主工具（gmake/binutils/gmp/mpfr/mpc），又让老 gcc 源码能过。
- **容器出网**：容器镜像不绑定特定出网方式；从零重建所需的网络（拉取 NetBSD 7 源码、容器 apt）由构建机自身保证，本仓库不附带特定代理配置。

## 3. 部署 / 设备端约束
- **TC 的 sshd 没有 SFTP 子系统**，现代 OpenSSH `scp` 默认走 SFTP 会 `subsystem request failed`。解决：`scp -O`（强制 legacy SCP 协议）。
- **开机阶段 PATH 里没有我们的工具**，所以 boot 时注入 `.profile` 的脚本（`seed_profile.sh`）**只能用 POSIX shell 内建**（`case`/`while read`/`printf`），不能用 `grep`/`sed -i`/`head` 等。
- **根文件系统每次启动从固件重置**，因此 `.profile`（我们往里加工具箱 PATH 的地方）会被清空。唯一可靠做法是：在开机钩子 `boot.sh` 里每启动重注。
- `/.profile` 是 Apple 出厂**只读**文件：编辑前 `chmod u+w`，改完 `chmod u-w`。
- **NetBSD 的 `sed -i` 必须显式给空后缀**：`sed -i "" 'script' file`，否则静默失败。
- **部分命令在 netbsd-7 base 里根本没有**，需特殊处理：
  - `nc`：netbsd-7 base 无 `usr.bin/nc` → 从 `netbsd-10` 分支取 `usr.bin/nc`（autoconf-free BSD Makefile）交叉编。
  - `od`：base 任何版本都无独立 `od` 源码 → 由 `usr.bin/hexdump` 的 `LINKS=... ${BINDIR}/od` 自动产出，编 `hexdump` 后 `cp` 为 `od`（按 `argv[0]` 切 `odsyntax` 模式）。
  - `diff`：base 的 `diff` 在 `gnu/usr.bin/diffutils`，需先编父目录（`Makefile` 的 `SUBDIR= lib .WAIT diff diff3`）生成 `libdiffutils.a`，再编 `diff`。
- `rsync`：本仓库 `bin/rsync` 是更早的 TimeCapsuleSMB 项目产出的 earmv4 静态 3.4.4，原样保留以保证与设备现状完全一致（其源码不在此仓库）。

## 4. 已验证清单（实机）
- 52 个自构建静态二进制 + `rsync` = **53** 个，全部 `objdump` 确认静态。
- `nc -h` / `diff`（差异 rc=2）/ `od -c` / `hexdump -C` 在 TC 上实机正常。
- **真实重启**后 `.profile` 被 boot 自动重注，恰好 1 个工具箱块；`dk2` 正常挂载；登录即带工具箱。
