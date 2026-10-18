#!/data/data/com.termux/files/usr/bin/bash
set -uo pipefail

REPO="${DSH_REPO:-/data/data/com.termux/files/home/deepseek-harness}"
SHARP_DIR="$REPO/node_modules/.pnpm/sharp@0.35.3_@types+node@22.20.0/node_modules/sharp"
GYP="$REPO/node_modules/.pnpm/node-gyp@12.4.0/node_modules/node-gyp/bin/node-gyp.js"
ADDON_API_SRC="${ADDON_API_SRC:-$HOME/sharp-build/node_modules/node-addon-api}"

log()  { printf '\033[36m[sharp-setup]\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m  ok\033[0m %s\n' "$*"; }
bad()  { printf '\033[31m  FAIL\033[0m %s\n' "$*"; }
warn() { printf '\033[33m  warn\033[0m %s\n' "$*"; }
die()  { bad "$*"; exit 1; }

locate_sharp() {
  if [ -d "$SHARP_DIR" ]; then return 0; fi
  local found
  found=$(find "$REPO/node_modules/.pnpm" -maxdepth 4 -type d -name sharp -path '*sharp@0.35*' 2>/dev/null | head -1)
  [ -n "$found" ] || return 1
  SHARP_DIR="$found"
  GYP=$(find "$REPO/node_modules/.pnpm" -maxdepth 6 -path '*node-gyp*/bin/node-gyp.js' 2>/dev/null | head -1)
  log "重新定位 sharp 安装目录: $SHARP_DIR"
}

sharp_version() { node -p "require('$SHARP_DIR/package.json').version" 2>/dev/null; }

artifact_path() {
  local ver; ver=$(sharp_version)
  echo "$SHARP_DIR/src/build/Release/sharp-android-arm64-${ver}.node"
}

check_prereqs() {
  log "检查前置条件"
  local vips_ver
  vips_ver=$(pkg-config --modversion vips-cpp 2>/dev/null) || die "pkg-config 找不到 vips-cpp（libvips 未安装或 PKG_CONFIG_PATH 未设）"
  ok "libvips-cpp $vips_ver"
  node -e "
    const need=require('$SHARP_DIR/package.json').config.libvips.replace(/[^0-9.]/g,'');
    const n=need.split('.').map(Number), g='$vips_ver'.split('.').map(Number);
    const seriesCmp=(n[0]-g[0])||(n[1]-g[1]);
    if(seriesCmp>0){console.error('libvips $vips_ver 次版本低于要求 '+need);process.exit(1)}
    if(((n[2]||0)-(g[2]||0))>0){console.error('libvips $vips_ver 补丁号低于要求 '+need);process.exit(2)}
  "; gate=$?
  [ "$gate" -eq 1 ] && die "libvips 版本低于 sharp 要求（次版本不足）"
  [ "$gate" -eq 2 ] && warn "libvips 补丁号低于 sharp 要求，按 ABI 兼容继续"
  ok "版本检查通过（$vips_ver）"

  [ -f "$SHARP_DIR/src/binding.gyp" ] || die "找不到 $SHARP_DIR/src/binding.gyp"
  [ -f "$GYP" ] || die "找不到 node-gyp: $GYP"
  ok "node-gyp 就位"
  command -v c++filt >/dev/null || die "缺少 c++filt（binding.gyp 用它探测 libstdc++ ABI）"
  ok "c++filt 就位"

  local addon_ok=0
  if (cd "$SHARP_DIR" && node -e "
    const [maj, min] = require('node-addon-api/package.json').version.split('.').map(Number);
    process.exit(maj > 8 || (maj === 8 && min >= 9) ? 0 : 1);
  ") >/dev/null 2>&1; then addon_ok=1; fi

  if [ "$addon_ok" -eq 0 ]; then
    if [ ! -d "$ADDON_API_SRC" ]; then
      warn "补装源缺失，临时安装 node-addon-api"
      mkdir -p "$(dirname "$(dirname "$ADDON_API_SRC")")"
      npm install --prefix "$(dirname "$(dirname "$ADDON_API_SRC")")" node-addon-api@8.9.0 --no-save >/dev/null 2>&1 || die "node-addon-api 安装失败"
    fi
    warn "node-addon-api 缺失或版本低于 ^8.9.0，从 $ADDON_API_SRC 补装"
    [ -d "$ADDON_API_SRC" ] || die "补装源不存在: $ADDON_API_SRC"
    mkdir -p "$SHARP_DIR/node_modules"
    rm -rf "$SHARP_DIR/node_modules/node-addon-api"
    cp -r "$ADDON_API_SRC" "$SHARP_DIR/node_modules/" || die "复制 node-addon-api 失败"
  fi
  ok "node-addon-api $(cd "$SHARP_DIR" && node -p "require('node-addon-api/package.json').version")"
}

verify_runtime() {
  node -e "
    const sharp = require('$SHARP_DIR');
    sharp({ create: { width: 8, height: 8, channels: 3, background: { r: 200, g: 30, b: 60 } } })
      .png().toBuffer()
      .then(buf => sharp(buf).resize(4, 4).raw().toBuffer())
      .then(raw => {
        if (raw.length !== 4 * 4 * 3) throw new Error('raw 长度异常: ' + raw.length);
        process.exit(0);
      })
      .catch(e => { console.error(e.message); process.exit(1); });
  " >/dev/null 2>&1
}

do_build() {
  locate_sharp || die "在 $REPO 中找不到 sharp 安装目录"
  log "sharp 版本 $(sharp_version) @ $SHARP_DIR"
  check_prereqs

  local art; art=$(artifact_path)
  if [ "${1:-}" != "force" ] && [ -f "$art" ]; then
    if verify_runtime; then
      ok "已存在可用产物，跳过编译：$art"
      return 0
    fi
    warn "产物存在但无法加载，重新编译"
  fi

  log "开始编译（--directory=src，与 sharp 官方 install/build.js 一致）"
  ( cd "$SHARP_DIR" && SHARP_FORCE_GLOBAL_LIBVIPS=true node "$GYP" rebuild --directory=src --jobs="${SHARP_JOBS:-2}" ) 2>&1 | tail -20
  local st=${PIPESTATUS[0]}
  [ "$st" -eq 0 ] || die "编译失败（exit $st）"

  art=$(artifact_path)
  [ -f "$art" ] || die "编译结束但找不到产物：$art"
  ok "产物已生成 $(stat -c '%s' "$art") 字节"

  verify_runtime || die "产物无法被 node 加载"
  ok "运行时验证通过"
}

do_check() {
  locate_sharp || die "找不到 sharp 安装目录"
  log "sharp 版本 $(sharp_version)"
  local art; art=$(artifact_path)
  if [ -f "$art" ]; then
    ok "产物存在 $(stat -c '%s' "$art") 字节"
    if verify_runtime; then ok "可加载且图像处理正常"; else bad "存在但无法加载"; fi
  else
    bad "产物缺失：$art"
  fi
  if (cd "$SHARP_DIR" && node -e "
    const [maj, min] = require('node-addon-api/package.json').version.split('.').map(Number);
    process.exit(maj > 8 || (maj === 8 && min >= 9) ? 0 : 1);
  ") >/dev/null 2>&1; then
    ok "node-addon-api $(cd "$SHARP_DIR" && node -p "require('node-addon-api/package.json').version") 满足 ^8.9.0"
  else
    warn "node-addon-api 缺失或版本过低（pnpm install 后需重跑 build）"
  fi
}

do_verify() {
  locate_sharp || die "找不到 sharp 安装目录"
  log "运行时验证"
  node -e "
    const sharp = require('$SHARP_DIR');
    (async () => {
      const src = await sharp({ create: { width: 64, height: 48, channels: 3, background: { r: 220, g: 40, b: 90 } } }).png().toBuffer();
      const meta = await sharp(src).metadata();
      const jpg = await sharp(src).resize(16, 12).jpeg({ quality: 80 }).toBuffer();
      const raw = await sharp(src).raw().toBuffer();
      const back = await sharp(await sharp(raw, { raw: { width: 64, height: 48, channels: 3 } }).png().toBuffer()).raw().toBuffer();
      const px = await sharp(src).resize(1, 1, { fit: 'fill' }).raw().toBuffer();
      const webp = await sharp(src).rotate(90).extract({ left: 0, top: 0, width: 10, height: 10 }).webp().toBuffer();
      const checks = [
        ['metadata', meta.format === 'png' && meta.width === 64 && meta.height === 48],
        ['resize+JPEG', jpg.subarray(0, 2).toString('hex') === 'ffd8'],
        ['raw 往返一致', Buffer.compare(raw, back) === 0],
        ['像素取值 220,40,90', px[0] === 220 && px[1] === 40 && px[2] === 90],
        ['rotate+extract+webp', webp.subarray(0, 4).toString() === 'RIFF'],
      ];
      let fail = 0;
      for (const c of checks) { console.log((c[1] ? '  ok   ' : '  FAIL ') + c[0]); if (!c[1]) fail++; }
      console.log('  versions: vips=' + sharp.versions.vips + ' sharp=' + sharp.versions.sharp);
      process.exit(fail ? 1 : 0);
    })().catch(e => { console.error('  FAIL ' + e.message); process.exit(1); });
  "
}

case "${1:-check}" in
  check)  do_check ;;
  build)  do_build ;;
  force)  do_build force ;;
  verify) do_verify ;;
  *) echo "用法: $0 {check|build|force|verify}" >&2; exit 2 ;;
esac
