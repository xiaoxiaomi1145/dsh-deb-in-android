#!/data/data/com.termux/files/usr/bin/bash
set -uo pipefail
DEB="${1:?deb path}"
SHIM_BACKUP="${2:?shim backup path}"
SHIM=/data/data/com.termux/files/usr/bin/dsh
PAYLOAD=/data/data/com.termux/files/usr/lib/dsh

echo "===== 1) apt install ./deb ====="
out=$(apt install -y "$DEB" 2>&1); rc=$?
echo "apt_rc=$rc"; echo "$out" | tail -8

echo "===== 2) dpkg 状态与文件 ====="
dpkg -l dsh 2>/dev/null | tail -2
ls -la "$SHIM" 2>&1 | head -2
head -3 "$SHIM" 2>/dev/null
du -sh "$PAYLOAD" 2>/dev/null
ls "$PAYLOAD" 2>/dev/null | head -8
echo "-- 补丁是否在包内 --"
echo "idleTimeoutMs: $(grep -c 'idleTimeoutMs' "$PAYLOAD/apps/cli/src/plugin.ts" 2>/dev/null)"
echo "termux-patch:  $(grep -c 'termux-patch' "$PAYLOAD/scripts/install-lefthook.mjs" 2>/dev/null)"
echo "isLinkPolicyDenied: $(grep -c 'isLinkPolicyDenied' "$PAYLOAD/packages/fs/fs-local/src/fsio.ts" 2>/dev/null)"
echo "tsx shim: $(ls "$PAYLOAD/node_modules/.bin/tsx" 2>/dev/null)"

echo "===== 3) 运行验证（deb 版 dsh） ====="
cd /data/data/com.termux/files/home
timeout 180 dsh --version 2>&1 | tail -5; echo "version_rc=$?"
timeout 120 dsh --help 2>&1 | head -10; echo "help_rc=$?"
timeout 240 dsh plugin --profile web list --depth 0 2>&1 | tail -12; echo "plugin_list_rc=$?"

echo "===== 4) 卸载 ====="
out=$(apt remove -y dsh 2>&1); rc=$?
echo "remove_rc=$rc"; echo "$out" | tail -6

echo "===== 5) 还原原 shim ====="
cp -a "$SHIM_BACKUP" "$SHIM"
echo "restored_sha=$(sha256sum "$SHIM" | cut -c1-16)"
ls -la "$SHIM"

echo "===== 6) 残留检查 ====="
ls -d "$PAYLOAD" 2>&1 | head -2
dpkg -l dsh 2>/dev/null | tail -1
echo "DONE"
