# 从零重建二进制（可选）

绝大多数复刻场景**不需要**重新构建——直接使用仓库里的 `bin/`（53 个预编译静态二进制）即可，见 `README.md` 的"快捷复刻"。本节只在你需要重新生成或修改某个工具时才有用。

## 前置条件
- 一台能跑 Docker 的 macOS 主机（推荐 OrbStack；本仓库的容器与挂载约定按 macOS 设计）。
- Mac 上运行 **Surge 代理**并开启 `:6152`（HTTP）/`:6153`（SOCKS5）对外（容器以此作为唯一出网路径）。若你的代理端口/软件不同，改 `Dockerfile` 里的 `http_proxy` / `https_proxy` 环境变量。
- 能访问 `github.com/NetBSD/src`（codeload 下载源码）与 Debian 镜像（容器 `apt`）。

## 目录约定（容器内）
- `/buildroot`：宿主 `./buildroot` 的绑定挂载，承载下载的源码 tarball 与**最终成品** `stage/bin`。
- `/wb-build`：独立的、大小写敏感的 Docker 卷（`tc_wb`），承载 NetBSD `src/`、`obj/`、`tools/`、sysroot——这些必须用大小写敏感 FS。
- `/work`：宿主 `./build` 只读挂载，提供 `build/env.sh` 与 `config.guess`/`config.sub`。

## 步骤
1. **构建镜像**（第一次会拉 Debian + 装依赖，几分钟）：
   ```sh
   ./run.sh          # 只构建 48 个核心静态工具
   # 或
   EXTRA=1 ./run.sh  # 额外构建 nc / diff / od / hexdump
   ```
   `run.sh` 会：
   - `docker build` 生成 `tcbuild` 镜像（见 `Dockerfile`）。
   - 创建大小写敏感卷 `tc_wb`。
   - 在容器内依次执行 `fetch_src.sh`（下载并解包 NetBSD 7 源码，幂等）→ `build_toolbox.sh`（构建交叉工具链 + 静态库 + 48 个核心工具，幂等）→（可选）`build_extra.sh`（nc/diff/od/hexdump）。
   - 所有日志写到 `./buildroot/build.log`。

2. **取出成品**：
   ```sh
   cp buildroot/stage/bin/* bin/
   ```
   （`bin/` 即部署目录，结构已与设备 `/Volumes/dk2/.tc_tools/bin` 对齐。）

## 关于 `build/env.sh`
`build/env.sh` 源自 **TimeCapsuleSMB** 项目的 SDK 环境脚本（本仓库在 `build/` 下附带一份副本，便于自包含重建）。它负责：
- 定义 `select_tool_triple()`（earmv4 对应 `armv4--netbsdelf-eabi`）；
- 提供 NetBSD7 的 SDK 默认变量（`NETBSD7_ROOT`/`NETBSD7_SRC`/`OBJ`/`TOOLS` 等，均用 `:-` 默认值，故 `build_toolbox.sh`/`build_extra.sh` 随后用 `/wb-build`、`/buildroot` 覆盖时不会冲突）。

若你不想要这份外部依赖，`build_toolbox.sh`/`build_extra.sh` 已内置 `select_tool_triple` 兜底，并在 `env.sh` 缺失时安全跳过（`|| true`），仍可运行——只是 `env.sh` 提供的其他 SDK 默认将回落到脚本内的覆盖值。

## 构建耗时与排错
- 首次构建交叉工具链耗时较长（小时级），且强依赖 Surge 代理（源码拉取、apt 均走它）。
- 若 `apt` 报证书/签名错误：容器已设 `Acquire::https::Verify-Peer/Host false` 并用 HTTPS CONNECT，仍由 Debian keyring 校验 InRelease；确认 Surge 的 `:6152` 确实可达。
- 若源码解包后报"大小写冲突/文件缺失"：确认 `/wb-build` 是大小写敏感卷（重建 `tc_wb` 卷即可）。
