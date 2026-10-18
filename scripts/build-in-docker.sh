#!/usr/bin/env bash
set -euo pipefail

TAG="${1:?用法: build-in-docker.sh <tag> [version]}"
VER="${2:-${TAG#dsh-v}}"
VER="${VER#v}"

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
IMAGE="${IMAGE:-termux/termux-docker:aarch64}"

mkdir -p "$ROOT/dist" "$ROOT/logs"
chmod 777 "$ROOT/dist" "$ROOT/logs"

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  if ! docker pull "$IMAGE"; then
    IMAGE=termux/termux-docker:latest
    docker pull "$IMAGE"
  fi
fi

printf 'TAG=%s\nVER=%s\n' "$TAG" "$VER" > "$ROOT/dist/.ci-vars"

echo "镜像: $IMAGE"
echo "版本: $TAG / $VER"

docker run --rm -i \
  -v "$ROOT:/builder" \
  -w /builder \
  "$IMAGE" bash -s <<'INNER'
set -e
export PATH="${PREFIX:-/data/data/com.termux/files/usr}/bin:$PATH"
export COREPACK_ENABLE_STRICT=0
MIRROR="${TERMUX_MIRROR:-https://packages.termux.dev}"
printf 'deb %s/apt/termux-main stable main\n' "$MIRROR" > "$PREFIX/etc/apt/sources.list"
mkdir -p "$PREFIX/etc/apt/sources.list.d"
mv "$PREFIX/etc/apt/sources.list.d" "$PREFIX/etc/apt/sources.list.d.off" 2>/dev/null || true
mkdir -p "$PREFIX/etc/apt/sources.list.d"
echo "apt 源: $(cat "$PREFIX/etc/apt/sources.list")"
echo "额外源数量: $(ls "$PREFIX/etc/apt/sources.list.d" | wc -l)"
export TERMUX_PKG_NO_MIRROR_SELECT=1

echo "== 容器 =="
uname -m
id
echo "PREFIX=$PREFIX HOME=$HOME"
. /builder/dist/.ci-vars
echo "TAG=$TAG VER=$VER"
if touch /builder/dist/.wtest 2>/dev/null; then echo "dist: writable"; rm -f /builder/dist/.wtest; else echo "dist: NOT writable"; fi
df -h / | tail -2

pkg update -y
pkg upgrade -y || apt full-upgrade -y || true
pkg install -y nodejs-lts git python clang make cmake pkg-config libvips libicu dpkg tar xz-utils coreutils ca-certificates
node -v

npm i -g pnpm@11.28.5 node-gyp --silent || true
GYP="$PREFIX/lib/node_modules/npm/node_modules/node-gyp/bin/node-gyp.js"
if [ -f "$GYP" ]; then chmod +x "$GYP"; ln -sf "$GYP" "$PREFIX/bin/node-gyp"; fi
PNPM_JS="$(npm root -g)/pnpm/bin/pnpm.cjs"
mkdir -p "$PREFIX/tmp"
LAUNCH_TMP="$PREFIX/tmp/pnpm-launch.$$"
cat > "$LAUNCH_TMP" <<LAUNCH
#!$PREFIX/bin/bash
exec "$PREFIX/bin/node" "$PNPM_JS" "\$@"
LAUNCH
chmod +x "$LAUNCH_TMP"
mv -f "$LAUNCH_TMP" "$PREFIX/bin/pnpm"
pnpm -v

echo "== 拉源码 =="
SRC="$PREFIX/tmp/dsh"
rm -rf "$SRC"
git clone --depth 1 -b "$TAG" https://github.com/deepseek-ai/deepseek-harness.git "$SRC"

echo "== 打补丁 =="
cd /builder
bash scripts/apply-all-patches.sh --repo "$SRC" --force

echo "== 依赖 =="
cd "$SRC"
pnpm install --frozen-lockfile --ignore-scripts || pnpm install --no-frozen-lockfile --ignore-scripts
printf 'pm-on-fail=ignore\nmanage-package-manager-versions=false\npackage-import-method=copy\n' > "$HOME/.npmrc"
(cd packages/fs/fs-local && node -e "try{require('koffi');console.log('koffi OK')}catch(e){console.log('koffi FAIL: '+e.message)}")
(cd packages/subprocess/subprocess-local && node -e "try{require('node-pty');console.log('node-pty OK')}catch(e){console.log('node-pty FAIL: '+e.message)}")
KOFFI=$(find node_modules/.pnpm -maxdepth 4 -type d -name koffi -path '*koffi@*' | head -1)
if [ -n "$KOFFI" ]; then
  BC="$KOFFI/lib/native/base/base.cc"
  if [ -f "$BC" ]; then
    L=$(grep -n 'const char \*pathname = filename;' "$BC" | head -1 | cut -d: -f1)
    if [ -n "$L" ]; then
      sed -i "$((L-1))s/#if defined(__linux__)/#if defined(__linux__) \&\& !defined(__ANDROID__)/" "$BC"
      echo "koffi statx 分支已跳过"
    fi
  fi
  (cd "$KOFFI" && node ./cnoke.cjs -P . -D src/koffi --prebuild --release) || echo "koffi 构建失败"
fi
PTY=$(find node_modules/.pnpm -maxdepth 4 -type d -name node-pty -path '*node-pty@*' | head -1)
if [ -n "$PTY" ]; then (cd "$PTY" && (node scripts/prebuild.js || node-gyp rebuild)) || echo "node-pty 构建失败"; fi

echo "== 原生模块 =="
DSH_REPO="$SRC" bash /builder/scripts/build-addon.sh
DSH_REPO="$SRC" bash /builder/scripts/sharp-setup.sh build

echo "== 编译 =="
echo "-- rolldown 包:"; ls -d node_modules/.pnpm/rolldown@* 2>/dev/null | sed 's|.*/||'
echo "-- 已装绑定:"; ls -d node_modules/.pnpm/@rolldown+binding-android-arm64@* 2>/dev/null | sed 's|.*/||'
for v in $(ls -d node_modules/.pnpm/rolldown@* 2>/dev/null | sed 's|.*/rolldown@||'); do
  BIND="node_modules/.pnpm/@rolldown+binding-android-arm64@$v/node_modules/@rolldown/binding-android-arm64"
  DST="node_modules/.pnpm/rolldown@$v/node_modules/@rolldown/binding-android-arm64"
  mkdir -p "$(dirname "$DST")"
  rm -rf "$DST"
  if [ -d "$BIND" ]; then
    cp -a "$BIND" "$DST"
    echo "对齐 rolldown@$v -> 本地绑定 $v"
  else
    mkdir -p "$DST"
    if curl -fsSL "https://registry.npmjs.org/@rolldown/binding-android-arm64/-/binding-android-arm64-$v.tgz" | tar -xzf - --strip-components=1 -C "$DST"; then
      echo "下载 rolldown@$v -> 绑定 $v"
    else
      echo "跳过 rolldown@$v（无 $v 绑定）"
      rm -rf "$DST"
    fi
  fi
done
echo "== 清理悬空链接 =="
find node_modules -xtype l -print -delete 2>/dev/null | head -10
for d in node_modules/.pnpm/@rolldown+binding-android-arm64@*; do
  [ -d "$d/node_modules/@rolldown/binding-android-arm64" ] || rm -rf "$d"
done
ls -ld node_modules/.pnpm/@rolldown+binding-android-arm64@* 2>&1 | head -3
echo "bin 数量: $(ls node_modules/.bin 2>/dev/null | wc -l)"
fix_shim() {
  sed -i "1s|^#!/bin/sh$|#!$PREFIX/bin/sh|; 1s|^#!/bin/bash$|#!$PREFIX/bin/bash|; 1s|^#!/usr/bin/env node$|#!$PREFIX/bin/node|; 1s|^#!/usr/bin/env bash$|#!$PREFIX/bin/bash|; 1s|^#!/usr/bin/env sh$|#!$PREFIX/bin/sh|" "$1"
}
for f in node_modules/.bin/*; do [ -f "$f" ] && fix_shim "$f"; done
find node_modules -type d -name .bin 2>/dev/null | while read -r d; do
  for f in "$d"/*; do [ -f "$f" ] && fix_shim "$f"; done
done
for f in node_modules/.bin/*; do
  b=$(basename "$f")
  [ "$b" = "vite" ] && continue
  [ -e "$PREFIX/bin/$b" ] || ln -s "$PWD/$f" "$PREFIX/bin/$b"
done
head -1 node_modules/.bin/tsx
echo "== vite 解析 =="
node -e "console.log('root vite =', require('vite/package.json').version)" 2>&1 | head -2
(cd apps/web && node -e "console.log('apps/web vite =', require('vite/package.json').version)" 2>&1 | head -2)
ls -l apps/web/node_modules/.bin/vite 2>&1 | head -1
V6=$(ls -d node_modules/.pnpm/vite@6.4.3*/node_modules/vite 2>/dev/null | head -1)
echo "vite6 目录: ${V6:-无}"
if [ -n "$V6" ]; then
  mkdir -p apps/web/node_modules/.bin
  rm -f apps/web/node_modules/.bin/vite
  cat > apps/web/node_modules/.bin/vite <<VITE_EOF
#!$PREFIX/bin/sh
exec "$PREFIX/bin/node" "$PWD/$V6/bin/vite.js" "\$@"
VITE_EOF
  chmod +x apps/web/node_modules/.bin/vite
  echo "已强制 apps/web vite -> $V6"
  cat apps/web/node_modules/.bin/vite
fi
PATH="$PWD/apps/web/node_modules/.bin:$PATH" DSH_GATE_CONCURRENCY=1 NODE_OPTIONS=--max-old-space-size=2048 pnpm run build:artifacts --profile official

echo "== 打包 =="
REPO="$SRC" WORK=/builder/dist bash /builder/scripts/build-all.sh --skip-install --only=deb --version="$VER"

ls -l /builder/dist
INNER

ls -l "$ROOT/dist"/*.deb
