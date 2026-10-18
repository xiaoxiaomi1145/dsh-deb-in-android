#!/data/data/com.termux/files/usr/bin/bash
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
REPO="${DSH_REPO:-/data/data/com.termux/files/home/deepseek-harness}"
SRC="${ADDON_SRC:-$HOME/dsh-addon-src}"
REF="${ADDON_REF:-36e2a4c9505fd4d05216f2fa9745676cd06d0012}"
URL="${ADDON_URL:-https://github.com/deepseek-ai/dsh-node-addon-require-builtin.git}"
PATCH="$ROOT/patches/addon/node-addon-require-builtin.patch"
log() { printf '[addon] %s\n' "$*"; }
die() { printf '[addon] FAIL %s\n' "$*"; exit 1; }
[ -d "$REPO" ] || die "找不到 dsh 仓库: $REPO"
[ -f "$PATCH" ] || die "找不到补丁: $PATCH"
if [ ! -d "$SRC/.git" ]; then
  log "克隆 $URL"
  rm -rf "$SRC"
  git clone "$URL" "$SRC" || die "克隆失败"
fi
log "检出 $REF"
git -C "$SRC" fetch --all --tags --prune || die "fetch 失败"
git -C "$SRC" checkout -q --force "$REF" || die "checkout 失败"
git -C "$SRC" clean -xdfq -e node_modules >/dev/null 2>&1 || true
if git -C "$SRC" apply --check "$PATCH" 2>/dev/null; then
  git -C "$SRC" apply "$PATCH" || die "打补丁失败"
  log "补丁已应用"
else
  log "补丁已存在，跳过"
fi
cd "$SRC" || die "进入源码目录失败"
[ -d node_modules ] || node -e "const fs=require('fs');const p=JSON.parse(fs.readFileSync('package.json','utf8'));delete p.packageManager;fs.writeFileSync('package.json',JSON.stringify(p,null,2)+'\n')"
pnpm install --frozen-lockfile --ignore-scripts || die "依赖安装失败"
ls -l node_modules/.bin/tsx 2>&1 | head -2
NARB_PRODUCT=require-builtin NARB_BACKEND=napi node node_modules/tsx/dist/cli.mjs ./scripts/build.ts || die "编译失败"
BIN="$SRC/packages/require-builtin/entry/build/napi/napi-v9-android-arm64/require_builtin.node"
[ -f "$BIN" ] || die "找不到产物: $BIN"
PKG=$(find "$REPO/node_modules/.pnpm" -maxdepth 4 -type d -name node-addon-require-builtin 2>/dev/null | head -1)
[ -n "$PKG" ] || die "仓库里没有 node-addon-require-builtin，先跑 pnpm install"
ABI="node-v$(node -p 'process.versions.modules')"
mkdir -p "$PKG/build/napi/napi-v9-android-arm64" "$PKG/build/nodeabi/$ABI-android-arm64"
cp -f "$BIN" "$PKG/build/napi/napi-v9-android-arm64/require_builtin.node"
cp -f "$BIN" "$PKG/build/nodeabi/$ABI-android-arm64/require_builtin.node"
log "已写入 $PKG/build"
node -e "const m=require('$PKG');const i=m.getBindingInfo();console.log('[addon] binding',JSON.stringify(i))" || die "加载失败"
