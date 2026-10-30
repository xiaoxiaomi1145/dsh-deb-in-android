#!/usr/bin/env python3
import argparse
import os
import re
import sys

DIFF_HEADER = re.compile(r'^diff --git a/(.+?) b/(.+?)$')
NEW_FILE = re.compile(r'^new file mode ')
DELETED_FILE = re.compile(r'^deleted file mode ')
HUNK = re.compile(r'^@@')
TRIVIAL = set(['{', '}', '(', ')', '};', ');', '],', '[,', 'else', 'try {', '} catch {', '});'])
COMMENT_PREFIXES = ('//', '/*', '*/', '*', '#')


def is_comment_only(line):
    stripped = line.strip()
    return stripped.startswith(COMMENT_PREFIXES)


def normalize(text):
    return re.sub(r'\s+', ' ', text).strip()


def parse_patch(path):
    files = []
    current = None
    in_hunk = False
    with open(path, 'r', encoding='utf-8', errors='replace') as handle:
        for raw in handle:
            line = raw.rstrip('\n')
            header = DIFF_HEADER.match(line)
            if header:
                current = {'target': header.group(2), 'added': [], 'new': False, 'deleted': False}
                files.append(current)
                in_hunk = False
                continue
            if current is None:
                continue
            if NEW_FILE.match(line):
                current['new'] = True
                continue
            if DELETED_FILE.match(line):
                current['deleted'] = True
                continue
            if HUNK.match(line):
                in_hunk = True
                continue
            if not in_hunk:
                continue
            if line.startswith('+++') or line.startswith('---'):
                continue
            if line.startswith('+'):
                body = line[1:]
                if normalize(body) in TRIVIAL:
                    continue
                if len(normalize(body)) < 4:
                    continue
                current['added'].append(body)
    return files


def read_target(root, relative):
    full = os.path.join(root, relative)
    if not os.path.exists(full):
        return None
    with open(full, 'r', encoding='utf-8', errors='replace') as handle:
        return handle.read()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--repo', required=True)
    parser.add_argument('--patch', required=True)
    parser.add_argument('--json', action='store_true')
    args = parser.parse_args()

    files = parse_patch(args.patch)
    missing = []
    checked = 0
    for entry in files:
        if entry['deleted']:
            if os.path.exists(os.path.join(args.repo, entry['target'])):
                missing.append({'file': entry['target'], 'reason': 'file should be deleted', 'line': ''})
            continue
        content = read_target(args.repo, entry['target'])
        if content is None:
            missing.append({'file': entry['target'], 'reason': 'file missing', 'line': ''})
            continue
        blob = normalize(content)
        remainder = content
        normalized_remainder = blob
        for line in entry['added']:
            want = normalize(line)
            if is_comment_only(line):
                continue
            if want in normalized_remainder:
                checked += 1
                continue
            missing.append({'file': entry['target'], 'reason': 'added line absent', 'line': want[:120]})
            break

    if args.json:
        import json
        print(json.dumps({'checked': checked, 'missing': missing}, ensure_ascii=False))
    else:
        if missing:
            print('verify: %d missing' % len(missing))
            for item in missing:
                print('  %s: %s %s' % (item['file'], item['reason'], item['line']))
        else:
            print('verify: ok (%d lines)' % checked)
    return 1 if missing else 0


if __name__ == '__main__':
    sys.exit(main())
