#!/usr/bin/env node
// Bundle exact built-in OBJ bytes from the locked upstream source.
import { createHash } from 'node:crypto'
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { fetchVerifiedArchive, sourceIdentity } from './export-reference.mjs'

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const DEFAULT_OUT = join(ROOT, 'Sources/Noisemaker/Resources/meshes')
const hash = bytes => createHash('sha256').update(bytes).digest('hex')

function inputs(ref, lock) {
  sourceIdentity(ref, lock)
  const dir = join(ref, 'share/meshes')
  const files = readdirSync(dir).filter(name => /^[A-Za-z0-9_-]+\.obj$/.test(name)).sort()
  if (!files.length) throw new Error('locked upstream has no built-in OBJ meshes')
  const entries = files.map(name => {
    const bytes = readFileSync(join(dir, name))
    return { name, bytes, sha256: hash(bytes) }
  })
  const manifest = { schemaVersion: 1, authority: { repository: lock.repository,
    commit: lock.commit, sourceManifestSha256: lock.sourceManifestSha256,
    licenseSha256: lock.licenseSha256 },
  files: entries.map(({ name, bytes, sha256 }) => ({ name, sha256, bytes: bytes.length })) }
  return { entries, manifestBytes: Buffer.from(JSON.stringify(manifest, null, 2) + '\n') }
}

async function main() {
  const [mode = '--check', outArg = DEFAULT_OUT] = process.argv.slice(2)
  if (!['--check', '--write'].includes(mode) || process.argv.length > 4) {
    throw new Error('usage: node tools/import-meshes.mjs [--check|--write] [out-dir]')
  }
  const lock = JSON.parse(readFileSync(join(ROOT, 'parity/reference.json')))
  const archive = process.env.NM_REFERENCE_ROOT ? null : fetchVerifiedArchive(lock)
  try {
    const { entries, manifestBytes } = inputs(resolve(process.env.NM_REFERENCE_ROOT || archive.root), lock)
    const out = resolve(outArg)
    const names = [...entries.map(entry => entry.name), 'manifest.json'].sort()
    if (mode === '--check') {
      if (!existsSync(out) || JSON.stringify(readdirSync(out).sort()) !== JSON.stringify(names)) {
        throw new Error('bundled mesh inventory differs from locked upstream')
      }
      for (const entry of entries) if (!readFileSync(join(out, entry.name)).equals(entry.bytes)) {
        throw new Error(`bundled mesh differs from locked upstream: ${entry.name}`)
      }
      if (!readFileSync(join(out, 'manifest.json')).equals(manifestBytes)) {
        throw new Error('bundled mesh manifest differs from locked upstream')
      }
    } else {
      if (existsSync(out) && readdirSync(out).some(name => !names.includes(name))) {
        throw new Error('bundled mesh directory contains unrelated files')
      }
      mkdirSync(out, { recursive: true })
      for (const entry of entries) writeFileSync(join(out, entry.name), entry.bytes)
      writeFileSync(join(out, 'manifest.json'), manifestBytes)
    }
    process.stdout.write(JSON.stringify({ mode, files: entries.length,
      bytes: entries.reduce((sum, entry) => sum + entry.bytes.length, 0),
      manifestSha256: hash(manifestBytes) }) + '\n')
  } finally { archive?.cleanup() }
}

main().catch(error => { process.stderr.write(`${error?.stack || String(error)}\n`); process.exitCode = 1 })
