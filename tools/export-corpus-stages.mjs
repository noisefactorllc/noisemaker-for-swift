#!/usr/bin/env node
// Independent stage digests for every imported DSL, executed by locked JS.
import { createHash } from 'node:crypto'
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { encode, exportAuthority, fetchVerifiedArchive, fullTokenView } from './export-reference.mjs'

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const OUT = join(ROOT, 'parity/corpus-stages.json')
const sha256 = bytes => createHash('sha256').update(bytes).digest('hex')
const digest = value => sha256(JSON.stringify(value))
const json = path => JSON.parse(readFileSync(path, 'utf8'))

function stageError(error) {
  return { name: error?.name || 'Error', message: error?.message || String(error),
    ...(error?.diagnostic !== undefined ? { diagnostic: encode(error.diagnostic) } : {}),
    ...(error?.errors !== undefined ? { errors: encode(error.errors) } : {}) }
}

async function portableRegistry(ref, corpus) {
  const { CanvasRenderer } = await import(pathToFileURL(join(ref, 'shaders/src/index.js')).href)
  const renderer = new CanvasRenderer()
  // exportAuthority already registers the Swift micro Portable cases. The
  // sibling Portable family alone needs registration here.
  for (const item of corpus.cases.filter(item => item.family === 'portable')) {
    const sidecar = item.assets.find(asset => asset.path.endsWith('.portable.json'))
    if (!sidecar) throw new Error(`${item.id}: missing portable definition`)
    const definition = JSON.parse(sidecar.text)
    definition.shaders ||= {}
    for (const wgsl of item.assets.filter(asset => asset.path.endsWith('.wgsl'))) {
      const program = wgsl.path.split('/').at(-1).split('.').at(-2)
      definition.shaders[program] ||= {}
      definition.shaders[program].wgsl = wgsl.text
    }
    for (const pass of definition.passes || []) {
      if (pass.program && !definition.shaders[pass.program]?.wgsl) throw new Error(`${item.id}: ${pass.program} lacks WGSL`)
    }
    await renderer.registerPortableEffect(definition)
  }
}

function stagesFor(source, api, includePayload = false) {
  const stages = {}
  let value
  const take = (name, execute, transform = encode) => {
    try {
      value = execute()
      const payload = transform(value)
      stages[name] = { status: 'ok', sha256: digest(payload), ...(includePayload ? { payload } : {}) }
      return value
    } catch (error) {
      stages[name] = { status: 'error', error: stageError(error) }
      return null
    }
  }
  const tokens = take('lex', () => api.lex(source), fullTokenView)
  if (!tokens) return { stages }
  const ast = take('parse', () => api.parse(tokens))
  if (!ast) return { stages }
  const validated = take('validate', () => api.validate(ast))
  if (!validated) return { stages }
  const expanded = take('expand', () => api.expand(validated))
  if (!expanded) return { stages }
  const allocated = take('allocate', () => api.allocateResources(expanded.passes))
  if (!allocated) return { stages }
  const graph = take('graph', () => {
    const graph = api.compileGraph(source)
    return { ...graph, compiledAt: { $type: 'volatile-timestamp' } }
  })
  if (!graph) return { stages }
  return { stages, graphId: graph.id, passCount: graph.passes.length,
    effects: [...new Set(graph.passes.map(pass => pass.effectKey).filter(Boolean))].sort(),
    referencedPrograms: [...new Set(graph.passes.map(pass => pass.program).filter(Boolean))].length }
}

async function run(ref, out, lock, corpus, verifiedArchive, dumpIds = new Set()) {
  await exportAuthority(ref, out, lock, verifiedArchive)
  await portableRegistry(ref, corpus)
  const api = await import(pathToFileURL(join(ref, 'shaders/src/index.js')).href)
  const selected = dumpIds.size ? corpus.cases.filter(item => dumpIds.has(item.id)) : corpus.cases
  const cases = selected.map((item, index) => {
    const record = stagesFor(item.source, api, dumpIds.has(item.id))
    if ((index + 1) % 250 === 0) process.stderr.write(`stage oracle ${index + 1}/${selected.length}\n`)
    return { id: item.id, sourceSha256: item.sourceSha256, ...record }
  })
  const stageCounts = Object.fromEntries(['lex', 'parse', 'validate', 'expand', 'allocate', 'graph']
    .map(stage => [stage, { ok: cases.filter(item => item.stages[stage]?.status === 'ok').length,
      error: cases.filter(item => item.stages[stage]?.status === 'error').length }]))
  return { schemaVersion: 1, authority: { commit: lock.commit, sourceManifestSha256: lock.sourceManifestSha256 },
    corpusSha256: sha256(readFileSync(join(ROOT, 'parity/corpus.json'))),
    expected: selected.length, stageCounts, cases }
}

async function main() {
  const mode = process.argv[2] || '--check'
  if (!['--check', '--write', '--dump'].includes(mode) ||
      (mode === '--dump' ? process.argv.length < 4 : process.argv.length > 3)) {
    throw new Error('usage: node tools/export-corpus-stages.mjs [--check|--write|--dump case-id ...]')
  }
  const lock = json(join(ROOT, 'parity/reference.json'))
  const corpus = json(join(ROOT, 'parity/corpus.json'))
  const dumpIds = new Set(mode === '--dump' ? process.argv.slice(3) : [])
  if (dumpIds.size !== (mode === '--dump' ? process.argv.length - 3 : 0) ||
      [...dumpIds].some(id => !corpus.cases.some(item => item.id === id))) {
    throw new Error('duplicate or unknown corpus stage dump ID')
  }
  const tmp = mkdtempSync(join(tmpdir(), 'nm-corpus-stages-'))
  const archive = process.env.NM_REFERENCE_ROOT ? null : fetchVerifiedArchive(lock)
  try {
    const oracle = await run(resolve(process.env.NM_REFERENCE_ROOT || archive.root), tmp, lock, corpus, !!archive, dumpIds)
    if (mode === '--dump') {
      for (const item of oracle.cases.filter(item => dumpIds.has(item.id))) {
        const path = join(ROOT, '.build/reference/corpus-cases', `${item.id}.json`)
        mkdirSync(dirname(path), { recursive: true })
        writeFileSync(path, JSON.stringify(item, null, 2) + '\n')
        process.stdout.write(`${path}\n`)
      }
      return
    }
    const bytes = Buffer.from(JSON.stringify(oracle, null, 2) + '\n')
    if (mode === '--write') writeFileSync(OUT, bytes)
    else if (!existsSync(OUT) || !readFileSync(OUT).equals(bytes)) throw new Error('corpus stage oracle differs from locked upstream; regenerate only after investigating source/corpus drift')
    process.stdout.write(JSON.stringify({ mode, expected: oracle.expected, stageCounts: oracle.stageCounts,
      sha256: sha256(bytes) }) + '\n')
  } finally {
    archive?.cleanup()
    rmSync(tmp, { recursive: true, force: true })
  }
}

main().catch(error => { process.stderr.write(`${error?.stack || String(error)}\n`); process.exitCode = 1 })
