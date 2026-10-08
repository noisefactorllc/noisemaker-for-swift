import test from 'node:test'
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { copyFileSync, mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'

test('software Canvas overlay raw bytes are complete and tamper-detecting', () => {
  const root = mkdtempSync(join(tmpdir(), 'nm-overlays-'))
  const out = join(root, 'overlays')
  mkdirSync(out)
  const source = resolve('parity/overlays')
  const oracle = JSON.parse(readFileSync(join(source, 'oracle.json')))
  for (const item of oracle.cases) {
    copyFileSync(join(source, item.file), join(out, item.file))
    copyFileSync(join(source, item.segmentFile), join(out, item.segmentFile))
  }
  copyFileSync(join(source, 'oracle.json'), join(out, 'oracle.json'))
  const check = () => execFileSync(process.execPath, ['tools/check-overlays.mjs', out], { stdio: 'pipe' })
  try {
    check()
    const bytes = readFileSync(join(out, oracle.cases[0].file))
    bytes[0] ^= 1
    writeFileSync(join(out, oracle.cases[0].file), bytes)
    assert.throws(() => check(), /Command failed/)
  } finally { rmSync(root, { recursive: true, force: true }) }
})
