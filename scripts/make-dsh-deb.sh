#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

REPO="${REPO:-/data/data/com.termux/files/home/deepseek-harness}"
VERSION="${1:-0.2.1-alpha.5}"
ARCH="aarch64"
WORK="${WORK:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)/dist}"
PKG="$WORK/pkg"
PAYLOAD_REL="data/data/com.termux/files/usr/lib/dsh"
LAUNCHER_MODE="${LAUNCHER_MODE:-A}"
case "$LAUNCHER_MODE" in
  A) LAUNCHER_REL="data/data/com.termux/files/usr/bin/dsh";        EXTRA_LAUNCHER_REL="" ;;
  B) LAUNCHER_REL="data/data/com.termux/files/usr/bin/dsh-bundle"; EXTRA_LAUNCHER_REL="" ;;
  C) LAUNCHER_REL="data/data/com.termux/files/usr/bin/dsh";        EXTRA_LAUNCHER_REL="data/data/com.termux/files/usr/bin/dsh-bundle" ;;
  *) echo "LAUNCHER_MODE 只能是 A / B / C（当前: $LAUNCHER_MODE）" >&2; exit 2 ;;
esac
OUT="$WORK/dsh_${VERSION}_${ARCH}.deb"

echo "== 清理旧的 staging =="
rm -rf "$PKG" "$OUT"
mkdir -p "$PKG/DEBIAN" "$PKG/$PAYLOAD_REL" "$PKG/$(dirname "$LAUNCHER_REL")"

echo "== 复制仓库（排除 .git 与临时垃圾） =="
tar -C "$REPO" --hard-dereference \
  --exclude='./.git' \
  --exclude='./apps/cli/lib-bundle' \
  --exclude='./apps/cli/tsdown.bundle.config.ts' \
  --exclude='./.v4fix-tmp' \
  --exclude='./_repair' \
  --exclude='*.bak' \
  --exclude='*.bak2' \
  --exclude='*.bak3' \
  --exclude='*.dshpurge.bak' \
  --exclude='./rg-output.txt' \
  --exclude='./node_modules/.cache' \
  --exclude='./node_modules/.pnpm/@rolldown+binding-android-arm64@*' \
  --exclude='./packages/session/session-persistence-jsonl/_*.mts' \
  --exclude='./.agents' \
  --exclude='./docs' \
  --exclude='./snapshots' \
  --exclude='./benchmarks' \
  --exclude='./website' \
  --exclude='./python' \
  --exclude='./.github' \
  --exclude='./apps/desktop' \
  --exclude='./*.tsbuildinfo' \
  --exclude='*.spec.ts' \
  --exclude='*.spec.tsx' \
  --exclude='*.spec.mjs' \
  --exclude='*.test.ts' \
  --exclude='*.test.tsx' \
  --exclude='*/tests' \
  --exclude='*.map' \
  --exclude='./node_modules/.pnpm/mermaid@*' \
  --exclude='./node_modules/.pnpm/@mermaid-js+*' \
  --exclude='./node_modules/.pnpm/chrome-devtools-frontend@*' \
  --exclude='./node_modules/.pnpm/playwright@*' \
  --exclude='./node_modules/.pnpm/playwright-core@*' \
  --exclude='./node_modules/.pnpm/electron-winstaller@*' \
  --exclude='./node_modules/.pnpm/electron@*' \
  --exclude='./node_modules/.pnpm/@rolldown+*' \
  --exclude='./node_modules/.pnpm/rolldown@*' \
  --exclude='./node_modules/.pnpm/tsdown@*' \
  --exclude='./node_modules/.pnpm/happy-dom@*' \
  --exclude='./node_modules/.pnpm/jsdom@*' \
  --exclude='./node_modules/.pnpm/@oxlint+*' \
  --exclude='./node_modules/.pnpm/oxlint@*' \
  --exclude='./node_modules/.pnpm/jscpd@*' \
  --exclude='./node_modules/.pnpm/pnpm@*' \
  --exclude='./node_modules/mermaid' \
  --exclude='./node_modules/chrome-devtools-frontend' \
  --exclude='./node_modules/playwright' \
  --exclude='./node_modules/playwright-core' \
  --exclude='./node_modules/electron-winstaller' \
  --exclude='./node_modules/@mermaid-js' \
  --exclude='./node_modules/@rolldown' \
  --exclude='./node_modules/@oxlint' \
  --exclude='./node_modules/happy-dom' \
  --exclude='./node_modules/jsdom' \
  --exclude='./node_modules/pnpm' \
  -cf - . | tar -C "$PKG/$PAYLOAD_REL" -xf -

echo "== 写入 launcher =="
cat > "$PKG/$LAUNCHER_REL" <<'LAUNCHER'
if [ -z "${DSH_HOME:-}" ]; then
  _dsh_shim_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
  for _dsh_rel in "$_dsh_shim_dir/.dsh" "$_dsh_shim_dir/../.dsh" "$_dsh_shim_dir/../../.dsh"; do
    if [ -d "$_dsh_rel" ]; then DSH_HOME=$(CDPATH= cd -- "$_dsh_rel" && pwd); export DSH_HOME; break; fi
  done
  unset _dsh_shim_dir _dsh_rel
fi
export NODE_OPTIONS="--max-old-space-size=4096"
export NODE_COMPILE_CACHE="${HOME}/.cache/dsh-compile"
DSH_ROOT="/data/data/com.termux/files/usr/lib/dsh"
cd "$DSH_ROOT"
if [ "${DSH_USE_SOURCE:-0}" != "1" ] && [ -f "$DSH_ROOT/apps/cli/lib/bin.js" ]; then
  exec node "$DSH_ROOT/apps/cli/lib/bin.js" "$@"
fi
exec ./node_modules/.bin/tsx apps/cli/src/bin.ts "$@"
LAUNCHER
chmod 755 "$PKG/$LAUNCHER_REL"
if [ -n "$EXTRA_LAUNCHER_REL" ]; then
  cp "$PKG/$LAUNCHER_REL" "$PKG/$EXTRA_LAUNCHER_REL"
  chmod 755 "$PKG/$EXTRA_LAUNCHER_REL"
  echo "== launcher: 同时安装 /usr/bin/dsh 与 /usr/bin/dsh-bundle =="
else
  echo "== launcher: 仅安装 /usr/bin/$(basename "$LAUNCHER_REL") =="
fi

echo "== 写入 control =="
cat > "$PKG/DEBIAN/control" <<CONTROL
Package: dsh
Version: $VERSION
Architecture: $ARCH
Maintainer: Termux local build <dsh@localhost>
Section: utils
Priority: optional
Depends: nodejs-lts | nodejs, bash
Recommends: libvips (>= 8.18.7), libc++
Description: DeepSeek Harness (dsh) with bundled build artifacts and node_modules
 Self-contained dsh distribution for Termux aarch64: ships the deepseek-harness
 source tree together with its build outputs and node_modules, plus a
 /usr/bin/dsh launcher. Node is the only hard requirement (nodejs-lts or nodejs);
 image processing additionally uses the system libvips (>= 8.18.7) and libc++.
CONTROL
chmod 755 "$PKG/DEBIAN"
chmod 644 "$PKG/DEBIAN/control"

echo "== staging 冒烟测试（裁剪后仍能启动） =="
( cd "$PKG/$PAYLOAD_REL" && timeout 300 ./node_modules/.bin/tsx apps/cli/src/bin.ts --version ) || {
  echo "!! staging 冒烟测试失败，终止打包"; exit 1; }

echo "== 打包 =="
dpkg-deb --build --root-owner-group "$PKG" "$OUT"

echo "== 结果 =="
ls -lh "$OUT"
du -sh "$PKG/$PAYLOAD_REL"
dpkg-deb -I "$OUT" | head -18
