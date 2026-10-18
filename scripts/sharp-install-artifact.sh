#!/data/data/com.termux/files/usr/bin/bash
set -uo pipefail
CACHE="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)/sharp-artifacts"
ROOT=/data/data/com.termux/files/home/deepseek-harness/node_modules/.pnpm
TARGETS=("$@")
[ ${#TARGETS[@]} -gt 0 ] || TARGETS=(
  /data/data/com.termux/files/home/.dsh/profiles/web/node_modules/sharp
  /data/data/com.termux/files/home/.dsh/profiles/dsh-tui/node_modules/sharp
)
rc=0
for t in "${TARGETS[@]}"; do
  [ -d "$t" ] || { echo "跳过（不存在）: $t"; continue; }
  ver=$(node -p "require('$t/package.json').version" 2>/dev/null)
  [ -n "$ver" ] || { echo "无法读取版本: $t"; rc=1; continue; }
  name="sharp-android-arm64-$ver.node"
  if [ ! -f "$t/src/build/Release/$name" ]; then
    src=""
    for cand in "$CACHE/$name" $(ls "$ROOT"/sharp@"$ver"_*/node_modules/sharp/src/build/Release/"$name" 2>/dev/null); do
      [ -f "$cand" ] && { src="$cand"; break; }
    done
    [ -n "$src" ] || { echo "无可用产物（先跑 sharp-setup.sh build）: $t"; rc=1; continue; }
    mkdir -p "$t/src/build/Release" && cp -f "$src" "$t/src/build/Release/$name" && echo "已复制 $(basename "$src")"
  fi
  out=$( cd "$t/../.." && node -e "const s=require('sharp');console.log(s.versions.sharp+' | libvips '+s.versions.vips)" 2>&1 | tail -1 )
  echo "OK $t -> $out"
done
exit $rc
