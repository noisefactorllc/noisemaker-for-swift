#!/usr/bin/env node
// Source-executed, per-step graph mutation oracle from the locked JS runtime.
import { createHash } from 'node:crypto'
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { encode, exportAuthority, fetchVerifiedArchive } from './export-reference.mjs'

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const OUTPUT = join(ROOT, 'parity/parameter-updates.json')
const sha256 = bytes => createHash('sha256').update(bytes).digest('hex')
const CORPUS = JSON.parse(readFileSync(join(ROOT, 'parity/corpus.json')))
const byId = new Map(CORPUS.cases.map(item => [item.id, item]))

const FIXTURES = [
  { id: 'same-effect-step', source: 'search synth, filter\nsolid().blur().blur().write(o0)\nrender(o0)\n',
    path: 'CanvasRenderer.applyStepParameterValues', updates: { step_2: { radiusX: 17 } } },
  { id: 'uniform-alias', origin: 'coverage/classicNoisedeck_coalesce',
    path: 'CanvasRenderer.applyStepParameterValues', updates: { step_3: { mix: 37 } } },
  { id: 'inherited-volume', origin: 'coverage/filter3d_flow3d',
    path: 'CanvasRenderer.applyStepParameterValues',
    updates: { step_0: { volumeSize: 32 }, step_1: { volumeSize: 128 } } },
  { id: 'scoped-zoom', origin: 'coverage/synth_cellularAutomata',
    path: 'CanvasRenderer.applyStepParameterValues', updates: { step_0: { zoom: 8 } } },
  { id: 'node-state-size', origin: 'coverage/render_pointsEmit',
    path: 'ProgramState.setValue/_applyToPipeline', updates: { step_1: { stateSize: 128 } } },
  { id: 'host-media-dimensions', origin: 'coverage/synth_media',
    path: 'ProgramState.setValue/_applyToPipeline', updates: { step_0: { imageSize: [768, 576] } } },
  { id: 'palette-post-write', origin: 'coverage/classicNoisedeck_cellNoise',
    path: 'CanvasRenderer.applyStepParameterValues',
    updates: { step_0: { palette: 12, paletteOffset: [0.1, 0.2, 0.3] } } },
  ...[
    ['zero', 0], ['negative', -1], ['above-count', 56],
    ['positive-infinity', Infinity], ['negative-infinity', -Infinity],
    ['fractional-above-count', 55.5], ['numeric-string', '2'],
    ['bom-numeric-string', '\uFEFF2'], ['nbsp-numeric-string', '\u00A02'],
    ['true', true], ['false', false], ['null', null]
  ].map(([suffix, palette]) => ({ id: `palette-${suffix}`,
    origin: 'coverage/classicNoisedeck_cellNoise',
    path: 'CanvasRenderer.applyStepParameterValues', updates: { step_0: { palette } } })),
  ...[
    ['fractional-positive', 1.5], ['fractional-below-one', 0.5],
    ['nan', NaN], ['malformed-string', '2px'], ['nel-numeric-string', '\u00852']
  ].map(([suffix, palette]) => ({ id: `palette-refusal-${suffix}`,
    origin: 'coverage/classicNoisedeck_cellNoise', expectError: 'TypeError',
    path: 'CanvasRenderer.applyStepParameterValues', updates: { step_0: { palette } } })),
  { id: 'int-string-prefix', origin: 'coverage/synth_noise',
    path: 'CanvasRenderer.applyStepParameterValues', updates: { step_0: { octaves: '12.5' } } },
  { id: 'int-negative-half', origin: 'coverage/synth_noise',
    path: 'CanvasRenderer.applyStepParameterValues', updates: { step_0: { octaves: -0.5 } } },
  { id: 'float-string-prefix', origin: 'coverage/synth_noise',
    path: 'CanvasRenderer.applyStepParameterValues', updates: { step_0: { scaleX: '12.5px' } } }
]

function memoryBackend() {
  return {
    textures: new Map(), capabilities: { maxTextureSize: 16384, maxColorBytesPerSample: 32 },
    createTexture(id, spec) { this.textures.set(id, { ...spec }) },
    createTexture3D(id, spec) { this.textures.set(id, { ...spec }) },
    destroyTexture(id) { this.textures.delete(id) },
    copyTexture() {} // Pixel preservation does not affect sizing or uniforms.
  }
}

function snapshot(graph, pipeline, backend) {
  const textures = []
  for (const [id, spec] of graph.textures) {
    const surfaceName = pipeline.parseGlobalName(id)
    const actualIds = surfaceName && pipeline.surfaces.has(surfaceName)
      ? [pipeline.surfaces.get(surfaceName).read, pipeline.surfaces.get(surfaceName).write] : [id]
    for (const actualId of actualIds) {
      const texture = backend.textures.get(actualId)
      textures.push([actualId, texture ? { width: texture.width, height: texture.height,
        ...(texture.depth !== undefined ? { depth: texture.depth } : {}), format: texture.format } : null])
    }
  }
  return {
    passes: graph.passes.map(pass => ({ id: pass.id, stepIndex: pass.stepIndex ?? null,
      effectKey: pass.effectKey ?? null, uniforms: encode(pass.uniforms),
      scopedParams: encode(pass.scopedParams), uniformAliases: encode(pass.uniformAliases),
      inheritsVolumeSize: pass.inheritsVolumeSize === true })),
    textures: encode(new Map(textures)), globalUniforms: encode(pipeline.globalUniforms)
  }
}

function runFixture(fixture, api) {
  const source = fixture.source ?? byId.get(fixture.origin)?.source
  if (!source) throw new Error(`missing source corpus case ${fixture.origin}`)
  const graph = api.compileGraph(source)
  const backend = memoryBackend()
  const pipeline = new api.Pipeline(graph, backend)
  pipeline.width = 256
  pipeline.height = 256
  pipeline.createSurfaces()
  pipeline.recreateTextures(pipeline.collectDefaultUniforms())
  const renderer = new api.CanvasRenderer({ width: 256, height: 256 })
  renderer._pipeline = pipeline
  let state = null
  if (fixture.path.startsWith('ProgramState.')) {
    state = new api.ProgramState({ renderer })
    state.fromDsl(source)
  }
  const before = snapshot(graph, pipeline, backend)
  let failure = null
  try {
    if (state) {
      for (const [step, values] of Object.entries(fixture.updates)) {
        for (const [name, value] of Object.entries(values)) state.setValue(step, name, value)
      }
    } else {
      renderer.applyStepParameterValues(fixture.updates)
    }
  } catch (error) {
    if (!fixture.expectError || error?.name !== fixture.expectError) throw error
    failure = { name: error.name, message: error.message }
  }
  if (fixture.expectError && !failure) throw new Error(`${fixture.id} did not reject the source update`)
  const after = snapshot(graph, pipeline, backend)
  if (JSON.stringify(before) === JSON.stringify(after)) throw new Error(`${fixture.id} did not mutate graph state`)
  return { id: fixture.id, path: fixture.path, source, sourceSha256: sha256(source),
    ...(fixture.origin ? { originCaseId: fixture.origin } : {}),
    size: [256, 256], updates: encode(fixture.updates), before, after,
    ...(failure ? { error: failure } : {}) }
}

async function main() {
  const mode = process.argv[2] || '--check'
  if (!['--check', '--write'].includes(mode) || process.argv.length > 3) {
    throw new Error('usage: node tools/export-param-updates.mjs [--check|--write]')
  }
  const lock = JSON.parse(readFileSync(join(ROOT, 'parity/reference.json')))
  const fetched = process.env.NM_REFERENCE_ROOT ? null : fetchVerifiedArchive(lock)
  const ref = resolve(process.env.NM_REFERENCE_ROOT || fetched.root)
  const output = mkdtempSync(join(tmpdir(), 'nm-param-authority-'))
  try {
    await exportAuthority(ref, output, lock, !!fetched || !existsSync(join(ref, '.git')))
    const api = await import(pathToFileURL(join(ref, 'shaders/src/index.js')).href)
    const records = FIXTURES.map(fixture => runFixture(fixture, api))
    const cases = records.filter(record => !record.error)
    const refusals = records.filter(record => record.error)
    const oracle = { schemaVersion: 1, authority: { repository: lock.repository, commit: lock.commit,
      sourceManifestSha256: lock.sourceManifestSha256 }, cases, refusals }
    const bytes = Buffer.from(JSON.stringify(oracle, null, 2) + '\n')
    if (mode === '--write') writeFileSync(OUTPUT, bytes)
    else if (!existsSync(OUTPUT) || !readFileSync(OUTPUT).equals(bytes)) {
      throw new Error('parameter update oracle differs from pinned source')
    }
    process.stdout.write(JSON.stringify({ mode, cases: cases.length, refusals: refusals.length,
      sha256: sha256(bytes) }) + '\n')
  } finally {
    fetched?.cleanup()
    rmSync(output, { recursive: true, force: true })
  }
}

main().catch(error => { process.stderr.write(`${error?.stack || error}\n`); process.exitCode = 1 })
