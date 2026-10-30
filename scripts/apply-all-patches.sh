#!/data/data/com.termux/files/usr/bin/bash
set -uo pipefail

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PATCH_DIR="$SELF_DIR/../patches"
REPO="${DSH_REPO:-$HOME/deepseek-harness}"
MODE=apply
WITH_ENV=0
WITH_SHIM=0
FORCE=0
SKIP=""

die() { echo "错误: $*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)     REPO="${2:?}"; shift 2 ;;
    --check)    MODE=check; shift ;;
    --with-env) WITH_ENV=1; shift ;;
    --shim)     WITH_SHIM=1; shift ;;
    --force)    FORCE=1; shift ;;
    --skip)     SKIP=",$(echo "${2:?}" | tr ',' ' ' | tr ' ' ',')"; shift 2 ;;
    -h|--help)
      echo "用法: apply-all-patches.sh [--repo DIR] [--check] [--with-env] [--shim] [--skip 07,08] [--force]"
      exit 0 ;;
    *)          die "未知参数: $1（--help 查看用法）" ;;
  esac
done

[ -e "$REPO/.git" ] || die "不是 git 仓库: $REPO"
[ -d "$PATCH_DIR" ] || die "找不到补丁目录: $PATCH_DIR"
command -v git >/dev/null || die "缺少 git"

MANIFEST="$PATCH_DIR/MANIFEST.txt"
BASE_TAG=""; BASE_COMMIT=""
if [ -f "$MANIFEST" ]; then
  BASE_TAG=$(sed -n 's/^base_tag=//p' "$MANIFEST")
  BASE_COMMIT=$(sed -n 's/^base_commit=//p' "$MANIFEST")
fi

CUR_COMMIT=$(git -C "$REPO" rev-parse HEAD 2>/dev/null) || die "无法读取 HEAD"
say "仓库  : $REPO"
say "当前  : $(git -C "$REPO" describe --tags --always 2>/dev/null || echo "$CUR_COMMIT")"
say "基线  : ${BASE_TAG:-未知} ${BASE_COMMIT:+(${BASE_COMMIT:0:12})}"
say "模式  : $([ "$MODE" = check ] && echo '仅校验' || echo '应用')"
say ""

if [ -n "$BASE_COMMIT" ] && [ "$CUR_COMMIT" != "$BASE_COMMIT" ]; then
  say "⚠ 当前 HEAD 与补丁基线不一致（补丁按上下文 3-way 合并，可能需要手工解冲突）"
  if [ "$FORCE" -ne 1 ]; then
    say "  确认要继续请加 --force；或先 checkout 到基线："
    say "    git -C \"$REPO\" checkout ${BASE_TAG:-$BASE_COMMIT}"
    exit 3
  fi
  say ""
fi

applied=0; skipped=0; failed=0; failed_list=""

if [ -n "$BASE_TAG" ] && [ -n "$BASE_COMMIT" ] && ! git -C "$REPO" cat-file -e "${BASE_COMMIT}^{commit}" 2>/dev/null; then
  say "补全基线对象（3-way 合并需要）：$BASE_TAG"
  if git -C "$REPO" fetch -q --depth 1 origin "+refs/tags/$BASE_TAG:refs/tags/$BASE_TAG" 2>/dev/null; then
    say "  ok  基线对象已就位"
  else
    say "  --  基线对象不可得（离线或标签缺失），将改用宽松方式应用"
  fi
  say ""
fi

E=$(mktemp "${TMPDIR:-$PREFIX/tmp}/dsh-patch.XXXXXX") || die "无法创建临时文件"
BAK=$(mktemp -d "${TMPDIR:-$PREFIX/tmp}/dsh-bak.XXXXXX") || die "无法创建备份目录"

patch_files() { sed -n 's|^diff --git a/.* b/||p' "$1"; }

snapshot() {
  local p="$1" out="$2" f
  rm -rf "$out"; mkdir -p "$out"
  patch_files "$p" | while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ -f "$REPO/$f" ]; then
      mkdir -p "$out/$(dirname "$f")"
      cp -p "$REPO/$f" "$out/$f"
    else
      mkdir -p "$out/$(dirname "$f")"
      : > "$out/$f.absent"
    fi
  done
}

restore() {
  local p="$1" bak="$2" f
  patch_files "$p" | while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ -f "$bak/$f" ]; then cp -p "$bak/$f" "$REPO/$f"; else rm -f "$REPO/$f"; fi
    rm -f "$REPO/$f.rej" "$REPO/$f.orig"
  done
  git -C "$REPO" reset -q 2>/dev/null || true
}

verify() {
  local unmerged
  unmerged=$(git -C "$REPO" diff --name-only --diff-filter=U 2>/dev/null)
  [ -z "$unmerged" ] || return 1
  command -v python3 >/dev/null 2>&1 || return 0
  python3 "$SELF_DIR/verify-patch.py" --repo "$REPO" --patch "$1" >"$E" 2>&1
}

try_level() {
  local lvl="$1" p="$2" unmerged rc
  case "$lvl" in
    1)
      git -C "$REPO" apply --3way "$p" >"$E" 2>&1
      rc=$?
      unmerged=$(git -C "$REPO" diff --name-only --diff-filter=U 2>/dev/null)
      if [ -n "$unmerged" ]; then
        if command -v python3 >/dev/null 2>&1 && python3 "$SELF_DIR/auto-merge.py" --repo "$REPO" >>"$E" 2>&1; then
          return 0
        fi
        return 1
      fi
      [ "$rc" -eq 0 ] && return 0
      return 1 ;;
    2) git -C "$REPO" apply -C1 --recount --ignore-whitespace "$p" >"$E" 2>&1 ;;
    3) ( cd "$REPO" && patch -p1 --forward --batch --fuzz=3 --no-backup-if-mismatch < "$p" >"$E" 2>&1 ) ;;
    4) python3 "$SELF_DIR/apply-fallback.py" --repo "$REPO" --group "$(basename "$p" .patch)" >"$E" 2>&1 ;;
    *) return 1 ;;
  esac
}

for p in "$PATCH_DIR"/*.patch; do
  [ -e "$p" ] || continue
  name=$(basename "$p" .patch)
  num="${name%%-*}"
  case "$SKIP" in *",$num,"*) say "  --  $name  跳过(--skip)"; skipped=$((skipped+1)); continue ;; esac

  if git -C "$REPO" apply -R --check "$p" >/dev/null 2>&1; then
    say "  ok  $name  （已应用，跳过）"
    skipped=$((skipped+1)); continue
  fi

  if [ "$MODE" = check ]; then
    if git -C "$REPO" apply --check "$p" >/dev/null 2>&1 || git -C "$REPO" apply --check --cached "$p" >/dev/null 2>&1; then
      say "  ok  $name  可应用"
      applied=$((applied+1))
    elif git -C "$REPO" apply -C1 --recount --ignore-whitespace --check "$p" >/dev/null 2>&1; then
      say "  ok  $name  可应用"
      applied=$((applied+1))
    elif [ -f "$SELF_DIR/apply-fallback.py" ] && python3 "$SELF_DIR/apply-fallback.py" --list 2>/dev/null | tr ' ' '\n' | grep -qx "$num"; then
      say "  ok  $name  可应用"
      applied=$((applied+1))
    else
      say "  !!  $name  无法应用"
      failed=$((failed+1)); failed_list="$failed_list $name"
    fi
    continue
  fi

  done_ok=0
  for lvl in 1 2 3 4; do
    if [ "$lvl" = 4 ] && [ ! -f "$SELF_DIR/apply-fallback.py" ]; then continue; fi
    snapshot "$p" "$BAK/snap"
    if try_level "$lvl" "$p"; then
      if verify "$p"; then
        case "$lvl" in
          1) say "  ok  $name  已应用" ;;
          2) say "  ok  $name  已应用" ;;
          3) say "  ok  $name  已应用" ;;
          4) say "  ok  $name  已应用" ;;
        esac
        applied=$((applied+1)); done_ok=1; break
      fi
      say "      $name L$lvl 应用后校验未通过，回滚重试" >&2
    fi
    restore "$p" "$BAK/snap"
  done

  if [ "$done_ok" -ne 1 ]; then
    say "  !!  $name  无法应用或校验失败：$(tail -3 "$E" | tr '\n' ' ')"
    failed=$((failed+1)); failed_list="$failed_list $name"
  fi
done
rm -rf "$BAK" "$E"

say ""
say "补丁结果: 应用 $applied / 跳过 $skipped / 失败 $failed"
if [ "$MODE" = apply ] && [ "$applied" -gt 0 ]; then
  say "提示: --3way 会把改动放进暂存区；想恢复成普通未暂存改动，执行 git -C \"$REPO\" reset -q"
fi
if [ "$failed" -gt 0 ]; then
  say "失败补丁:$failed_list"
  say "处理建议: git -C \"$REPO\" status 查看冲突；解决后 git add，再重跑本脚本（已应用的会自动跳过）。"
fi

if [ "$WITH_ENV" -eq 1 ]; then
  say ""
  say "== 环境补丁 =="

  PENTEST="$HOME/.dsh/profiles/web/node_modules/@howmp/dsh-pentest/lib/pentest.js"
  if [ -f "$PENTEST" ]; then
    if bash "$SELF_DIR/patch-pentest.sh" 2>&1 | sed 's/^/  /'; then :; else say "  !! pentest 补丁失败"; fi
  else
    say "  --  pentest 插件未安装，跳过"
  fi

  if node "$SELF_DIR/../env/billion-context-warm0.mjs" 2>&1 | sed 's/^/  /'; then :; else say "  !! billion-context 配置失败"; fi

  NPMRC="$HOME/.npmrc"
  touch "$NPMRC"
  ensure_npmrc() {
    local k="$1" v="$2"
    if grep -qE "^${k}=" "$NPMRC" 2>/dev/null; then
      sed -i "s|^${k}=.*|${k}=${v}|" "$NPMRC"
    else
      printf '%s=%s\n' "$k" "$v" >> "$NPMRC"
    fi
  }
  ensure_npmrc pm-on-fail ignore
  ensure_npmrc node-linker hoisted
  ensure_npmrc prefer-offline true
  ensure_npmrc packageImportMethod copy
  say "  ok  ~/.npmrc 关键项已就位（pm-on-fail/node-linker/prefer-offline/packageImportMethod）"

  if [ -x "$HOME/.local/bin/pnpm" ]; then
    say "  ok  pnpm 12 包装器存在: $("$HOME/.local/bin/pnpm" --version 2>/dev/null)"
  else
    say "  --  未检测到 ~/.local/bin/pnpm（pnpm 12），参考 pnpm12-setup.md 安装"
  fi

  SHIM=/data/data/com.termux/files/usr/bin/dsh
  if [ "$WITH_SHIM" -eq 1 ]; then
    if [ -f "$SHIM" ] && ! cmp -s "$SELF_DIR/env/dsh-shim.sh" "$SHIM"; then
      cp -f "$SHIM" "$SHIM.bak-$(date +%Y%m%d-%H%M%S)"
      say "  已备份原 shim"
    fi
    install -m 755 "$SELF_DIR/env/dsh-shim.sh" "$SHIM" && say "  ok  已安装 shim: $SHIM"
  elif [ -f "$SHIM" ]; then
    say "  --  shim 已存在（如需覆盖：--shim）"
  else
    say "  --  未安装 shim（需要时加 --shim）"
  fi
fi

say ""
NEXT_BUILD="$SELF_DIR/build-all.sh"
[ -f "$NEXT_BUILD" ] || NEXT_BUILD="$SELF_DIR/build-all.sh"
if [ -f "$NEXT_BUILD" ]; then
  say "下一步: cd \"$REPO\" && pnpm install --frozen-lockfile && bash \"$NEXT_BUILD\""
else
  say "下一步: cd \"$REPO\" && pnpm install --frozen-lockfile && pnpm run build:artifacts --profile official"
fi
exit $([ "$failed" -gt 0 ] && echo 1 || echo 0)
