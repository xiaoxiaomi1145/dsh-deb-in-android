#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$SELF_DIR/.." && pwd)
OUT="${1:-$ROOT/dsh-all-patches.sh}"

FILES=("scripts/apply-all-patches.sh")
if [ -f "$ROOT/scripts/patch-pentest.sh" ]; then FILES+=("scripts/patch-pentest.sh"); fi
for f in "$ROOT"/patches/*.patch "$ROOT"/patches/MANIFEST.txt "$ROOT"/patches/addon/*.patch "$ROOT"/env/*; do
  if [ -f "$f" ]; then FILES+=("${f#"$ROOT"/}"); fi
done

{
  printf '#!/data/data/com.termux/files/usr/bin/bash\n'
  cat <<'HEADER'
set -euo pipefail

SELF=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/$(basename -- "$0")
TMP=$(mktemp -d "${TMPDIR:-${PREFIX:-/data/data/com.termux/files/usr}/tmp}/dsh-patches.XXXXXX")
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT
mkdir -p "$TMP/scripts" "$TMP/patches/addon" "$TMP/env"
HEADER

  i=0
  for rel in "${FILES[@]}"; do
    i=$((i+1))
    d="DSH_EOF_${i}"
    while grep -qxF "$d" "$ROOT/$rel"; do d="${d}_x"; done
    printf 'cat > "$TMP/%s" <<%s\n' "$rel" "'$d'"
    cat "$ROOT/$rel"
    printf '%s\n' "$d"
  done

  cat <<'FOOTER'

chmod +x "$TMP/scripts/"*.sh 2>/dev/null || true
set +e
bash "$TMP/scripts/apply-all-patches.sh" "$@"
rc=$?
set -e
exit $rc
FOOTER
} > "$OUT"

chmod +x "$OUT"
printf '已生成: %s\n大小  : %s\n文件数: %s\n' "$OUT" "$(du -h "$OUT" | cut -f1)" "${#FILES[@]}"
