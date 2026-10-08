#!/usr/bin/env node
// Verify the imported coverage tier against this port's locked catalog.
import { readFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const catalog = JSON.parse(readFileSync(join(root, 'Sources/Noisemaker/Resources/catalog.json'), 'utf8'))
const corpus = JSON.parse(readFileSync(join(root, 'parity/corpus.json'), 'utf8'))
const coverage = new Set(corpus.cases.filter(item => item.family === 'coverage').map(item => item.id))
const ordered = value => value?.$type === 'object' ? Object.fromEntries(value.entries.map(([key, item]) => [key, ordered(item)]))
  : Array.isArray(value) ? value.map(ordered) : value
const token = value => String(value).replace(/[^A-Za-z0-9]+/g, '_').replace(/^_+|_+$/g, '') || 'x'
const missing = []
let required = 0
for (const effect of catalog.effects) {
  const definition = ordered(effect.value)
  const stem = `${effect.namespace}_${effect.func}`
  const base = `coverage/${stem}`
  required++
  if (!coverage.has(base)) missing.push(base)
  for (const [parameter, spec] of Object.entries(definition.globals || {})) {
    const variants = []
    if (spec.choices && typeof spec.choices === 'object') {
      for (const [name, value] of Object.entries(spec.choices)) {
        if (name.endsWith(':') || value === spec.default ||
            (typeof value === 'number' && Number(spec.default) === value && spec.type !== 'member')) continue
        variants.push(name)
      }
    } else if (spec.type === 'boolean') variants.push(String(!(spec.default === true)))
    for (const value of variants) {
      const id = `${base}__${token(parameter)}_${token(value)}`
      required++
      if (!coverage.has(id)) missing.push(id)
    }
  }
}
process.stdout.write(JSON.stringify({ effects: catalog.effects.length, required, present: required - missing.length,
  missing: missing.length, examples: missing.slice(0, 30) }) + '\n')
if (missing.length) process.exitCode = 1
