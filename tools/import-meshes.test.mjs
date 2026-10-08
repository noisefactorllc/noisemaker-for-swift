import test from 'node:test'
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { appendFileSync, mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

test('bundled OBJ bytes and inventory are exact locked-source data', () => {
  const root = mkdtempSync(join(tmpdir(), 'nm-mesh-oracle-'))
  const out = join(root, 'meshes')
  const run = mode => execFileSync(process.execPath, ['tools/import-meshes.mjs', mode, out],
    { env: process.env, stdio: 'pipe' })
  try {
    run('--write')
    run('--check')
    const manifest = JSON.parse(readFileSync(join(out, 'manifest.json')))
    assert.equal(manifest.files.length, 7)
    assert.ok(manifest.files.every(file => file.name.endsWith('.obj') && file.bytes > 0))
    appendFileSync(join(out, 'cube.obj'), '\n# changed\n')
    assert.throws(() => run('--check'), /Command failed/)
  } finally { rmSync(root, { recursive: true, force: true }) }
})
