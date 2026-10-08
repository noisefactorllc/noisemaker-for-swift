import test from 'node:test'
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

test('locked OBJ oracle covers builtins, edge semantics, and full texture packing', () => {
  const root = mkdtempSync(join(tmpdir(), 'nm-obj-oracle-'))
  const output = join(root, 'obj-oracle.json')
  const run = mode => execFileSync(process.execPath, ['tools/export-obj-oracle.mjs', mode, output],
    { env: process.env, stdio: 'pipe' })
  try {
    run('--write')
    run('--check')
    const oracle = JSON.parse(readFileSync(output))
    assert.equal(oracle.builtins.length, 7)
    assert.equal(oracle.edgeCases.length, 6)
    assert.ok(oracle.builtins.every(item => item.packed.positions.length === 256 * 256 * 4))
    const negative = oracle.edgeCases.find(item => item.id === 'negative-and-missing')
    assert.deepEqual(negative.parsed.positions.values, [0,0,0, 0,0,0, 1,2,3])
    const truncated = oracle.edgeCases.find(item => item.id === 'truncated-quad')
    assert.equal(truncated.vertexCount, 6)
    assert.equal(truncated.packedVertexCount, 2)
    const degenerate = oracle.edgeCases.find(item => item.id === 'degenerate-face')
    assert.deepEqual(degenerate.parsed.normals.values, [0,0,1, 0,0,1, 0,0,1])
    oracle.builtins[0].packed.positions.sha256 = '0'.repeat(64)
    writeFileSync(output, JSON.stringify(oracle))
    assert.throws(() => run('--check'), /Command failed/)
  } finally { rmSync(root, { recursive: true, force: true }) }
})
