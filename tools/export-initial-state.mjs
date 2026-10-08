#!/usr/bin/env node
// Locked-source ProgramState post-UI oracle. --check is CPU-only; --write and
// --live-check execute the actual pinned browser runtime on a GPU host.
import { createHash } from 'node:crypto'
import { existsSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { fetchVerifiedArchive, sourceIdentity } from './export-reference.mjs'
import { sizePage } from '../parity/marker-golden.mjs'

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const OUTPUT = join(ROOT, 'parity/initial-program-state.json')
const sha256 = bytes => createHash('sha256').update(bytes).digest('hex')
const json = path => JSON.parse(readFileSync(path, 'utf8'))
const IDS = [
  'curated/blender_bb_only', 'curated/babylonjs_target_particles',
  'programs/funcStateValues', 'programs/coalesce',
  'coverage/synth3d_noise3d__volumeSize_x128',
  'programs/funcBoolean', 'programs/funcHiddenFloat',
  'programs/funcHiddenParam', 'programs/funcNumeric', 'programs/hero',
  'curated/blender_int_nobl', 'curated/blender_int_ns',
  'curated/unity_v104_mandala_negative_fractional_speed',
  'coverage/points_lenia', 'coverage/points_life',
  'coverage/points_life__boundaryMode_bounce',
  'coverage/points_life__symmetricForces_true',
  'coverage/points_life__useTypeColor_true'
]

function checkStatic(oracle, lock, corpus, stageOracle) {
  if (JSON.stringify(oracle.authority) !== JSON.stringify(lock)) throw new Error('initial-state authority differs from reference lock')
  if (oracle.corpusSha256 !== sha256(readFileSync(join(ROOT, 'parity/corpus.json')))) throw new Error('initial-state corpus hash differs')
  if (!Array.isArray(oracle.cases) || !oracle.cases.length) throw new Error('initial-state oracle is empty')
  const corpusById = new Map(corpus.cases.map(item => [item.id, item]))
  const stagesById = new Map(stageOracle.cases.map(item => [item.id, item]))
  const seen = new Set()
  for (const item of oracle.cases) {
    if (seen.has(item.id)) throw new Error(`duplicate initial-state case ${item.id}`)
    seen.add(item.id)
    const source = corpusById.get(item.id)
    const stages = stagesById.get(item.id)
    if (!source || !stages || item.sourceSha256 !== source.sourceSha256 ||
        item.graphStageSha256 !== stages.stages.graph?.sha256 ||
        item.backend !== 'WebGPU' || !Number.isInteger(item.maxTextureDimension2D) ||
        item.maxTextureDimension2D < 256 || !Number.isInteger(item.hostStepApplyCount) ||
        item.hostStepApplyCount < 1 || !Array.isArray(item.passes) ||
        !Array.isArray(item.stepStates) || !Array.isArray(item.textures)) {
      throw new Error(`initial-state case is stale or incomplete: ${item.id}`)
    }
  }
  if (oracle.cases.length !== IDS.length || IDS.some(id => !seen.has(id))) {
    throw new Error('initial-state case inventory differs from source-bound selection')
  }
}

async function captureCase(session, item, stage) {
  await session.setBackend('webgpu')
  const page = session.page
  await sizePage(page, ...item.capture.size)
  await page.evaluate(source => {
    const renderer = window.__noisemakerCanvasRenderer
    const applyStep = renderer.applyStepParameterValues
    renderer.__nmInitialStepApplyCount = 0
    renderer.applyStepParameterValues = function (...args) {
      this.__nmInitialStepApplyCount++
      return applyStep.apply(this, args)
    }
    const state = window.__noisemakerProgramState
    if (Array.isArray(state?._structure)) state._structure = []
    const editor = document.getElementById('dsl-editor')
    editor.value = source
    editor.dispatchEvent(new Event('input', { bubbles: true }))
    document.getElementById('dsl-run-btn').click()
  }, item.source)
  await page.waitForFunction(source => {
    const status = document.getElementById('status')?.textContent || ''
    if (/error|failed/i.test(status)) throw Error(status)
    const pipeline = window.__noisemakerRenderingPipeline
    return pipeline?.graph?.source === source.trim() && !pipeline.isCompiling &&
      pipeline.backend?.getName?.() === 'WebGPU' && /compiled/i.test(status)
  }, item.source, { timeout: 120000 })
  await page.waitForTimeout(150)
  const result = await page.evaluate(() => {
    const pipeline = window.__noisemakerRenderingPipeline
    const state = window.__noisemakerProgramState
    const backend = pipeline.backend
    function encode(value) {
      if (value === undefined) return { $type: 'undefined' }
      if (typeof value === 'function') return { $type: 'function', source: Function.prototype.toString.call(value) }
      if (typeof value === 'number') {
        if (Number.isNaN(value)) return { $type: 'number', value: 'NaN' }
        if (value === Infinity) return { $type: 'number', value: 'Infinity' }
        if (value === -Infinity) return { $type: 'number', value: '-Infinity' }
        if (Object.is(value, -0)) return { $type: 'number', value: '-0' }
      }
      if (value instanceof Map) return { $type: 'map', entries: [...value].map(([k, v]) => [encode(k), encode(v)]) }
      if (Array.isArray(value)) return value.map(encode)
      if (value && typeof value === 'object') return { $type: 'object', entries: Object.entries(value).map(([k, v]) => [k, encode(v)]) }
      return value
    }
    return {
      graphId: pipeline.graph.id, backend: backend.getName(),
      hostStepApplyCount: window.__noisemakerCanvasRenderer.__nmInitialStepApplyCount,
      maxTextureDimension2D: backend.device.limits.maxTextureDimension2D,
      passes: pipeline.graph.passes.map(pass => ({
        id: pass.id, program: pass.program, effectKey: pass.effectKey,
        uniforms: encode(pass.uniforms), uniformAliases: encode(pass.uniformAliases)
      })),
      stepStates: [...state._stepStates].map(([id, value]) => ({
        id, effect: `${value.effectDef?.namespace}.${value.effectDef?.func}`,
        values: encode(value.values)
      })),
      textures: [...backend.textures].map(([id, value]) => ({
        id, width: value.width, height: value.height, depth: value.depth || 1,
        format: value.format
      }))
    }
  })
  return { id: item.id, sourceSha256: item.sourceSha256,
    graphStageSha256: stage.stages.graph.sha256, ...result }
}

async function capture(lock, corpus, stageOracle) {
  const archive = process.env.NM_REFERENCE_ROOT ? null : fetchVerifiedArchive(lock)
  const ref = resolve(process.env.NM_REFERENCE_ROOT || archive.root)
  try {
    sourceIdentity(ref, lock)
    process.env.SHADE_VIEWER_ROOT = ref
    process.env.SHADE_VIEWER_PATH = '/demo/shaders/'
    process.env.SHADE_EFFECTS_DIR = join(ref, 'shaders/effects')
    process.env.SHADE_GLOBALS_PREFIX = '__noisemaker'
    process.env.SHADE_HEADLESS = '1'
    const { BrowserSession } = await import(pathToFileURL(join(ref, 'vendor/shade-mcp/harness/index.js')).href)
    const corpusById = new Map(corpus.cases.map(item => [item.id, item]))
    const stagesById = new Map(stageOracle.cases.map(item => [item.id, item]))
    const cases = []
    for (const id of IDS) {
      const item = corpusById.get(id)
      const stage = stagesById.get(id)
      if (!item || stage?.stages.graph?.status !== 'ok' ||
          item.sourceSha256 !== stage.sourceSha256) throw new Error(`missing pinned graph stage for ${id}`)
      const session = new BrowserSession({ backend: 'webgpu' })
      await session.setup()
      try {
        cases.push(await captureCase(session, item, stage))
        process.stderr.write(`[initial-state ${cases.length}/${IDS.length}] ${id}\n`)
      } finally {
        await session.teardown()
      }
    }
    return { authority: lock,
      corpusSha256: sha256(readFileSync(join(ROOT, 'parity/corpus.json'))), cases }
  } finally {
    archive?.cleanup()
  }
}

async function main() {
  const mode = process.argv[2] || '--check'
  if (!['--check', '--write', '--live-check'].includes(mode) || process.argv.length > 3) {
    throw new Error('usage: node tools/export-initial-state.mjs [--check|--write|--live-check]')
  }
  const lock = json(join(ROOT, 'parity/reference.json'))
  const corpus = json(join(ROOT, 'parity/corpus.json'))
  const stages = json(join(ROOT, 'parity/corpus-stages.json'))
  if (mode === '--check') {
    if (!existsSync(OUTPUT)) throw new Error('initial-state oracle is missing')
    checkStatic(json(OUTPUT), lock, corpus, stages)
    process.stdout.write(`initial-state source inventory ${IDS.length} cases current\n`)
    return
  }
  const actual = await capture(lock, corpus, stages)
  checkStatic(actual, lock, corpus, stages)
  const bytes = Buffer.from(JSON.stringify(actual, null, 2) + '\n')
  if (mode === '--write') writeFileSync(OUTPUT, bytes)
  else if (!existsSync(OUTPUT) || !readFileSync(OUTPUT).equals(bytes)) {
    throw new Error('live initial-state oracle differs from locked source runtime')
  }
  process.stdout.write(`${mode} initial-state ${IDS.length} cases sha256=${sha256(bytes)}\n`)
}

main().catch(error => { process.stderr.write(`${error?.stack || String(error)}\n`); process.exitCode = 1 })
