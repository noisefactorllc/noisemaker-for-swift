#!/usr/bin/env node
// Fast integrity check for source-captured software Canvas byte fixtures.
import { createHash } from 'node:crypto'
import { readFileSync, readdirSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const out = resolve(process.argv[2] || join(ROOT, 'parity/overlays'))
const hash = bytes => createHash('sha256').update(bytes).digest('hex')
const expected = new Map([
  ['fibers-default', ['fibers', 65, 33, {}]],
  ['fibers-dense', ['fibers', 67, 35, { seed: 2, density: 1 }]],
  ['fibers-coverage-256', ['fibers', 256, 256, { seed: 1, density: 1 }, 'coverage/filter_fibers']],
  ['scratches-default', ['scratches', 65, 33, {}]],
  ['scratches-seeded', ['scratches', 67, 35, { seed: 2, density: 0.8 }]],
  ['scratches-coverage-256', ['scratches', 256, 256, { seed: 1, density: 0.3 }, 'coverage/filter_scratches']],
  ['strayHair-default', ['strayHair', 65, 33, {}]],
  ['strayHair-dense', ['strayHair', 69, 31, { seed: 3, density: 1 }]],
  ['strayHair-coverage-256', ['strayHair', 256, 256, { seed: 1, density: 1 }, 'coverage/filter_strayHair']]
])
const lock = JSON.parse(readFileSync(join(ROOT, 'parity/reference.json')))
const oracle = JSON.parse(readFileSync(join(out, 'oracle.json')))
if (oracle.schemaVersion !== 1 || oracle.authority.repository !== lock.repository ||
    oracle.authority.commit !== lock.commit ||
    oracle.authority.sourceManifestSha256 !== lock.sourceManifestSha256 ||
    oracle.format.channels !== 'RGBA' || oracle.format.bitDepth !== 8 ||
    oracle.format.orientation !== 'top-down' || !Array.isArray(oracle.cases) ||
    oracle.cases.length !== expected.size) throw new Error('overlay oracle authority or capture contract mismatch')
const effects = new Set()
const seen = new Set()
const names = ['oracle.json']
for (const item of oracle.cases) {
  const spec = expected.get(item.id)
  if (!spec || seen.has(item.id) || item.effect !== spec[0] ||
      item.width !== spec[1] || item.height !== spec[2] ||
      JSON.stringify(item.params) !== JSON.stringify(spec[3]) ||
      item.file !== `${item.id}.rgba8` || !Number.isInteger(item.updates) || item.updates < 2 ||
      item.segmentFile !== `${item.id}.segments.f64le` || !Number.isInteger(item.segmentCount) ||
      item.segmentCount < 1 || item.cap !== 'round' || item.join !== 'round' ||
      !item.canvasAttributes?.willReadFrequently || item.source.effectPath !==
      `shaders/effects/filter/${item.effect}/definition.js`) {
    throw new Error(`invalid overlay record ${item.id}`)
  }
  seen.add(item.id)
  const bytes = readFileSync(join(out, item.file))
  if (bytes.length !== item.width * item.height * 4 || bytes.length !== item.bytes ||
      hash(bytes) !== item.sha256) throw new Error(`overlay pixel hash mismatch: ${item.id}`)
  const hostCase = spec[4]
  if (hostCase) {
    const upload = item.hostUpload
    if (!upload || Object.keys(upload).sort().join(',') !== 'sha256,sourceCaseId,textureId' ||
        upload.sourceCaseId !== hostCase || upload.textureId !== 'node_1_overlayTex' ||
        !/^[a-f0-9]{64}$/.test(upload.sha256)) {
      throw new Error(`overlay host upload metadata mismatch: ${item.id}`)
    }
    const rowBytes = item.width * 4
    const uploaded = Buffer.allocUnsafe(bytes.length)
    for (let row = 0; row < item.height; row++) {
      bytes.copy(uploaded, row * rowBytes, (item.height - 1 - row) * rowBytes,
        (item.height - row) * rowBytes)
    }
    if (hash(uploaded) !== upload.sha256) {
      throw new Error(`overlay host upload hash mismatch: ${item.id}`)
    }
  } else if (item.hostUpload !== undefined) {
    throw new Error(`unexpected overlay host upload metadata: ${item.id}`)
  }
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
if (seen.size !== expected.size || effects.size !== 3 ||
    JSON.stringify(readdirSync(out).sort()) !== JSON.stringify(names.sort())) {
  throw new Error('overlay inventory mismatch')
}
process.stdout.write(JSON.stringify({ cases: oracle.cases.length, bytes: oracle.cases.reduce((sum, row) => sum + row.bytes, 0),
  ledgerSha256: hash(readFileSync(join(out, 'oracle.json'))) }) + '\n')
