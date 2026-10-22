#!/usr/bin/env node
// generate-kit-compat.mjs: the export kit's effect list.
//
// Writes export-kit/compat-effects.json: a JSON array of the `<namespace>/<name>`
// keys of every effect in the bundled catalog
// (Sources/Noisemaker/Resources/catalog.json), sorted. The kit builder reads it
// (kit.config.json `compat.fromJsonList`) to write the kit's compat.json, the
// list of effects Noisedeck's export dialog lets this kit render. The full
// parity sweep requires informative exact or strict evidence for every catalog
// effect (scripts/parity-summary).
//
// Usage:
//   node tools/generate-kit-compat.mjs           write the file
//   node tools/generate-kit-compat.mjs --check   exit 1 if the file is stale

import { existsSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, join, relative, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const CATALOG = join(ROOT, 'Sources', 'Noisemaker', 'Resources', 'catalog.json')
const OUT = join(ROOT, 'export-kit', 'compat-effects.json')

const args = process.argv.slice(2)
const check = args.includes('--check')
for (const arg of args) {
  if (arg !== '--check') {
    console.error(`generate-kit-compat: unknown argument ${arg}`)
    process.exit(2)
  }
}

const catalog = JSON.parse(readFileSync(CATALOG, 'utf8'))
const ids = (catalog.effects || []).map(effect => effect.key)
if (!ids.length || ids.length !== catalog.effectCount || new Set(ids).size !== ids.length ||
    !ids.every(id => typeof id === 'string' && /^[A-Za-z0-9]+\/[A-Za-z0-9]+$/.test(id))) {
  console.error(`generate-kit-compat: ${relative(ROOT, CATALOG)} has no consistent effect inventory`)
  process.exit(1)
}
ids.sort()
const text = JSON.stringify(ids, null, 2) + '\n'

if (check) {
  const current = existsSync(OUT) ? readFileSync(OUT, 'utf8') : null
  if (current !== text) {
    console.error(`generate-kit-compat: ${relative(ROOT, OUT)} is stale; run node tools/generate-kit-compat.mjs`)
    process.exit(1)
  }
  console.log(`KIT-COMPAT: ${ids.length} effects, ${relative(ROOT, OUT)} is current`)
} else {
  writeFileSync(OUT, text)
  console.log(`KIT-COMPAT: ${ids.length} effects -> ${relative(ROOT, OUT)}`)
}
