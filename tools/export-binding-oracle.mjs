#!/usr/bin/env node
// Source-executed WebGPU binding admission for the catalog's structured-uniform cases.
import { createHash } from 'node:crypto'
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { exportAuthority, fetchVerifiedArchive } from './export-reference.mjs'

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const OUT = join(ROOT, 'parity/binding-oracle.json')
const IDS = [
  'coverage/filter_crt', 'coverage/filter_fxaa', 'coverage/filter_grain',
  'coverage/filter_historicPalette', 'coverage/filter_osd', 'coverage/filter_palette',
  'coverage/filter_reindex', 'coverage/filter_smooth', 'coverage/filter_snow',
  'coverage/filter3d_palette3d', 'coverage/synth_cellularAutomata',
  'coverage/synth_mandelbrot', 'coverage/synth_newton'
]
const sha256 = value => createHash('sha256').update(value).digest('hex')
const json = path => JSON.parse(readFileSync(path, 'utf8'))

function programBindings(graph, backend, id) {
  const pass = graph.passes.find(item => item.id === id)
  if (!pass) throw new Error(`missing pass ${id}`)
  const spec = graph.programs[pass.program]
  if (!spec) throw new Error(`${id}: missing program ${pass.program}`)
  const source = backend.resolveWGSLSource(spec)
  if (!source) throw new Error(`${id}: missing WGSL`)
  const resolved = backend.injectDefines(source, spec.defines || {})
  const bindings = backend.parseShaderBindings(resolved)
  const isCompute = /@compute\s/.test(resolved) && !/@fragment\s/.test(resolved)
  const selectedEntryPoint = pass.entryPoint || (isCompute ?
    spec.computeEntryPoint || backend.detectEntryPoints(resolved).compute || 'main' :
    spec.fragmentEntryPoint || spec.entryPoint || backend.detectEntryPoints(resolved).fragment || 'main')
  const entryPointBindings = isCompute ? backend.parseEntryPointBindings(resolved, bindings) : new Map()
  // This mirrors createBindGroup: multi-entry compute passes first retain names
  // supplied by the pass, params, and storage buffers. The entry-point map is
  // exported separately because the upstream backend records it but does not
  // currently apply it during createBindGroup.
  const neededNames = new Set([...Object.keys(pass.inputs || {}), ...Object.keys(pass.outputs || {}), 'params',
    ...bindings.filter(binding => binding.type === 'storage').map(binding => binding.name)])
  const bindGroupBindings = pass.entryPoint && isCompute ? bindings.filter(binding => neededNames.has(binding.name)) : bindings
  const inputs = Object.keys(pass.inputs || {})
  return { passId: id, programId: pass.program, selectedEntryPoint, isCompute,
    resolvedWgslSha256: sha256(resolved), sourceHasBindings: backend.hasShaderBindings(resolved),
    inputs, outputs: Object.keys(pass.outputs || {}), bindings,
    bindGroupBindings, selectedEntryPointBindingIndices: [...(entryPointBindings.get(selectedEntryPoint) || [])],
    liveTextureInputs: bindGroupBindings.filter(binding => binding.type === 'texture' || binding.type === 'storage_texture')
      .map(binding => ({ name: binding.name, binding: binding.binding, type: binding.type,
        inPassInputs: Object.hasOwn(pass.inputs || {}, binding.name),
        inPassOutputs: Object.hasOwn(pass.outputs || {}, binding.name) })) }
}

async function build(ref, lock, corpus, tmp) {
  await exportAuthority(ref, tmp, lock)
  const { WebGPUBackend } = await import(pathToFileURL(join(ref, 'shaders/src/runtime/backends/webgpu.js')).href)
  const api = await import(pathToFileURL(join(ref, 'shaders/src/index.js')).href)
  const backend = WebGPUBackend.prototype
  const cases = IDS.map(id => {
    const item = corpus.cases.find(entry => entry.id === id)
    if (!item) throw new Error(`missing corpus case ${id}`)
    if (sha256(item.source) !== item.sourceSha256) throw new Error(`${id}: corpus source hash mismatch`)
    const graph = api.compileGraph(item.source)
    const passes = graph.passes.map(pass => programBindings(graph, backend, pass.id))
    return { id, sourceSha256: item.sourceSha256, graphPassCount: graph.passes.length, passes }
  })
  const syntaxSources = [
    ['spaced-decorators', '@group (0) @binding (1) var<uniform> value: f32; fn main() { let x = value; }'],
    ['compact-decorators', '@group(0)@binding(1)var<uniform> value:f32;fn main(){let x=value;}']
  ]
  const syntaxCases = syntaxSources.map(([id, wgsl]) => ({ id, wgsl, wgslSha256: sha256(wgsl),
    bindings: backend.parseShaderBindings(wgsl) }))
  return { schemaVersion: 1, authority: { commit: lock.commit, sourceManifestSha256: lock.sourceManifestSha256 },
    corpusSha256: sha256(readFileSync(join(ROOT, 'parity/corpus.json'))), cases, syntaxCases }
}

async function main() {
  const mode = process.argv[2] || '--check'
  if (!['--check', '--write'].includes(mode) || process.argv.length > 3) throw new Error('usage: node tools/export-binding-oracle.mjs [--check|--write]')
  const lock = json(join(ROOT, 'parity/reference.json'))
  const corpus = json(join(ROOT, 'parity/corpus.json'))
  const archive = process.env.NM_REFERENCE_ROOT ? null : fetchVerifiedArchive(lock)
  const tmp = mkdtempSync(join(tmpdir(), 'nm-binding-oracle-'))
  try {
    const ref = resolve(process.env.NM_REFERENCE_ROOT || archive.root)
    const result = await build(ref, lock, corpus, tmp)
    const bytes = Buffer.from(JSON.stringify(result, null, 2) + '\n')
    if (mode === '--write') writeFileSync(OUT, bytes)
    else if (!existsSync(OUT) || !readFileSync(OUT).equals(bytes)) throw new Error('binding oracle differs from locked source')
    process.stdout.write(JSON.stringify({ mode, cases: result.cases.length,
      passes: result.cases.reduce((n, item) => n + item.passes.length, 0), sha256: sha256(bytes) }) + '\n')
  } finally {
    archive?.cleanup()
    rmSync(tmp, { recursive: true, force: true })
  }
}

main().catch(error => { process.stderr.write(`${error?.stack || JSON.stringify(error)}\n`); process.exitCode = 1 })
