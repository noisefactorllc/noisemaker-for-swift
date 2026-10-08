import test from 'node:test'
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { createHash } from 'node:crypto'
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
  const refuse = pattern => assert.throws(check, error => pattern.test(String(error.stderr)))
  const writeOracle = value => writeFileSync(join(out, 'oracle.json'), JSON.stringify(value))
  const tamperOracle = (mutate, pattern) => {
    const changed = structuredClone(oracle)
    mutate(changed)
    writeOracle(changed)
    refuse(pattern)
    writeOracle(oracle)
  }
  try {
    assert.equal(JSON.parse(check()).cases, 9)
    tamperOracle(value => { value.cases.pop() }, /overlay oracle authority or capture contract mismatch/)
    tamperOracle(value => { value.cases[2] = structuredClone(value.cases[0]) }, /invalid overlay record/)
    tamperOracle(value => { value.cases[2].id = 'fibers-unknown' }, /invalid overlay record/)
    tamperOracle(value => { value.cases[2].hostUpload.sourceCaseId = 'coverage/filter_scratches' },
      /overlay host upload metadata mismatch/)
    tamperOracle(value => { value.cases[2].hostUpload.sha256 = '0'.repeat(64) },
      /overlay host upload hash mismatch/)
    const bytes = readFileSync(join(out, oracle.cases[0].file))
    bytes[0] ^= 1
    writeFileSync(join(out, oracle.cases[0].file), bytes)
    refuse(/overlay pixel hash mismatch/)
    bytes[0] ^= 1
    writeFileSync(join(out, oracle.cases[0].file), bytes)
    const coverage = oracle.cases.find(item => item.id === 'fibers-coverage-256')
    const coveragePath = join(out, coverage.file)
    const coverageBytes = readFileSync(coveragePath)
    coverageBytes[0] ^= 1
    writeFileSync(coveragePath, coverageBytes)
    tamperOracle(value => {
      value.cases.find(item => item.id === coverage.id).sha256 =
        createHash('sha256').update(coverageBytes).digest('hex')
    }, /overlay host upload hash mismatch/)
  } finally { rmSync(root, { recursive: true, force: true }) }
})
