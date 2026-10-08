#!/usr/bin/env node
// Capture exact software Canvas bytes from pinned built-in CPU overlay hooks.
import { createHash } from 'node:crypto'
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { sourceIdentity } from './export-reference.mjs'
import { verifyArchivedSource } from '../parity/marker-golden.mjs'

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const SOURCE_WORM = 'shaders/src/cpu/wormTracer.js'
const CASES = [
  { id: 'fibers-default', effect: 'fibers', width: 65, height: 33, params: {} },
  { id: 'fibers-dense', effect: 'fibers', width: 67, height: 35, params: { seed: 2, density: 1 } },
  { id: 'fibers-coverage-256', effect: 'fibers', width: 256, height: 256,
    params: { seed: 1, density: 1 }, hostUpload: { sourceCaseId: 'coverage/filter_fibers',
      textureId: 'node_1_overlayTex', sha256: '21afa5dd331c57f68f60328533e5199686244c5f74ac690006370a73501cbdc2' } },
  { id: 'scratches-default', effect: 'scratches', width: 65, height: 33, params: {} },
  { id: 'scratches-seeded', effect: 'scratches', width: 67, height: 35, params: { seed: 2, density: 0.8 } },
  { id: 'scratches-coverage-256', effect: 'scratches', width: 256, height: 256,
    params: { seed: 1, density: 0.3 }, hostUpload: { sourceCaseId: 'coverage/filter_scratches',
      textureId: 'node_1_overlayTex', sha256: '8484f0ff8a5d72095e5a95d922a043194dc2e437a6c47b2b32ea855110fe3a40' } },
  { id: 'strayHair-default', effect: 'strayHair', width: 65, height: 33, params: {} },
  { id: 'strayHair-dense', effect: 'strayHair', width: 69, height: 31, params: { seed: 3, density: 1 } },
  { id: 'strayHair-coverage-256', effect: 'strayHair', width: 256, height: 256,
    params: { seed: 1, density: 1 }, hostUpload: { sourceCaseId: 'coverage/filter_strayHair',
      textureId: 'node_1_overlayTex', sha256: '50be00e66dcfd9af668162406e30fa2caa6a37b91e4815fef0e3dcbc7fd0dd6f' } }
]
const hash = bytes => createHash('sha256').update(bytes).digest('hex')

async function generate(ref, lock) {
  if (existsSync(join(ref, '.git'))) sourceIdentity(ref, lock)
  else verifyArchivedSource(ref, lock, join(ROOT, '.build/reference'))
  const harness = join(ref, 'vendor/shade-mcp/harness/index.js')
  if (!existsSync(harness)) throw new Error('pinned browser harness missing')
  process.env.SHADE_VIEWER_ROOT = ref
  process.env.SHADE_VIEWER_PATH = '/demo/shaders/'
  process.env.SHADE_EFFECTS_DIR = join(ref, 'shaders/effects')
  process.env.SHADE_GLOBALS_PREFIX = '__noisemaker'
  process.env.SHADE_HEADLESS = process.env.SHADE_HEADLESS ?? '1'
  const { BrowserSession } = await import(pathToFileURL(harness).href)
  const session = new BrowserSession({ backend: 'webgpu' })
  await session.setup()
  try {
    const page = session.page
    const captures = new Map()
    const browserErrors = []
    page.on('pageerror', error => browserErrors.push(error.message))
    await page.route('**/__nm_overlay_capture/*', async route => {
      const id = new URL(route.request().url()).pathname.split('/').at(-1)
      if (!CASES.some(item => item.id === id) || captures.has(id)) {
        throw new Error(`unexpected overlay capture ${id}`)
      }
      captures.set(id, route.request().postDataBuffer())
      await route.fulfill({ status: 204 })
    })
    const browser = await page.evaluate(() => navigator.userAgent)
    const rows = []
    const segmentCaptures = new Map()
    for (const item of CASES) {
      const details = await page.evaluate(async item => {
        const definition = (await import(`/shaders/effects/filter/${item.effect}/definition.js`)).default
        if (typeof definition.asyncInit !== 'function') throw new Error(`${item.effect} has no asyncInit`)
        let updates = 0
        let canvas = null
        let lastBytes = null
        const segments = []
        const color = style => {
          const rgb = /^rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*(?:,\s*([\d.]+))?\s*\)$/.exec(style)
          if (rgb) return [Number(rgb[1]), Number(rgb[2]), Number(rgb[3]), rgb[4] === undefined ? 1 : Number(rgb[4])]
          const hex = /^#([a-f\d]{6})$/i.exec(style)
          if (hex) return [0, 2, 4].map(offset => parseInt(hex[1].slice(offset, offset + 2), 16)).concat(1)
          throw new Error(`unsupported source Canvas strokeStyle ${style}`)
        }
        let instrumented = false
        await definition.asyncInit({ width: item.width, height: item.height, params: item.params,
          isCancelled: () => false,
          updateTexture: (id, nextCanvas) => {
            if (id !== 'overlayTex' || nextCanvas.width !== item.width || nextCanvas.height !== item.height) {
              throw new Error(`${item.effect} returned an unexpected overlay texture`)
            }
            canvas = nextCanvas
            const ctx = canvas.getContext('2d')
            const attributes = ctx.getContextAttributes?.()
            if (!attributes?.willReadFrequently) throw new Error(`${item.effect} did not use software Canvas`)
            if (!instrumented) {
              instrumented = true
              const beginPath = ctx.beginPath.bind(ctx)
              const moveTo = ctx.moveTo.bind(ctx)
              const lineTo = ctx.lineTo.bind(ctx)
              const stroke = ctx.stroke.bind(ctx)
              let from = null
              let to = null
              ctx.beginPath = () => { from = null; to = null; return beginPath() }
              ctx.moveTo = (x, y) => { from = [x, y]; return moveTo(x, y) }
              ctx.lineTo = (x, y) => { to = [x, y]; return lineTo(x, y) }
              ctx.stroke = () => {
                if (!from || !to) throw new Error(`${item.effect} emitted a non-segment stroke`)
                segments.push({ from, to, width: ctx.lineWidth, rgba: color(ctx.strokeStyle),
                  cap: ctx.lineCap, join: ctx.lineJoin })
                return stroke()
              }
            }
            lastBytes = new Uint8Array(ctx.getImageData(0, 0, item.width, item.height).data)
            updates++
          } })
        if (!canvas || !lastBytes || updates < 2) throw new Error(`${item.effect} produced no completed overlay`)
        const response = await fetch(`/__nm_overlay_capture/${item.id}`, { method: 'POST',
          headers: { 'content-type': 'application/octet-stream' }, body: lastBytes })
        if (!response.ok) throw new Error(`overlay capture failed ${response.status}`)
        if (segments.length < updates - 1) throw new Error(`${item.effect} has fewer strokes than progressive updates`)
        return { updates, segments, canvasAttributes: canvas.getContext('2d').getContextAttributes(),
          alphaPixels: Array.from({ length: item.width * item.height }, (_, index) => lastBytes[index * 4 + 3])
            .filter(alpha => alpha !== 0).length }
      }, item)
      const bytes = captures.get(item.id)
      if (!bytes || bytes.length !== item.width * item.height * 4 || !details.alphaPixels) {
        throw new Error(`${item.id} capture has missing, wrong-sized, or empty pixels`)
      }
      if (item.hostUpload) {
        const rowBytes = item.width * 4
        const uploaded = Buffer.allocUnsafe(bytes.length)
        for (let row = 0; row < item.height; row++) {
          bytes.copy(uploaded, row * rowBytes, (item.height - 1 - row) * rowBytes,
            (item.height - row) * rowBytes)
        }
        if (hash(uploaded) !== item.hostUpload.sha256) {
          throw new Error(`${item.id} Canvas bytes differ from captured source WebGPU host upload`)
        }
      }
      const segmentBytes = Buffer.allocUnsafe(details.segments.length * 9 * 8)
      details.segments.forEach((segment, index) => {
        if (segment.cap !== 'round' || segment.join !== 'round') throw new Error(`${item.id} changed stroke cap/join`)
        const fields = [...segment.from, ...segment.to, segment.width, ...segment.rgba]
        if (fields.length !== 9 || fields.some(value => !Number.isFinite(value))) {
          throw new Error(`${item.id} emitted a non-finite stroke`)
        }
        fields.forEach((value, field) => segmentBytes.writeDoubleLE(value, (index * 9 + field) * 8))
      })
      segmentCaptures.set(item.id, segmentBytes)
      rows.push({ ...item, file: `${item.id}.rgba8`, sha256: hash(bytes), bytes: bytes.length,
        updates: details.updates, alphaPixels: details.alphaPixels,
        segmentFile: `${item.id}.segments.f64le`, segmentCount: details.segments.length,
        segmentBytes: segmentBytes.length, segmentsSha256: hash(segmentBytes), cap: 'round', join: 'round',
        canvasAttributes: details.canvasAttributes,
        source: { effectPath: `shaders/effects/filter/${item.effect}/definition.js`,
          effectSha256: hash(readFileSync(join(ref, `shaders/effects/filter/${item.effect}/definition.js`))) } })
    }
    if (browserErrors.length) throw new Error(`pinned browser page errors: ${browserErrors.join(' | ')}`)
    const result = { schemaVersion: 1, authority: { repository: lock.repository, commit: lock.commit,
      sourceManifestSha256: lock.sourceManifestSha256 }, browser,
    format: { channels: 'RGBA', bitDepth: 8, orientation: 'top-down', colorSpace: 'srgb',
      stage: 'software Canvas2D getImageData after source asyncInit, before WebGPU upload' },
    wormSource: { path: SOURCE_WORM, sha256: hash(readFileSync(join(ref, SOURCE_WORM))) }, cases: rows }
    return { result, captures, segmentCaptures }
  } finally { await session.teardown() }
}

async function main() {
  const [mode = '--check', outArg = join(ROOT, 'parity/overlays')] = process.argv.slice(2)
  if (!['--check', '--write'].includes(mode) || process.argv.length > 4) {
    throw new Error('usage: NM_REFERENCE_ROOT=... node tools/export-overlays.mjs [--check|--write] [out-dir]')
  }
  if (!process.env.NM_REFERENCE_ROOT) throw new Error('NM_REFERENCE_ROOT with pinned browser harness and Playwright is required')
  const lock = JSON.parse(readFileSync(join(ROOT, 'parity/reference.json')))
  const { result, captures, segmentCaptures } = await generate(resolve(process.env.NM_REFERENCE_ROOT), lock)
  const out = resolve(outArg)
  const ledger = Buffer.from(JSON.stringify(result, null, 2) + '\n')
  if (mode === '--check') {
    if (!existsSync(join(out, 'oracle.json')) || !readFileSync(join(out, 'oracle.json')).equals(ledger)) {
      throw new Error('software Canvas overlay ledger differs from pinned source')
    }
    for (const item of result.cases) if (!existsSync(join(out, item.file)) ||
      !readFileSync(join(out, item.file)).equals(captures.get(item.id))) {
      throw new Error(`software Canvas pixels differ from pinned source: ${item.id}`)
    }
    for (const item of result.cases) if (!existsSync(join(out, item.segmentFile)) ||
      !readFileSync(join(out, item.segmentFile)).equals(segmentCaptures.get(item.id))) {
      throw new Error(`software Canvas stroke stream differs from pinned source: ${item.id}`)
    }
  } else {
    mkdirSync(out, { recursive: true })
    for (const item of result.cases) {
      writeFileSync(join(out, item.file), captures.get(item.id))
      writeFileSync(join(out, item.segmentFile), segmentCaptures.get(item.id))
    }
    writeFileSync(join(out, 'oracle.json'), ledger)
  }
  process.stdout.write(JSON.stringify({ mode, cases: result.cases.length, ledgerSha256: hash(ledger),
    bytes: result.cases.reduce((sum, item) => sum + item.bytes, 0) }) + '\n')
}

main().catch(error => { process.stderr.write(`${error?.stack || String(error)}\n`); process.exitCode = 1 })
