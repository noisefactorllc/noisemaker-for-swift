#!/usr/bin/env node
// Regenerate or check the bundled catalog against the locked upstream source.
import { createHash } from 'node:crypto'
import { copyFileSync, existsSync, mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { exportAuthority, fetchVerifiedArchive } from './export-reference.mjs'

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const RESOURCE = join(ROOT, 'Sources/Noisemaker/Resources/catalog.json')
const hash = bytes => createHash('sha256').update(bytes).digest('hex')

async function main() {
  const mode = process.argv[2] || '--check'
  if (!['--check', '--write'].includes(mode) || process.argv.length > 3) {
    throw new Error('usage: node tools/import-catalog.mjs [--check|--write]')
  }
  const lock = JSON.parse(readFileSync(join(ROOT, 'parity/reference.json'), 'utf8'))
  const out = mkdtempSync(join(tmpdir(), 'nm-swift-catalog-'))
  const archive = process.env.NM_REFERENCE_ROOT ? null : fetchVerifiedArchive(lock)
  try {
    const ref = resolve(process.env.NM_REFERENCE_ROOT || archive.root)
    await exportAuthority(ref, out, lock, !!archive)
    const generated = join(out, 'catalog.json')
    const bytes = readFileSync(generated)
    if (mode === '--write') copyFileSync(generated, RESOURCE)
    else if (!existsSync(RESOURCE) || !readFileSync(RESOURCE).equals(bytes)) {
      throw new Error(`bundled catalog differs from locked upstream source; run node tools/import-catalog.mjs --write`)
    }
    const catalog = JSON.parse(bytes)
    if (catalog.effectCount !== catalog.effects.length ||
        catalog.validatorOps.entries.length !== catalog.effects.length ||
        !Array.isArray(catalog.paletteTable) || !catalog.paletteTable.length ||
        !catalog.paletteTable.every(entry => entry.$type === 'object' &&
          ['amp', 'freq', 'offset', 'phase', 'mode'].every(key => entry.entries.some(([name]) => name === key))) ||
        !catalog.effects.every(effect => ['onInit', 'onUpdate', 'onDestroy', 'asyncInit']
          .every(key => typeof effect.lifecycle?.[key] === 'boolean')) ||
        new Set(catalog.effects.map(effect => effect.key)).size !== catalog.effects.length) {
      throw new Error('source catalog inventory, unique keys, and validator registrations disagree')
    }
    process.stdout.write(JSON.stringify({ mode, sha256: hash(bytes), effects: catalog.effectCount,
      validatorOps: catalog.validatorOps.entries.length, starterOps: catalog.starterOps.length }) + '\n')
  } finally {
    archive?.cleanup()
    rmSync(out, { recursive: true, force: true })
  }
}

main().catch(error => { process.stderr.write(`${error?.stack || String(error)}\n`); process.exitCode = 1 })
