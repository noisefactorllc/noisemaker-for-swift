import test from 'node:test'
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { appendFileSync, cpSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { fetchVerifiedArchive } from '../tools/export-reference.mjs'
import { verifyArchivedSource } from './marker-golden.mjs'

test('archived browser source must match the locked export byte for byte with no extra inputs', () => {
  const lock = JSON.parse(readFileSync('parity/reference.json', 'utf8'))
  const authority = process.env.NM_REFERENCE_ROOT
    ? { root: resolve(process.env.NM_REFERENCE_ROOT), cleanup: () => {} }
    : fetchVerifiedArchive(lock)
  const out = mkdtempSync(join(tmpdir(), 'nm-marker-manifest-'))
  const archiveRoot = mkdtempSync(join(tmpdir(), 'nm-marker-archive-'))
  try {
    for (const path of ['package.json', 'share/palettes.json', 'shaders/src', 'shaders/effects',
      'demo/shaders', 'vendor/shade-mcp/harness']) {
      cpSync(join(authority.root, path), join(archiveRoot, path), { recursive: true })
    }
    execFileSync(process.execPath, ['tools/export-reference.mjs', out],
      { env: { ...process.env, NM_REFERENCE_ROOT: authority.root } })
    assert.doesNotThrow(() => verifyArchivedSource(archiveRoot, lock, out))
    const archivedOut = mkdtempSync(join(tmpdir(), 'nm-marker-archive-export-'))
    try {
      execFileSync(process.execPath, ['tools/export-reference.mjs', archivedOut],
        { env: { ...process.env, NM_REFERENCE_ROOT: archiveRoot } })
      assert.deepEqual(readFileSync(join(archivedOut, 'source-manifest.json')),
        readFileSync(join(out, 'source-manifest.json')))
    } finally { rmSync(archivedOut, { recursive: true, force: true }) }
    const html = join(archiveRoot, 'demo/shaders/index.html')
    appendFileSync(html, '\n<!-- tamper -->\n')
    assert.throws(() => verifyArchivedSource(archiveRoot, lock, out), /differs at demo\/shaders\/index.html/)
    writeFileSync(html, readFileSync(join(authority.root, 'demo/shaders/index.html')))
    const injected = join(archiveRoot, 'shaders/src/runtime/injected.js')
    writeFileSync(injected, 'export default 1\n')
    assert.throws(() => verifyArchivedSource(archiveRoot, lock, out), /file count differs/)
  } finally {
    authority.cleanup()
    rmSync(out, { recursive: true, force: true })
    rmSync(archiveRoot, { recursive: true, force: true })
  }
})
