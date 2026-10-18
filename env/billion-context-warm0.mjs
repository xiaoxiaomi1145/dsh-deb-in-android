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
