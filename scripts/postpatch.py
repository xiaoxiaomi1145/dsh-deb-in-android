import sys, pathlib
root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else '.')
targets = [
    ('packages/client/ui-chat/src/client/chat/UserContent.tsx',
     '{showBubble && <div className={css.bubble}>',
     '{showBubble && <div className={css.bubble} data-text-interaction-source="">'),
]
failed = []
for rel, old, new in targets:
    p = root / rel
    if not p.exists():
        failed.append(rel + ' 不存在')
        continue
    t = p.read_text()
    if new in t or 'data-text-interaction-source' in t:
        print('skip ' + rel)
        continue
    if old not in t:
        failed.append(rel + ' 找不到锚点')
        continue
    p.write_text(t.replace(old, new, 1))
    print('patched ' + rel)
if failed:
    print('FAILED: ' + '; '.join(failed), file=sys.stderr)
    sys.exit(1)
p = root / 'packages/client/ui-chat/src/client/chat/UserContent.tsx'
if 'data-text-interaction-source' not in p.read_text():
    print('FAILED: 校验未通过', file=sys.stderr)
    sys.exit(1)
print('ok 后处理校验通过')
