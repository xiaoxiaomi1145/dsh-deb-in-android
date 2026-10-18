#!/data/data/com.termux/files/usr/bin/bash
set -uo pipefail

REPO="${REPO:-$HOME/deepseek-harness}"
B="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
export WORK="${WORK:-$B/dist}"
LOGDIR="$B/logs"
mkdir -p "$LOGDIR"
LOG="$LOGDIR/build-all-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1

SKIP_INSTALL=0
ONLY_DEB=0
DO_VERIFY=0
LAUNCHER_MODE="${LAUNCHER_MODE:-A}"
VERSION=""
for arg in "$@"; do
  case "$arg" in
    --skip-install) SKIP_INSTALL=1 ;;
    --only=deb)     ONLY_DEB=1 ;;
    --verify)       DO_VERIFY=1 ;;
    --version=*)    VERSION="${arg#*=}" ;;
    -h|--help)
      echo "用法: build-all.sh [--skip-install] [--only=deb] [--verify] [--version=X]"
      echo "环境: REPO=仓库路径 LAUNCHER_MODE=A|B|C"
      exit 0 ;;
    *) echo "未知参数: $arg" >&2; exit 2 ;;
  esac
done

STEP="preflight"
on_err() {
  rc=$?
  echo
  echo "############ 失败 ############"
  echo "步骤 : $STEP (exit=$rc)"
  echo "日志 : $LOG"
  echo "常见原因: 内存不足(需要 ~2GB 空闲)、pnpm 网络超时、磁盘满"
  exit "$rc"
}
trap on_err ERR

hr() { echo; echo "===== [$1] $(date +%H:%M:%S) ====="; }
ts() { date +%s%N; }

STEP="preflight"
hr "0. 环境检查"
echo "repo      : $REPO"
echo "node      : $(node -v 2>&1) ($(command -v node))"
echo "pnpm      : $(pnpm --version 2>&1) ($(command -v pnpm))"
echo "launcher  : $LAUNCHER_MODE"
free -m | sed -n '1,2p'
df -h "$HOME" | tail -1
AVAIL_MB=$(free -m | awk '/^Mem:/{print $7}')
if [ "${AVAIL_MB:-0}" -lt 1200 ]; then
  echo "!! 警告: 可用内存只有 ${AVAIL_MB}MB，构建可能 OOM。建议先停掉占用大的进程。"
  sleep 5
fi
[ -d "$REPO" ] || { echo "仓库不存在: $REPO"; exit 1; }
cd "$REPO"

STEP="install"
if [ "$ONLY_DEB" = "0" ] && [ "$SKIP_INSTALL" = "0" ]; then
  hr "1. pnpm install --frozen-lockfile"
  s=$(ts); pnpm install --frozen-lockfile; e=$(ts)
  echo "install 用时 $(( (e-s)/1000000 ))ms"
else
  echo "== 跳过 install =="
fi

STEP="native"
if [ "$ONLY_DEB" = "0" ] && [ "$SKIP_INSTALL" = "0" ]; then
  hr "1b. 原生模块 addon + sharp"
  DSH_REPO="$REPO" bash "$B/scripts/build-addon.sh" || { echo "addon 编译失败"; exit 1; }
  DSH_REPO="$REPO" bash "$B/scripts/sharp-setup.sh" build || { echo "sharp 编译失败"; exit 1; }
else
  echo "== 跳过原生模块 =="
fi

STEP="build:artifacts"
if [ "$ONLY_DEB" = "0" ]; then
  hr "2. build:artifacts --profile official (GATE_CONCURRENCY=1, heap 2048)"
  s=$(ts)
  DSH_GATE_CONCURRENCY=1 NODE_OPTIONS=--max-old-space-size=2048 \
    pnpm run build:artifacts --profile official
  e=$(ts)
  echo "build 用时 $(( (e-s)/1000000 ))ms"
else
  echo "== 跳过构建 =="
fi

STEP="version"
if [ -z "$VERSION" ]; then
  VERSION=$(node -p "require('$REPO/package.json').version")
fi
echo "版本: $VERSION"

STEP="deb"
hr "3. 打包 .deb (LAUNCHER_MODE=$LAUNCHER_MODE)"
s=$(ts)
REPO="$REPO" LAUNCHER_MODE="$LAUNCHER_MODE" bash "$B/scripts/make-dsh-deb.sh" "$VERSION"
e=$(ts)
DEB="$WORK/dsh_${VERSION}_aarch64.deb"
[ -f "$DEB" ] || { echo "没找到产物: $DEB"; exit 1; }
echo "打包用时 $(( (e-s)/1000000 ))ms"

STEP="inspect"
hr "4. 产物检查"
ls -lh "$DEB"
echo "-- control --"
dpkg-deb -f "$DEB" Package Version Architecture Depends 2>&1
echo "-- launcher --"
dpkg-deb -c "$DEB" 2>/dev/null | grep -E 'usr/bin/(dsh|dsh-bundle)$'
echo "-- 包内文件数 --"
dpkg-deb -c "$DEB" 2>/dev/null | wc -l

if [ "$DO_VERIFY" = "1" ]; then
  STEP="verify"
  hr "5. 安装验证（会 apt install 再卸载）"
  SHIM_BACKUP=$(ls -t "$B"/dsh-shim-backup-* 2>/dev/null | head -1)
  [ -n "$SHIM_BACKUP" ] || { echo "没有 shim 备份，跳过 verify"; SHIM_BACKUP=/dev/null; }
  bash "$B/scripts/verify-dsh-deb.sh" "$DEB" "$SHIM_BACKUP"
fi

hr "完成"
echo "deb    : $DEB"
echo "大小   : $(du -h "$DEB" | cut -f1)"
echo "日志   : $LOG"
echo
echo "安装:  apt install -y $DEB"
echo "卸载:  apt remove -y dsh"
