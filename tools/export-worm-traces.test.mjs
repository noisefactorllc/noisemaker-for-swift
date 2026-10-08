import test from 'node:test'
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

test('locked worm tracer exports deterministic geometry and rejects changed oracle bytes', () => {
  const root = mkdtempSync(join(tmpdir(), 'nm-worm-oracle-'))
  const path = join(root, 'traces.json')
  const run = mode => execFileSync(process.execPath, ['tools/export-worm-traces.mjs', mode, path],
    { env: process.env })
  try {
    run('--write')
    const first = readFileSync(path)
    const oracle = JSON.parse(first)
    assert.equal(oracle.authority.commit, JSON.parse(readFileSync('parity/reference.json')).commit)
    assert.ok(oracle.source.sha256)
    assert.equal(oracle.rng.length, 6)
    assert.equal(oracle.traces.length, 5)
    assert.ok(oracle.traces.every(item => item.segmentCount > 0 && item.events.length > 0))
    assert.deepEqual(new Set(oracle.traces.map(item => item.options.behavior)),
      new Set(['chaotic', 'obedient', 'unruly']))
    run('--check')
    run('--write')
    assert.deepEqual(readFileSync(path), first)
    writeFileSync(path, first.toString().replace('"segmentCount":', '"segmentCount": -1, "tamper":'))
    assert.throws(() => run('--check'), /Command failed/)
  } finally { rmSync(root, { recursive: true, force: true }) }
})
