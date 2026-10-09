#!/usr/bin/env node
// Same-frame nonzero host audio pixels and effective uniforms on source browsers.
import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { createRequire } from 'node:module'
import { isAbsolute, join, relative, resolve } from 'node:path'
import { pathToFileURL } from 'node:url'
import { sizePage } from '../parity/marker-golden.mjs'
import { sourceIdentity, sourceManifest } from './export-reference.mjs'

const referenceRoot = process.env.NM_REFERENCE_ROOT
if (!referenceRoot) throw new Error('NM_REFERENCE_ROOT must name the current source checkout')
const root = resolve(referenceRoot)
const lock = JSON.parse(readFileSync(new URL('../parity/reference.json', import.meta.url)))
// An unpinned local probe is diagnostic only; qualification requires the exact
// committed authority and source manifest checked by sourceIdentity.
const diagnostic = process.env.NM_UNPINNED_PROBE === '1'
if (!diagnostic) sourceIdentity(root, lock)
const sourceManifestBefore = sourceManifest(root, lock)
if (!diagnostic) assert.equal(sourceManifestBefore.contentSha256, lock.sourceManifestSha256,
  'source manifest before audio captures differs from pinned authority')
const provenance = diagnostic ? { qualification: 'diagnostic-unpinned',
  expectedAuthorityCommit: lock.commit } : { qualification: 'pinned',
  authorityCommit: lock.commit, authorityManifestSha256: lock.sourceManifestSha256 }
process.env.SHADE_VIEWER_ROOT = root
process.env.SHADE_VIEWER_PATH = '/demo/shaders/'
process.env.SHADE_EFFECTS_DIR = join(root, 'shaders/effects')
process.env.SHADE_GLOBALS_PREFIX = '__noisemaker'
process.env.SHADE_HEADLESS = '1'
const { BrowserSession } = await import(pathToFileURL(join(root, 'vendor/shade-mcp/harness/index.js')).href)
const fixture = JSON.parse(readFileSync(new URL('../parity/inputs/audio-v1.json', import.meta.url)))
const digest = bytes => createHash('sha256').update(Buffer.from(bytes)).digest('hex')
const floatBytes = values => {
  const bytes = Buffer.alloc(values.length * 4)
  values.forEach((value, index) => bytes.writeFloatLE(value, index * 4))
  return bytes
}
const outDir = process.argv[2], nativeDir = process.argv[3] && resolve(process.argv[3])
if (process.argv.length > 4 || (nativeDir && !outDir)) {
  throw new Error('usage: node tools/qualify-audio-source.mjs [raw-output-dir] [native-candidates-dir]')
}
if (outDir) mkdirSync(outDir, { recursive: true })
const nativeLedgerPath = nativeDir && join(nativeDir, 'candidates.json')
const nativeFingerprintPath = nativeDir && resolve(nativeDir, '../build-fingerprint.json')
const nativeLedgerBytes = nativeLedgerPath && readFileSync(nativeLedgerPath)
const nativeFingerprintBytes = nativeFingerprintPath && readFileSync(nativeFingerprintPath)
const nativeLedger = nativeLedgerBytes && JSON.parse(nativeLedgerBytes)
const nativeFingerprint = nativeFingerprintBytes && JSON.parse(nativeFingerprintBytes)
const PNG = nativeDir
  ? createRequire(pathToFileURL(join(root, 'package.json')))('pngjs').PNG : null
if (nativeLedger) {
  assert.equal(nativeLedger.schemaVersion, 1)
  assert.equal(nativeLedger.compileOnly, false)
  const corpusBytes = readFileSync(new URL('../parity/corpus.json', import.meta.url))
  assert.equal(nativeLedger.corpusSha256, digest(corpusBytes))
  assert.equal(nativeLedger.qualificationFingerprintSha256, digest(nativeFingerprintBytes),
    'native ledger differs from its sibling qualification fingerprint')
  assert.match(nativeFingerprint.binarySha256 || '', /^[0-9a-f]{64}$/,
    'qualification fingerprint lacks native executable hash')
  assert.equal(nativeFingerprint.referenceAuthority?.sourceManifestSha256,
    lock.sourceManifestSha256, 'native build differs from pinned source authority')
  const authorityManifestBytes = readFileSync(new URL('../.build/reference/source-manifest.json', import.meta.url))
  const authorityManifest = JSON.parse(authorityManifestBytes)
  assert.equal(nativeFingerprint.referenceAuthority.sourceManifestFileSha256,
    digest(authorityManifestBytes), 'native build differs from exported source manifest')
  assert.equal(authorityManifest.repository, lock.repository)
  assert.equal(authorityManifest.commit, lock.commit)
  assert.equal(authorityManifest.contentSha256, lock.sourceManifestSha256)
  if (!diagnostic) assert.deepEqual(authorityManifest.files, sourceManifestBefore.files,
    'native authority manifest differs from live source files')
  assert.match(nativeFingerprint.buildEnvironment?.os || '', /^macOS-/,
    'native qualification build must be on macOS')
  assert.ok(Array.isArray(nativeLedger.cases), 'native ledger lacks cases')
  const corpus = JSON.parse(corpusBytes)
  for (const effect of ['scope', 'spectrum']) {
    const id = `coverage/synth_${effect}`
    const records = nativeLedger.cases.filter(item => item.id === id)
    assert.equal(records.length, 1, `${id} must have exactly one native case`)
    const sourceCase = corpus.cases.find(item => item.id === id)
    assert.equal(records[0].sourceSha256, sourceCase?.sourceSha256,
      `${id} native source differs from pinned corpus`)
    assert.equal(records[0].backend, 'Metal', `${id} native backend`)
    const runtime = records[0].runtimeEnvironment
    assert.equal(runtime?.executableSha256, nativeFingerprint.binarySha256,
      `${id} native executable differs from qualified binary`)
    assert.equal(runtime?.architecture, nativeFingerprint.buildEnvironment.architecture,
      `${id} native architecture differs from qualified build`)
    assert.ok(typeof runtime?.os === 'string' && runtime.os,
      `${id} lacks native OS identity`)
    assert.ok(typeof runtime?.device?.name === 'string' && runtime.device.name,
      `${id} lacks Metal device name`)
    assert.match(runtime.device.registryID || '', /^[1-9][0-9]*$/,
      `${id} lacks physical Metal device registry ID`)
  }
  const [scope, spectrum] = ['scope', 'spectrum'].map(effect =>
    nativeLedger.cases.find(item => item.id === `coverage/synth_${effect}`))
  assert.deepEqual(scope.runtimeEnvironment, spectrum.runtimeEnvironment,
    'native Metal environment changed between audio captures')
}
function flipRows(bytes) {
  const flipped = new Uint8Array(bytes.length), row = 256 * 4
  for (let y = 0; y < 256; y++) {
    flipped.set(bytes.slice((255 - y) * row, (256 - y) * row), y * row)
  }
  return flipped
}

async function runBackend(name) {
  const session = new BrowserSession({ backend: name })
  await session.setup()
  try {
    await session.setBackend(name)
    const page = session.page
    await page.waitForFunction(() => !!window.__noisemakerCanvasRenderer &&
      !!document.getElementById('dsl-editor'), null, { timeout: 120000 })
    await sizePage(page, 256, 256)
    const results = []
    for (const effect of ['scope', 'spectrum']) {
      const source = `search synth\n${effect}().write(o0)\nrender(o0)\n`
      await page.evaluate(source => {
        const state = window.__noisemakerProgramState
        if (Array.isArray(state?._structure)) state._structure = []
        document.getElementById('status').textContent = ''
        const editor = document.getElementById('dsl-editor')
        editor.value = source
        editor.dispatchEvent(new Event('input', { bubbles: true }))
        document.getElementById('dsl-run-btn').click()
      }, source)
      await page.waitForFunction(({ source, name }) => {
        const status = document.getElementById('status')?.textContent || ''
        if (/error|failed/i.test(status)) throw new Error(status)
        const pipeline = window.__noisemakerRenderingPipeline
        return pipeline?.graph?.source === source.trim() && !pipeline.isCompiling &&
          pipeline.backend?.getName?.().toLowerCase() === name && /compiled/i.test(status)
      }, { source, name }, { timeout: 120000 })
      const result = await page.evaluate(async ({ effect, waveformBytes, spectrumBytes, name }) => {
        const renderer = window.__noisemakerCanvasRenderer
        const state = renderer.setAudioState()
        state.setWaveform(new Uint8Array(waveformBytes))
        state.setSpectrum(new Uint8Array(spectrumBytes))
        const pipeline = window.__noisemakerRenderingPipeline
        const backend = pipeline.backend
        if (pipeline.externalState.audio !== state ||
            !(state.waveform instanceof Float32Array) ||
            !(state.spectrum instanceof Float32Array)) {
          throw new Error('AudioState typed samples did not reach source pipeline')
        }
        pipeline.globalUniforms = {}
        pipeline.frameIndex = 0
        pipeline.lastTime = 0
        window.__noisemakerSetPausedTime?.(0.25)
        let binding = null, calls = 0, presented = null
        const capture = value => {
          const current = Array.from(value)
          if (current.length !== 128) throw new Error('audio binding length differs')
          if (binding && current.some((sample, index) => !Object.is(sample, binding[index]))) {
            throw new Error('audio binding changed during static frames')
          }
          binding = current
          calls++
        }
        const originalPresent = backend.present
        const originalUniform = backend._setUniform
        const originalBuffer = backend.createSingleUniformBuffer
        if (name === 'webgl2') {
          backend._setUniform = function (gl, uniform, value) {
            if (uniform.size === 128 && value?.length === 128) capture(value)
            return originalUniform.call(this, gl, uniform, value)
          }
        } else {
          backend.createSingleUniformBuffer = function (value, typeDecl) {
            if (typeDecl === 'array<vec4<f32>, 32>') capture(value)
            return originalBuffer.call(this, value, typeDecl)
          }
        }
        backend.present = function (id) { presented = id; return originalPresent.call(this, id) }
        try {
          for (let frame = 0; frame < 8; frame++) pipeline.render(0.25)
        } finally {
          backend.present = originalPresent
          backend._setUniform = originalUniform
          backend.createSingleUniformBuffer = originalBuffer
        }
        if (calls !== 8 || !binding || !presented) {
          throw new Error(`${effect}/${name}: ${calls} bindings, presented ${presented}`)
        }
        if (name === 'webgpu') await backend.device.queue.onSubmittedWorkDone()
        const pixels = await backend.readPixels(presented)
        if (pixels.width !== 256 || pixels.height !== 256) throw new Error('source pixels changed size')
        return { effect, frame: 8, binding, pixels: Array.from(pixels.data) }
      }, { effect, waveformBytes: fixture.waveformBytes,
        spectrumBytes: fixture.spectrumBytes, name })
      results.push(result)
    }
    return results
  } finally {
    await session.teardown()
  }
}

const byBackend = { webgl2: await runBackend('webgl2'), webgpu: await runBackend('webgpu') }
const sourceManifestAfter = sourceManifest(root, lock)
assert.deepEqual(sourceManifestAfter, sourceManifestBefore,
  'source manifest changed during audio captures')
if (!diagnostic) {
  assert.equal(sourceManifestAfter.contentSha256, lock.sourceManifestSha256,
    'source manifest after audio captures differs from pinned authority')
  sourceIdentity(root, lock)
}
const reports = []
for (let index = 0; index < 2; index++) {
  const left = byBackend.webgl2[index], right = byBackend.webgpu[index]
  const effect = left.effect
  assert.equal(effect, right.effect)
  const oracle = fixture[effect === 'scope' ? 'waveformF32' : 'spectrumF32'].sha256
  assert.equal(digest(floatBytes(left.binding)), oracle, `WebGL2 effective ${effect} audio`)
  assert.equal(digest(floatBytes(right.binding)), oracle, `WebGPU effective ${effect} audio`)
  assert.ok(left.binding.some(value => value > 0), `${effect} source audio must be nonzero`)
  assert.ok(new Set(left.pixels).size > 2, `${effect} WebGL2 frame must be informative`)
  assert.ok(new Set(right.pixels).size > 2, `${effect} WebGPU frame must be informative`)
  let differingPixels = 0, flippedDifferingPixels = 0, maxChannelDelta = 0
  for (let pixel = 0; pixel < 256 * 256; pixel++) {
    let differs = false, flippedDiffers = false
    const x = pixel % 256, y = Math.floor(pixel / 256)
    const flippedPixel = (255 - y) * 256 + x
    for (let channel = 0; channel < 4; channel++) {
      const delta = Math.abs(left.pixels[pixel * 4 + channel] -
        right.pixels[pixel * 4 + channel])
      maxChannelDelta = Math.max(maxChannelDelta, delta)
      differs ||= delta !== 0
      flippedDiffers ||= left.pixels[flippedPixel * 4 + channel] !==
        right.pixels[pixel * 4 + channel]
    }
    if (differs) differingPixels++
    if (flippedDiffers) flippedDifferingPixels++
  }
  // WebGL2 readPixels reports a top-down view of its bottom-origin render
  // texture. CanvasSink presentation flips that texture; the flipped bytes
  // must match WebGPU's same-frame render before comparing with native output.
  assert.equal(flippedDifferingPixels, 0, `${effect} presented WebGL2/WebGPU pixels`)
  if (outDir) {
    writeFileSync(join(outDir, `${effect}.webgpu.rgba8`), Buffer.from(right.pixels))
    writeFileSync(join(outDir, `${effect}.webgl2.raw.rgba8`), Buffer.from(left.pixels))
  }
  let metalPixelsSha256 = null
  if (nativeLedger) {
    const id = `coverage/synth_${effect}`
    const candidate = nativeLedger.cases.find(item => item.id === id)
    assert.equal(candidate?.status, 'ok', `${id} native candidate`)
    assert.equal(candidate.audioBindingEffectiveSha256, oracle,
      `${id} native effective audio binding`)
    const images = candidate.images?.filter(item => item.frame === 8) || []
    assert.equal(images.length, 1, `${id} must have exactly one native frame 8`)
    const image = images[0]
    assert.ok(image?.path, `${id} native frame 8`)
    const imagePath = resolve(nativeDir, image.path)
    const imageRelative = relative(nativeDir, imagePath)
    assert.ok(imageRelative && !imageRelative.startsWith('..') && !isAbsolute(imageRelative),
      `${id} native image must be inside its candidate directory`)
    const pngBytes = readFileSync(imagePath)
    assert.equal(digest(pngBytes), image.sha256, `${id} native PNG provenance`)
    const decoded = PNG.sync.read(pngBytes)
    assert.deepEqual([decoded.width, decoded.height], [256, 256])
    // nm-render's PNG encoder flips its graph texture to match CanvasSink's
    // presented surface. Match the same vertically flipped WebGPU frame.
    assert.deepEqual(Array.from(decoded.data), Array.from(flipRows(right.pixels)),
      `${id} native Metal vs WebGPU presented pixels`)
    metalPixelsSha256 = digest(decoded.data)
  }
  reports.push({ ...provenance, effect,
    frame: left.frame, size: [256, 256],
    effectiveAudioSha256: oracle, webgl2PixelsSha256: digest(left.pixels),
    webgpuPixelsSha256: digest(right.pixels), differingPixels,
    flippedDifferingPixels, maxChannelDelta, metalPixelsSha256,
    ...(nativeFingerprint ? { nativeQualificationFingerprintSha256: digest(nativeFingerprintBytes),
      nativeBinarySha256: nativeFingerprint.binarySha256,
      nativeMetalDevice: nativeLedger.cases.find(item => item.id === `coverage/synth_${effect}`)
        .runtimeEnvironment.device } : {}) })
}
if (nativeLedger) {
  assert.equal(digest(readFileSync(nativeLedgerPath)), digest(nativeLedgerBytes),
    'native ledger changed during audio captures')
  assert.equal(digest(readFileSync(nativeFingerprintPath)), digest(nativeFingerprintBytes),
    'native qualification fingerprint changed during audio captures')
}
for (const report of reports) console.log(JSON.stringify(report))
