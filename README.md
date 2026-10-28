# dsh-deb-builder

把 [deepseek-harness](https://github.com/deepseek-ai/deepseek-harness) 打成 Termux aarch64 可直接安装的 `.deb`，同时带上一整套本地补丁（Termux 兼容 + 卡死修复 + 启动优化 + Android 原生模块）。

## 目录

```
scripts/    构建、打包、原生模块编译脚本
patches/    10 个 dsh 补丁（基线 dsh-v0.2.2-alpha.2）
patches/addon/  node-addon-require-builtin 的 Android 补丁
env/        Termux 环境补丁（shim / billion-context 配置）
dist/       打好的 .deb
```

## 手动构建

```bash
cd ~/deepseek-harness
pnpm install --frozen-lockfile
DSH_REPO=~/deepseek-harness bash ~/dsh-deb-builder/scripts/build-addon.sh
DSH_REPO=~/deepseek-harness bash ~/dsh-deb-builder/scripts/sharp-setup.sh build
REPO=~/deepseek-harness bash ~/dsh-deb-builder/scripts/build-all.sh
```

只重打包（原生模块和构建产物都已就位）：

```bash
REPO=~/deepseek-harness bash scripts/build-all.sh --skip-install --only=deb
```

产物在 `dist/dsh_<版本>_aarch64.deb`：

```bash
apt install -y ./dist/dsh_0.2.1-rc.2_aarch64.deb
```

`LAUNCHER_MODE=B` 装成 `dsh-bundle`，不覆盖系统里的 `dsh`。

## 原生模块

`node-addon-require-builtin` 官方只发布 darwin/linux/win32 的预编译包，Android 没有，必须从源码编译：

```bash
bash scripts/build-addon.sh
```

它会克隆 `dsh-node-addon-require-builtin` 到固定 commit，打上 `patches/addon/node-addon-require-builtin.patch`（放开 `__ANDROID__` 的 glibc 分支 + 让 build.ts 认 android 平台），编译出 `napi-v9-android-arm64/require_builtin.node`，再写进 dsh 的 `node_modules/.pnpm/node-addon-require-builtin@*/node_modules/node-addon-require-builtin/build/`。不打这个补丁，dsh 启动直接报 `No usable prebuilt binary found`。

`sharp` 同理，没有 Android 预编译包：

```bash
bash scripts/sharp-setup.sh build
```

需要 libvips ≥ 8.18.7、clang、python3、node-gyp。仓库里不放编译好的 `.node`，全部由脚本现编。

## 补丁

```bash
bash scripts/apply-all-patches.sh --check
bash scripts/apply-all-patches.sh --repo ~/deepseek-harness
```

单文件版：`bash dsh-all-patches.sh --repo ~/deepseek-harness`。

## 自动构建

`.github/workflows/build.yml`：

- 每天 04:23 和 16:23（UTC）各检查一次上游 release
- 上游有新 tag 且本仓库还没有同名 release 时才构建，否则跳过
- 构建流程：clone 上游 tag → 打补丁 → `pnpm install` → 编译 addon → 编译 sharp → `build:artifacts` → 打 deb → 发布到 Releases，tag 与上游一致

构建必须在 Termux 环境里跑（android-arm64 的 `.node`、bionic 的 node、Termux 的 dpkg 布局），普通 Ubuntu runner 上编出来的东西装不上。两种跑法，用仓库变量 `BUILD_MODE` 切换：

**`BUILD_MODE=docker`（不用手机）**

- 作业跑在 `ubuntu-24.04-arm` 上，把 `termux/termux-docker` 的 aarch64 镜像当构建环境：里面就是 Android bionic + Termux 前缀，`pkg install nodejs clang libvips dpkg` 之后和手机上一样编
- 设仓库变量 `BUILD_MODE=docker` 即可，不需要自托管 runner
- 一次 20–40 分钟，磁盘吃满 14GB 左右

```bash
bash scripts/build-in-docker.sh dsh-v0.2.2-alpha.2
```

**默认（自托管 Termux）**

- 手机上注册 self-hosted runner，默认标签 `self-hosted` + `termux`
- 换标签设仓库变量 `RUNNER_LABELS`，值是 JSON 数组，例如 `["self-hosted","myphone"]`
- runner 需要：node 24、pnpm、git、dpkg-deb、libvips ≥ 8.18.7、clang、python3、c++filt

手动触发：Actions → dsh-deb → Run workflow，`force` 填 `yes` 强制重建已有版本。
