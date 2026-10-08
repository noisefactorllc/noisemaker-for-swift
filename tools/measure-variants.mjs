#!/usr/bin/env node
// Measure the source-bound corpus program universe before selecting packaging.
import { createHash } from 'node:crypto'
import { readFileSync, writeFileSync, mkdirSync, mkdtempSync, readdirSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { isDeepStrictEqual } from 'node:util'
import { exportAuthority, fetchVerifiedArchive } from './export-reference.mjs'

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const sha = data => createHash('sha256').update(data).digest('hex')
const json = file => JSON.parse(readFileSync(file, 'utf8'))
const lock = json(join(root, 'parity/reference.json'))
const corpusBytes = readFileSync(join(root, 'parity/corpus.json'))
const corpus = JSON.parse(corpusBytes)
const out = resolve(process.argv[2] || join(root, '.build/variant-measurement'))
const archive = process.env.NM_REFERENCE_ROOT ? null : fetchVerifiedArchive(lock)
const source = resolve(process.env.NM_REFERENCE_ROOT || archive.root)
const temporary = mkdtempSync(join(tmpdir(), 'nm-variant-measure-'))
try {
  await exportAuthority(source, temporary, lock, !!archive)
  const api = await import(pathToFileURL(join(source, 'shaders/src/index.js')).href)
  const renderer = new api.CanvasRenderer()
  const sourcePortables = new Map()
  for (const file of readdirSync(join(temporary, 'cases'))) {
    const exported = json(join(temporary, 'cases', file))
    const definition = exported.portableDefinition
    if (definition) sourcePortables.set(`${definition.namespace}.${definition.func}`, definition)
  }
  const portableEffects = new Set()
  for (const item of corpus.cases) {
    const definitions = item.assets.filter(asset => asset.path.endsWith('.portable.json'))
    if (!definitions.length) continue
    if (definitions.length !== 1) throw new Error(`${item.id}: multiple Portable definitions`)
    const definition = JSON.parse(definitions[0].text)
    if (typeof definition.namespace !== 'string' || typeof definition.func !== 'string') {
      throw new Error(`${item.id}: Portable effect identity is missing`)
    }
    definition.shaders ||= {}
    for (const asset of item.assets.filter(asset => asset.path.endsWith('.wgsl'))) {
      const program = asset.path.split('/').at(-1).split('.').at(-2)
      definition.shaders[program] ||= {}
      definition.shaders[program].wgsl = asset.text
    }
    const key = `${definition.namespace}.${definition.func}`
    if (sourcePortables.has(key)) {
      if (!isDeepStrictEqual(definition, sourcePortables.get(key))) {
        throw new Error(`${item.id}: Portable assets differ from the pinned source export`)
      }
    } else {
      await renderer.registerPortableEffect(definition)
    }
    portableEffects.add(key)
  }
  const variants = new Map(), passStates = new Set(), references = { catalog: 0, portable: 0 }
  let passCount = 0
  for (const item of corpus.cases) {
    const graph = api.compileGraph(item.source)
    for (const pass of graph.passes) {
      const program = graph.programs[pass.program]
      if (!program?.wgsl) throw new Error(`${item.id}: missing WGSL ${pass.program}`)
      let prefix = ''
      for (const [key, value] of Object.entries(program.defines || {})) {
        if (typeof value === 'boolean') prefix += `const ${key}: bool = ${value};\n`
        else if (typeof value === 'number') prefix += `const ${key}: ${Number.isInteger(value) ? 'i32' : 'f32'} = ${value};\n`
        else prefix += `const ${key} = ${value};\n`
      }
      const wgsl = prefix + program.wgsl
      const identity = sha(wgsl)
      if (!variants.has(identity)) variants.set(identity, { sha256: identity, wgsl, bytes: Buffer.byteLength(wgsl),
        families: new Set(), effects: new Set(), cases: new Set() })
      const variant = variants.get(identity)
      const origin = portableEffects.has(pass.effectKey) ? 'portable' : 'catalog'
      variant.families.add(origin)
      if (pass.effectKey) variant.effects.add(pass.effectKey)
      variant.cases.add(item.id)
      references[origin]++
      passStates.add(sha(JSON.stringify({ program: identity, drawMode: pass.drawMode, blend: pass.blend,
        outputs: Object.values(pass.outputs || {}).map(name => graph.textures.get(name)?.format || 'global'),
        entryPoint: pass.entryPoint })))
      passCount++
    }
  }
  const inventory = json(join(temporary, 'inventory.json'))
  mkdirSync(out, { recursive: true })
  const programs = [...variants.values()].sort((a,b) => a.sha256.localeCompare(b.sha256)).map(variant => ({
    ...variant, families: [...variant.families].sort(), effects: [...variant.effects].sort(), cases: [...variant.cases].sort()
  }))
  const report = { schemaVersion: 1, authority: lock, corpusSha256: sha(corpusBytes), cases: corpus.cases.length,
    effects: inventory.effects, sourceWGSLFiles: inventory.wgslFiles, passReferences: passCount,
    references, uniqueAssembledWGSL: programs.length, uniquePassStates: passStates.size,
    assembledWGSLBytes: programs.reduce((sum,item) => sum + item.bytes, 0),
    catalogVariants: programs.filter(item => item.families.includes('catalog')).length,
    portableOnlyVariants: programs.filter(item => !item.families.includes('catalog')).length,
    declaredDefineSpaces: inventory.entries.map(item => ({ effect: `${item.namespace}.${item.func}`, variants: item.defineVariants })) }
  writeFileSync(join(out, 'programs.json'), JSON.stringify(programs) + '\n')
  writeFileSync(join(out, 'measurement.json'), JSON.stringify(report, null, 2) + '\n')
  console.log(JSON.stringify({ ...report, declaredDefineSpaces: undefined }))
} finally { archive?.cleanup(); rmSync(temporary, { recursive: true, force: true }) }
