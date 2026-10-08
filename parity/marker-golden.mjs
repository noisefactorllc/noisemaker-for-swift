#!/usr/bin/env node
// Mint one same-run WebGPU golden from the pinned upstream demo's presented canvas.
import { createHash } from 'node:crypto'
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from 'node:fs'
import { basename, dirname, join, relative, resolve } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { deflateSync } from 'node:zlib'
import { CASES, sourceIdentity } from '../tools/export-reference.mjs'

const sha256 = bytes => createHash('sha256').update(bytes).digest('hex')
const WIDTH = 257
const HEIGHT = 129
const PORTABLE_FIXTURES = {
  marker: { dsl: 'marker.dsl', definition: 'marker.portable.json', shaders: ['marker.marker.wgsl'] },
  mrtProbe: { dsl: 'mrt.dsl', definition: 'mrt.portable.json', shaders: ['mrt.split.wgsl', 'mrt.combine.wgsl'] },
  samplerProbe: { dsl: 'sampler.dsl', definition: 'sampler.portable.json', shaders: ['sampler.pattern.wgsl', 'sampler.sample.wgsl'] }
}

function pngChunk(type, data) {
  const body = Buffer.concat([Buffer.from(type, 'ascii'), data])
  let crc = 0xffffffff
  for (const byte of body) {
    crc ^= byte
    for (let bit = 0; bit < 8; bit++) crc = (crc & 1) ? (0xedb88320 ^ (crc >>> 1)) : (crc >>> 1)
  }
  const out = Buffer.alloc(12 + data.length)
  out.writeUInt32BE(data.length, 0)
  body.copy(out, 4)
  out.writeUInt32BE((crc ^ 0xffffffff) >>> 0, 8 + data.length)
  return out
}

export function encodePng(width, height, rgba) {
  if (rgba.length !== width * height * 4) throw new Error(`GPU readback has ${rgba.length} bytes for ${width}x${height}`)
  const ihdr = Buffer.alloc(13)
  ihdr.writeUInt32BE(width, 0)
  ihdr.writeUInt32BE(height, 4)
  ihdr[8] = 8
  ihdr[9] = 6
  const stride = width * 4
  const rows = Buffer.alloc(height * (stride + 1))
  for (let y = 0; y < height; y++) rgba.copy(rows, y * (stride + 1) + 1, y * stride, (y + 1) * stride)
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
    pngChunk('IHDR', ihdr), pngChunk('IDAT', deflateSync(rows)), pngChunk('IEND', Buffer.alloc(0))])
}

function filesUnder(dir, suffix) {
  if (!existsSync(dir)) return []
  return readdirSync(dir, { withFileTypes: true }).flatMap(entry => {
    const path = join(dir, entry.name)
    return entry.isDirectory() ? filesUnder(path, suffix) : entry.isFile() && entry.name.endsWith(suffix) ? [path] : []
  }).sort()
}

// The native GPU host can receive an exact git archive instead of a checkout.
// Verify every imported source byte and reject any extra importable source.
export function verifyArchivedSource(ref, lock, exportedRoot) {
  const manifest = JSON.parse(readFileSync(join(exportedRoot, 'source-manifest.json'), 'utf8'))
  if (manifest.repository !== lock.repository || manifest.commit !== lock.commit) throw new Error('reference source manifest does not match lock')
  const manifestHash = sha256(manifest.files.map(file => `${file.path}\0${file.sha256}\n`).join(''))
  if (manifestHash !== manifest.contentSha256 || manifestHash !== lock.sourceManifestSha256) throw new Error('reference source manifest hash does not match lock')
  const recorded = new Map(manifest.files.map(file => [file.path, file.sha256]))
  const actual = [join(ref, 'package.json'), join(ref, 'share/palettes.json'),
    ...filesUnder(join(ref, 'share/meshes'), ''),
    ...filesUnder(join(ref, 'shaders/src'), '.js'),
    ...filesUnder(join(ref, 'shaders/effects'), '.js'),
    ...filesUnder(join(ref, 'shaders/effects'), '.wgsl'),
    ...filesUnder(join(ref, 'shaders/effects'), 'parity-case.json'),
    join(ref, 'shaders/effects/manifest.json'),
    ...filesUnder(join(ref, 'demo/shaders'), ''),
    ...filesUnder(join(ref, 'vendor/shade-mcp/harness'), '.js')]
  if (actual.length !== recorded.size) throw new Error('reference source archive file count differs from manifest')
  for (const path of actual) {
    const name = relative(ref, path).replaceAll('\\', '/')
    if (!recorded.has(name) || sha256(readFileSync(path)) !== recorded.get(name)) throw new Error(`reference source archive differs at ${name}`)
  }
}

export async function sizePage(page, width = WIDTH, height = HEIGHT) {
  await page.setViewportSize({ width: 1000, height: 700 })
  await page.evaluate(({ width, height }) => {
    window.__noisemakerSetPaused?.(true)
    const renderer = window.__noisemakerCanvasRenderer
    const canvas = renderer?.canvas
    if (!renderer || !canvas) throw new Error('reference canvas renderer unavailable')
    const widthDescriptor = Object.getOwnPropertyDescriptor(HTMLCanvasElement.prototype, 'width')
    const heightDescriptor = Object.getOwnPropertyDescriptor(HTMLCanvasElement.prototype, 'height')
    widthDescriptor.set.call(canvas, width)
    heightDescriptor.set.call(canvas, height)
    Object.defineProperty(canvas, 'width', { configurable: true, get: () => width, set: () => {} })
    Object.defineProperty(canvas, 'height', { configurable: true, get: () => height, set: () => {} })
    Object.assign(canvas.style, { width: `${width}px`, height: `${height}px`, border: '0', padding: '0', margin: '0' })
    renderer.resize(width, height)
  }, { width, height })
}

async function mint(casePath, output, metadataPath) {
  const ref = process.env.NM_REFERENCE_ROOT
  if (!ref) throw new Error('NM_REFERENCE_ROOT must name the pinned upstream checkout with browser dependencies')
  const root = resolve(dirname(fileURLToPath(import.meta.url)), '..')
  const lock = JSON.parse(readFileSync(join(root, 'parity/reference.json'), 'utf8'))
  const referenceRoot = resolve(ref)
  if (existsSync(join(referenceRoot, '.git'))) sourceIdentity(referenceRoot, lock)
  else verifyArchivedSource(referenceRoot, lock, join(root, '.build/reference'))
  const exported = JSON.parse(readFileSync(casePath, 'utf8'))
  const caseName = basename(casePath, '.json')
  const fixture = PORTABLE_FIXTURES[caseName]
  if (!Object.hasOwn(CASES, caseName)) throw new Error(`unsupported reference GPU fixture ${caseName}`)
  const source = CASES[caseName]
  let fixtureSha256 = null
  if (fixture) {
    const definitionBytes = readFileSync(join(root, 'parity', fixture.definition))
    const shaderBytes = fixture.shaders.map(file => readFileSync(join(root, 'parity', file)))
    fixtureSha256 = sha256(Buffer.concat([Buffer.from(source), definitionBytes, ...shaderBytes]))
  }
  if (exported.stages.source !== source || exported.fixtureSha256 !== (fixtureSha256 ?? undefined)) {
    throw new Error(`exported ${caseName} fixture is stale`)
  }
  const harness = join(referenceRoot, 'vendor/shade-mcp/harness/index.js')
  if (!existsSync(harness)) throw new Error(`Shade browser harness missing: ${harness}`)
  process.env.SHADE_VIEWER_ROOT = referenceRoot
  process.env.SHADE_VIEWER_PATH = '/demo/shaders/'
  process.env.SHADE_EFFECTS_DIR = join(referenceRoot, 'shaders/effects')
  process.env.SHADE_GLOBALS_PREFIX = '__noisemaker'
  process.env.SHADE_HEADLESS = process.env.SHADE_HEADLESS ?? '1'
  const { BrowserSession } = await import(pathToFileURL(harness).href)
  const session = new BrowserSession({ backend: 'webgpu' })
  await session.setup()
  try {
    await session.setBackend('webgpu')
    const page = session.page
    const browserErrors = []
    page.on('console', message => { if (message.type() === 'error') browserErrors.push(message.text()) })
    page.on('pageerror', error => browserErrors.push(error.message))
    await page.waitForFunction(() => !!window.__noisemakerCanvasRenderer && !!document.getElementById('dsl-editor'), null, { timeout: 120000 })
    await sizePage(page)
    if (fixture) {
      const registration = await page.evaluate(async definition => {
        try {
          await window.__noisemakerCanvasRenderer.registerPortableEffect(definition)
          return { ok: true }
        } catch (error) { return { error: error?.message || String(error) } }
      }, exported.portableDefinition)
      if (registration.error) throw new Error(`portable ${caseName} registration failed: ${registration.error}`)
    }
    await page.evaluate(dsl => {
      const state = window.__noisemakerProgramState
      if (Array.isArray(state?._structure)) state._structure = []
      document.getElementById('status').textContent = ''
      const editor = document.getElementById('dsl-editor')
      editor.value = dsl
      editor.dispatchEvent(new Event('input', { bubbles: true }))
      document.getElementById('dsl-run-btn').click()
    }, source)
    await page.waitForFunction(({ dsl, passes }) => {
      const status = document.getElementById('status')?.textContent || ''
      if (/error|failed/i.test(status)) throw new Error(`reference DSL failed: ${status}`)
      const pipeline = window.__noisemakerRenderingPipeline
      return pipeline?.graph?.source === dsl.trim() && !pipeline.isCompiling &&
        pipeline.backend?.getName?.() === 'WebGPU' && pipeline.graph.passes?.length === passes &&
        /compiled/i.test(status)
    }, { dsl: source, passes: exported.passPrograms.length }, { timeout: 120000 })
    let readbackBytes
    let backingBytes
    await page.route('**/__nm_marker_capture/*', async route => {
      if (route.request().url().endsWith('/1')) readbackBytes = route.request().postDataBuffer()
      else if (route.request().url().endsWith('/2')) backingBytes = route.request().postDataBuffer()
      else throw new Error(`unexpected marker capture URL ${route.request().url()}`)
      await route.fulfill({ status: 204 })
    })
    const state = await page.evaluate(async ({ width, height, expectedGraphId, captureUniforms }) => {
      const pipeline = window.__noisemakerRenderingPipeline
      if (pipeline.backend?.getName?.() !== 'WebGPU') throw new Error('reference backend switched from WebGPU')
      if (pipeline.graph?.id !== expectedGraphId) throw new Error(`reference execution graph ID ${pipeline.graph?.id} differs from ${expectedGraphId}`)
      const canvas = window.__noisemakerCanvasRenderer.canvas
      if (canvas.width !== width || canvas.height !== height) throw new Error(`reference canvas is ${canvas.width}x${canvas.height}`)
      const bounds = canvas.getBoundingClientRect()
      if (Math.round(bounds.width) !== width || Math.round(bounds.height) !== height) throw new Error(`presented canvas bounds are ${bounds.width}x${bounds.height}`)
      const backend = pipeline.backend
      const device = backend.device
      const canvasFormat = backend.canvasFormat || navigator.gpu.getPreferredCanvasFormat()
      if (canvasFormat !== 'bgra8unorm' && canvasFormat !== 'rgba8unorm') throw new Error(`unsupported canvas format ${canvasFormat}`)
      const currentConfig = backend.context.getConfiguration?.()
      backend.context.configure({ device, format: canvasFormat,
        usage: (currentConfig?.usage || (GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.COPY_DST)) | GPUTextureUsage.COPY_SRC,
        alphaMode: currentConfig?.alphaMode || 'premultiplied' })
      for (const [id, texture] of pipeline.backend.textures) {
        if (texture?.isExternal || texture?.is3D || texture?.cube) continue
        pipeline.backend.clearTexture(id)
      }
      for (const [name, surface] of pipeline.surfaces.entries()) {
        if (pipeline.backend.textures.has(`global_${name}_read`) && pipeline.backend.textures.has(`global_${name}_write`)) {
          surface.read = `global_${name}_read`
          surface.write = `global_${name}_write`
        }
      }
      pipeline.globalUniforms = {}
      pipeline.frameIndex = 0
      pipeline.lastTime = 0
      window.__noisemakerSetPausedTime?.(0.25)
      const sinkBefore = [...pipeline.sinkManager.stats.values()].reduce((total, stats) => total + stats.accepted, 0)
      let canvasCopy = null
      const packedUniforms = []
      const originalPack = backend.packUniformsWithLayout.bind(backend)
      if (captureUniforms) backend.packUniformsWithLayout = (uniforms, layout) => {
        const bytes = originalPack(uniforms, layout)
        if (pipeline.frameIndex === 7) packedUniforms.push({
          layout, uniformNames: Object.keys(uniforms).filter(key => uniforms[key] !== undefined),
          byteLength: bytes.byteLength,
          hex: Array.from(bytes, byte => byte.toString(16).padStart(2, '0')).join('')
        })
        return bytes
      }
      const originalPresent = backend.present.bind(backend)
      backend.present = textureId => {
        originalPresent(textureId)
        if (pipeline.frameIndex !== 7) return
        const canvasTexture = backend.context.getCurrentTexture()
        const rowBytes = Math.ceil(width * 4 / 256) * 256
        const buffer = device.createBuffer({ size: rowBytes * height,
          usage: GPUBufferUsage.COPY_DST | GPUBufferUsage.MAP_READ })
        const encoder = device.createCommandEncoder()
        encoder.copyTextureToBuffer({ texture: canvasTexture }, { buffer, bytesPerRow: rowBytes },
          { width, height, depthOrArrayLayers: 1 })
        device.queue.submit([encoder.finish()])
        canvasCopy = { buffer, rowBytes, textureId }
      }
      try {
        for (let frame = 0; frame < 8; frame++) pipeline.render(0.25)
      } finally {
        backend.present = originalPresent
        if (captureUniforms) backend.packUniformsWithLayout = originalPack
      }
      await device.queue.onSubmittedWorkDone()
      if (pipeline.backend?.getName?.() !== 'WebGPU') throw new Error('reference backend switched during render')
      const surfaceName = pipeline.graph.renderSurface
      const surface = pipeline.surfaces.get(surfaceName)
      if (!surface) throw new Error(`reference presentation surface ${surfaceName} missing`)
      const sinkStats = [...pipeline.sinkManager.stats.values()]
      const sinkAccepted = sinkStats.reduce((total, stats) => total + stats.accepted, 0) - sinkBefore
      if (sinkAccepted !== 8 || sinkStats.some(stats => stats.failed !== 0)) throw new Error(`reference canvas sink did not present eight frames: accepted delta ${sinkAccepted}; stats ${JSON.stringify(sinkStats)}`)
      const presentedTexture = pipeline.frameReadTextures.get(surfaceName)
      if (!canvasCopy || canvasCopy.textureId !== presentedTexture) throw new Error('canvas copy did not follow the final presented surface')
      const backing = await backend.readPixels(presentedTexture)
      const backingUpload = await fetch('/__nm_marker_capture/2', { method: 'POST',
        headers: { 'content-type': 'application/octet-stream' }, body: new Blob([backing.data]) })
      if (backingUpload.status !== 204) throw new Error(`backing texture upload failed: ${backingUpload.status}`)
      await canvasCopy.buffer.mapAsync(GPUMapMode.READ)
      const mapped = new Uint8Array(canvasCopy.buffer.getMappedRange())
      const pixels = new Uint8Array(width * height * 4)
      for (let y = 0; y < height; y++) {
        for (let x = 0; x < width; x++) {
          const src = y * canvasCopy.rowBytes + x * 4
          const dst = (y * width + x) * 4
          pixels[dst] = mapped[src + (canvasFormat === 'bgra8unorm' ? 2 : 0)]
          pixels[dst + 1] = mapped[src + 1]
          pixels[dst + 2] = mapped[src + (canvasFormat === 'bgra8unorm' ? 0 : 2)]
          pixels[dst + 3] = mapped[src + 3]
        }
      }
      canvasCopy.buffer.unmap()
      canvasCopy.buffer.destroy()
      const upload = await fetch('/__nm_marker_capture/1', { method: 'POST',
        headers: { 'content-type': 'application/octet-stream' }, body: new Blob([pixels]) })
      if (upload.status !== 204) throw new Error(`canvas readback upload failed: ${upload.status}`)
      const adapter = await navigator.gpu.requestAdapter()
      const info = adapter?.info
      return { backend: pipeline.backend.getName(), adapter: info ? {
        vendor: info.vendor ?? null, architecture: info.architecture ?? null,
        device: info.device ?? null, description: info.description ?? null
      } : null,
        browser: navigator.userAgent, graphId: pipeline.graph.id, frameIndex: pipeline.frameIndex,
        width, height, graphRenderSurface: surfaceName, canvasFormat,
        presentedTexture, lastPassCount: pipeline.lastPassCount, sinkStats, packedUniforms }
    }, { width: WIDTH, height: HEIGHT, expectedGraphId: exported.executionGraphId, captureUniforms: caseName === 'computeFilter' })
    if (browserErrors.length) throw new Error(`WebGPU browser errors: ${browserErrors.join(' | ')}`)
    if (!readbackBytes) throw new Error('presented canvas GPU readback was not uploaded')
    if (!backingBytes) throw new Error('presented surface backing readback was not uploaded')
    if (state.width !== WIDTH || state.height !== HEIGHT) throw new Error(`presented canvas is ${state.width}x${state.height}`)
    const png = encodePng(state.width, state.height, readbackBytes)
    const backingPng = encodePng(state.width, state.height, backingBytes)
    mkdirSync(dirname(output), { recursive: true })
    writeFileSync(output, png)
    const backingPath = output.endsWith('.png') ? `${output.slice(0, -4)}.backing.png` : `${output}.backing.png`
    writeFileSync(backingPath, backingPng)
    const cornerSamples = bytes => Object.fromEntries(Object.entries({ topLeft: [4, 4], topRight: [252, 4],
      bottomLeft: [4, 124], bottomRight: [252, 124] }).map(([name, [x, y]]) => [name,
      [...bytes.subarray((y * WIDTH + x) * 4, (y * WIDTH + x + 1) * 4)]]))
    const metadata = { case: caseName, reference: lock, fixtureSha256, goldenSha256: sha256(png), browserErrors,
      backingSha256: sha256(backingPng), presentedCorners: cornerSamples(readbackBytes),
      backingCorners: cornerSamples(backingBytes),
      capture: { sourceSha256: sha256(source), width: WIDTH, height: HEIGHT, normalizedTime: 0.25,
        frames: 8, deltaTime: 0, resetState: true, source: 'GPUCanvasContext current texture after CanvasSink.present',
        orientation: 'top-down RGBA8' }, ...state }
    writeFileSync(metadataPath, JSON.stringify(metadata, null, 2) + '\n')
    process.stdout.write(JSON.stringify(metadata) + '\n')
  } finally { await session.teardown() }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  if (process.argv.length !== 5) {
    process.stderr.write('usage: node parity/marker-golden.mjs <exported-case.json> <golden.png> <metadata.json>\n')
    process.exitCode = 2
  } else mint(resolve(process.argv[2]), resolve(process.argv[3]), resolve(process.argv[4]))
    .catch(error => { process.stderr.write(`${error.stack || error}\n`); process.exitCode = 1 })
}
