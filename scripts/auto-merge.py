#!/usr/bin/env python3
import argparse
import os
import re
import subprocess
import sys

START = '<<<<<<<'
MID = '======='
END = '>>>>>>>'
COMMENT_PREFIXES = ('//', '/*', '*/', '*', '#', '--', ';')


def is_comment(line):
    stripped = line.strip()
    if not stripped:
        return True
    return stripped.startswith(COMMENT_PREFIXES)


def conflicted_files(repo):
    out = subprocess.run(['git', '-C', repo, 'diff', '--name-only', '--diff-filter=U'], capture_output=True, text=True)
    return [line for line in out.stdout.splitlines() if line.strip()]


def split_blocks(text):
    lines = text.splitlines(keepends=True)
    blocks = []
    current = None
    for line in lines:
        if line.startswith(START):
            current = {'ours': [], 'theirs': [], 'phase': 'ours', 'start': line.rstrip('\n')}
            continue
        if current is None:
            continue
        if line.startswith(MID) and current['phase'] == 'ours':
            current['phase'] = 'theirs'
            continue
        if line.startswith(END):
            blocks.append(current)
            current = None
            continue
        current[current['phase']].append(line)
    return blocks


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--repo', required=True)
    parser.add_argument('--keep', choices=['ours', 'theirs'], default='ours')
    args = parser.parse_args()

    files = conflicted_files(args.repo)
    if not files:
        print('no conflicts')
        return 1

    code_conflicts = []
    resolved = []
    for relative in files:
        full = os.path.join(args.repo, relative)
        with open(full, 'r', encoding='utf-8', errors='replace') as handle:
            text = handle.read()
        blocks = split_blocks(text)
        if not blocks:
            code_conflicts.append((relative, 'unparsable conflict'))
            continue
        bad = [block for block in blocks if not all(is_comment(line) for line in block['ours'] + block['theirs'])]
        if bad:
            code_conflicts.append((relative, '%d code conflict(s)' % len(bad)))
            continue
        out = []
        in_block = False
        for line in text.splitlines(keepends=True):
            if line.startswith(START):
                in_block = True
                out.append(line)
                continue
            if line.startswith(MID) and in_block:
                continue
            if line.startswith(END) and in_block:
                in_block = False
                out.append(line)
                continue
            if in_block:
                continue
            out.append(line)
        merged = ''.join(out)
        merged = re.sub(r'(?m)^<<<<<<<.*\n', '', merged)
        merged = re.sub(r'(?m)^>>>>>>>.*\n', '', merged)
        with open(full, 'w', encoding='utf-8') as handle:
            handle.write(merged)
        resolved.append(relative)

    if code_conflicts:
        print('comment-only resolution impossible:')
        for relative, reason in code_conflicts:
            print('  %s: %s' % (relative, reason))
        return 1

    subprocess.run(['git', '-C', args.repo, 'add'] + resolved, capture_output=True, text=True)
    print('resolved comment-only conflicts: %s' % ', '.join(resolved))
    return 0


if __name__ == '__main__':
    sys.exit(main())
