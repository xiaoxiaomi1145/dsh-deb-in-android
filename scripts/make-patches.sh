#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

REPO="${REPO:-/data/data/com.termux/files/home/deepseek-harness}"
OUT="${OUT:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)/patches}"

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --out)  OUT="$2";  shift 2 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

[ -e "$REPO/.git" ] || { echo "不是 git 仓库: $REPO" >&2; exit 1; }
mkdir -p "$OUT"
rm -f "$OUT"/*.patch

BASE_TAG="$(git -C "$REPO" describe --tags --always)"
BASE_COMMIT="$(git -C "$REPO" rev-parse HEAD)"

emit() { # emit <name> <desc> <paths...>
  local name="$1" desc="$2"; shift 2
  local file="$OUT/$name.patch"
  git -C "$REPO" diff --no-color --binary -- "$@" > "$file"
  if [ -s "$file" ]; then
    local n; n=$(grep -c '^diff --git' "$file")
    printf '  %-28s %2d 个文件  %6d 字节  %s\n' "$name" "$n" "$(stat -c%s "$file")" "$desc"
  else
    rm -f "$file"; printf '  %-28s (无改动，跳过)\n' "$name"
  fi
}

echo "仓库: $REPO"
echo "基线: $BASE_TAG ($BASE_COMMIT)"
echo "输出: $OUT"
echo

emit 01-plugin-manager-hang "dsh plugin 安装/卸载卡死修复" \
  apps/cli/src/plugin.ts \
  packages/boot/plugin-manager/src/operations.ts \
  packages/boot/plugin-manager/tests/operations.spec.ts

emit 02-telemetry-rows "遥测行默认禁用" \
  packages/boot/app-boot/src/profile-context.ts \
  packages/boot/app-boot/src/index.ts \
  packages/boot/app-boot/tests/app-boot.spec.ts \
  apps/cli/tests/telemetry-switch.spec.ts

emit 03-termux-fs "Termux 文件系统兼容（link 回退 / rg PATH 回退）" \
  packages/fs/fs-local/src/fsio.ts \
  packages/fs/fs-local/tests/fsio.spec.ts \
  packages/fs/tool-fs-search/src/search-core.ts \
  packages/fs/tool-fs-search/tests/rg-path.spec.ts \
  packages/fs/tool-fs-search/tests/tools.spec.ts

emit 04-session-jsonl "会话日志 Termux 兼容（rename/generation）" \
  packages/session/session-persistence-jsonl/src/index.ts \
  packages/session/session-persistence-jsonl/src/generation.ts

emit 05-native-android "native/system Android aarch64 构建与 flock" \
  native/system/packages/entry/src/flock.ts \
  native/system/packages/entry/src/index.ts \
  native/system/packages/linux-arm64/prebuilds.json \
  native/system/scripts/build.ts

emit 06-perf-misc "启动性能与杂项修复" \
  packages/attachment/attachment-local/src/store.ts \
  packages/attachment/attachment-local/tests/file-store.spec.ts \
  packages/core/agent-loop/src/assistant-stream.ts \
  scripts/install-lefthook.mjs

emit 07-sharp-wasm32 "根依赖补 @img/sharp-wasm32（Android 无原生二进制时的回退）" \
  package.json

emit 08-lockfile "pnpm-lock.yaml" \
  pnpm-lock.yaml

emit 09-web-worker-context "apps/web 构建插件 getWatchFiles 兼容守卫" \
  apps/web/product-isolation.ts

emit 10-config-editor-composition "配置编辑器：每行配置只合并一次（N 次全量深拷贝 → 至多 2 次）" \
  packages/boot/config-editor/src/index.ts \
  packages/settings/settings/tests/configuration-inheritance.spec.ts


{
  echo "base_tag=$BASE_TAG"
  echo "base_commit=$BASE_COMMIT"
  echo "generated=$(date -Iseconds)"
  echo "repo=$REPO"
  echo
  for f in "$OUT"/*.patch; do
    printf '%s  %s  %s\n' "$(sha256sum "$f" | cut -d' ' -f1)" "$(basename "$f")" "$(grep -c '^diff --git' "$f") files"
  done
} > "$OUT/MANIFEST.txt"

echo
echo "MANIFEST.txt 已写入；共 $(ls -1 "$OUT"/*.patch | wc -l) 个补丁。"
