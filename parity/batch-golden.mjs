#!/usr/bin/env node
// Same-run WebGPU presented-surface capture in one browser session.
import { createHash } from 'node:crypto'
import { platform, release, arch } from 'node:os'
import { createReadStream, existsSync, mkdirSync, readFileSync, realpathSync, renameSync, writeFileSync } from 'node:fs'
import { createRequire } from 'node:module'
import { dirname, isAbsolute, join, relative, resolve } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { sourceIdentity } from '../tools/export-reference.mjs'
import { encodePng, sizePage, verifyArchivedSource } from './marker-golden.mjs'

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const sha256 = bytes => createHash('sha256').update(bytes).digest('hex')
const readJson = path => JSON.parse(readFileSync(path, 'utf8'))
const require = createRequire(import.meta.url)

async function fileSha256(path) {
  const checksum = createHash('sha256')
  for await (const block of createReadStream(path)) checksum.update(block)
  return checksum.digest('hex')
}

function chromiumExecutable(referenceRoot, headless) {
  // This is the same registry and selection used by the pinned Playwright
  // Chromium launcher with no channel or executablePath override.
  const core = require(join(referenceRoot, 'node_modules/playwright-core/lib/coreBundle.js'))
  const name = headless ? 'chromium-headless-shell' : 'chromium'
  const path = core.registry?.registry?.findExecutable(name)?.executablePath()
  if (!path) throw new Error(`Playwright has no ${name} executable`)
  return realpathSync(path)
}
const EXTERNAL_TEXTURE_ID = /^[A-Za-z][A-Za-z0-9]*_step_\d+$/
const ASYNC_OVERLAY_ID = /^node_\d+_[A-Za-z][A-Za-z0-9]*$/
const MESH_TEXTURE_INPUT = /^global_mesh\d+_(positions|normals|uvs)/
const SESSION_CASE_LIMIT = 60
export function createCaptureCancellation() {
  let signal = null
  let session = null
  let closing = null
  const beginClose = () => {
    if (!session || closing) return
    const current = session
    closing = Promise.resolve().then(() => current.teardown())
    // The main loop awaits this promise in its finally block; attach a
    // handler now so an early teardown rejection is never unhandled.
    closing.catch(() => {})
  }
  const cancel = name => {
    if (signal) return
    signal = name
    process.exitCode = name === 'SIGINT' ? 130 : 143
    beginClose()
  }
  const onInterrupt = () => cancel('SIGINT')
  const onTerminate = () => cancel('SIGTERM')
  process.on('SIGINT', onInterrupt)
  process.on('SIGTERM', onTerminate)
  return {
    get cancelled() { return !!signal },
    throwIfCancelled() { if (signal) throw new Error(`golden capture cancelled by ${signal}`) },
    setSession(current) {
      session = current
      if (signal) beginClose()
    },
    async closeSession(current) {
      if (session === current) session = null
      try { await closing }
      finally {
        closing = null
        // setup may have completed after an early signal-triggered teardown.
        await current.teardown()
      }
    },
    dispose() {
      process.off('SIGINT', onInterrupt)
      process.off('SIGTERM', onTerminate)
    }
  }
}
const safeId = id => {
  if (!/^[A-Za-z0-9_/-]+$/.test(id) || id.includes('..')) throw new Error(`unsafe case id ${id}`)
  return id
}

function portableDefinition(item) {
  const sidecar = item.assets.find(asset => asset.path.endsWith('.portable.json'))
  if (!sidecar) return null
  const definition = JSON.parse(sidecar.text)
  definition.shaders ||= {}
  for (const shader of item.assets.filter(asset => asset.path.endsWith('.wgsl'))) {
    const program = shader.path.split('/').at(-1).split('.').at(-2)
    definition.shaders[program] ||= {}
    definition.shaders[program].wgsl = shader.text
  }
  return definition
}

function selectedCases(corpus, requested) {
  if (!requested.length) return corpus.cases
  const byId = new Map(corpus.cases.map(item => [item.id, item]))
  const result = []
  for (const id of requested) {
    const item = byId.get(id)
    if (!item) throw new Error(`unknown corpus case ${id}`)
    if (result.includes(item)) throw new Error(`duplicate case ${id}`)
    result.push(item)
  }
  return result
}

function sampleFrames(item) {
  if (item.capture.frameTime) {
    return [...new Set([...item.capture.sampleFrames,
      ...Array.from({ length: item.capture.runSeconds }, (_, n) => (n + 1) * 600)])].sort((a, b) => a - b)
  }
  return [item.capture.frames]
}

export async function installAsyncInitTracker(page) {
  // The editor can appear before the demo finishes constructing its pipeline.
  // Install the tracker only after the actual source runtime is available.
  await page.waitForFunction(() => !!window.__noisemakerRenderingPipeline, null, { timeout: 120000 })
  await page.evaluate(() => {
    const proto = Object.getPrototypeOf(window.__noisemakerRenderingPipeline)
    if (proto.__nmTracksAsyncInit) return
    if (typeof proto._startAsyncInit !== 'function') throw new Error('reference pipeline has no _startAsyncInit')
    window.__nmAsyncInitPending = 0
    window.__nmAsyncInitNodes = new Set()
    const start = proto._startAsyncInit
    proto._startAsyncInit = function (nodeId, effectDef, options) {
      if (options?.debounce) return start.call(this, nodeId, effectDef, options)
      window.__nmAsyncInitNodes.add(nodeId)
      const own = Object.prototype.hasOwnProperty.call(effectDef, 'asyncInit')
      const asyncInit = effectDef.asyncInit
      effectDef.asyncInit = function (context) {
        let pending
        try { pending = Promise.resolve(asyncInit.call(this, context)) }
        catch (error) { pending = Promise.reject(error) }
        window.__nmAsyncInitPending++
        const settle = () => { window.__nmAsyncInitPending-- }
        pending.then(settle, settle)
        return pending
      }
      try { return start.call(this, nodeId, effectDef, options) }
      finally {
        if (own) effectDef.asyncInit = asyncInit
        else delete effectDef.asyncInit
      }
    }
    proto.__nmTracksAsyncInit = true
  })
}

function midiMessages(item) {
  const asset = item.assets.find(asset => asset.path.endsWith('.midi.json'))
  if (!asset) return null
  const messages = JSON.parse(asset.text).messages
  if (!Array.isArray(messages) || !messages.every(message => Array.isArray(message) && message.length &&
    message.every(byte => Number.isInteger(byte) && byte >= 0 && byte <= 255))) {
    throw new Error(`${item.id}: invalid MIDI sidecar`)
  }
  return messages
}

function audioPlan(item, lock) {
  const assets = item.assets.filter(asset => asset.path === 'parity/inputs/audio-v1.json')
  if (!assets.length) return null
  if (assets.length !== 1) throw new Error(`${item.id}: duplicate audio host sidecars`)
  const asset = assets[0]
  if (sha256(asset.text) !== asset.sha256 ||
      readFileSync(join(ROOT, asset.path), 'utf8') !== asset.text) {
    throw new Error(`${item.id}: audio sidecar SHA differs`)
  }
  const value = JSON.parse(asset.text)
  if (value.schemaVersion !== 1 || value.authority?.commit !== lock.commit ||
      value.authority?.sourceManifestSha256 !== lock.sourceManifestSha256 ||
      value.frame !== 0 || value.updatePolicy !== 'static-before-frame-1' ||
      value.sampleCount !== 128 || value.inputFormat !== 'analyser-uint8' ||
      value.shaderFormat !== 'array<vec4<f32>,32>') {
    throw new Error(`${item.id}: audio sidecar protocol differs from locked source`)
  }
  for (const name of ['waveform', 'spectrum']) {
    const bytes = value[`${name}Bytes`]
    const f32 = value[`${name}F32`]
    if (!Array.isArray(bytes) || bytes.length !== 128 ||
        !bytes.every(sample => Number.isInteger(sample) && sample >= 0 && sample <= 255) ||
        f32?.path !== `audio-v1.${name}.f32le` || f32?.bytes !== 512 ||
        !/^[a-f0-9]{64}$/.test(f32.sha256)) {
      throw new Error(`${item.id}: invalid ${name} audio samples`)
    }
    const sourceFile = join(ROOT, 'parity/inputs', f32.path)
    if (!existsSync(sourceFile) || sha256(readFileSync(sourceFile)) !== f32.sha256) {
      throw new Error(`${item.id}: ${name} float snapshot differs`)
    }
  }
  return { asset, value }
}

async function injectAudio(page, item, plan) {
  if (!plan) return null
  const representation = item.capture.audioInput?.representation
  if (representation !== undefined && representation !== 'plain-array') {
    throw new Error(`${item.id}: unsupported audio host representation`)
  }
  const plainArrayProbe = representation === 'plain-array'
  const samples = await page.evaluate(({ waveformBytes, spectrumBytes, plainArrayProbe }) => {
    const renderer = window.__noisemakerCanvasRenderer
    const state = renderer.setAudioState()
    state.setWaveform(new Uint8Array(waveformBytes))
    state.setSpectrum(new Uint8Array(spectrumBytes))
    const pipeline = window.__noisemakerRenderingPipeline
    if (plainArrayProbe) {
      pipeline.setAudioState({ waveform: Array.from(state.waveform), spectrum: Array.from(state.spectrum) })
    }
    if (pipeline.externalState.audio !== state && !plainArrayProbe) {
      throw new Error('source pipeline did not accept host audio state')
    }
    if (plainArrayProbe && (!Array.isArray(pipeline.externalState.audio.waveform) ||
        !Array.isArray(pipeline.externalState.audio.spectrum))) throw new Error('source pipeline did not accept plain host audio arrays')
    return { waveform: Array.from(state.waveform), spectrum: Array.from(state.spectrum) }
  }, { ...plan.value, plainArrayProbe })
  for (const name of ['waveform', 'spectrum']) {
    const bytes = Buffer.alloc(512)
    samples[name].forEach((sample, index) => bytes.writeFloatLE(sample, index * 4))
    if (sha256(bytes) !== plan.value[`${name}F32`].sha256) {
      throw new Error(`${item.id}: source AudioState ${name} floats differ from oracle`)
    }
  }
  return { frame: 0, assetPath: plan.asset.path, assetSha256: plan.asset.sha256,
    updatePolicy: plan.value.updatePolicy,
    waveformF32Sha256: plan.value.waveformF32.sha256,
    spectrumF32Sha256: plan.value.spectrumF32.sha256,
    ...(plainArrayProbe ? { representation: 'plain-array' } : {}) }
}

async function meshPlan(referenceRoot, item, graph) {
  const asset = item.assets.find(asset => asset.path.endsWith('.obj'))
  const readsMesh = graph.passes.some(pass => Object.values(pass.inputs || {}).some(id =>
    typeof id === 'string' && MESH_TEXTURE_INPUT.test(id)))
  if (!readsMesh && !asset) return null
  const builtins = []
  const seen = new Set()
  for (const pass of graph.passes) {
    const key = pass.effectKey
    if (!key || seen.has(`${pass.stepIndex}|${key}`)) continue
    seen.add(`${pass.stepIndex}|${key}`)
    const [namespace, func] = key.split('.')
    const path = join(referenceRoot, 'shaders/effects', namespace, func, 'definition.js')
    if (!existsSync(path)) continue
    const mod = await import(pathToFileURL(path).href)
    const definition = typeof mod.default === 'function' ? new mod.default() : mod.default
    if (!definition?.externalMesh || !definition.builtinMeshes) continue
    const first = Object.values(definition.builtinMeshes)[0]
    if (first) builtins.push({ meshId: definition.externalMesh, path: first })
  }
  return { objText: asset?.text ?? null, builtins }
}

async function readyHostInputs(page, referenceRoot, item) {
  const graph = await page.evaluate(() => {
    const passes = window.__noisemakerRenderingPipeline?.graph?.passes || []
    return { passes: passes.map(pass => ({ effectKey: pass.effectKey, stepIndex: pass.stepIndex,
      inputs: Object.fromEntries(Object.entries(pass.inputs || {})),
      outputs: Object.fromEntries(Object.entries(pass.outputs || {})) })) }
  })
  const plan = await meshPlan(referenceRoot, item, graph)
  if (plan) {
    await page.waitForFunction(() => [...document.querySelectorAll('.mesh-status')].every(el =>
      el.textContent !== 'loading...'), null, { timeout: 120000 })
    const results = await page.evaluate(async ({ objText, builtins }) => {
      const renderer = window.__noisemakerCanvasRenderer
      const out = []
      for (const builtin of builtins) out.push(await renderer.loadOBJFromURL(`${renderer._basePath}/${builtin.path}`, builtin.meshId))
      if (objText !== null) out.push(await renderer.loadOBJFromString(objText, 'mesh0'))
      else if (!builtins.length) out.push(await renderer.loadOBJFromString('', 'mesh0'))
      return out
    }, plan)
    if (results.some(result => !result?.success)) throw new Error(`mesh load failed: ${JSON.stringify(results)}`)
  }
  const midi = midiMessages(item)
  if (midi) await page.evaluate(messages => {
    const state = window.__noisemakerCanvasRenderer.setMidiState()
    for (const message of messages) state.handleMessage(new Uint8Array(message))
  }, midi)
  const externalIds = [...new Set(graph.passes.flatMap(pass => Object.values(pass.inputs || {}).filter(id =>
    typeof id === 'string' && EXTERNAL_TEXTURE_ID.test(id))))]
  await page.waitForFunction(ids => {
    const pipeline = window.__noisemakerRenderingPipeline
    if (pipeline?._asyncDebounceTimers?.size) return false
    if (window.__nmAsyncInitPending > 0) return false
    return ids.every(id => !!pipeline?.backend?.textures?.get(id))
  }, externalIds, { timeout: 120000 })
  const overlays = await page.evaluate(() => {
    const pipeline = window.__noisemakerRenderingPipeline
    const passes = pipeline.graph.passes
    const written = new Set(passes.flatMap(pass => Object.values(pass.outputs || {})))
    const ids = new Set()
    for (const pass of passes) for (const id of Object.values(pass.inputs || {})) {
      if (written.has(id) || !pipeline.backend.textures.get(id)) continue
      for (const node of window.__nmAsyncInitNodes || []) if (id.startsWith(`${node}_`)) ids.add(id)
    }
    return [...ids]
  })
  return [...externalIds, ...overlays.filter(id => ASYNC_OVERLAY_ID.test(id))]
}

async function captureHostTexture(page, item, index, id, images, out) {
  if (!/^[A-Za-z0-9_]+$/.test(id)) throw new Error(`unsafe host texture ID ${id}`)
  const metadata = await page.evaluate(async ({ id, index }) => {
    const backend = window.__noisemakerRenderingPipeline?.backend
    const texture = backend?.textures?.get(id)
    if (!texture) throw new Error(`host texture ${id} is missing`)
    const format = texture.gpuFormat || texture.format
    if (format !== 'rgba8unorm' && format !== 'rgba8') {
      throw new Error(`host texture ${id} has unsupported exact capture format ${format}`)
    }
    const { width, height } = texture
    if (!Number.isInteger(width) || !Number.isInteger(height) || width < 1 || height < 1) {
      throw new Error(`host texture ${id} has invalid dimensions ${width}x${height}`)
    }
    const device = backend.device
    const rowBytes = Math.ceil(width * 4 / 256) * 256
    const output = device.createBuffer({ size: rowBytes * height,
      usage: GPUBufferUsage.COPY_DST | GPUBufferUsage.MAP_READ })
    let temporary = null
    device.pushErrorScope('validation')
    try {
      let source = texture.handle
      if (!(texture.usage & GPUTextureUsage.COPY_SRC)) {
        temporary = device.createTexture({ size: [width, height], format: 'rgba8unorm',
          usage: GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.COPY_SRC })
        const module = device.createShaderModule({ code: `
@vertex fn vs(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
  var p = array<vec2f, 3>(vec2f(-1.0, -1.0), vec2f(3.0, -1.0), vec2f(-1.0, 3.0));
  return vec4f(p[i], 0.0, 1.0);
}
@group(0) @binding(0) var src: texture_2d<f32>;
@fragment fn fs(@builtin(position) pos: vec4f) -> @location(0) vec4f {
  return textureLoad(src, vec2u(pos.xy), 0);
}` })
        const pipeline = device.createRenderPipeline({ layout: 'auto',
          vertex: { module, entryPoint: 'vs' },
          fragment: { module, entryPoint: 'fs', targets: [{ format: 'rgba8unorm' }] },
          primitive: { topology: 'triangle-list' } })
        const binding = device.createBindGroup({ layout: pipeline.getBindGroupLayout(0),
          entries: [{ binding: 0, resource: texture.view }] })
        const encoder = device.createCommandEncoder()
        const pass = encoder.beginRenderPass({ colorAttachments: [{ view: temporary.createView(),
          loadOp: 'clear', storeOp: 'store', clearValue: { r: 0, g: 0, b: 0, a: 0 } }] })
        pass.setPipeline(pipeline)
        pass.setBindGroup(0, binding)
        pass.draw(3)
        pass.end()
        device.queue.submit([encoder.finish()])
        source = temporary
      }
      const encoder = device.createCommandEncoder()
      encoder.copyTextureToBuffer({ texture: source }, { buffer: output, bytesPerRow: rowBytes },
        { width, height, depthOrArrayLayers: 1 })
      device.queue.submit([encoder.finish()])
      await output.mapAsync(GPUMapMode.READ)
      const mapped = new Uint8Array(output.getMappedRange())
      const bytes = new Uint8Array(width * height * 4)
      for (let row = 0; row < height; row++) bytes.set(mapped.subarray(row * rowBytes, row * rowBytes + width * 4), row * width * 4)
      output.unmap()
      const upload = await fetch(`/__nm_batch_host/${index}/${id}`, { method: 'POST',
        headers: { 'content-type': 'application/octet-stream' }, body: new Blob([bytes]) })
      if (upload.status !== 204) throw new Error(`host texture ${id} upload failed: ${upload.status}`)
    } finally {
      const error = await device.popErrorScope()
      output.destroy()
      temporary?.destroy()
      if (error) throw new Error(`host texture ${id} capture validation: ${error.message}`)
    }
    return { width, height, format: 'rgba8unorm', orientation: 'top-down', bytesPerRow: width * 4 }
  }, { id, index })
  const key = `host/${index}/${id}`
  const bytes = images.get(key)
  if (!bytes || bytes.length !== metadata.width * metadata.height * 4) {
    throw new Error(`host texture ${id} binary upload is incomplete`)
  }
  images.delete(key)
  const path = join(out, `${safeId(item.id)}.host.${id}.frame0.rgba8`)
  mkdirSync(dirname(path), { recursive: true })
  writeFileSync(path, bytes)
  return { id, frame: 0, path, sha256: sha256(bytes), ...metadata }
}

async function injectHostVolume(page, item, out) {
  const input = item.capture.volumeInput
  if (!input) return null
  if (input.id !== 'node_0_volume' || input.assetPath !== 'parity/inputs/sampled3d-v1.rgba8' ||
      input.width !== 8 || input.height !== 8 || input.depth !== 8 ||
      input.format !== 'rgba8unorm' || input.bytesPerRow !== 32 ||
      input.bytesPerImage !== 256 || input.frame !== 0 ||
      input.updatePolicy !== 'static-before-frame-1' ||
      input.orientation !== 'x-fastest-y-next-z-outermost') {
    throw new Error(`${item.id}: unsupported host volume protocol`)
  }
  const source = join(ROOT, input.assetPath)
  const bytes = readFileSync(source)
  if (bytes.length !== 2048 || sha256(bytes) !== input.assetSha256) {
    throw new Error(`${item.id}: host volume binary differs from capture contract`)
  }
  await page.evaluate(async ({ input, logical }) => {
    const backend = window.__noisemakerRenderingPipeline?.backend
    if (backend?.getName?.() !== 'WebGPU') throw new Error('host volume requires locked WebGPU')
    const texture = backend.textures.get(input.id)
    if (!texture || !texture.is3D || texture.width !== input.width ||
        texture.height !== input.height || texture.depth !== input.depth ||
        (texture.gpuFormat || texture.format) !== input.format) {
      throw new Error(`host volume graph texture differs: ${input.id}`)
    }
    const stagingRow = 256
    const staging = new Uint8Array(stagingRow * input.height * input.depth)
    const raw = new Uint8Array(logical)
    for (let z = 0; z < input.depth; z++) for (let y = 0; y < input.height; y++) {
      const sourceOffset = z * input.bytesPerImage + y * input.bytesPerRow
      const targetOffset = (z * input.height + y) * stagingRow
      staging.set(raw.subarray(sourceOffset, sourceOffset + input.bytesPerRow), targetOffset)
    }
    const device = backend.device
    device.pushErrorScope('validation')
    device.queue.writeTexture({ texture: texture.handle }, staging,
      { bytesPerRow: stagingRow, rowsPerImage: input.height },
      { width: input.width, height: input.height, depthOrArrayLayers: input.depth })
    await device.queue.onSubmittedWorkDone()
    const error = await device.popErrorScope()
    if (error) throw new Error(`host volume upload validation: ${error.message}`)
  }, { input, logical: [...bytes] })
  const path = join(out, `${safeId(item.id)}.host.${input.id}.frame0.rgba8`)
  mkdirSync(dirname(path), { recursive: true })
  writeFileSync(path, bytes)
  return { ...input, path, sha256: sha256(bytes) }
}

async function capture(page, item, index, images, expected) {
  const [width, height] = item.capture.size
  const frames = sampleFrames(item)
  const response = await page.evaluate(async ({ width, height, frames, timed, index, expectedGraphId, keepIds, diagnosticIds, passDiagnostic, uniformPassId, audioBindingProbe }) => {
    const pipeline = window.__noisemakerRenderingPipeline
    if (pipeline.backend?.getName?.() !== 'WebGPU') throw new Error('reference backend is not WebGPU')
    if (pipeline.graph?.id !== expectedGraphId) throw new Error(`reference graph ID ${pipeline.graph?.id} differs from ${expectedGraphId}`)
    const canvas = window.__noisemakerCanvasRenderer.canvas
    if (canvas.width !== width || canvas.height !== height) throw new Error(`reference canvas is ${canvas.width}x${canvas.height}`)
    const bounds = canvas.getBoundingClientRect()
    if (Math.round(bounds.width) !== width || Math.round(bounds.height) !== height) throw new Error(`presented canvas bounds are ${bounds.width}x${bounds.height}`)
    const backend = pipeline.backend
    const device = backend.device
    const canvasFormat = backend.canvasFormat || navigator.gpu.getPreferredCanvasFormat()
    if (!['bgra8unorm', 'rgba8unorm'].includes(canvasFormat)) throw new Error(`unsupported canvas format ${canvasFormat}`)
    const currentConfig = backend.context.getConfiguration?.()
    backend.context.configure({ device, format: canvasFormat,
      usage: (currentConfig?.usage || (GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.COPY_DST)) | GPUTextureUsage.COPY_SRC,
      alphaMode: currentConfig?.alphaMode || 'premultiplied' })
    const keep = new Set(keepIds)
    for (const [id, texture] of pipeline.backend.textures) {
      if (keep.has(id) || /^global_mesh\d+_(positions|normals|uvs)$/.test(id) ||
        id === 'midiNoteGrid' || texture?.isExternal || texture?.is3D || texture?.cube) continue
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
    window.__noisemakerSetPausedTime?.(timed ? 0 : 0.25)
    const sinkBefore = [...pipeline.sinkManager.stats.values()].reduce((sum, stat) => sum + stat.accepted, 0)
    const captureSet = new Set(frames)
    const copied = []
    const originalPresent = backend.present.bind(backend)
    const sourceUpdate = backend.updateTextureFromSource
    const dataUpload = backend.uploadDataTexture
    let hostUpdates = 0
    const changedHostIds = new Set()
    const uniformCaptures = new Map()
    const originalCreateUniformBuffer = backend.createUniformBuffer
    const originalCreateSingleUniformBuffer = backend.createSingleUniformBuffer
    let audioBindingValues = null
    let audioBindingCalls = 0
    const originalPackWithLayout = backend.packUniformsWithLayout
    const originalExecutePass = backend.executePass
    let activeUniformPass = null
    let passCopy = null
    if (uniformPassId) {
      backend.createUniformBuffer = function (pass, state, program) {
        activeUniformPass = pass.id
        try { return originalCreateUniformBuffer.call(this, pass, state, program) }
        finally { activeUniformPass = null }
      }
      backend.packUniformsWithLayout = function (...args) {
        const data = originalPackWithLayout.apply(this, args)
        if (activeUniformPass === uniformPassId) uniformCaptures.set(activeUniformPass, new Uint8Array(data))
        return data
      }
    }
    if (audioBindingProbe) {
      backend.createSingleUniformBuffer = function (value, typeDecl) {
        if (typeDecl === 'array<vec4<f32>, 32>') {
          const current = Array.from(value)
          if (current.length !== 128) throw new Error(`audio binding has ${current.length} floats`)
          if (audioBindingValues && current.some((sample, i) => !Object.is(sample, audioBindingValues[i]))) {
            throw new Error('source WebGPU audio binding changed during static capture')
          }
          audioBindingValues = current
          audioBindingCalls++
        }
        return originalCreateSingleUniformBuffer.call(this, value, typeDecl)
      }
    }
    if (passDiagnostic) {
      backend.executePass = function (pass, state) {
        const result = originalExecutePass.call(this, pass, state)
        if (pass.id !== passDiagnostic.id || pipeline.frameIndex + 1 !== frames.at(-1)) return result
        if (passCopy) throw new Error(`diagnostic pass executed more than once: ${pass.id}`)
        const surfaceName = this.parseGlobalName(passDiagnostic.output)
        const resolvedId = surfaceName && state.writeSurfaces?.[surfaceName]
          ? state.writeSurfaces[surfaceName] : passDiagnostic.output
        const texture = this.textures.get(resolvedId)
        if (!texture) throw new Error(`diagnostic pass texture missing: ${passDiagnostic.output} -> ${resolvedId}`)
        const format = texture.gpuFormat || texture.format
        const pixelBytes = { rgba16float: 8, rgba32float: 16, rgba8unorm: 4 }[format]
        if (!pixelBytes || !(texture.usage & GPUTextureUsage.COPY_SRC)) {
          throw new Error(`diagnostic pass texture lacks supported format/COPY_SRC: ${format}`)
        }
        const rowBytes = Math.ceil(texture.width * pixelBytes / 256) * 256
        const buffer = device.createBuffer({ size: rowBytes * texture.height,
          usage: GPUBufferUsage.COPY_DST | GPUBufferUsage.MAP_READ })
        this.commandEncoder.copyTextureToBuffer({ texture: texture.handle }, { buffer, bytesPerRow: rowBytes },
          { width: texture.width, height: texture.height, depthOrArrayLayers: 1 })
        passCopy = { buffer, rowBytes, pixelBytes, id: `after_${pass.id}`,
          width: texture.width, height: texture.height, format, resolvedId }
        return result
      }
    }
    backend.updateTextureFromSource = function (id, ...args) {
      if (keep.has(id)) { hostUpdates++; changedHostIds.add(id) }
      return sourceUpdate.call(this, id, ...args)
    }
    backend.uploadDataTexture = function (id, ...args) {
      if (keep.has(id)) { hostUpdates++; changedHostIds.add(id) }
      return dataUpload.call(this, id, ...args)
    }
    backend.present = textureId => {
      originalPresent(textureId)
      const frame = pipeline.frameIndex + 1
      if (!captureSet.has(frame)) return
      const rowBytes = Math.ceil(width * 4 / 256) * 256
      const buffer = device.createBuffer({ size: rowBytes * height,
        usage: GPUBufferUsage.COPY_DST | GPUBufferUsage.MAP_READ })
      const encoder = device.createCommandEncoder()
      encoder.copyTextureToBuffer({ texture: backend.context.getCurrentTexture() },
        { buffer, bytesPerRow: rowBytes }, { width, height, depthOrArrayLayers: 1 })
      device.queue.submit([encoder.finish()])
      copied.push({ frame, rowBytes, buffer, textureId })
    }
    try {
      const frameCount = frames.at(-1)
      for (let frame = 0; frame < frameCount; frame++) {
        const time = timed ? ((frame + 1) / 600) % 1 : 0.25
        pipeline.render(time)
      }
    } finally {
      backend.present = originalPresent
      backend.updateTextureFromSource = sourceUpdate
      backend.uploadDataTexture = dataUpload
      backend.createUniformBuffer = originalCreateUniformBuffer
      backend.createSingleUniformBuffer = originalCreateSingleUniformBuffer
      backend.packUniformsWithLayout = originalPackWithLayout
      backend.executePass = originalExecutePass
    }
    if (hostUpdates) throw new Error(`host textures changed during capture after frame0: ${[...changedHostIds].join(', ')} (${hostUpdates} uploads)`)
    if (audioBindingProbe && (audioBindingCalls !== frames.at(-1) || !audioBindingValues)) {
      throw new Error(`source WebGPU audio binding ran ${audioBindingCalls} of ${frames.at(-1)} frames`)
    }
    await device.queue.onSubmittedWorkDone()
    const accepted = [...pipeline.sinkManager.stats.values()].reduce((sum, stat) => sum + stat.accepted, 0) - sinkBefore
    if (accepted !== frames.at(-1)) throw new Error(`sink accepted ${accepted} of ${frames.at(-1)} frames`)
    if (copied.length !== frames.length) throw new Error(`captured ${copied.length} of ${frames.length} samples`)
    const surfaceName = pipeline.graph.renderSurface
    const presented = pipeline.frameReadTextures.get(surfaceName)
    for (const sample of copied) {
      if (sample.frame === frames.at(-1) && sample.textureId !== presented) throw new Error('final copy did not follow presented surface')
      await sample.buffer.mapAsync(GPUMapMode.READ)
      const mapped = new Uint8Array(sample.buffer.getMappedRange())
      const pixels = new Uint8Array(width * height * 4)
      for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) {
        const src = y * sample.rowBytes + x * 4
        const dst = (y * width + x) * 4
        pixels[dst] = mapped[src + (canvasFormat === 'bgra8unorm' ? 2 : 0)]
        pixels[dst + 1] = mapped[src + 1]
        pixels[dst + 2] = mapped[src + (canvasFormat === 'bgra8unorm' ? 0 : 2)]
        pixels[dst + 3] = mapped[src + 3]
      }
      sample.buffer.unmap()
      sample.buffer.destroy()
      const upload = await fetch(`/__nm_batch_capture/${index}/${sample.frame}`, { method: 'POST',
        headers: { 'content-type': 'application/octet-stream' }, body: new Blob([pixels]) })
      if (upload.status !== 204) throw new Error(`capture upload failed: ${upload.status}`)
    }
    const intermediates = []
    for (const id of diagnosticIds) {
      const surfaceName = backend.parseGlobalName(id)
      const resolvedId = surfaceName
        ? (pipeline.frameReadTextures?.get(surfaceName) || pipeline.surfaces.get(surfaceName)?.read || id)
        : id
      const texture = backend.textures.get(resolvedId)
      if (!texture) throw new Error(`diagnostic texture missing: ${id} -> ${resolvedId}`)
      const format = texture.gpuFormat || texture.format
      const pixelBytes = { rgba16float: 8, rgba32float: 16, rgba8unorm: 4 }[format]
      if (!pixelBytes || !(texture.usage & GPUTextureUsage.COPY_SRC)) {
        throw new Error(`diagnostic texture ${id} lacks supported format/COPY_SRC: ${format}`)
      }
      const rowBytes = Math.ceil(texture.width * pixelBytes / 256) * 256
      const buffer = device.createBuffer({ size: rowBytes * texture.height,
        usage: GPUBufferUsage.COPY_DST | GPUBufferUsage.MAP_READ })
      device.pushErrorScope('validation')
      try {
        const encoder = device.createCommandEncoder()
        encoder.copyTextureToBuffer({ texture: texture.handle }, { buffer, bytesPerRow: rowBytes },
          { width: texture.width, height: texture.height, depthOrArrayLayers: 1 })
        device.queue.submit([encoder.finish()])
        await buffer.mapAsync(GPUMapMode.READ)
        const mapped = new Uint8Array(buffer.getMappedRange())
        const bytes = new Uint8Array(texture.width * texture.height * pixelBytes)
        for (let row = 0; row < texture.height; row++) {
          bytes.set(mapped.subarray(row * rowBytes, row * rowBytes + texture.width * pixelBytes),
            row * texture.width * pixelBytes)
        }
        buffer.unmap()
        const upload = await fetch(`/__nm_batch_intermediate/${index}/${id}`, { method: 'POST',
          headers: { 'content-type': 'application/octet-stream' }, body: new Blob([bytes]) })
        if (upload.status !== 204) throw new Error(`diagnostic texture upload failed: ${id}`)
      } finally {
        const error = await device.popErrorScope()
        buffer.destroy()
        if (error) throw new Error(`diagnostic texture validation ${id}: ${error.message}`)
      }
      intermediates.push({ id, resolvedTexture: resolvedId,
        width: texture.width, height: texture.height, format,
        orientation: 'top-down', bytesPerRow: texture.width * pixelBytes })
    }
    if (passDiagnostic && !passCopy) throw new Error(`diagnostic pass not executed: ${passDiagnostic.id}`)
    if (passCopy) {
      await passCopy.buffer.mapAsync(GPUMapMode.READ)
      const mapped = new Uint8Array(passCopy.buffer.getMappedRange())
      const bytes = new Uint8Array(passCopy.width * passCopy.height * passCopy.pixelBytes)
      for (let row = 0; row < passCopy.height; row++) {
        bytes.set(mapped.subarray(row * passCopy.rowBytes, row * passCopy.rowBytes + passCopy.width * passCopy.pixelBytes),
          row * passCopy.width * passCopy.pixelBytes)
      }
      passCopy.buffer.unmap()
      passCopy.buffer.destroy()
      const upload = await fetch(`/__nm_batch_intermediate/${index}/${passCopy.id}`, { method: 'POST',
        headers: { 'content-type': 'application/octet-stream' }, body: new Blob([bytes]) })
      if (upload.status !== 204) throw new Error(`diagnostic pass upload failed: ${passCopy.id}`)
      intermediates.push({ id: passCopy.id, sourceTexture: passDiagnostic.output,
        resolvedTexture: passCopy.resolvedId, width: passCopy.width, height: passCopy.height,
        format: passCopy.format, orientation: 'top-down', bytesPerRow: passCopy.width * passCopy.pixelBytes })
    }
    for (const [passId, bytes] of uniformCaptures) {
      const upload = await fetch(`/__nm_batch_uniform/${index}/${passId}`, { method: 'POST',
        headers: { 'content-type': 'application/octet-stream' }, body: new Blob([bytes]) })
      if (upload.status !== 204) throw new Error(`diagnostic uniform upload failed: ${passId}`)
    }
    const adapter = await navigator.gpu.requestAdapter()
    const info = adapter?.info
    return { backend: backend.getName(), browser: navigator.userAgent,
      capabilityProfile: { maxTextureDimension2D: device.limits.maxTextureDimension2D },
      adapter: info ? { vendor: info.vendor ?? null, architecture: info.architecture ?? null,
        device: info.device ?? null, description: info.description ?? null } : null,
      graphId: pipeline.graph.id, frameIndex: pipeline.frameIndex, width, height,
      surface: surfaceName, canvasFormat, presentedTexture: presented, sinkAccepted: accepted,
      sampleFrames: frames, intermediates,
      diagnosticPassUniforms: uniformPassId
        ? Object.fromEntries(Object.entries(pipeline.graph.passes.find(pass => pass.id === uniformPassId)?.uniforms || {})) : null,
      diagnosticUniformPasses: [...uniformCaptures.keys()], audioBindingValues }
  }, { width, height, frames, timed: !!item.capture.frameTime, index,
    expectedGraphId: expected.graphId, keepIds: expected.keepIds,
    diagnosticIds: expected.diagnosticIds || [], passDiagnostic: expected.passDiagnostic || null,
    uniformPassId: expected.uniformPassId || null, audioBindingProbe: !!expected.audioBindingProbe })
  const paths = []
  for (const frame of frames) {
    const data = images.get(`${index}/${frame}`)
    if (!data) throw new Error(`${item.id}: frame ${frame} presented readback missing`)
    const png = encodePng(width, height, data)
    const path = join(expected.out, `${safeId(item.id)}.frame${frame}.png`)
    mkdirSync(dirname(path), { recursive: true })
    writeFileSync(path, png)
    paths.push({ frame, path, sha256: sha256(png) })
    images.delete(`${index}/${frame}`)
  }
  const intermediates = response.intermediates.map(row => {
    const bytes = images.get(`intermediate/${index}/${row.id}`)
    if (!bytes || bytes.length !== row.bytesPerRow * row.height) throw new Error(`${item.id}: diagnostic ${row.id} missing`)
    const path = join(expected.out, `${safeId(item.id)}.${row.id}.frame${frames.at(-1)}.raw`)
    writeFileSync(path, bytes)
    images.delete(`intermediate/${index}/${row.id}`)
    return { ...row, path, sha256: sha256(bytes) }
  })
  const uniformBuffers = response.diagnosticUniformPasses.map(passId => {
    const bytes = images.get(`uniform/${index}/${passId}`)
    if (!bytes) throw new Error(`${item.id}: diagnostic uniform ${passId} missing`)
    const path = join(expected.out, `${safeId(item.id)}.${passId}.frame${frames.at(-1)}.uniforms`)
    writeFileSync(path, bytes)
    images.delete(`uniform/${index}/${passId}`)
    return { passId, path, bytes: bytes.length, sha256: sha256(bytes) }
  })
  const { audioBindingValues, ...captureResponse } = response
  const audioBindingEffectiveSha256 = audioBindingValues ? (() => {
    const bytes = Buffer.alloc(512)
    audioBindingValues.forEach((sample, sampleIndex) => bytes.writeFloatLE(sample, sampleIndex * 4))
    return sha256(bytes)
  })() : null
  return { ...captureResponse, intermediates, uniformBuffers, images: paths,
    ...(audioBindingEffectiveSha256 ? { audioBindingEffectiveSha256 } : {}) }
}

async function main() {
  const cancellation = createCaptureCancellation()
  try {
  const [outArg, ...caseArgs] = process.argv.slice(2)
  if (!outArg) throw new Error('usage: node parity/batch-golden.mjs <out-dir> [--resume] [corpus-case-id ...]')
  const resume = caseArgs[0] === '--resume'
  const requested = resume ? caseArgs.slice(1) : caseArgs
  const out = resolve(outArg)
  const ref = process.env.NM_REFERENCE_ROOT
  if (!ref) throw new Error('NM_REFERENCE_ROOT must name the pinned upstream checkout or verified archive with browser dependencies')
  const lock = readJson(join(ROOT, 'parity/reference.json'))
  const referenceRoot = resolve(ref)
  if (existsSync(join(referenceRoot, '.git'))) sourceIdentity(referenceRoot, lock)
  else verifyArchivedSource(referenceRoot, lock, join(ROOT, '.build/reference'))
  const corpus = readJson(join(ROOT, 'parity/corpus.json'))
  const stages = readJson(join(ROOT, 'parity/corpus-stages.json'))
  if (corpus.sourceManifestSha256 !== lock.sourceManifestSha256 || stages.corpusSha256 !== sha256(readFileSync(join(ROOT, 'parity/corpus.json')))) {
    throw new Error('corpus or stage oracle differs from locked source')
  }
  const selected = selectedCases(corpus, requested)
  const stageById = new Map(stages.cases.map(item => [item.id, item]))
  const harness = join(referenceRoot, 'vendor/shade-mcp/harness/index.js')
  process.env.SHADE_VIEWER_ROOT = referenceRoot
  process.env.SHADE_VIEWER_PATH = '/demo/shaders/'
  process.env.SHADE_EFFECTS_DIR = join(referenceRoot, 'shaders/effects')
  process.env.SHADE_GLOBALS_PREFIX = '__noisemaker'
  process.env.SHADE_HEADLESS = process.env.SHADE_HEADLESS ?? '1'
  const { BrowserSession } = await import(pathToFileURL(harness).href)
  const corpusSha256 = sha256(readFileSync(join(ROOT, 'parity/corpus.json')))
  mkdirSync(out, { recursive: true })
  const ledgerPath = join(out, 'goldens.json')
  const prior = resume && existsSync(ledgerPath) ? readJson(ledgerPath) : null
  if (prior && (prior.schemaVersion !== 1 || prior.corpusSha256 !== corpusSha256 ||
      JSON.stringify(prior.authority) !== JSON.stringify(lock) || prior.expected !== selected.length ||
      !Array.isArray(prior.cases) || prior.cases.length > selected.length)) {
    throw new Error('resumed golden ledger differs from locked authority or selected corpus')
  }
  const fingerprintPath = process.env.NM_QUALIFICATION_FINGERPRINT
  const qualificationFingerprintSha256 = fingerprintPath ? sha256(readFileSync(fingerprintPath)) : null
  const fingerprint = fingerprintPath ? readJson(fingerprintPath) : null
  const qualifiedBrowser = fingerprint?.referenceAuthority?.browser
  const headless = !(process.env.SHADE_HEADLESS === '0' || process.env.SHADE_HEADLESS === 'false')
  const executablePath = chromiumExecutable(referenceRoot, headless)
  const executableSha256 = await fileSha256(executablePath)
  if (fingerprintPath && (!qualifiedBrowser || qualifiedBrowser.headless !== headless ||
      qualifiedBrowser.executablePath !== executablePath ||
      qualifiedBrowser.executableSha256 !== executableSha256 ||
      !/^[0-9a-f]{64}$/.test(qualifiedBrowser.bundleSha256))) {
    throw new Error('launched Chromium executable differs from qualification fingerprint')
  }
  if (prior && prior.qualificationFingerprintSha256 !== qualificationFingerprintSha256) {
    throw new Error('resumed golden qualification fingerprint differs')
  }
  const ledger = prior?.cases || []
  // A failure has no binary artifact to rehash. Re-execute it and every later
  // case rather than trusting an editable diagnostic from a previous process.
  const firstFailure = ledger.findIndex(record => record.status !== 'ok')
  if (firstFailure >= 0) ledger.splice(firstFailure)
  for (let index = 0; index < ledger.length; index++) {
    const record = ledger[index]
    const item = selected[index]
    if (record.id !== item.id || record.sourceSha256 !== item.sourceSha256 ||
        JSON.stringify(record.capture) !== JSON.stringify(item.capture) ||
        !['ok', 'fail'].includes(record.status)) {
      throw new Error(`resumed golden ledger case ${index} differs from selected corpus`)
    }
    if (record.status === 'ok') {
      const expectedFrames = sampleFrames(item)
      if (!Array.isArray(record.images) || record.images.length !== expectedFrames.length ||
          record.images.some((image, sample) => image.frame !== expectedFrames[sample] ||
            resolve(image.path || '') !== join(out, `${safeId(item.id)}.frame${image.frame}.png`))) {
        throw new Error(`resumed golden image protocol differs from selected corpus: ${item.id}`)
      }
      for (const descriptor of [...(record.images || []), ...(record.hostTextures || []),
        ...(record.intermediates || []), ...(record.uniformBuffers || [])]) {
        const path = descriptor.path && resolve(descriptor.path)
        const location = path && relative(out, path)
        if (!path || !location || location.startsWith('..') || isAbsolute(location) ||
            !descriptor.sha256 || !existsSync(path) || sha256(readFileSync(path)) !== descriptor.sha256) {
          throw new Error(`resumed golden artifact differs from ledger: ${item.id}`)
        }
      }
    }
  }
  const writeLedger = () => {
    writeFileSync(`${ledgerPath}.tmp`, JSON.stringify({ schemaVersion: 1, authority: lock,
      corpusSha256, qualificationFingerprintSha256, expected: selected.length,
      cases: ledger }, null, 2) + '\n')
    renameSync(`${ledgerPath}.tmp`, ledgerPath)
  }
  writeLedger()
  for (let start = ledger.length; start < selected.length; start = ledger.length) {
    cancellation.throwIfCancelled()
    const session = new BrowserSession({ backend: 'webgpu' })
    cancellation.setSession(session)
    try {
    if (session.options.headless !== headless) {
      throw new Error('pinned browser harness launch mode differs from qualified Chromium')
    }
    await session.setup()
    cancellation.throwIfCancelled()
    await session.setBackend('webgpu')
    const page = session.page
    const runtimeEnvironment = {
      browser: session.browser.version(), node: process.version,
      os: `${platform()} ${release()}`, architecture: arch(),
      ...(qualifiedBrowser ? { browserExecutablePath: executablePath,
        browserExecutableSha256: executableSha256,
        browserBundleSha256: qualifiedBrowser.bundleSha256 } : {})
    }
    const errors = []
    const images = new Map()
    page.on('console', message => { if (message.type() === 'error') errors.push(message.text()) })
    page.on('pageerror', error => errors.push(error.message))
    await page.route('**/__nm_batch_capture/**', async route => {
      const match = route.request().url().match(/\/__nm_batch_capture\/(\d+\/\d+)$/)
      if (!match) throw new Error(`unexpected batch capture URL ${route.request().url()}`)
      images.set(match[1], route.request().postDataBuffer())
      await route.fulfill({ status: 204 })
    })
    await page.route('**/__nm_batch_host/**', async route => {
      const match = route.request().url().match(/\/__nm_batch_host\/(\d+\/\w+)$/)
      if (!match) throw new Error(`unexpected host texture URL ${route.request().url()}`)
      images.set(`host/${match[1]}`, route.request().postDataBuffer())
      await route.fulfill({ status: 204 })
    })
    await page.route('**/__nm_batch_intermediate/**', async route => {
      const match = route.request().url().match(/\/__nm_batch_intermediate\/(\d+\/\w+)$/)
      if (!match) throw new Error(`unexpected intermediate URL ${route.request().url()}`)
      images.set(`intermediate/${match[1]}`, route.request().postDataBuffer())
      await route.fulfill({ status: 204 })
    })
    await page.route('**/__nm_batch_uniform/**', async route => {
      const match = route.request().url().match(/\/__nm_batch_uniform\/(\d+\/\w+)$/)
      if (!match) throw new Error(`unexpected uniform URL ${route.request().url()}`)
      images.set(`uniform/${match[1]}`, route.request().postDataBuffer())
      await route.fulfill({ status: 204 })
    })
    // The source checkout has a tracked shaders/share alias to ../share. A
    // verified git archive contains the target bytes but deliberately creates
    // no symlink; serve the same pinned OBJ bytes at the demo's alias URL.
    await page.route('**/shaders/share/meshes/*.obj', async route => {
      const path = new URL(route.request().url()).pathname
      const match = path.match(/^\/shaders\/share\/meshes\/([A-Za-z0-9_-]+\.obj)$/)
      if (!match) throw new Error(`unexpected built-in mesh URL ${path}`)
      const source = join(referenceRoot, 'share/meshes', match[1])
      if (!existsSync(source)) throw new Error(`locked built-in mesh missing: ${match[1]}`)
      await route.fulfill({ status: 200, contentType: 'text/plain', body: readFileSync(source) })
    })
    await page.waitForFunction(() => !!window.__noisemakerCanvasRenderer && !!document.getElementById('dsl-editor'), null, { timeout: 120000 })
    await installAsyncInitTracker(page)
    for (let index = start; index < Math.min(start + SESSION_CASE_LIMIT, selected.length); index++) {
      cancellation.throwIfCancelled()
      const item = selected[index]
      const oracle = stageById.get(item.id)
      const record = { id: item.id, sourceSha256: item.sourceSha256,
        capture: item.capture, backend: 'WebGPU', runtimeEnvironment: { ...runtimeEnvironment } }
      try {
        if (!oracle || oracle.sourceSha256 !== item.sourceSha256 || oracle.stages.graph?.status !== 'ok') {
          throw new Error('case lacks matching successful locked-JS graph oracle')
        }
        const [width, height] = item.capture.size
        await sizePage(page, width, height)
        record.capabilityProfile = await page.evaluate(async () => {
          const device = window.__noisemakerRenderingPipeline?.backend?.device
          let limit = device?.limits?.maxTextureDimension2D
          if (limit === undefined) {
            const adapter = await navigator.gpu.requestAdapter()
            if (!adapter) throw new Error('source WebGPU adapter unavailable')
            const requiredFeatures = adapter.features.has('float32-filterable') ? ['float32-filterable'] : []
            const probeDevice = await adapter.requestDevice({ requiredFeatures, requiredLimits: {
              maxColorAttachmentBytesPerSample: Math.min(adapter.limits.maxColorAttachmentBytesPerSample, 128)
            } })
            try { limit = probeDevice.limits.maxTextureDimension2D }
            finally { probeDevice.destroy() }
          }
          if (!Number.isSafeInteger(limit) || limit < 256 || limit > 16384) {
            throw new Error(`invalid source WebGPU texture dimension limit: ${limit}`)
          }
          return { maxTextureDimension2D: limit }
        })
        await page.evaluate(() => {
          window.__nmAsyncInitNodes = new Set()
          const renderer = window.__noisemakerCanvasRenderer
          if (renderer?._midiState) {
            renderer._midiState = null
            window.__noisemakerRenderingPipeline?.setMidiState?.(null)
          }
        })
        const definition = portableDefinition(item)
        if (definition) {
          const registration = await page.evaluate(async value => {
            try { await window.__noisemakerCanvasRenderer.registerPortableEffect(value); return { ok: true } }
            catch (error) { return { error: error?.message || String(error) } }
          }, definition)
          if (registration.error) throw new Error(`Portable registration failed: ${registration.error}`)
        }
        errors.length = 0
        await page.evaluate(source => {
          const state = window.__noisemakerProgramState
          if (Array.isArray(state?._structure)) state._structure = []
          document.getElementById('status').textContent = ''
          const editor = document.getElementById('dsl-editor')
          editor.value = source
          editor.dispatchEvent(new Event('input', { bubbles: true }))
          document.getElementById('dsl-run-btn').click()
        }, item.source)
        await page.waitForFunction(source => {
          const status = document.getElementById('status')?.textContent || ''
          if (/error|failed/i.test(status)) throw new Error(`reference DSL failed: ${status}`)
          const pipeline = window.__noisemakerRenderingPipeline
          return pipeline?.graph?.source === source.trim() && !pipeline.isCompiling &&
            pipeline.backend?.getName?.() === 'WebGPU' && /compiled/i.test(status)
        }, item.source, { timeout: 120000 })
        const current = await page.evaluate(() => ({ id: window.__noisemakerRenderingPipeline.graph.id,
          passes: window.__noisemakerRenderingPipeline.graph.passes.length }))
        const actualLimit = await page.evaluate(() => window.__noisemakerRenderingPipeline.backend.device.limits.maxTextureDimension2D)
        if (!Number.isSafeInteger(actualLimit) || actualLimit < 256 || actualLimit > 16384) {
          throw new Error(`invalid source WebGPU device texture dimension limit: ${actualLimit}`)
        }
        record.capabilityProfile = { maxTextureDimension2D: actualLimit }
        record.runtimeEnvironment.device = await page.evaluate(() => {
          const device = window.__noisemakerRenderingPipeline.backend.device
          const info = device.adapterInfo
          if (!info) throw new Error('active WebGPU device lacks adapter identity')
          return { vendor: info.vendor, architecture: info.architecture, device: info.device,
            description: info.description, features: [...device.features].sort(),
            maxTextureDimension2D: device.limits.maxTextureDimension2D }
        })
        if (current.passes !== oracle.passCount) throw new Error(`reference pass count ${current.passes} differs from stage oracle ${oracle.passCount}`)
        if (oracle.effects.includes('filter.text')) {
          // The unmodified demo schedules its hidden text canvas upload 50 ms
          // after building controls. Let that source-owned redraw finish before
          // zeroing frame state and counting only our explicit render calls.
          await page.evaluate(() => document.fonts.ready)
          await page.waitForTimeout(150)
        }
        const keepIds = await readyHostInputs(page, referenceRoot, item)
        const audio = audioPlan(item, lock)
        const hostAudio = await injectAudio(page, item, audio)
        const hostVolume = await injectHostVolume(page, item, out)
        const hostTextures = []
        for (const id of keepIds) hostTextures.push(await captureHostTexture(page, item, index, id, images, out))
        const diagnosticIds = item.id === 'coverage/filter_wormhole' && process.env.NM_WORMHOLE_DIAGNOSTICS === '1'
          ? ['node_0_out', 'node_1_wormhole_accum']
          : item.id === process.env.NM_DIAGNOSTIC_CASE && process.env.NM_INTERMEDIATE_IDS
            ? process.env.NM_INTERMEDIATE_IDS.split(',') : []
        const passDiagnostic = item.id === process.env.NM_DIAGNOSTIC_CASE && process.env.NM_DIAGNOSTIC_PASS_ID
          ? { id: process.env.NM_DIAGNOSTIC_PASS_ID, output: process.env.NM_DIAGNOSTIC_PASS_OUTPUT } : null
        const uniformPassId = item.id === process.env.NM_DIAGNOSTIC_CASE && process.env.NM_UNIFORM_PASS_ID
          ? process.env.NM_UNIFORM_PASS_ID : item.id === 'coverage/filter_wormhole' && process.env.NM_WORMHOLE_DIAGNOSTICS === '1'
            ? 'node_1_pass_1' : null
        if (diagnosticIds.some(id => !/^\w+$/.test(id)) ||
            (passDiagnostic && (!/^\w+$/.test(passDiagnostic.id) || !/^\w+$/.test(passDiagnostic.output))) ||
            (uniformPassId && !/^\w+$/.test(uniformPassId))) {
          throw new Error('unsafe intermediate diagnostic selector')
        }
        const result = await capture(page, item, index, images, { graphId: current.id, keepIds, out,
          diagnosticIds, passDiagnostic, uniformPassId, audioBindingProbe: !!hostAudio })
        const caseErrors = errors.filter(message => !(midiMessages(item) &&
          /^MIDI access denied: NotAllowedError: Permission to use Web MIDI API was not granted\.?$/.test(message)) &&
          !(hostAudio && /^Audio access denied: (?:NotSupportedError|NotAllowedError):/.test(message)))
        if (caseErrors.length) throw new Error(`WebGPU browser errors: ${caseErrors.join(' | ')}`)
        Object.assign(record, { status: 'ok', hostTextures,
          ...(hostVolume ? { hostVolumes: [hostVolume] } : {}),
          ...(hostAudio ? { hostAudio } : {}), ...result })
      } catch (error) {
        cancellation.throwIfCancelled()
        const deviceLimit = await page.evaluate(() =>
          window.__noisemakerRenderingPipeline?.backend?.device?.limits?.maxTextureDimension2D).catch(() => null)
        if (Number.isSafeInteger(deviceLimit) && deviceLimit >= 256 && deviceLimit <= 16384) {
          record.capabilityProfile = { maxTextureDimension2D: deviceLimit }
        }
        record.status = 'fail'
        record.error = error?.stack || String(error)
      }
      cancellation.throwIfCancelled()
      ledger.push(record)
      writeLedger()
      process.stderr.write(`[golden ${index + 1}/${selected.length}] ${item.id}: ${record.status}${record.error ? `: ${record.error.split('\n')[0]}` : ''}\n`)
      // A failed compile may leave the source UI's pipeline partially replaced.
      // Do not feed the next case to that browser session.
      if (record.status !== 'ok') break
    }
    } finally { await cancellation.closeSession(session) }
  }
  cancellation.throwIfCancelled()
  writeLedger()
  process.stdout.write(JSON.stringify({ expected: selected.length, captured: ledger.filter(x => x.status === 'ok').length,
    failed: ledger.filter(x => x.status !== 'ok').map(x => x.id) }) + '\n')
  if (ledger.some(x => x.status !== 'ok')) process.exitCode = 1
  } finally { cancellation.dispose() }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch(error => { process.stderr.write(`${error?.stack || String(error)}\n`); process.exitCode ||= 1 })
}
