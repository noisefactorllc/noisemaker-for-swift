#!/usr/bin/env node
// Fast integrity check for source-captured software Canvas byte fixtures.
import { createHash } from 'node:crypto'
import { readFileSync, readdirSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const out = resolve(process.argv[2] || join(ROOT, 'parity/overlays'))
const hash = bytes => createHash('sha256').update(bytes).digest('hex')
const lock = JSON.parse(readFileSync(join(ROOT, 'parity/reference.json')))
const oracle = JSON.parse(readFileSync(join(out, 'oracle.json')))
if (oracle.schemaVersion !== 1 || oracle.authority.repository !== lock.repository ||
    oracle.authority.commit !== lock.commit ||
    oracle.authority.sourceManifestSha256 !== lock.sourceManifestSha256 ||
    oracle.format.channels !== 'RGBA' || oracle.format.bitDepth !== 8 ||
    oracle.format.orientation !== 'top-down' || !Array.isArray(oracle.cases) ||
    oracle.cases.length !== 6) throw new Error('overlay oracle authority or capture contract mismatch')
const effects = new Set()
const names = ['oracle.json']
for (const item of oracle.cases) {
  if (!/^(fibers|scratches|strayHair)-[A-Za-z]+$/.test(item.id) ||
      item.file !== `${item.id}.rgba8` || !Number.isInteger(item.width) ||
      !Number.isInteger(item.height) || !Number.isInteger(item.updates) || item.updates < 2 ||
      item.segmentFile !== `${item.id}.segments.f64le` || !Number.isInteger(item.segmentCount) ||
      item.segmentCount < 1 || item.cap !== 'round' || item.join !== 'round' ||
      !item.canvasAttributes?.willReadFrequently || item.source.effectPath !==
      `shaders/effects/filter/${item.effect}/definition.js`) {
    throw new Error(`invalid overlay record ${item.id}`)
  }
  const bytes = readFileSync(join(out, item.file))
  if (bytes.length !== item.width * item.height * 4 || bytes.length !== item.bytes ||
      hash(bytes) !== item.sha256) throw new Error(`overlay pixel hash mismatch: ${item.id}`)
  let alphaPixels = 0
  for (let offset = 3; offset < bytes.length; offset += 4) if (bytes[offset] !== 0) alphaPixels++
  if (alphaPixels !== item.alphaPixels || alphaPixels === 0) throw new Error(`overlay alpha mismatch: ${item.id}`)
  effects.add(item.effect)
  names.push(item.file)
  const segments = readFileSync(join(out, item.segmentFile))
  if (segments.length !== item.segmentCount * 9 * 8 || segments.length !== item.segmentBytes ||
      hash(segments) !== item.segmentsSha256) throw new Error(`overlay stroke hash mismatch: ${item.id}`)
  names.push(item.segmentFile)
}
if (effects.size !== 3 || JSON.stringify(readdirSync(out).sort()) !== JSON.stringify(names.sort())) {
  throw new Error('overlay inventory mismatch')
}
process.stdout.write(JSON.stringify({ cases: oracle.cases.length, bytes: oracle.cases.reduce((sum, row) => sum + row.bytes, 0),
  ledgerSha256: hash(readFileSync(join(out, 'oracle.json'))) }) + '\n')
