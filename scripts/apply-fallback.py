#!/usr/bin/env python3
import argparse
import json
import os
import re
import sys

WASM_DEP = '@img/sharp-wasm32'
WASM_RANGE = '^0.35.5'
WASM_VERSION = '0.35.5'
SNAPSHOT_HEADS = ["'@emnapi/runtime@1.11.3':", "'@img/sharp-wasm32@0.35.5':"]


def read(path):
    with open(path, 'r', encoding='utf-8') as handle:
        return handle.read()


def write(path, text):
    with open(path, 'w', encoding='utf-8') as handle:
        handle.write(text)


def adapt_root_package(root):
    path = os.path.join(root, 'package.json')
    data = json.loads(read(path))
    deps = data.get('dependencies')
    if not isinstance(deps, dict):
        deps = {}
        data['dependencies'] = deps
    if deps.get(WASM_DEP) == WASM_RANGE:
        return 'already'
    deps[WASM_DEP] = WASM_RANGE
    data['dependencies'] = dict(sorted(deps.items()))
    write(path, json.dumps(data, indent=2, ensure_ascii=False) + '\n')
    return 'patched'


def adapt_lockfile(root):
    path = os.path.join(root, 'pnpm-lock.yaml')
    text = read(path)
    if not text.startswith('lockfileVersion:'):
        return 'unexpected layout'
    importer_anchor = '\n  .:\n'
    marker = "      '%s':" % WASM_DEP
    changed = False
    if marker not in text.split('packages:')[0]:
        index = text.find(importer_anchor)
        if index < 0:
            return 'importer block not found'
        insert_at = index + len(importer_anchor)
        block = (
            '    dependencies:\n'
            "      '%s':\n"
            '        specifier: %s\n'
            '        version: %s\n'
        ) % (WASM_DEP, WASM_RANGE, WASM_VERSION)
        text = text[:insert_at] + block + text[insert_at:]
        changed = True
    for head in SNAPSHOT_HEADS:
        start = text.find('\n  %s\n' % head)
        if start < 0:
            continue
        next_head = text.find("\n  '", start + 1)
        end = len(text) if next_head < 0 else next_head
        block = text[start:end]
        trimmed = re.sub(r'\n    optional: true(?=\n)', '', block)
        if trimmed != block:
            text = text[:start] + trimmed + text[end:]
            changed = True
    if not changed:
        return 'already'
    write(path, text)
    return 'patched'


def adapt_worker_context(root):
    path = os.path.join(root, 'apps/web/product-isolation.ts')
    if not os.path.exists(path):
        return 'file missing'
    text = read(path)
    guarded = "typeof this.getWatchFiles === 'function' ? this.getWatchFiles() : []"
    if guarded in text:
        return 'already'
    pattern = re.compile(r'inputs\.workerBundle\(bundle, this\.getWatchFiles\(\)\)')
    if not pattern.search(text):
        return 'anchor not found'
    write(path, pattern.sub('inputs.workerBundle(bundle, %s)' % guarded, text))
    return 'patched'


HANDLERS = {
    '07': adapt_root_package,
    '08': adapt_lockfile,
    '09': adapt_worker_context,
}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--repo', required=True)
    parser.add_argument('--group', required=True)
    parser.add_argument('--list', action='store_true')
    args = parser.parse_args()

    if args.list:
        print(' '.join(sorted(HANDLERS)))
        return 0

    key = args.group.split('-')[0]
    handler = HANDLERS.get(key)
    if handler is None:
        print('no fallback for group %s' % args.group)
        return 2
    result = handler(args.repo)
    print('%s: %s' % (args.group, result))
    if result in ('patched', 'already'):
        return 0
    return 1


if __name__ == '__main__':
    sys.exit(main())
