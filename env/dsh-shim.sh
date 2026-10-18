#!/bin/bash
if [ -z "${DSH_HOME:-}" ]; then
  _dsh_shim_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
  for _dsh_rel in "$_dsh_shim_dir/.dsh" "$_dsh_shim_dir/../.dsh" "$_dsh_shim_dir/../../.dsh"; do
    if [ -d "$_dsh_rel" ]; then DSH_HOME=$(CDPATH= cd -- "$_dsh_rel" && pwd); export DSH_HOME; break; fi
  done
  unset _dsh_shim_dir _dsh_rel
fi

export PATH="$HOME/.local/bin:$PATH"
export NODE_OPTIONS="--max-old-space-size=4096"
export NODE_COMPILE_CACHE="$HOME/.cache/dsh-compile"
export DSH_TELEMETRY_DISABLED="${DSH_TELEMETRY_DISABLED-1}"

PROJECT_DIR="${DSH_PROJECT_DIR:-$HOME/deepseek-harness}"

cd "$PROJECT_DIR" || { echo "dsh: 项目目录不存在: $PROJECT_DIR" >&2; exit 1; }

if [ "${DSH_USE_SOURCE:-0}" != "1" ] && [ -f "$PROJECT_DIR/apps/cli/lib/bin.js" ]; then
  exec node "$PROJECT_DIR/apps/cli/lib/bin.js" "$@"
fi
exec ./node_modules/.bin/tsx apps/cli/src/bin.ts "$@"
