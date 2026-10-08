#!/usr/bin/env node
// Exact geometry oracle from the pinned upstream CPU worm tracer.
import { createHash } from 'node:crypto'
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { encode, fetchVerifiedArchive, sourceIdentity } from './export-reference.mjs'

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const SOURCE_PATH = 'shaders/src/cpu/wormTracer.js'
const hash = bytes => createHash('sha256').update(bytes).digest('hex')

const TRACE_CASES = [
  { id: 'fiber-chaotic-odd', width: 17, height: 11, seed: 1001, density: 1.3,
    kink: 6, stride: 0.75, strideDeviation: 0.125, duration: 1,
    behavior: 'chaotic', flowFreq: 4, lineWidth: 1.5, colorModel: 'fibers' },
  { id: 'scratch-obedient-odd', width: 19, height: 13, seed: 1251, density: 0.22,
    kink: 0.25, stride: 0.75, strideDeviation: 0.5, duration: 2,
    behavior: 'obedient', flowFreq: 2, lineWidth: 0.5, colorModel: 'scratches' },
  { id: 'hair-unruly-odd', width: 21, height: 9, seed: 1042, density: 0.005,
    kink: 7, stride: 0.5, strideDeviation: 0.25, duration: 8,
    behavior: 'unruly', flowFreq: 4, lineWidth: 1, colorModel: 'strayHair' },
  { id: 'overflow-chaotic-odd', width: 13, height: 7, seed: 4294967297, density: 0.35,
    kink: 2.5, stride: 1.125, strideDeviation: 0.375, duration: 3,
    behavior: 'chaotic', flowFreq: 3, lineWidth: 0.75, colorModel: 'variable' },
  { id: 'negative-obedient-odd', width: 15, height: 17, seed: -17, density: 0.4,
    kink: 1.75, stride: 0.625, strideDeviation: 0.25, duration: 2,
    behavior: 'obedient', flowFreq: 5, lineWidth: 1.25, colorModel: 'red' }
]

function colorFunction(name) {
  if (name === 'fibers') return rng => ({
    r: Math.floor(rng.float() * 200 + 55), g: Math.floor(rng.float() * 200 + 55),
    b: Math.floor(rng.float() * 200 + 55), a: 0.5 })
  if (name === 'scratches') return () => ({ r: 255, g: 255, b: 255, a: 1 })
  if (name === 'strayHair') return rng => ({
    r: Math.floor(rng.float() * 30), g: Math.floor(rng.float() * 30),
    b: Math.floor(rng.float() * 30), a: 0.666 })
  if (name === 'variable') return rng => ({
    r: Math.floor(rng.float() * 256), g: Math.floor(rng.float() * 256),
    b: Math.floor(rng.float() * 256), a: 0.25 + 0.75 * rng.float() })
  if (name === 'red') return () => ({ r: 223, g: 17, b: 41, a: 0.75 })
  throw new Error(`unknown color model ${name}`)
}

function recordingContext(width, height) {
  const events = []
  const context = { canvas: { width, height },
    beginPath() { events.push(['beginPath']) },
    moveTo(x, y) { events.push(['moveTo', x, y]) },
    lineTo(x, y) { events.push(['lineTo', x, y]) },
    stroke() { events.push(['stroke']) } }
  for (const property of ['lineCap', 'lineJoin', 'lineWidth', 'strokeStyle']) {
    Object.defineProperty(context, property, { set(value) { events.push([property, value]) } })
  }
  return { context, events }
}

function rngRecord(SeededRNG, seed) {
  const values = new SeededRNG(seed)
  const floats = new SeededRNG(seed)
  const integers = new SeededRNG(seed)
  const normals = new SeededRNG(seed)
  return { seed, next: Array.from({ length: 12 }, () => values.next()),
    float: Array.from({ length: 8 }, () => floats.float()),
    int: Array.from({ length: 8 }, () => integers.int(-7, 11)),
    normal: Array.from({ length: 4 }, () => normals.normal(0.25, 1.5)) }
}

async function traceRecord(traceWorms, options) {
  const { context, events } = recordingContext(options.width, options.height)
  let progressCalls = 0
  await traceWorms(context, { ...options, colorFn: colorFunction(options.colorModel),
    isCancelled: () => false,
    onProgress: canvas => {
      if (canvas !== context.canvas) throw new Error('source tracer progress canvas differs from recording context')
      progressCalls++
    } })
  const encoded = encode(events)
  const segmentCount = events.filter(event => event[0] === 'stroke').length
  if (!segmentCount || events.filter(event => event[0] === 'beginPath').length !== segmentCount ||
      events.filter(event => event[0] === 'moveTo').length !== segmentCount ||
      events.filter(event => event[0] === 'lineTo').length !== segmentCount) {
    throw new Error(`${options.id}: source tracer produced incomplete segment commands`)
  }
  return { id: options.id, options, segmentCount, progressCalls,
    eventsSha256: hash(JSON.stringify(encoded)), events: encoded }
}

async function generate(ref, lock) {
  sourceIdentity(ref, lock)
  const sourceBytes = readFileSync(join(ref, SOURCE_PATH))
  const { SeededRNG, traceWorms } = await import(pathToFileURL(join(ref, SOURCE_PATH)).href)
  const seeds = [0, 1, -1, 4294967295, 4294967297, Number.MAX_SAFE_INTEGER]
  const result = { schemaVersion: 1,
    authority: { repository: lock.repository, commit: lock.commit,
      sourceManifestSha256: lock.sourceManifestSha256 },
    source: { path: SOURCE_PATH, sha256: hash(sourceBytes), bytes: sourceBytes.length },
    rng: seeds.map(seed => rngRecord(SeededRNG, seed)),
    traces: [] }
  for (const options of TRACE_CASES) result.traces.push(await traceRecord(traceWorms, options))
  return Buffer.from(JSON.stringify(result, null, 2) + '\n')
}

async function main() {
  const [mode = '--check', pathArg = join(ROOT, 'parity/worm-traces.json')] = process.argv.slice(2)
  if (!['--check', '--write'].includes(mode)) throw new Error('usage: node tools/export-worm-traces.mjs [--check|--write] [output.json]')
  const lock = JSON.parse(readFileSync(join(ROOT, 'parity/reference.json')))
  const archive = process.env.NM_REFERENCE_ROOT ? null : fetchVerifiedArchive(lock)
  try {
    const bytes = await generate(resolve(process.env.NM_REFERENCE_ROOT || archive.root), lock)
    const path = resolve(pathArg)
    if (mode === '--check') {
      if (!existsSync(path) || !readFileSync(path).equals(bytes)) throw new Error('worm trace oracle differs from locked upstream source')
    } else {
      mkdirSync(dirname(path), { recursive: true })
      writeFileSync(path, bytes)
    }
    process.stdout.write(JSON.stringify({ mode, sha256: hash(bytes), traces: TRACE_CASES.length }) + '\n')
  } finally { archive?.cleanup() }
}

main().catch(error => { process.stderr.write(`${error?.stack || String(error)}\n`); process.exitCode = 1 })
