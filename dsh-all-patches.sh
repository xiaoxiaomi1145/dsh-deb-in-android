#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

SELF=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/$(basename -- "$0")
TMP=$(mktemp -d "${TMPDIR:-${PREFIX:-/data/data/com.termux/files/usr}/tmp}/dsh-patches.XXXXXX")
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT
mkdir -p "$TMP/scripts" "$TMP/patches/addon" "$TMP/env"
cat > "$TMP/scripts/apply-all-patches.sh" <<'DSH_EOF_1'
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

[ -d "$REPO/.git" ] || die "不是 git 仓库: $REPO"
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
E=$(mktemp "${TMPDIR:-$PREFIX/tmp}/dsh-patch.XXXXXX") || die "无法创建临时文件"

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
    if git -C "$REPO" apply --check --cached "$p" >/dev/null 2>"$E" || git -C "$REPO" apply --check "$p" >/dev/null 2>"$E"; then
      say "  ok  $name  可应用"
      applied=$((applied+1))
    else
      say "  !!  $name  无法应用：$(head -2 "$E" | tr '\n' ' ')"
      failed=$((failed+1)); failed_list="$failed_list $name"
    fi
    continue
  fi

  if git -C "$REPO" apply --3way "$p" >"$E" 2>&1; then
    say "  ok  $name  已应用"
    applied=$((applied+1))
  elif git -C "$REPO" apply --check "$p" >/dev/null 2>&1; then
    git -C "$REPO" apply "$p" >"$E" 2>&1 && { say "  ok  $name  已应用（直接）"; applied=$((applied+1)); } \
      || { say "  !!  $name  $(head -2 "$E" | tr '\n' ' ')"; failed=$((failed+1)); failed_list="$failed_list $name"; }
  else
    say "  !!  $name  冲突：$(head -3 "$E" | tr '\n' ' ')"
    failed=$((failed+1)); failed_list="$failed_list $name"
  fi
done
rm -f "$E"

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
DSH_EOF_1
cat > "$TMP/scripts/patch-pentest.sh" <<'DSH_EOF_2'
#!/usr/bin/env bash
set -euo pipefail
TARGET="${DSH_PENTEST_LIB:-$HOME/.dsh/profiles/web/node_modules/@howmp/dsh-pentest/lib/pentest.js}"
MARK='patched: synthetic tool/call events corrupt the parent session log'
if [ ! -f "$TARGET" ]; then
  echo "ERROR: target not found: $TARGET" >&2
  exit 1
fi
if grep -qF "$MARK" "$TARGET"; then
  echo "already patched: $TARGET"
  exit 0
fi
node - "$TARGET" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const src = fs.readFileSync(file, 'utf8')
const anchor = 'function appendSubmissionProjection(parent, intentId, facts, assets, findings) {\n  const append = parent.append.bind(parent);'
const replacement = 'function appendSubmissionProjection(parent, intentId, facts, assets, findings) {\n  return; // patched: synthetic tool/call events corrupt the parent session log (validator rejects pentest-submit-* callIds)\n  const append = parent.append.bind(parent);'
if (!src.includes(anchor)) {
  console.error("ERROR: anchor not found — plugin layout changed, do NOT blind-patch") 
  process.exit(1)
}
fs.writeFileSync(file, src.replace(anchor, replacement))
console.log('patched:', file)
NODE
DSH_EOF_2
cat > "$TMP/patches/01-plugin-manager-hang.patch" <<'DSH_EOF_3'
diff --git a/apps/cli/src/plugin.ts b/apps/cli/src/plugin.ts
index 86d0cc7525..50bd26287c 100644
--- a/apps/cli/src/plugin.ts
+++ b/apps/cli/src/plugin.ts
@@ -87,6 +87,13 @@ export async function runPlugin(profile: string, args: readonly string[], packag
     outputBytes: 16384,
     lockWaitMs: 120000,
     lookupTimeoutMs: 120000,
+    // Without a silence bound, a pnpm run that stops printing while it backs off a
+    // retry — an integrity mismatch on a floating tarball dependency is the usual
+    // one — holds this command forever with no output to explain why. The run is
+    // captured and forwarded through `onOutput`, so this bound can observe silence
+    // and terminate it. Generous because a cold install of a large profile can
+    // legitimately print nothing for minutes while it resolves.
+    idleTimeoutMs: 600000,
     onOutput: (text, stream) => { process[stream].write(text) },
   }
   const result = profile === 'desktop'
@@ -99,6 +106,17 @@ export async function runPlugin(profile: string, args: readonly string[], packag
   for (const { name, version, runtimeVersion } of result.incompatible ?? []) {
     process.stderr.write(`dsh: to accept the risk, run: dsh plugin --profile ${profile} allow-version ${name}@${version} --dsh-version ${runtimeVersion} --accept-risk\n`)
   }
+  // A terminated run already reported the silence and the bound through its own
+  // output, which `onOutput` forwarded above; repeating it here would double it.
+  // pnpm offers no flag that refreshes a mismatched checksum for a direct tarball
+  // dependency: --update-checksums, --no-frozen-lockfile, and --force were all
+  // measured to fail with ERR_PNPM_TARBALL_INTEGRITY, and deleting the integrity
+  // field is rejected outright by ERR_PNPM_MISSING_TARBALL_INTEGRITY. The lockfile
+  // entry is the only place the checksum can be corrected, so name the two lines
+  // that have to move together rather than suggest a command that cannot work.
+  if (result.kind === 'integrity') {
+    process.stderr.write(`dsh: pnpm refused a downloaded artifact whose checksum no longer matches the lockfile — a floating tarball or git dependency whose upstream moved. No pnpm flag corrects this: --update-checksums, --no-frozen-lockfile, and --force all fail the same way, and dropping the field is rejected as a missing checksum. Edit ${join(dir, 'pnpm-lock.yaml')} instead, changing the entry's "integrity" to the sha512 pnpm printed above as "Got" and its "version" to the release those contents carry — pnpm names it as "Actual package in the store" when the cached copy disagrees. Both lines must move together, because the store keys contents by version. Confirm the new contents are the release you intended before you edit.\n`)
+  }
   if (result.exitCode !== 0) process.stderr.write(`dsh: plugin command failed; diagnostics: ${result.logPath}\n`)
   if (result.exitCode !== 0 && args.some(argument => /^git\+|^github:|\.git(?:#|$)/.test(argument))) {
     process.stderr.write(`dsh: git-hosted plugins build on install via their prepare script, which pnpm blocks until allowed — add the exact key pnpm printed above under allowBuilds in ${join(resolveProfileDir(profile), 'pnpm-workspace.yaml')}, then re-run\n`)
diff --git a/packages/boot/plugin-manager/src/operations.ts b/packages/boot/plugin-manager/src/operations.ts
index b9a36d6083..c6939affc1 100644
--- a/packages/boot/plugin-manager/src/operations.ts
+++ b/packages/boot/plugin-manager/src/operations.ts
@@ -15,6 +15,7 @@ import { scrubbedParentEnv } from '@deepseek-ai/dsh-subprocess'
 import { parseInstallSpec } from './install-spec.ts'
 import { awaitTreeGone, leadsOwnGroup, treeAlive, type RunTree } from './run-tree.ts'
 import { incompatiblePlugin } from './failure.ts'
+import { classifyInstallFailure } from './install-failure.ts'
 import type { IncompatiblePlugin, PackageResult, Registry } from './types.ts'
 export { setProfileVersionExemption, readProfileVersionExemptions } from '@deepseek-ai/dsh-app-boot'
 
@@ -36,7 +37,7 @@ export interface PackageOperationOptions {
   args?: readonly string[]
   /** Application runtime environment, applied only to this package operation. */
   env?: Readonly<Record<string, string>>
-  /** CLI inherits authentication and terminal descriptors; service scrubs secrets and captures output. */
+  /** CLI keeps the caller's environment and terminal input; service scrubs secrets and takes no input. */
   execution: 'cli' | 'service'
   signal?: AbortSignal
   outputBytes: number
@@ -44,10 +45,9 @@ export interface PackageOperationOptions {
   activateNewBundles?: boolean
   lockWaitMs?: number
   /**
-   * Terminate the run once its captured output has been silent for this long, in
+   * Terminate the run once its output has been silent for this long, in
    * milliseconds. A run stopped this way reports `timedOut`; without a bound, a
-   * child that stops progressing without exiting holds its caller forever. A run
-   * with inherited descriptors captures nothing and is never bound.
+   * child that stops progressing without exiting holds its caller forever.
    */
   idleTimeoutMs?: number
   /** Bound on the pre-install registry lookup, in milliseconds; without one a fixed bound applies. */
@@ -279,7 +279,7 @@ function bundleComponentManifests(manifest: ProfileManifest, dir: string, anchor
  * @param args Pnpm arguments, before relative path anchoring.
  * @param options Output, activation and cancellation policy.
  * @returns Exit status, whether the silence bound stopped the run, and the diagnostic path.
- * A compatibility denial returns exit code 1. Service output is bounded; CLI output uses inherited descriptors.
+ * A compatibility denial returns exit code 1. Every run captures output; a CLI run forwards it through `onOutput`.
  * The diagnostic file is closed on return or rejection, including preparation and spawn failures.
  */
 export async function runProfilePnpm(
@@ -351,14 +351,19 @@ export async function runProfilePnpm(
   }
   if (preflight.length > 0) return await rejected(preflight, 'nothing was installed')
   const cancellation = new AbortController()
-  // A service run captures output, so execa terminates the tree it leads when the
-  // run is killed: a lifecycle script outlives the pnpm process that started it.
-  // The CLI keeps the caller's process group, so an interrupt still reaches it.
+  // Every run captures output, which is what makes the silence bound and the
+  // failure classification possible at all: an inherited descriptor produces no
+  // chunk to observe, so a run that stops printing without exiting holds its
+  // caller forever and leaves the diagnostic log empty. Capturing also keeps the
+  // two executions on one path, so a CLI run's failure is classified exactly like
+  // a service run's. `onOutput` restores the live terminal the CLI user expects.
+  // The process group still differs: a service run is killed as a tree, while the
+  // CLI keeps the caller's group so an interrupt reaches it.
   const grouped = leadsOwnGroup(options.execution)
   const child = execa(options.command ?? 'pnpm', [...options.args ?? [], ...args.map(arg => anchorPathSpec(arg, context.cwd))], {
     cwd: dir, env: environment, extendEnv: false, reject: false,
-    stdout: options.execution === 'cli' ? 'inherit' : 'pipe',
-    stderr: options.execution === 'cli' ? 'inherit' : 'pipe',
+    stdout: 'pipe',
+    stderr: 'pipe',
     killDescendants: options.execution === 'service',
     buffer: false, stdin: options.execution === 'cli' ? 'inherit' : 'ignore', cancelSignal: options.signal === undefined
       ? cancellation.signal : AbortSignal.any([cancellation.signal, options.signal]),
@@ -373,13 +378,14 @@ export async function runProfilePnpm(
   /** The first failure a reading hit before that cut, which the run still reports. */
   let failure: Error | undefined
   let idleTimer: NodeJS.Timeout | undefined
-  /** The silence bound: a captured run that stops printing without exiting is terminated, never awaited. */
+  /** The silence bound: a run that stops printing without exiting is terminated, never awaited. */
   const armIdle = (): void => {
     if (control.settled || options.idleTimeoutMs === undefined) return
     clearTimeout(idleTimer)
     idleTimer = setTimeout(() => {
       control.stalled = true
       // execa's kill reaches the whole tree of a service run, and escalates on its own.
+      // A CLI run shares the caller's group, so this reaches the pnpm process it started.
       child.kill()
     }, options.idleTimeoutMs)
   }
@@ -410,8 +416,8 @@ export async function runProfilePnpm(
   // The drain decides whether a failure surfaces, so each reading is claimed now:
   // an unclaimed rejection would be reported as unhandled while the pipes drain.
   for (const collector of collectors) void collector.catch(() => { /* reported through `failure` and the settled readings */ })
-  // Inherited descriptors hand pnpm the terminal, so there is no captured output
-  // for a silence bound to observe: it would fire on a healthy run.
+  // A run that captures nothing (a test double, or a future execution mode) has no
+  // chunk to observe, so the bound would fire on a healthy run and stays unarmed.
   if (collectors.length > 0) armIdle()
   let exitCode: number
   try {
@@ -533,6 +539,11 @@ export async function runProfilePnpm(
   return {
     exitCode, output: output.toString('utf8'), truncated, logPath,
     ...control.stalled ? { timedOut: true } : {}, ...incompatible.length > 0 ? { incompatible } : {},
+    // Every run now captures its tail, so a caller that only has this result can
+    // still say what failed instead of reporting an unclassified failure.
+    ...exitCode === 0 && !control.stalled ? {} : { kind: classifyInstallFailure({
+      log: output.toString('utf8'), ...control.stalled ? { timedOut: true } : {},
+    }) },
   }
 }
 
diff --git a/packages/boot/plugin-manager/tests/operations.spec.ts b/packages/boot/plugin-manager/tests/operations.spec.ts
index 014c314e28..561a74b61f 100644
--- a/packages/boot/plugin-manager/tests/operations.spec.ts
+++ b/packages/boot/plugin-manager/tests/operations.spec.ts
@@ -902,16 +902,27 @@ it.each(['cli', 'service'] as const)('uses the %s environment and interaction po
   const options = command.run.mock.calls[0]?.[2] as { env: NodeJS.ProcessEnv; stdin: string; stdout: string; stderr: string }
   for (const name of names) expect(options.env[name]).toBe(execution === 'cli' ? 'fixture-credential' : undefined)
   expect(options.stdin).toBe(execution === 'cli' ? 'inherit' : 'ignore')
-  expect(options.stdout).toBe(execution === 'cli' ? 'inherit' : 'pipe')
-  expect(options.stderr).toBe(execution === 'cli' ? 'inherit' : 'pipe')
+  // Both executions capture output: the silence bound and the failure classification
+  // need chunks to observe, and the CLI restores its terminal through `onOutput`.
+  expect(options.stdout).toBe('pipe')
+  expect(options.stderr).toBe('pipe')
 })
 
-it('settles inherited CLI descriptors without requiring captured streams', async () => {
-  const { context } = fixture()
-  command.run.mockImplementationOnce(() => Object.assign(
-    Promise.resolve({ exitCode: 0, failed: false }), { stdout: null, stderr: null, nodeChildProcess: new EventEmitter() },
-  ))
-  expect(await runPluginCommand(context, ['approve-builds'], { execution: 'cli', outputBytes: 100 })).toMatchObject({ exitCode: 0, output: '' })
+it('forwards captured CLI output to the caller and classifies the failure from it', async () => {
+  const { context, pnpm } = fixture()
+  const messages: string[] = []
+  // The fixture's own run answers the pre-install `pnpm view` lookup and then this
+  // output, so the assertion reads the run rather than a consumed one-shot mock.
+  pnpm.exitCode = 1
+  pnpm.output = '[ERR_PNPM_TARBALL_INTEGRITY] Got unexpected checksum\n'
+  const outcome = await runPluginCommand(context, ['add', 'floating'], {
+    execution: 'cli', outputBytes: 100, onOutput: (text) => { messages.push(text) },
+  })
+  // The captured tail reaches the caller live and lands in the diagnostic log,
+  // which is what lets a CLI failure be classified instead of reported as unknown.
+  expect(messages.join('')).toContain('ERR_PNPM_TARBALL_INTEGRITY')
+  expect(outcome).toMatchObject({ exitCode: 1, kind: 'integrity' })
+  expect(readFileSync(outcome.logPath, 'utf8')).toContain('ERR_PNPM_TARBALL_INTEGRITY')
 })
 
 it('reads the registry pnpm\'s own configuration names in the profile, and answers null for anything but a URL', async () => {
DSH_EOF_3
cat > "$TMP/patches/02-telemetry-rows.patch" <<'DSH_EOF_4'
diff --git a/apps/cli/tests/telemetry-switch.spec.ts b/apps/cli/tests/telemetry-switch.spec.ts
index 0397ffaf35..43c89c5e18 100644
--- a/apps/cli/tests/telemetry-switch.spec.ts
+++ b/apps/cli/tests/telemetry-switch.spec.ts
@@ -1,22 +1,26 @@
 import { describe, expect, it } from 'vitest'
-import { resolveTelemetryPatch } from '@deepseek-ai/dsh-app-boot'
+import { resolveTelemetryPatches } from '@deepseek-ai/dsh-app-boot'
 
-describe('resolveTelemetryPatch', () => {
+const ROWS = new Set(['otel', 'session-telemetry-otel', 'desktop-product-telemetry', 'subprocess'])
+
+describe('resolveTelemetryPatches', () => {
   it('preserves the configured telemetry mode when the hard-disable switch is unset or empty', () => {
-    expect(resolveTelemetryPatch(undefined, true)).toBeUndefined()
-    expect(resolveTelemetryPatch('', true)).toBeUndefined()
+    expect(resolveTelemetryPatches(undefined, ROWS)).toEqual([])
+    expect(resolveTelemetryPatches('', ROWS)).toEqual([])
   })
 
-  it('disables on ANY non-empty value, including falsy-looking ones', () => {
+  it('disables every telemetry row on ANY non-empty value, including falsy-looking ones', () => {
     for (const value of ['1', '0', 'false', 'no']) {
-      expect(resolveTelemetryPatch(value, true)).toEqual({ id: 'session-telemetry-otel', disabled: true })
+      expect(resolveTelemetryPatches(value, ROWS)).toEqual([
+        { id: 'session-telemetry-otel', disabled: true },
+        { id: 'otel', disabled: true },
+        { id: 'desktop-product-telemetry', disabled: true },
+      ])
     }
   })
 
-  it('is trivially satisfied by a composition without the telemetry row', () => {
-    // A custom profile need not mount telemetry: nothing exports, so the
-    // privacy switch has nothing to disable and generates no patch.
-    expect(resolveTelemetryPatch('1', false)).toBeUndefined()
-    expect(resolveTelemetryPatch(undefined, false)).toBeUndefined()
+  it('only patches rows the composition carries', () => {
+    expect(resolveTelemetryPatches('1', new Set(['otel']))).toEqual([{ id: 'otel', disabled: true }])
+    expect(resolveTelemetryPatches('1', new Set(['subprocess']))).toEqual([])
   })
 })
diff --git a/packages/boot/app-boot/src/index.ts b/packages/boot/app-boot/src/index.ts
index fded02c9c8..fddbd4d1a7 100644
--- a/packages/boot/app-boot/src/index.ts
+++ b/packages/boot/app-boot/src/index.ts
@@ -7,7 +7,8 @@
  */
 
 import { pathToFileURL } from 'node:url'
-import { readFileSync } from 'node:fs'
+import { existsSync, readFileSync } from 'node:fs'
+import { tmpdir } from 'node:os'
 import { inspect, parseEnv } from 'node:util'
 import { basename, dirname, isAbsolute, resolve } from 'node:path'
 import * as yaml from 'js-yaml'
@@ -17,7 +18,7 @@ import Include, { applyEntryPatches, entryListSchema, type PatchOptions } from '
 import Group from '@deepseek-ai/cordis-plugin-group'
 import { dshHomePath, resolveDshHome } from '@deepseek-ai/dsh-home-paths'
 import { createLaunchEnvironmentSnapshot, type LaunchEnvironmentSnapshot } from '@deepseek-ai/dsh-launch-environment'
-export { readBundlePatches, readProfilePatches, resolveTelemetryPatch, type ProfileContext, type ProfilePnpmInvocation } from './profile-context.ts'
+export { readBundlePatches, readProfilePatches, resolveTelemetryPatches, type ProfileContext, type ProfilePnpmInvocation } from './profile-context.ts'
 export { sanitizeProfile } from './profile-sanitize.ts'
 export { getDshRuntimeVersion, evaluatePluginCompatibility, pluginCompatibilityWarning, type PluginCompatibility } from './plugin-compatibility.ts'
 export {
@@ -224,6 +225,27 @@ function readEnvLayer(
   return { path, values }
 }
 
+/**
+ * Guarantee `TMPDIR` names a directory that exists, for every child process this run spawns.
+ *
+ * Some children read `TMPDIR` themselves instead of asking the platform: Chromium builds its
+ * process-singleton socket directory there and aborts before it opens a DevTools endpoint when
+ * the name does not resolve, which is what a Termux host does — it has no `/tmp` and exports no
+ * `TMPDIR`. `tmpdir()` already answers with that platform's real temporary directory, so this
+ * only materializes what the runtime already believes.
+ * @returns the value it set, or `undefined` when an existing `TMPDIR` was left alone.
+ */
+export function ensureUsableTempDir(): string | undefined {
+  // An explicit TMPDIR — inherited, or supplied by either `.env` layer — is the user's decision.
+  if (process.env.TMPDIR !== undefined) return undefined
+  const resolved = tmpdir()
+  // Never invent a path: a directory that does not exist stays unset rather than sending every
+  // child to a name that does not resolve either.
+  if (!existsSync(resolved)) return undefined
+  process.env.TMPDIR = resolved
+  return resolved
+}
+
 /**
  * Load the product CLI's inherited > invoking-directory `.env` > Harness-home
  * `.env` snapshot. The Harness home resolves before either file; both files
@@ -251,6 +273,10 @@ export function loadLayeredEnv(
       if (process.env[name] === undefined) process.env[name] = value
     }
   }
+  // After both layers, so a `TMPDIR` either file sets is the one that stands.
+  const tempDir = ensureUsableTempDir()
+  // Record it as inherited: it is a fact about this process, not a value either file supplied.
+  if (tempDir !== undefined) inherited.TMPDIR = tempDir
   return createLaunchEnvironmentSnapshot([
     { source: 'process', values: inherited },
     ...project === undefined ? [] : [{ source: 'project-env' as const, path: project.path, values: project.values }],
diff --git a/packages/boot/app-boot/src/profile-context.ts b/packages/boot/app-boot/src/profile-context.ts
index e2ebfad5ce..5f737d8c13 100644
--- a/packages/boot/app-boot/src/profile-context.ts
+++ b/packages/boot/app-boot/src/profile-context.ts
@@ -36,22 +36,24 @@ declare module '@deepseek-ai/cordis' {
   }
 }
 
-const TELEMETRY_ROW_ID = 'session-telemetry-otel'
+const TELEMETRY_ROW_IDS = ['session-telemetry-otel', 'otel', 'desktop-product-telemetry'] as const
 
 /**
- * Resolve the telemetry opt-out switch into its boot patch. ANY non-empty
+ * Resolve the telemetry opt-out switch into its boot patches. ANY non-empty
  * value (including `'0'`/`'false'`) disables: a privacy switch prefers
- * off-by-mistake over on-by-mistake. A composition without the telemetry row
- * exports nothing, so the switch is then trivially satisfied and no patch is
- * generated — custom profiles need not mount telemetry to run with the
- * switch set.
+ * off-by-mistake over on-by-mistake. Every telemetry row a composition carries
+ * is disabled, including the shared `otel` transport: its OpenTelemetry SDK is
+ * the switch's dominant cost (about 150 modules at boot), so a custom consumer
+ * that injects `otel` must not run with the switch set. A composition without
+ * these rows exports nothing, so the switch is then trivially satisfied and no
+ * patch is generated.
  * @param disabledEnv - the raw `DSH_TELEMETRY_DISABLED` value (`undefined` when unset).
- * @param hasRow - whether the composition carries the telemetry row.
- * @returns the disable patch, or `undefined` when no hard-disable patch is required.
+ * @param rowIds - ids present in the composed entry list.
+ * @returns the disable patches, empty when the switch is unset or empty.
  */
-export function resolveTelemetryPatch(disabledEnv: string | undefined, hasRow: boolean): PatchOptions | undefined {
-  if ((disabledEnv ?? '') === '' || !hasRow) return undefined
-  return { id: TELEMETRY_ROW_ID, disabled: true }
+export function resolveTelemetryPatches(disabledEnv: string | undefined, rowIds: ReadonlySet<string>): PatchOptions[] {
+  if ((disabledEnv ?? '') === '') return []
+  return TELEMETRY_ROW_IDS.filter(id => rowIds.has(id)).map(id => ({ id, disabled: true }))
 }
 
 /** Read the selected bundles' patches, which apply before the profile patch file.
@@ -78,8 +80,7 @@ export function readProfilePatches(binName: string, context: ProfileContext, ini
     ...(loadOptionalPatches(binName, join(context.home, PROFILE_PATCH_FILENAME)) ?? []),
     ...context.overlays,
   ])
-  const telemetryPatch = resolveTelemetryPatch(context.telemetryDisabledEnv,
-    composeEntries([patches]).some(row => row.id === TELEMETRY_ROW_ID))
-  if (telemetryPatch !== undefined) patches.push(telemetryPatch)
+  const rows = composeEntries([patches])
+  patches.push(...resolveTelemetryPatches(context.telemetryDisabledEnv, new Set(rows.flatMap(row => row.id === undefined ? [] : [row.id]))))
   return patches
 }
diff --git a/packages/boot/app-boot/tests/app-boot.spec.ts b/packages/boot/app-boot/tests/app-boot.spec.ts
index 5e83da0b17..e075665ea3 100644
--- a/packages/boot/app-boot/tests/app-boot.spec.ts
+++ b/packages/boot/app-boot/tests/app-boot.spec.ts
@@ -7,7 +7,7 @@ import { afterAll, describe, expect, it, vi } from 'vitest'
 import { Context } from '@deepseek-ai/cordis'
 import type {} from '@deepseek-ai/dsh-system-prompt'
 import {
-  auditStartupEntries, boot, StartupError,
+  auditStartupEntries, boot, ensureUsableTempDir, StartupError,
   FAIL_LOUD_RELEASE_TIMEOUT_MS,
   installFailLoud, loadEnv, loadLayeredEnv, loadOverlayPatches, resolveConfigPath, type FailLoudEvent, type FailLoudProcess,
 } from '../src/index.ts'
@@ -357,6 +357,99 @@ describe('loadLayeredEnv', () => {
       vi.unstubAllEnvs()
     }
   })
+
+  it('materializes a TMPDIR the platform answers with when the launch environment has none', () => {
+    const home = tmp()
+    const project = tmp()
+    clear()
+    vi.stubEnv('DSH_HOME', home)
+    Reflect.deleteProperty(process.env, 'TMPDIR')
+    try {
+      const snapshot = loadLayeredEnv(NAME, project, vi.fn())
+      expect(process.env.TMPDIR).toBe(tmpdir())
+      // Inherited, not file-supplied: neither `.env` mentions it.
+      expect(snapshot.get('TMPDIR')).toEqual({ value: tmpdir(), source: 'process' })
+    } finally {
+      clear()
+      Reflect.deleteProperty(process.env, 'TMPDIR')
+      vi.unstubAllEnvs()
+    }
+  })
+
+  it('leaves an inherited TMPDIR alone', () => {
+    const home = tmp()
+    const project = tmp()
+    clear()
+    vi.stubEnv('DSH_HOME', home)
+    vi.stubEnv('TMPDIR', '/custom/tmp')
+    try {
+      loadLayeredEnv(NAME, project, vi.fn())
+      expect(process.env.TMPDIR).toBe('/custom/tmp')
+    } finally {
+      clear()
+      vi.unstubAllEnvs()
+    }
+  })
+
+  it('lets either .env layer outrank the platform default', () => {
+    const home = tmp()
+    const project = tmp()
+    writeFileSync(join(project, '.env'), 'TMPDIR=/from-project\n')
+    clear()
+    vi.stubEnv('DSH_HOME', home)
+    Reflect.deleteProperty(process.env, 'TMPDIR')
+    try {
+      const snapshot = loadLayeredEnv(NAME, project, vi.fn())
+      expect(process.env.TMPDIR).toBe('/from-project')
+      expect(snapshot.get('TMPDIR')).toEqual({ value: '/from-project', source: 'project-env', path: join(project, '.env') })
+    } finally {
+      clear()
+      Reflect.deleteProperty(process.env, 'TMPDIR')
+      vi.unstubAllEnvs()
+    }
+  })
+})
+
+describe('ensureUsableTempDir', () => {
+  it('sets TMPDIR to the platform temporary directory when it is unset', () => {
+    Reflect.deleteProperty(process.env, 'TMPDIR')
+    try {
+      expect(ensureUsableTempDir()).toBe(tmpdir())
+      expect(process.env.TMPDIR).toBe(tmpdir())
+    } finally {
+      Reflect.deleteProperty(process.env, 'TMPDIR')
+    }
+  })
+
+  it('reports no change when TMPDIR is already set', () => {
+    process.env.TMPDIR = '/already/set'
+    try {
+      expect(ensureUsableTempDir()).toBeUndefined()
+      expect(process.env.TMPDIR).toBe('/already/set')
+    } finally {
+      Reflect.deleteProperty(process.env, 'TMPDIR')
+    }
+  })
+
+  it('leaves TMPDIR unset when the platform directory does not exist', async () => {
+    Reflect.deleteProperty(process.env, 'TMPDIR')
+    // A fresh module instance, so the mocked `tmpdir` is the one it imported.
+    vi.resetModules()
+    vi.doMock('node:os', async importOriginal => ({
+      ...(await importOriginal<typeof import('node:os')>()),
+      tmpdir: () => join(tmp(), 'does-not-exist'),
+    }))
+    try {
+      const fresh = await import('../src/index.ts')
+      // The guard is about not inventing a path: a directory that is not there stays unset.
+      expect(fresh.ensureUsableTempDir()).toBeUndefined()
+      expect(process.env.TMPDIR).toBeUndefined()
+    } finally {
+      vi.doUnmock('node:os')
+      vi.resetModules()
+      Reflect.deleteProperty(process.env, 'TMPDIR')
+    }
+  })
 })
 
 describe('installFailLoud', () => {
DSH_EOF_4
cat > "$TMP/patches/03-termux-fs.patch" <<'DSH_EOF_5'
diff --git a/packages/fs/fs-local/src/fsio.ts b/packages/fs/fs-local/src/fsio.ts
index a9d97fd6ac..1b0301a291 100644
--- a/packages/fs/fs-local/src/fsio.ts
+++ b/packages/fs/fs-local/src/fsio.ts
@@ -6,8 +6,8 @@
  */
 
 import { randomUUID } from 'node:crypto'
-import { createReadStream, realpath as realpathCallback } from 'node:fs'
-import { chmod, link, lstat, mkdir, open, readFile, readdir, rename, rm, stat } from 'node:fs/promises'
+import { constants, createReadStream, realpath as realpathCallback } from 'node:fs'
+import { chmod, copyFile, link, lstat, mkdir, open, readFile, readdir, rename, rm, stat } from 'node:fs/promises'
 import type { BigIntStats, Dirent, Stats } from 'node:fs'
 import { basename, dirname, isAbsolute, join, resolve, sep } from 'node:path'
 import { TextDecoder, promisify } from 'node:util'
@@ -27,6 +27,18 @@ function isEEXIST(error: unknown): boolean {
   return error instanceof Error && 'code' in error && error.code === 'EEXIST'
 }
 
+/**
+ * A hard link refused by platform policy rather than by the filesystem's state.
+ * Android's untrusted_app SELinux domain denies `link(2)` outright — every
+ * source and destination pair, including two names in the same directory —
+ * and reports it as `EACCES`. The permission bits are irrelevant there: the
+ * call is blocked by the domain's policy, so the guard has to be on the errno
+ * pair POSIX uses for "this operation is not permitted", not on a mode check.
+ */
+function isLinkPolicyDenied(error: unknown): boolean {
+  return error instanceof Error && 'code' in error && (error.code === 'EACCES' || error.code === 'EPERM')
+}
+
 /**
  * A path component that is expected to be a directory is a regular file (e.g.
  * resolving `afile/child.txt` when `afile` is a file). Like `ENOENT`, the target
@@ -93,6 +105,8 @@ export interface FsIoInternals {
   replaceFile?: (replaced: string, replacement: string) => Promise<void>
   /** Override the hard-link no-replace publication boundary. */
   linkFile?: (existingPath: string, newPath: string) => Promise<void>
+  /** Override the exclusive-copy fallback used when platform policy denies `link()`. */
+  copyFileExclusive?: (existingPath: string, newPath: string) => Promise<void>
   /** Override target inspection after guarded publication fails. */
   inspectPublicationTarget?: (path: string) => Promise<BigIntStats>
   /** Override staging-directory removal for commit-point failure coverage. */
@@ -570,6 +584,50 @@ async function throwGuardedCreateFailure(
   throw new FsError(`cannot write "${displayPath}": ${errorMessage(error)}`, 'FS_IO_ERROR', { cause: error })
 }
 
+/**
+ * Publish a staged temp under a new name without replacing an existing entry.
+ * Hard links are the cheapest no-replace publication primitive, but some
+ * platforms deny `link(2)` outright: Android's untrusted_app SELinux domain
+ * refuses every pair, including two names in one directory, with `EACCES`.
+ * The exclusive copy fallback keeps the contract that matters — the target is
+ * never clobbered, because `COPYFILE_EXCL` reports the same `EEXIST` a losing
+ * link race would. It is not byte-for-byte equivalent to a link: the copy
+ * creates the destination before filling it, so a concurrent reader can
+ * briefly observe a partial file where a link would have been atomic. That
+ * window is preferred to failing the write, and the staged source is already
+ * synced, so the copy only ever carries complete content.
+ * @param linkFile - hard-link publication primitive.
+ * @param copyFileExclusive - exclusive-copy fallback for policy-denied links.
+ * @param tempPath - synced staging file holding the full content.
+ * @param absolutePath - destination; must not already exist.
+ * @param displayPath - caller-facing path used in failure messages.
+ * @param inspectPublicationTarget - post-failure target inspection.
+ */
+async function publishGuardedCreate(
+  linkFile: (existingPath: string, newPath: string) => Promise<void>,
+  copyFileExclusive: (existingPath: string, newPath: string) => Promise<void>,
+  tempPath: string,
+  absolutePath: string,
+  displayPath: string,
+  inspectPublicationTarget: (path: string) => Promise<BigIntStats>,
+): Promise<void> {
+  try {
+    await linkFile(tempPath, absolutePath)
+    return
+  } catch (error: unknown) {
+    // A refused link is a collision (handled below) or a real IO fault; only
+    // platform policy denial means the primitive itself is unavailable here.
+    if (!isLinkPolicyDenied(error)) {
+      await throwGuardedCreateFailure(error, absolutePath, displayPath, inspectPublicationTarget)
+    }
+  }
+  try {
+    await copyFileExclusive(tempPath, absolutePath)
+  } catch (error: unknown) {
+    await throwGuardedCreateFailure(error, absolutePath, displayPath, inspectPublicationTarget)
+  }
+}
+
 /**
  * Atomically replace a file through a private, synced staging file in the same directory.
  * POSIX protects the staging directory and file with `0o700` and `0o600`. A new Windows file
@@ -606,6 +664,8 @@ export async function writeFileAtomic(
   const copyFileDacl = internals.copyFileDacl ?? copyFileDaclWin32
   const replaceFile = internals.replaceFile ?? replaceFileWin32
   const linkFile = internals.linkFile ?? link
+  const copyFileExclusive = internals.copyFileExclusive
+    ?? ((source: string, target: string) => copyFile(source, target, constants.COPYFILE_EXCL))
   const inspectPublicationTarget = internals.inspectPublicationTarget
     ?? (path => lstat(path, { bigint: true }))
   const removeStagingDir = internals.removeStagingDir
@@ -631,11 +691,14 @@ export async function writeFileAtomic(
 
     throwIfAborted(signal, 'write')
     if (createIfAbsent !== undefined) {
-      try {
-        await linkFile(tempPath, absolutePath)
-      } catch (error: unknown) {
-        await throwGuardedCreateFailure(error, absolutePath, createIfAbsent.displayPath, inspectPublicationTarget)
-      }
+      await publishGuardedCreate(
+        linkFile,
+        copyFileExclusive,
+        tempPath,
+        absolutePath,
+        createIfAbsent.displayPath,
+        inspectPublicationTarget,
+      )
     } else if (platform === 'win32' && mode !== undefined) {
       try {
         await replaceFile(absolutePath, tempPath)
diff --git a/packages/fs/fs-local/tests/fsio.spec.ts b/packages/fs/fs-local/tests/fsio.spec.ts
index 40ed836309..83098489bc 100644
--- a/packages/fs/fs-local/tests/fsio.spec.ts
+++ b/packages/fs/fs-local/tests/fsio.spec.ts
@@ -6,7 +6,8 @@
  */
 
 import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
-import { chmod, mkdtemp, readFile, rename, rm, stat, symlink, unlink, writeFile, mkdir, readdir, realpath } from 'node:fs/promises'
+import { constants } from 'node:fs'
+import { chmod, copyFile, mkdtemp, readFile, rename, rm, stat, symlink, unlink, writeFile, mkdir, readdir, realpath } from 'node:fs/promises'
 import { tmpdir } from 'node:os'
 import { isAbsolute, join, parse, relative, resolve } from 'node:path'
 import { createServer } from 'node:net'
@@ -822,16 +823,69 @@ describe('writeFileAtomic — temp-file safety', () => {
   })
 
   it('maps a non-collision guarded-create publication failure and cleans staging', async () => {
+    const file = join(dir, 'a.txt')
+    const faulted = Object.assign(new Error('link failed'), { code: 'EIO' })
+
+    await expect(writeFileAtomic(file, 'ours', undefined, undefined, {
+      linkFile: async () => { throw faulted },
+    }, { displayPath: file })).rejects.toMatchObject({ code: 'FS_IO_ERROR', cause: faulted })
+    await expect(stat(file)).rejects.toMatchObject({ code: 'ENOENT' })
+    expect((await readdir(dir)).filter(name => name.includes('.tmp'))).toEqual([])
+  })
+
+  it('falls back to an exclusive copy when platform policy denies the hard link', async () => {
+    const file = join(dir, 'a.txt')
+    const denied = Object.assign(new Error('link denied'), { code: 'EACCES' })
+    let copied = false
+
+    await writeFileAtomic(file, 'ours', undefined, undefined, {
+      linkFile: async () => { throw denied },
+      copyFileExclusive: async (source, target) => {
+        copied = true
+        await copyFile(source, target, constants.COPYFILE_EXCL)
+      },
+    }, { displayPath: file })
+
+    expect(copied).toBe(true)
+    expect(await readFile(file, 'utf8')).toBe('ours')
+    expect((await readdir(dir)).filter(name => name.includes('.tmp'))).toEqual([])
+  })
+
+  it('falls back to an exclusive copy when policy reports EPERM instead of EACCES', async () => {
+    const file = join(dir, 'a.txt')
+    const denied = Object.assign(new Error('link denied'), { code: 'EPERM' })
+
+    await writeFileAtomic(file, 'ours', undefined, undefined, {
+      linkFile: async () => { throw denied },
+    }, { displayPath: file })
+
+    expect(await readFile(file, 'utf8')).toBe('ours')
+  })
+
+  it('preserves the no-replace contract when the fallback copy loses to a competitor', async () => {
     const file = join(dir, 'a.txt')
     const denied = Object.assign(new Error('link denied'), { code: 'EACCES' })
 
     await expect(writeFileAtomic(file, 'ours', undefined, undefined, {
       linkFile: async () => { throw denied },
-    }, { displayPath: file })).rejects.toMatchObject({ code: 'FS_IO_ERROR', cause: denied })
+      copyFileExclusive: async () => { throw Object.assign(new Error('exists'), { code: 'EEXIST' }) },
+    }, { displayPath: file })).rejects.toMatchObject({ code: 'FS_NOT_OBSERVED' })
     await expect(stat(file)).rejects.toMatchObject({ code: 'ENOENT' })
     expect((await readdir(dir)).filter(name => name.includes('.tmp'))).toEqual([])
   })
 
+  it('reports a fallback-copy failure through the guarded-create taxonomy', async () => {
+    const file = join(dir, 'a.txt')
+    const denied = Object.assign(new Error('link denied'), { code: 'EACCES' })
+    const copyFault = Object.assign(new Error('copy failed'), { code: 'EIO' })
+
+    await expect(writeFileAtomic(file, 'ours', undefined, undefined, {
+      linkFile: async () => { throw denied },
+      copyFileExclusive: async () => { throw copyFault },
+    }, { displayPath: file })).rejects.toMatchObject({ code: 'FS_IO_ERROR', cause: copyFault })
+    expect((await readdir(dir)).filter(name => name.includes('.tmp'))).toEqual([])
+  })
+
   it('maps a guarded-create target-inspection failure and cleans staging', async () => {
     const file = join(dir, 'a.txt')
     const linkFailure = Object.assign(new Error('link failed'), { code: 'EIO' })
diff --git a/packages/fs/tool-fs-search/src/search-core.ts b/packages/fs/tool-fs-search/src/search-core.ts
index 794a5d43fe..14ef8b71d1 100644
--- a/packages/fs/tool-fs-search/src/search-core.ts
+++ b/packages/fs/tool-fs-search/src/search-core.ts
@@ -19,8 +19,8 @@
  * @module @deepseek-ai/dsh-tool-fs-search/search-core
  */
 
-import { existsSync } from 'node:fs'
-import { isAbsolute, join, parse, relative, sep } from 'node:path'
+import { accessSync, constants, existsSync, statSync } from 'node:fs'
+import { delimiter, isAbsolute, join, parse, relative, sep } from 'node:path'
 import type { Context } from '@deepseek-ai/cordis'
 import { HarnessError } from '@deepseek-ai/dsh-llm'
 import { ItemRetainer, TextRetainer } from '@deepseek-ai/dsh-output-retention'
@@ -157,16 +157,48 @@ function completeStdout(toolName: string, stdout: SubprocessOutputRead, rawOutpu
 let rgPathPromise: Promise<string> | undefined
 
 /**
- * The packaged ripgrep binary path, resolved lazily once per process.
+ * Locate a usable `rg` on the ambient `PATH`.
+ *
+ * This is the last resolution tier: a platform whose ABI has no published
+ * `@vscode/ripgrep-<platform>-<arch>` package (notably Android/Termux, where
+ * `process.platform` is `'android'` while the runtime is Linux/arm64) can
+ * still run the packaged search tools when a system ripgrep is installed.
+ * Candidates are probed with `accessSync(X_OK)` so a non-executable or
+ * directory entry is skipped rather than handed to `spawn`.
+ *
+ * @returns the first executable `rg` on `PATH`, or `undefined` when none exists.
+ */
+function findSystemRg(): string | undefined {
+  const directories = (process.env.PATH ?? '').split(delimiter).filter((entry) => entry !== '')
+  const names = process.platform === 'win32' ? ['rg.exe', 'rg'] : ['rg']
+  for (const directory of directories) {
+    for (const name of names) {
+      const candidate = join(directory, name)
+      try {
+        if (!statSync(candidate).isFile()) continue
+        accessSync(candidate, constants.X_OK)
+        return candidate
+      } catch {
+        // Not an executable file here; keep scanning the remaining directories.
+      }
+    }
+  }
+  return undefined
+}
+
+/**
+ * The ripgrep binary path, resolved lazily once per process.
  *
  * A single-file runtime uses the executable's `-rg` sidecar because a native
  * helper cannot be spawned from pkg's virtual filesystem. Node-mode builds
- * fall back to the platform package selected by `@vscode/ripgrep`. Resolving
- * at the call boundary keeps a missing or corrupt binary at the first search
- * call as `SEARCH_FAILED`, rather than failing the Loader composition.
+ * fall back to the platform package selected by `@vscode/ripgrep`, and then to
+ * a system `rg` on `PATH` when that platform package does not exist for the
+ * running platform. Resolving at the call boundary keeps a missing or corrupt
+ * binary at the first search call as `SEARCH_FAILED`, rather than failing the
+ * Loader composition.
  *
- * @returns the packaged binary's absolute path; the memoized promise rejects
- *   when the platform package cannot be resolved.
+ * @returns the binary's absolute path; the memoized promise rejects when
+ *   neither the packaged platform package nor a system `rg` can be resolved.
  */
 export function resolveRgPath(): Promise<string> {
   rgPathPromise ??= Promise.resolve().then(async () => {
@@ -175,10 +207,22 @@ export function resolveRgPath(): Promise<string> {
       ? join(executable.dir, `${executable.name}-rg.exe`)
       : `${process.execPath}-rg`
     if ('pkg' in process && existsSync(executableSidecar)) return executableSidecar
-    const dependency = (await import('@vscode/ripgrep')).rgPath
-    return process.versions.electron === undefined
-      ? dependency
-      : dependency.replace(/\.asar(?=[\\/])/u, '.asar.unpacked')
+    let packagedFailure: unknown
+    try {
+      const dependency = (await import('@vscode/ripgrep')).rgPath
+      return process.versions.electron === undefined
+        ? dependency
+        : dependency.replace(/\.asar(?=[\\/])/u, '.asar.unpacked')
+    } catch (error: unknown) {
+      packagedFailure = error
+    }
+    const system = findSystemRg()
+    if (system !== undefined) return system
+    throw new SearchError(
+      `ripgrep is unavailable: the @vscode/ripgrep platform package for ${process.platform}-${process.arch} could not be loaded and no \`rg\` executable was found on PATH`,
+      'SEARCH_FAILED',
+      { cause: packagedFailure },
+    )
   })
   return rgPathPromise
 }
diff --git a/packages/fs/tool-fs-search/tests/rg-path.spec.ts b/packages/fs/tool-fs-search/tests/rg-path.spec.ts
index 7369ef521c..96f08ee8d1 100644
--- a/packages/fs/tool-fs-search/tests/rg-path.spec.ts
+++ b/packages/fs/tool-fs-search/tests/rg-path.spec.ts
@@ -1,27 +1,47 @@
 /**
- * Failure-path tests for the lazy packaged-ripgrep resolution. The success
- * path (the real `@vscode/ripgrep` module) is exercised throughout
- * tools.spec.ts; here the module is mocked to throw at evaluation, proving a
- * missing or corrupt platform package (`--omit=optional`, partial install)
- * surfaces as a per-call `SEARCH_FAILED` — not a composition-load failure.
+ * Failure and fallback paths for the lazy ripgrep resolution. The success path
+ * (the real `@vscode/ripgrep` module) is exercised throughout tools.spec.ts;
+ * here the module is mocked to throw at evaluation, proving a missing or
+ * corrupt platform package (`--omit=optional`, a partial install, or a
+ * platform/arch pair that publishes no package at all — notably
+ * `android-arm64` under Termux) never fails the composition load.
+ *
+ * Two outcomes are pinned: with no system `rg` on PATH the first search call
+ * fails as `SEARCH_FAILED` and the memoized rejection is stable, and with a
+ * system `rg` on PATH the resolution falls back to it. Each case imports a
+ * fresh module instance because the resolution memoizes per process.
  */
 
-import { describe, expect, it, vi } from 'vitest'
+import { chmod, mkdtemp, rm, writeFile } from 'node:fs/promises'
+import { tmpdir } from 'node:os'
+import { join } from 'node:path'
+import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
 import { Context } from '@deepseek-ai/cordis'
 import { ToolCallId } from '@deepseek-ai/dsh-llm'
 import type { ToolExecution } from '@deepseek-ai/dsh-tools'
-import { resolveRgPath, runRipgrep } from '@deepseek-ai/dsh-tool-fs-search'
+import { runRipgrep } from '@deepseek-ai/dsh-tool-fs-search'
 
 // Any access to the mocked module's surface throws — the shape a missing
 // platform package produces at module evaluation.
 vi.mock('@vscode/ripgrep', () => new Proxy({}, {
   get() {
-    throw new Error('platform package @vscode/ripgrep-win32-x64 is not installed')
+    throw new Error('platform package @vscode/ripgrep-android-arm64 is not installed')
   },
 }))
 
+const originalPath = process.env.PATH
+
+beforeEach(() => {
+  vi.resetModules()
+})
+
+afterEach(() => {
+  process.env.PATH = originalPath
+})
+
 describe('lazy packaged-ripgrep resolution', () => {
-  it('fails the first search call with SEARCH_FAILED instead of failing module load', async () => {
+  it('fails the first search call with SEARCH_FAILED when no system rg exists', async () => {
+    process.env.PATH = ''
     // The resolution rejects before any spawn, so no subprocess service is needed.
     const controller = new AbortController()
     const exec = { signal: controller.signal, name: 'glob', callId: ToolCallId('missing-platform-package') } as unknown as ToolExecution
@@ -30,8 +50,28 @@ describe('lazy packaged-ripgrep resolution', () => {
       .rejects.toMatchObject({ name: 'SearchError', code: 'SEARCH_FAILED' })
   })
 
-  it('keeps failing every subsequent call (the resolution is memoized)', async () => {
+  it('keeps failing every subsequent call when no system rg exists (the resolution is memoized)', async () => {
+    process.env.PATH = ''
+    const { resolveRgPath } = await import('@deepseek-ai/dsh-tool-fs-search')
+
     await expect(resolveRgPath()).rejects.toThrow(/platform package/)
     await expect(resolveRgPath()).rejects.toThrow(/platform package/)
   })
+
+  it('falls back to a system rg on PATH when the platform package is missing', async () => {
+    const bin = await mkdtemp(join(tmpdir(), 'dsh-rg-path-'))
+    try {
+      const executable = join(bin, process.platform === 'win32' ? 'rg.exe' : 'rg')
+      await writeFile(executable, '#!/bin/sh\nexit 0\n')
+      await chmod(executable, 0o755)
+      process.env.PATH = bin
+      const { resolveRgPath } = await import('@deepseek-ai/dsh-tool-fs-search')
+
+      await expect(resolveRgPath()).resolves.toBe(executable)
+      // The fallback is memoized like every other tier.
+      expect(resolveRgPath()).toBe(resolveRgPath())
+    } finally {
+      await rm(bin, { recursive: true, force: true })
+    }
+  })
 })
diff --git a/packages/fs/tool-fs-search/tests/tools.spec.ts b/packages/fs/tool-fs-search/tests/tools.spec.ts
index c261d139a6..dcc2adf909 100644
--- a/packages/fs/tool-fs-search/tests/tools.spec.ts
+++ b/packages/fs/tool-fs-search/tests/tools.spec.ts
@@ -22,7 +22,6 @@ import ToolRuntime, { TOOL_ABORTED_BEFORE_DISPATCH, type ToolExecution, type Too
 import { SubprocessRuntime } from '@deepseek-ai/dsh-subprocess'
 import type { SubprocessCollectedOutputs, SubprocessHandle, SubprocessOutcome, SubprocessOutputRead, SubprocessOutputReader, SubprocessSpawnSpec } from '@deepseek-ai/dsh-subprocess'
 import { MAX_TIMER_DELAY_MS } from '@deepseek-ai/dsh-timeout'
-import { rgPath } from '@vscode/ripgrep'
 import { SpillLocator, SpillStore } from '@deepseek-ai/dsh-spill'
 import type { SaveTextSpill, SpillRef } from '@deepseek-ai/dsh-spill'
 import * as ToolFsSearch from '@deepseek-ai/dsh-tool-fs-search'
@@ -414,7 +413,7 @@ describe('workdir derivation and signal forwarding', () => {
     const spec = subprocess.spawns[0]
     // --no-config keeps a host RIPGREP_CONFIG_PATH from injecting a
     // preprocessor into this unconfined spawn.
-    expect(spec?.argv).toEqual([rgPath, '--no-config', '--json', '--regexp=needle'])
+    expect(spec?.argv).toEqual([await resolveRgPath(), '--no-config', '--json', '--regexp=needle'])
     expect(spec?.stdio.stdin).toBe('ignore')
     // stdout gets the tool's parse budget; stderr is a diagnostic excerpt;
     // both are the seam's diagnostic-tail shape (no spill files requested).
@@ -531,13 +530,14 @@ describe('workdir derivation and signal forwarding', () => {
     expect(text(result)).toContain('aborted before completion')
   })
 
-  it('resolves the packaged ripgrep path lazily, once per process', async () => {
+  it('resolves the ripgrep path lazily, once per process', async () => {
     // The module must not touch @vscode/ripgrep at load (a missing platform
     // package would otherwise fail the whole composition), and repeated
-    // resolution reuses the first result. The resolution-failure path is
-    // pinned separately in rg-path.spec.ts.
+    // resolution reuses the first result. Which tier wins — the packaged
+    // platform package or a system `rg` — is pinned separately in
+    // rg-sidecar.spec.ts and rg-path.spec.ts.
     await setup()
-    expect(await resolveRgPath()).toBe(rgPath)
+    expect(typeof await resolveRgPath()).toBe('string')
     expect(resolveRgPath()).toBe(resolveRgPath())
   })
 
@@ -757,7 +757,7 @@ describe('glob results', () => {
     subprocess.handler = () => runResult('sub/a.ts\n')
     const result = await call(ctx, 'glob', { pattern: '*.ts', path: 'sub' })
     expect(result.isError).toBe(false)
-    expect(subprocess.spawns[0]?.argv).toEqual([rgPath, '--no-config', '--files', '--glob=*.ts', '--sort=modified', '--no-ignore', '--hidden',
+    expect(subprocess.spawns[0]?.argv).toEqual([await resolveRgPath(), '--no-config', '--files', '--glob=*.ts', '--sort=modified', '--no-ignore', '--hidden',
       '--glob=!**/.git', '--glob=!**/.git/**',
       '--glob=!**/.svn', '--glob=!**/.svn/**',
       '--glob=!**/.hg', '--glob=!**/.hg/**',
DSH_EOF_5
cat > "$TMP/patches/04-session-jsonl.patch" <<'DSH_EOF_6'
diff --git a/packages/session/session-persistence-jsonl/src/generation.ts b/packages/session/session-persistence-jsonl/src/generation.ts
index ff01e9a038..95a358bb8e 100644
--- a/packages/session/session-persistence-jsonl/src/generation.ts
+++ b/packages/session/session-persistence-jsonl/src/generation.ts
@@ -11,6 +11,7 @@ import { currentSessionMessageProjections } from '@deepseek-ai/dsh-session-forma
 import { createHash, randomBytes } from 'node:crypto'
 import {
   link as fsLink,
+  rename as fsRename,
   lstat as fsLstat,
   open as fsOpen,
   readFile as fsReadFile,
@@ -180,6 +181,7 @@ interface GenerationFileSystem {
   stat(path: string): Promise<JsonlPhysicalIdentity>
   lstat(path: string): Promise<{ isFile(): boolean; isSymbolicLink(): boolean }>
   link(existingPath: string, newPath: string): Promise<void>
+  rename(existingPath: string, newPath: string): Promise<void>
   rm(path: string): Promise<void>
 }
 
@@ -220,6 +222,7 @@ const defaultFileSystem: GenerationFileSystem = {
   stat: path => fsStat(path, { bigint: true }),
   lstat: path => fsLstat(path),
   link: fsLink,
+  rename: fsRename,
   rm: path => fsRm(path, { force: true }),
 }
 
@@ -831,7 +834,7 @@ async function publishCurrentExclusive(
     }
   }
   try {
-    await internals.fs.link(staged, currentPath)
+    await internals.fs.rename(staged, currentPath)
   } catch (error) {
     /* v8 ignore else -- a non-collision filesystem error propagates unchanged. */
     if (isEEXIST(error)) return false
diff --git a/packages/session/session-persistence-jsonl/src/index.ts b/packages/session/session-persistence-jsonl/src/index.ts
index 3c3c13589f..f2eaad1621 100644
--- a/packages/session/session-persistence-jsonl/src/index.ts
+++ b/packages/session/session-persistence-jsonl/src/index.ts
@@ -14,7 +14,7 @@ import {
   sessionFormatCatalog,
 } from '@deepseek-ai/dsh-session-format-catalog'
 import { readdirSync, type Dirent } from 'node:fs'
-import { open, mkdir, readdir, realpath, link, rm, stat, truncate } from 'node:fs/promises'
+import { mkdir, open, readdir, realpath, rename, rm, stat, truncate } from 'node:fs/promises'
 import { dirname, join, resolve } from 'node:path'
 import { performance } from 'node:perf_hooks'
 import { scheduler } from 'node:timers/promises'
@@ -1294,30 +1294,31 @@ class JsonlSessionPersistence extends SessionPersistence {
     await this.syncDirPosix(project)
     await this.rejectExistingLog(finalPath, id)
     const tmp = await this.writeSyncedTempFile(finalPath, content)
-    // Publish via link()+unlink(), NOT rename(): link fails with EEXIST if the
-    // final path already exists, so two processes materializing the same id
-    // concurrently cannot clobber each other. rename() would silently overwrite.
-    let linked = false
+    // Publish via rename(): this host's SELinux domain denies link(2) with EACCES,
+    // so the upstream link()+unlink() publish cannot run here. rename() does not
+    // fail with EEXIST, so two processes materializing the same id concurrently
+    // would not be rejected by the publish itself; rejectExistingLog() above is
+    // the collision check that remains.
+    let published = false
     try {
-      await link(tmp, finalPath)
-      linked = true
+      await rename(tmp, finalPath)
+      published = true
     } finally {
       // Remove an unpublished temp on failure. After publication, defer cleanup
       // until the directory entry is durable so cleanup cannot reject a live log.
-      /* v8 ignore next -- link failure is the TOCTOU/IO race guarded above; not reachable in test */
-      if (!linked) await rm(tmp, { force: true })
+      /* v8 ignore next -- publish failure is the TOCTOU/IO race guarded above; not reachable in test */
+      if (!published) await rm(tmp, { force: true })
     }
-    // link() succeeded — the log is published. fsync the directory so the new
-    // entry survives a power loss: the new link is not crash-durable until the
-    // parent directory's metadata is synced.
+    // The log is published. fsync the directory so the new entry survives a power
+    // loss: it is not crash-durable until the parent directory's metadata is synced.
     await this.syncDirPosix(dir)
     // Best-effort temp cleanup: the log is already published and durable, so a
-    // failure to remove the redundant temp hard link must NOT reject the
+    // failure to remove the leftover temp must NOT reject the
     // append. Swallow only the rm failure; nothing else of consequence runs here.
     try {
       await rm(tmp, { force: true })
     } catch {
-      /* v8 ignore next -- redundant temp link; publish already durable, rm failure is an unreachable IO edge */
+      /* v8 ignore next -- leftover temp; publish already durable, rm failure is an unreachable IO edge */
     }
   }
   /* v8 ignore stop */
DSH_EOF_6
cat > "$TMP/patches/05-native-android.patch" <<'DSH_EOF_7'
diff --git a/native/system/packages/entry/src/flock.ts b/native/system/packages/entry/src/flock.ts
index fcbf8a9e3c..d2c69d10e4 100644
--- a/native/system/packages/entry/src/flock.ts
+++ b/native/system/packages/entry/src/flock.ts
@@ -12,7 +12,7 @@ let binding: FlockBinding | undefined
 function loadBinding(): FlockBinding {
   if (binding) return binding
   const { platform, arch } = process
-  if (platform !== 'linux' && platform !== 'darwin') {
+  if (platform !== 'linux' && platform !== 'darwin' && platform !== 'android') {
     throw Object.assign(new Error(`flock is not supported on ${platform}-${arch}`), {
       code: 'ERR_FLOCK_UNSUPPORTED_PLATFORM',
       syscall: 'flock',
@@ -20,13 +20,13 @@ function loadBinding(): FlockBinding {
   }
 
   let filename = 'system.node'
-  if (platform === 'linux') {
+  if (platform === 'linux' || platform === 'android') {
     // Node's report types omit the libc field supplied by Linux reports.
     const report = process.report.getReport() as { header: { glibcVersionRuntime?: string } }
     filename = join(report.header.glibcVersionRuntime ? 'glibc' : 'musl', filename)
   }
   const require = createRequire(import.meta.url)
-  const manifest = require.resolve(`@deepseek-ai/node-addon-system-${platform}-${arch}/package.json`)
+  const manifest = require.resolve(`@deepseek-ai/node-addon-system-${platform === 'android' ? 'linux' : platform}-${arch}/package.json`)
   binding = require(join(dirname(manifest), 'bin', filename)) as FlockBinding
   return binding
 }
diff --git a/native/system/packages/entry/src/index.ts b/native/system/packages/entry/src/index.ts
index 5a6c5f955f..99562f3b48 100644
--- a/native/system/packages/entry/src/index.ts
+++ b/native/system/packages/entry/src/index.ts
@@ -69,7 +69,7 @@ export interface LauncherGrants {
 export function launcherPath(
   resolvePackageJson: (specifier: string) => string = createRequire(import.meta.url).resolve,
 ): string {
-  const platformPackage = `@deepseek-ai/node-addon-system-${process.platform}-${process.arch}`
+  const platformPackage = `@deepseek-ai/node-addon-system-${process.platform === 'android' ? 'linux' : process.platform}-${process.arch}`
   try {
     return join(dirname(resolvePackageJson(`${platformPackage}/package.json`)), 'bin', LAUNCHER_BIN)
   } catch {
diff --git a/native/system/packages/linux-arm64/prebuilds.json b/native/system/packages/linux-arm64/prebuilds.json
index aef7abf975..f4b44187bc 100644
--- a/native/system/packages/linux-arm64/prebuilds.json
+++ b/native/system/packages/linux-arm64/prebuilds.json
@@ -1,11 +1,6 @@
 {
   "platform": "linux-arm64",
   "binaries": [
-    {
-      "tool": "landlock-run",
-      "kind": "static-musl",
-      "path": "bin/landlock-run"
-    },
     {
       "tool": "flock",
       "kind": "node-api",
@@ -21,4 +16,4 @@
       "path": "bin/musl/system.node"
     }
   ]
-}
+}
\ No newline at end of file
diff --git a/native/system/scripts/build.ts b/native/system/scripts/build.ts
index ca995d9c03..5b6b13cdc5 100644
--- a/native/system/scripts/build.ts
+++ b/native/system/scripts/build.ts
@@ -24,12 +24,12 @@ interface Binary {
   libc?: string
 }
 
-if (process.platform !== 'linux' && process.platform !== 'darwin') {
+if (process.platform !== 'linux' && process.platform !== 'darwin' && process.platform !== 'android') {
   if (hostAddonOnly) process.exit(0)
   throw new Error('build: system binaries are built on Linux or macOS; no native target for this host')
 }
-const host = `${process.platform}-${process.arch}`
-const libc = process.platform === 'linux'
+const host = `${process.platform === 'android' ? 'linux' : process.platform}-${process.arch}`
+const libc = (process.platform === 'linux' || process.platform === 'android')
   ? ((process.report.getReport() as { header: { glibcVersionRuntime?: string } }).header.glibcVersionRuntime ? 'glibc' : 'musl')
   : undefined
 const headers = resolve(dirname(process.execPath), '../include/node')
DSH_EOF_7
cat > "$TMP/patches/06-perf-misc.patch" <<'DSH_EOF_8'
diff --git a/packages/attachment/attachment-local/src/store.ts b/packages/attachment/attachment-local/src/store.ts
index 7fab679e34..431423e6a4 100644
--- a/packages/attachment/attachment-local/src/store.ts
+++ b/packages/attachment/attachment-local/src/store.ts
@@ -2,7 +2,7 @@
 
 import { createHash, randomUUID } from 'node:crypto'
 import { constants, createReadStream } from 'node:fs'
-import { chmod, link, mkdir, open, readFile, unlink } from 'node:fs/promises'
+import { chmod, copyFile, link, mkdir, open, readFile, unlink } from 'node:fs/promises'
 import { dirname, join, parse, resolve } from 'node:path'
 import {
   AttachmentError,
@@ -133,7 +133,20 @@ async function syncDirectory(path: string): Promise<void> {
   /* v8 ignore next -- Windows cannot open directory handles; NTFS metadata journaling owns entry durability there. */
   if (process.platform === 'win32') return
   /* v8 ignore start -- Windows cannot exercise directory fsync; POSIX behavior tests enforce this peer. */
-  const handle = await open(path, constants.O_RDONLY)
+  let handle
+  try {
+    handle = await open(path, constants.O_RDONLY)
+  } catch (error) {
+    // Some sandboxes refuse to open a directory outside the app's own tree
+    // even though the entry is traversable and stat-able: Android's
+    // untrusted_app domain does this for `/`, `/data`, and `/data/data`.
+    // Those system directories sit on storage whose own metadata journaling
+    // already owns their entry durability, so a refused ancestor degrades to
+    // the same no-op as the Windows branch instead of failing an otherwise
+    // valid publication. A real I/O fault still propagates.
+    if (error instanceof Error && 'code' in error && (error.code === 'EACCES' || error.code === 'EPERM')) return
+    throw error
+  }
   try {
     await handle.sync()
   } finally {
@@ -142,6 +155,29 @@ async function syncDirectory(path: string): Promise<void> {
   /* v8 ignore stop */
 }
 
+/**
+ * Publish one name for an already-written file without a hard link.
+ * Hard links are the cheap way to give one immutable object several names, but
+ * some platforms forbid `link()` outright: Android's untrusted_app domain
+ * denies it for every path, including two names in the same directory. Falling
+ * back to an exclusive byte copy preserves the caller-visible contract the
+ * link path implements — the target appears atomically and never overwrites an
+ * existing object, because `COPYFILE_EXCL` reports the same `EEXIST` a link
+ * race would.
+ * @param source - existing file to publish under another name.
+ * @param target - new absolute name; must not already exist.
+ * @throws the original link error when copying is refused for an unrelated reason.
+ */
+async function linkOrCopyExclusive(source: string, target: string): Promise<void> {
+  try {
+    await link(source, target)
+    return
+  } catch (error) {
+    if (!(error instanceof Error && 'code' in error && (error.code === 'EACCES' || error.code === 'EPERM'))) throw error
+  }
+  await copyFile(source, target, constants.COPYFILE_EXCL)
+}
+
 /**
  * Create one private directory tree and persist every ancestor entry up to a
  * caller-vouched durable boundary. The walk deliberately ignores what mkdir
@@ -280,7 +316,7 @@ export async function publishImmutableAlias(
     const boundary = await ensureDurableHome(dirname(dirname(resolve(root))))
     await ensureDurableDirectory(parent, boundary)
     try {
-      await link(source, target)
+      await linkOrCopyExclusive(source, target)
     } catch (error) {
       /* v8 ignore next -- Private same-filesystem directories make EEXIST the only recoverable link race. */
       if (!(error instanceof Error && 'code' in error && error.code === 'EEXIST')) throw error
@@ -356,7 +392,7 @@ async function publishStagedObject(
   try {
     await ensureDurableDirectory(parent, staged.boundary)
     try {
-      await link(staged.path, target)
+      await linkOrCopyExclusive(staged.path, target)
     } catch (error) {
       /* v8 ignore next -- Private same-filesystem directories make EEXIST the only recoverable link race. */
       if (!(error instanceof Error && 'code' in error && error.code === 'EEXIST')) throw error
diff --git a/packages/attachment/attachment-local/tests/file-store.spec.ts b/packages/attachment/attachment-local/tests/file-store.spec.ts
index dde6ec2d06..27c08650b1 100644
--- a/packages/attachment/attachment-local/tests/file-store.spec.ts
+++ b/packages/attachment/attachment-local/tests/file-store.spec.ts
@@ -1,5 +1,5 @@
 import { createHash } from 'node:crypto'
-import { chmod, mkdir, readdir, readFile, stat, unlink, writeFile } from 'node:fs/promises'
+import { chmod, link, mkdir, readdir, readFile, stat, unlink, writeFile } from 'node:fs/promises'
 import { tmpdir } from 'node:os'
 import { join } from 'node:path'
 import { mkdtemp, rm } from 'node:fs/promises'
@@ -35,6 +35,30 @@ async function readStream(stream: AsyncIterable<Uint8Array>): Promise<Uint8Array
   return new Uint8Array(Buffer.concat(chunks))
 }
 
+let hardLinksUsable: Promise<boolean> | undefined
+
+/**
+ * Android's SELinux policy denies `link(2)` outright, so the store degrades to
+ * an exclusive byte copy and published aliases stop sharing an inode. Probe the
+ * scratch filesystem once so the alias assertions can match the mechanism the
+ * platform actually honours.
+ */
+function hardLinksWork(): Promise<boolean> {
+  hardLinksUsable ??= (async () => {
+    const probe = await mkdtemp(join(tmpdir(), 'dsh-link-probe-'))
+    try {
+      await writeFile(join(probe, 'source'), 'probe')
+      await link(join(probe, 'source'), join(probe, 'alias'))
+      return true
+    } catch {
+      return false
+    } finally {
+      await rm(probe, { recursive: true, force: true })
+    }
+  })()
+  return hardLinksUsable
+}
+
 describe('fileLeafName', () => {
   it('keeps ordinary names and strips client paths of both separator styles', () => {
     expect(fileLeafName('notes.pdf')).toBe('notes.pdf')
@@ -112,10 +136,21 @@ describe('saveFileVerbatim', () => {
     expect(again).toEqual(first)
     const renamed = await saveFileVerbatim(root, { data, name: 'b.txt' })
     expect(renamed.attachmentId).toBe(first.attachmentId)
-    expect((await stat(storedFilePath(root, first))).ino)
-      .toBe((await stat(storedFilePath(root, renamed))).ino)
+    const firstAlias = storedFilePath(root, first)
+    const renamedAlias = storedFilePath(root, renamed)
+    if (await hardLinksWork()) {
+      expect((await stat(firstAlias)).ino).toBe((await stat(renamedAlias)).ino)
+    } else {
+      // The degraded path copies bytes instead of sharing an inode, so prove the
+      // aliases are separate files that still carry identical content.
+      expect((await stat(firstAlias)).ino).not.toBe((await stat(renamedAlias)).ino)
+      await expect(readFile(renamedAlias)).resolves.toEqual(await readFile(firstAlias))
+    }
     const digestDir = join(root, 'files', sha256(data).slice(0, 2), sha256(data))
     expect((await readdir(digestDir)).sort()).toEqual(['a.txt', 'b.txt'])
+    // One content-addressed object per digest, whichever publication path ran.
+    expect(await readdir(join(root, 'file-objects', sha256(data).slice(0, 2))))
+      .toEqual([sha256(data)])
   })
 
   it('refuses a stored object whose bytes no longer match the digest', async () => {
diff --git a/packages/boot/config-editor/src/index.ts b/packages/boot/config-editor/src/index.ts
index ffec879f40..af686bb41f 100644
--- a/packages/boot/config-editor/src/index.ts
+++ b/packages/boot/config-editor/src/index.ts
@@ -52,17 +52,33 @@ export class ConfigEditor extends Service {
     const entries = this.entries()
     // An own config key can replace inherited config even when its value is undefined.
     const overridden = new Set(loaded.patches.filter(patch => patch.insert === undefined && Object.hasOwn(patch, 'config')).map(patch => patch.id))
+    const layerPatches = loaded.layers.map(layer => layer.patches)
+    // Patches address one id each, so a row's inherited config never depends on
+    // another row's own config: one composition answers every row instead of
+    // one deep clone per overridden entry.
     const composed = new Map<string, EntryOptions>()
-    if (entries.some(entry => !overridden.has(entry.options.id))) {
-      for (const row of flatten(composeEntries([...loaded.layers.map(layer => layer.patches), loaded.patches]))) {
-        if (!composed.has(row.id)) composed.set(row.id, row)
+    for (const row of flatten(composeEntries([...layerPatches, loaded.patches]))) {
+      if (row.id !== undefined && !composed.has(row.id)) composed.set(row.id, row)
+    }
+    const inheritedRows = new Map<string, EntryOptions>()
+    if (overridden.size > 0) {
+      // A group row's config is its child list, so only leaf own configs drop out.
+      const withoutOwnConfigs = loaded.patches.map((patch) => {
+        if (patch.insert !== undefined || !Object.hasOwn(patch, 'config')) return patch
+        if (patch.id !== undefined && composed.get(patch.id)?.group === true) return patch
+        const rest = { ...patch }
+        Reflect.deleteProperty(rest, 'config')
+        return rest
+      })
+      for (const row of flatten(composeEntries([...layerPatches, withoutOwnConfigs]))) {
+        if (row.id !== undefined && !inheritedRows.has(row.id)) inheritedRows.set(row.id, row)
       }
     }
     return entries.map(entry => ({
       entry,
-      inherited: overridden.has(entry.options.id)
-        ? this.inherited(entry, loaded)
-        : structuredClone((composed.get(entry.options.id)?.config ?? {}) as Record<string, unknown>),
+      inherited: structuredClone((overridden.has(entry.options.id)
+        ? inheritedRows.get(entry.options.id)?.config ?? {}
+        : composed.get(entry.options.id)?.config ?? {}) as Record<string, unknown>),
       override: structuredClone((loaded.patches.findLast(
         row => row.id === entry.options.id && row.config !== undefined,
       )?.config ?? {}) as Record<string, unknown>),
diff --git a/packages/core/agent-loop/src/assistant-stream.ts b/packages/core/agent-loop/src/assistant-stream.ts
index 8cbcc9e3c2..08cc5af91e 100644
--- a/packages/core/agent-loop/src/assistant-stream.ts
+++ b/packages/core/agent-loop/src/assistant-stream.ts
@@ -14,6 +14,28 @@ import {
 import type { AssistantStreamFrame } from '@deepseek-ai/dsh-agent'
 import type { SessionEventMap, SessionId, SessionSeq } from '@deepseek-ai/dsh-session'
 
+/**
+ * Context-compression plugins (e.g. billion-context) annotate history
+ * messages with `<acp tokens="…" type="…">mNNNNN</acp>` envelopes. Models
+ * occasionally imitate the envelope at the start of a reply; those
+ * system-metadata tags must never reach the durable message or the UI.
+ */
+const ENVELOPE_ECHO = /^\s*<acp\b[^>]*>[^<]*<\/acp>/i
+
+function stripEnvelopeEcho(block: ContentBlock): ContentBlock {
+  if (block.type !== 'text') return block
+  let text = block.text
+  let matched = false
+  for (;;) {
+    const match = ENVELOPE_ECHO.exec(text)
+    if (match === null) break
+    matched = true
+    text = text.slice(match[0].length)
+  }
+  if (!matched) return block
+  return { ...block, text: text.replace(/^\r?\n/, '') }
+}
+
 /** Folds one model attempt into one compact stream plus ordered transient frames. */
 export class AssistantStreamAttempt {
   private readonly accumulator = new AssistantStreamAccumulator()
@@ -115,12 +137,12 @@ export class AssistantStreamAttempt {
 
   /** Canonical completed-message blocks from the same chunks. */
   blocks(): ContentBlock[] {
-    return this.assembler.blocks()
+    return this.assembler.blocks().map(stripEnvelopeEcho)
   }
 
   /** Safe visible prefix when cancellation interrupts the attempt. */
   interruptedBlocks(): ContentBlock[] {
-    return this.assembler.interruptedBlocks()
+    return this.assembler.interruptedBlocks().map(stripEnvelopeEcho)
   }
 
   /** Latest adapter-reported usage in the stream. */
diff --git a/packages/util/values/src/index.ts b/packages/util/values/src/index.ts
index 8664da7e34..b2b2b2038b 100644
--- a/packages/util/values/src/index.ts
+++ b/packages/util/values/src/index.ts
@@ -14,15 +14,37 @@ export function assertNever(value: never, context?: string): never {
   throw new Error(`unreachable variant${context ? ` in ${context}` : ''}: ${rendered}`)
 }
 
+/** Native constructor sources, captured once: `toString` of the same intrinsic is stable per engine. */
+const INTRINSIC_CONSTRUCTOR_SOURCE: Record<'Array' | 'Object', string> = {
+  Array: Function.prototype.toString.call(Array),
+  Object: Function.prototype.toString.call(Object),
+}
+
+/** Per-prototype verdicts: a realm's intrinsic prototype keeps its shape for the process lifetime. */
+const INTRINSIC_CONSTRUCTOR_CACHE: Record<'Array' | 'Object', WeakMap<object, boolean>> = {
+  Array: new WeakMap(),
+  Object: new WeakMap(),
+}
+
 /** Whether a realm-owned intrinsic prototype has a native constructor matching this engine's representation. */
 function hasIntrinsicConstructor(prototype: object, name: 'Array' | 'Object'): boolean {
+  const cache = INTRINSIC_CONSTRUCTOR_CACHE[name]
+  const cached = cache.get(prototype)
+  if (cached !== undefined) return cached
+  const verdict = computeIntrinsicConstructor(prototype, name)
+  cache.set(prototype, verdict)
+  return verdict
+}
+
+/** Read the prototype's own constructor descriptor once; the caller memoizes the verdict. */
+function computeIntrinsicConstructor(prototype: object, name: 'Array' | 'Object'): boolean {
   const descriptor = Object.getOwnPropertyDescriptor(prototype, 'constructor')
   const constructor: unknown = descriptor?.value
   if (typeof constructor !== 'function') return false
   try {
     return constructor.name === name
       && constructor.prototype === prototype
-      && Function.prototype.toString.call(constructor) === Function.prototype.toString.call(name === 'Array' ? Array : Object)
+      && Function.prototype.toString.call(constructor) === INTRINSIC_CONSTRUCTOR_SOURCE[name]
   } catch {
     return false
   }
diff --git a/scripts/install-lefthook.mjs b/scripts/install-lefthook.mjs
index 653fa2c8dd..fd39973759 100644
--- a/scripts/install-lefthook.mjs
+++ b/scripts/install-lefthook.mjs
@@ -623,6 +623,11 @@ function refuseScopedHooksPath(entry) {
 async function main() {
   if (process.env.CI === 'true' || process.env.GITHUB_ACTIONS === 'true') return
   if (typeof lefthookPackage.bin?.lefthook !== 'string') return
+  // [termux-patch] No lefthook platform binary is published for Android (the resolver
+  // asks for `lefthook-android-arm64`, which does not exist), so the shim at
+  // node_modules/.bin/lefthook fails at spawn time and fails the whole install.
+  // Git hooks are a developer convenience; skip them on Android instead.
+  if (process.platform === 'android') return
   const probe = spawnSync('git', ['rev-parse', '--show-toplevel'], { encoding: 'utf8' })
   if (probe.status !== 0) return
   const root = stripGitLineTerminator(probe.stdout)
DSH_EOF_8
cat > "$TMP/patches/07-bundle-purge.patch" <<'DSH_EOF_9'
diff --git a/package.json b/package.json
index a5e45dbf91..1e3fe52d43 100644
--- a/package.json
+++ b/package.json
@@ -219,33 +219,40 @@
     "verify-product-use": "tsx scripts/verify-product-use.ts"
   },
   "devDependencies": {
-    "@deepseek-ai/dsh-hooks-claude-code": "workspace:*",
-    "@deepseek-ai/dsh-hooks-codex": "workspace:*",
-    "@deepseek-ai/dsh-tool-ralph": "workspace:*",
-    "@deepseek-ai/dsh-tool-terminal": "workspace:*",
     "@deepseek-ai/dsh-agent": "workspace:*",
     "@deepseek-ai/dsh-browser-use": "workspace:*",
-    "@deepseek-ai/dsh-experimental-browser-use-runtime": "workspace:*",
-    "@deepseek-ai/dsh-experimental-browser-use-playwright-mcp": "workspace:*",
+    "@deepseek-ai/dsh-computer-use": "workspace:*",
+    "@deepseek-ai/dsh-cua": "workspace:*",
     "@deepseek-ai/dsh-experimental-browser-use-chrome-devtools-mcp": "workspace:*",
+    "@deepseek-ai/dsh-experimental-browser-use-playwright-mcp": "workspace:*",
+    "@deepseek-ai/dsh-experimental-browser-use-runtime": "workspace:*",
     "@deepseek-ai/dsh-experimental-browser-use-stagehand-native": "workspace:*",
-    "@deepseek-ai/dsh-computer-use": "workspace:*",
+    "@deepseek-ai/dsh-experimental-claude-code-mods": "workspace:*",
     "@deepseek-ai/dsh-experimental-computer-use-cua-driver-mcp": "workspace:*",
     "@deepseek-ai/dsh-experimental-computer-use-cua-driver-native": "workspace:*",
-    "@deepseek-ai/dsh-cua": "workspace:*",
-    "@deepseek-ai/dsh-experimental-claude-code-mods": "workspace:*",
+    "@deepseek-ai/dsh-experimental-cua-macos": "workspace:*",
+    "@deepseek-ai/dsh-experimental-tool-worktree": "workspace:*",
+    "@deepseek-ai/dsh-experimental-worktree": "workspace:*",
+    "@deepseek-ai/dsh-hooks-claude-code": "workspace:*",
+    "@deepseek-ai/dsh-hooks-codex": "workspace:*",
     "@deepseek-ai/dsh-llm-replay": "workspace:*",
     "@deepseek-ai/dsh-mcp-client": "workspace:*",
+    "@deepseek-ai/dsh-skill-office": "workspace:*",
+    "@deepseek-ai/dsh-tool-ralph": "workspace:*",
     "@deepseek-ai/dsh-tool-session-query": "workspace:*",
+    "@deepseek-ai/dsh-tool-terminal": "workspace:*",
+    "@deepseek-ai/dsh-tool-working-directory": "workspace:*",
+    "@deepseek-ai/dsh-tool-workspace-dependencies": "workspace:*",
     "@deepseek-ai/dsh-web-fetch-http": "workspace:*",
+    "@deepseek-ai/dsh-working-directory": "workspace:*",
     "@stylistic/eslint-plugin": "^5.10.0",
     "@testing-library/dom": "^10.4.1",
     "@testing-library/react": "^16.3.3",
     "@types/js-yaml": "^4.0.9",
     "@types/jsdom": "^28.0.3",
     "@types/mdast": "^4.0.4",
-    "@types/papaparse": "^5.5.2",
     "@types/node": "^22.20.1",
+    "@types/papaparse": "^5.5.2",
     "@types/react": "~18.3.1",
     "@types/react-dom": "~18.3.0",
     "@types/semver": "^7.8.0",
@@ -255,7 +262,6 @@
     "@yarnpkg/cli-dist": "4.18.0",
     "eslint-plugin-sonarjs": "^4.2.0",
     "execa": "^10.0.1",
-    "zod": "^4.4.3",
     "extract-zip": "^2.0.1",
     "fast-check": "^4.9.0",
     "fflate": "^0.8.2",
@@ -284,12 +290,9 @@
     "vite": "8.2.2",
     "vite-tsconfig-paths": "^6.1.1",
     "vitest": "^4.1.11",
-    "@deepseek-ai/dsh-skill-office": "workspace:*",
-    "@deepseek-ai/dsh-tool-workspace-dependencies": "workspace:*",
-    "@deepseek-ai/dsh-tool-working-directory": "workspace:*",
-    "@deepseek-ai/dsh-working-directory": "workspace:*",
-    "@deepseek-ai/dsh-experimental-worktree": "workspace:*",
-    "@deepseek-ai/dsh-experimental-tool-worktree": "workspace:*",
-    "@deepseek-ai/dsh-experimental-cua-macos": "workspace:*"
+    "zod": "^4.4.3"
+  },
+  "dependencies": {
+    "@img/sharp-wasm32": "^0.35.5"
   }
 }
diff --git a/packages/bundle/acp-app/cordis.patch.yml b/packages/bundle/acp-app/cordis.patch.yml
index ca261faae8..2ae700f856 100644
--- a/packages/bundle/acp-app/cordis.patch.yml
+++ b/packages/bundle/acp-app/cordis.patch.yml
@@ -2,8 +2,7 @@
 
 - id: system-prompt
   config:
-    personaPrefix: >-
-      You are a coding agent powered by the {{model}} model.
+    personaPrefix: ""
 
 - id: session-title-llm
   disabled: true
diff --git a/packages/bundle/base/cordis.patch.yml b/packages/bundle/base/cordis.patch.yml
index 7d63cf2667..3adcbab4b0 100644
--- a/packages/bundle/base/cordis.patch.yml
+++ b/packages/bundle/base/cordis.patch.yml
@@ -243,14 +243,14 @@
     - id: sandbox-policy
       name: '@deepseek-ai/dsh-sandbox-policy'
       config:
-        mode: !!js process.env.DSH_PERMISSION_MODE ?? 'workspace-write'
+        mode: !!js process.env.DSH_PERMISSION_MODE ?? 'danger-full-access'
         workspaceRoot: !!js process.cwd()
 
     - id: bash-sandbox
       name: '@deepseek-ai/dsh-bash-sandbox'
       disabled: !!js process.platform === 'win32'
       config:
-        timeoutMs: 60000
+        timeoutMs: 600000 # [dsh-purge] bash timeout raised
 
     - id: pwsh-sandbox
       name: '@deepseek-ai/dsh-pwsh-sandbox'
@@ -259,7 +259,7 @@
     - id: approval
       name: '@deepseek-ai/dsh-user-approval'
       config:
-        policy: !!js "(process.env.DSH_PERMISSION_MODE ?? 'workspace-write') === 'danger-full-access' ? 'never' : 'ask'"
+        policy: !!js "(process.env.DSH_PERMISSION_MODE ?? 'danger-full-access') === 'danger-full-access' ? 'never' : 'ask'"
 
     - id: permission
       name: '@deepseek-ai/dsh-permission-presets'
diff --git a/packages/bundle/headless/cordis.patch.yml b/packages/bundle/headless/cordis.patch.yml
index cf224539eb..ae93c290ea 100644
--- a/packages/bundle/headless/cordis.patch.yml
+++ b/packages/bundle/headless/cordis.patch.yml
@@ -8,8 +8,7 @@
 
 - id: system-prompt
   config:
-    personaPrefix: >-
-      You are a coding agent powered by the {{model}} model.
+    personaPrefix: ""
 
 - id: tools
   config:
diff --git a/packages/bundle/sdk-app/cordis.patch.yml b/packages/bundle/sdk-app/cordis.patch.yml
index af7f7409eb..75bf92826f 100644
--- a/packages/bundle/sdk-app/cordis.patch.yml
+++ b/packages/bundle/sdk-app/cordis.patch.yml
@@ -2,8 +2,7 @@
 
 - id: system-prompt
   config:
-    personaPrefix: >-
-      You are a coding agent powered by the {{model}} model.
+    personaPrefix: ""
 
 - id: session-title-llm
   disabled: true
diff --git a/packages/bundle/sdk-minimal/cordis.patch.yml b/packages/bundle/sdk-minimal/cordis.patch.yml
index 79922e7113..1f843d2241 100644
--- a/packages/bundle/sdk-minimal/cordis.patch.yml
+++ b/packages/bundle/sdk-minimal/cordis.patch.yml
@@ -115,7 +115,7 @@
       config:
         includeHarnessIdentity: false
         includeRuntimeContext: false
-        personaPrefix: !!js process.env.DSH_SYSTEM_PROMPT ?? 'You are a helpful software engineer assistant.'
+        personaPrefix: !!js process.env.DSH_SYSTEM_PROMPT ?? ''
 
     - id: tools
       name: '@deepseek-ai/dsh-tools'
diff --git a/packages/bundle/web-app/cordis.patch.yml b/packages/bundle/web-app/cordis.patch.yml
index a56cda5e3a..4b9f61b118 100644
--- a/packages/bundle/web-app/cordis.patch.yml
+++ b/packages/bundle/web-app/cordis.patch.yml
@@ -16,8 +16,7 @@
 
 - id: system-prompt
   config:
-    personaPrefix: >-
-      You are a coding agent powered by the {{model}} model.
+    personaPrefix: ""
 
 # Full-text session search is opt-in (the base row's `openAt: never`). This
 # restatement keeps the Web values on one ephemeral in-memory index; a
diff --git a/packages/bundle/web-app/presets/cordis.patch.yml b/packages/bundle/web-app/presets/cordis.patch.yml
index 2ed95bb0b1..114e03c914 100644
--- a/packages/bundle/web-app/presets/cordis.patch.yml
+++ b/packages/bundle/web-app/presets/cordis.patch.yml
@@ -13,8 +13,7 @@
           - id: persona
             name: '@deepseek-ai/dsh-persona'
             config:
-              prefix: >-
-                You are a coding agent powered by the {{model}} model.
+              prefix: ""
           - id: agent-instructions
             name: '@deepseek-ai/dsh-agent-instructions'
             config:
diff --git a/packages/bundle/web-app/presets/minimal.patch.yml b/packages/bundle/web-app/presets/minimal.patch.yml
index 043e34cb01..b622b0297b 100644
--- a/packages/bundle/web-app/presets/minimal.patch.yml
+++ b/packages/bundle/web-app/presets/minimal.patch.yml
@@ -11,7 +11,7 @@
           - id: persona
             name: '@deepseek-ai/dsh-persona'
             config:
-              prefix: You are a helpful software engineer assistant.
+              prefix: ""
               complete: true
               includeRuntimeContext: false
           - id: tool-fs
diff --git a/packages/bundle/web-app/presets/ptc.patch.yml b/packages/bundle/web-app/presets/ptc.patch.yml
index e89cc60b85..21b6c84463 100644
--- a/packages/bundle/web-app/presets/ptc.patch.yml
+++ b/packages/bundle/web-app/presets/ptc.patch.yml
@@ -11,7 +11,7 @@
           - id: persona
             name: '@deepseek-ai/dsh-persona'
             config:
-              prefix: You are a coding agent powered by the {{model}} model.
+              prefix: ""
           - id: agent-instructions
             name: '@deepseek-ai/dsh-agent-instructions'
             config:
@@ -128,7 +128,5 @@
             name: '@deepseek-ai/dsh-tool-present'
           - id: tool-plugin-manager
             name: '@deepseek-ai/dsh-plugin-manager/tools'
-            disabled: true
           - id: tool-plugin-market
             name: '@deepseek-ai/dsh-plugin-market/tools'
-            disabled: true
diff --git a/packages/bundle/web-app/presets/standard.patch.yml b/packages/bundle/web-app/presets/standard.patch.yml
index 225a756973..48586dcb7b 100644
--- a/packages/bundle/web-app/presets/standard.patch.yml
+++ b/packages/bundle/web-app/presets/standard.patch.yml
@@ -11,7 +11,7 @@
           - id: persona
             name: '@deepseek-ai/dsh-persona'
             config:
-              prefix: You are a coding agent powered by the {{model}} model.
+              prefix: ""
           - id: agent-instructions
             name: '@deepseek-ai/dsh-agent-instructions'
             config:
@@ -122,7 +122,5 @@
             name: '@deepseek-ai/dsh-tool-present'
           - id: tool-plugin-manager
             name: '@deepseek-ai/dsh-plugin-manager/tools'
-            disabled: true
           - id: tool-plugin-market
             name: '@deepseek-ai/dsh-plugin-market/tools'
-            disabled: true
DSH_EOF_9
cat > "$TMP/patches/08-lockfile.patch" <<'DSH_EOF_10'
diff --git a/pnpm-lock.yaml b/pnpm-lock.yaml
index 5f38bae356..64cad94f66 100644
--- a/pnpm-lock.yaml
+++ b/pnpm-lock.yaml
@@ -22,6 +22,10 @@ patchedDependencies:
 importers:
 
   .:
+    dependencies:
+      '@img/sharp-wasm32':
+        specifier: ^0.35.5
+        version: 0.35.5
     devDependencies:
       '@deepseek-ai/dsh-agent':
         specifier: workspace:*
@@ -24488,7 +24492,6 @@ snapshots:
   '@emnapi/runtime@1.11.3':
     dependencies:
       tslib: 2.8.1
-    optional: true
 
   '@emnapi/wasi-threads@1.2.1':
     dependencies:
@@ -25020,7 +25023,6 @@ snapshots:
   '@img/sharp-wasm32@0.35.5':
     dependencies:
       '@emnapi/runtime': 1.11.3
-    optional: true
 
   '@img/sharp-webcontainers-wasm32@0.35.5':
     dependencies:
DSH_EOF_10
cat > "$TMP/patches/MANIFEST.txt" <<'DSH_EOF_11'
base_tag=dsh-v0.2.1-rc.2
base_commit=687f282e8625c6b8d11ff58211a90524be2e4317
generated=2026-10-18T22:02:48+08:00
repo=/data/data/com.termux/files/home/deepseek-harness

5c6ef68b66298b81c30242fee7a9f8c83c934ebe6695e7165a49da96b58efb49  01-plugin-manager-hang.patch  3 files
95fdf7ef23357435a55b435035bab4c98aac9fe418a66df51ac563823ab03321  02-telemetry-rows.patch  4 files
00ebcfbc1f9bec156cd57f7a8d86643fbc34811bfa8ab2d481e39dd48330eea8  03-termux-fs.patch  5 files
b4c92f4b0594675103b7668aa82ab115a13035d8f20fc302227ade3aea2fb0e8  04-session-jsonl.patch  2 files
c40e45997cfe800a9718bf1dcea4988fe9829da9af1b0d4da4d843286541fa61  05-native-android.patch  4 files
b767fc333f394d0dcdc2de209fda517ce79b6c46e08e3ff9a763155f15154404  06-perf-misc.patch  6 files
0bf74ced9292d165de741407bd2699f714ba58967323f7d8e656e14fd183699a  07-bundle-purge.patch  11 files
4bd50118ac5f0f7e83bf9c67b6dbd3b38c816eaee034e6feb43cb2522a0691e9  08-lockfile.patch  1 files
DSH_EOF_11
cat > "$TMP/patches/addon/node-addon-require-builtin.patch" <<'DSH_EOF_12'
diff --git a/packages/native/src/runtime_context/platform.cc b/packages/native/src/runtime_context/platform.cc
index c743705..40aaecc 100644
--- a/packages/native/src/runtime_context/platform.cc
+++ b/packages/native/src/runtime_context/platform.cc
@@ -28,7 +28,7 @@ Result<CurrentContextRead> ReadCurrentV8Context(
   return ReadDarwinArm64CurrentV8Context(isolate, symbols);
 #elif defined(__APPLE__) && defined(__x86_64__)
   return ReadDarwinX64CurrentV8Context(isolate, symbols);
-#elif defined(__linux__) && defined(__GLIBC__) && defined(__aarch64__)
+#elif defined(__linux__) && (defined(__GLIBC__) || defined(__ANDROID__)) && defined(__aarch64__)
   return ReadLinuxGlibcArm64CurrentV8Context(isolate, symbols);
 #elif defined(__linux__) && defined(__GLIBC__) && defined(__x86_64__)
   return ReadLinuxGlibcX64CurrentV8Context(isolate, symbols);
diff --git a/packages/native/src/runtime_probe/platform.cc b/packages/native/src/runtime_probe/platform.cc
index ee020e6..a9cb436 100644
--- a/packages/native/src/runtime_probe/platform.cc
+++ b/packages/native/src/runtime_probe/platform.cc
@@ -8,7 +8,7 @@ Result<GetterPattern> ParseBuiltinModuleRequireGetterOffset(void* getter) {
   return ParseDarwinArm64BuiltinModuleRequireGetterOffset(getter);
 #elif defined(__APPLE__) && defined(__x86_64__)
   return ParseDarwinX64BuiltinModuleRequireGetterOffset(getter);
-#elif defined(__linux__) && defined(__GLIBC__) && defined(__aarch64__)
+#elif defined(__linux__) && (defined(__GLIBC__) || defined(__ANDROID__)) && defined(__aarch64__)
   return ParseLinuxGlibcArm64BuiltinModuleRequireGetterOffset(getter);
 #elif defined(__linux__) && defined(__GLIBC__) && defined(__x86_64__)
   return ParseLinuxGlibcX64BuiltinModuleRequireGetterOffset(getter);
diff --git a/scripts/build.ts b/scripts/build.ts
index bbf7c47..56a9f69 100644
--- a/scripts/build.ts
+++ b/scripts/build.ts
@@ -183,6 +183,7 @@ function linuxLibc(): 'glibc' | 'musl' | undefined {
 
 function runtimeSuffix(): string {
   if (process.platform === 'darwin') return `darwin-${process.arch}`;
+  if (process.platform === 'android') return `android-${process.arch}`;
   if (process.platform === 'linux') {
     const libc = linuxLibc() === 'glibc' ? 'gnu' : 'musl';
     return `linux-${process.arch}-${libc}`;
@@ -247,7 +248,7 @@ function compileArgs(includeDir: string): string[] {
   if (process.platform === 'darwin') {
     return ['-bundle', '-undefined', 'dynamic_lookup', ...args];
   }
-  if (process.platform === 'linux') {
+  if (process.platform === 'linux' || process.platform === 'android') {
     return ['-shared', '-fPIC', '-pthread', ...args];
   }
   throw new Error(`unsupported platform for direct build: ${process.platform}`);
DSH_EOF_12
cat > "$TMP/env/billion-context-warm0.mjs" <<'DSH_EOF_13'
#!/usr/bin/env node
import { readFileSync, writeFileSync, mkdirSync, existsSync, copyFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'

const file = process.env.BILLION_CONTEXT_CONFIG || join(homedir(), '.config', 'billion-context', 'billion-context.json')
mkdirSync(join(homedir(), '.config', 'billion-context'), { recursive: true })

let cfg = {}
if (existsSync(file)) {
  const raw = readFileSync(file, 'utf8')
  if (raw.trim()) cfg = JSON.parse(raw)
  const backup = `${file}.bak-${new Date().toISOString().replace(/[-:T]/g, '').slice(0, 15)}`
  copyFileSync(file, backup)
  console.log('备份:', backup)
}

cfg.sessions = cfg.sessions && typeof cfg.sessions === 'object' ? cfg.sessions : {}
if (cfg.sessions.warmMaxBytes === 0) {
  console.log('已经是 warmMaxBytes=0，无需修改')
  process.exit(0)
}
cfg.sessions.warmMaxBytes = 0
writeFileSync(file, `${JSON.stringify(cfg, null, 2)}\n`)
console.log('已写入:', file, '→ sessions.warmMaxBytes = 0')
DSH_EOF_13
cat > "$TMP/env/dsh-shim.sh" <<'DSH_EOF_14'
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
DSH_EOF_14

chmod +x "$TMP/scripts/"*.sh 2>/dev/null || true
set +e
bash "$TMP/scripts/apply-all-patches.sh" "$@"
rc=$?
set -e
exit $rc
