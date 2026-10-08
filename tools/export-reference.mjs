#!/usr/bin/env node
// Development-only export of the locked Noisemaker compiler authority.
import { createHash } from 'node:crypto'
import { execFileSync } from 'node:child_process'
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { resolve, join, relative, dirname } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const REPOSITORY = 'https://github.com/noisefactorllc/noisemaker'
export const CASES = {
  solid: 'search synth\nsolid(color: [0.2, 0.6, 0.9]).write(o0)\nrender(o0)\n',
  resourceHeavy: 'search synth, render\nsolid().pointsEmit(stateSize: 128, seed: 1).pointsBillboardRender().write(o0)\nrender(o0)\n',
  compute: 'search synth, filter\nnoise(seed: 1).grain().write(o0)\nrender(o0)\n',
  numericDefineOutsideChoices: 'search synth\nnoise(type: 12, seed: 1).write(o0)\nrender(o0)\n',
  builtinEnum: 'search synth\nnoise(scaleX: osc(type: oscKind.sine, min: 1, max: 8), seed: 1).write(o0)\nrender(o0)\n',
  multipassBlur: 'search synth, filter\nnoise(seed: 1).blur(radiusX: 4, radiusY: 3).write(o0)\nrender(o0)\n',
  computeFilter: 'search synth, filter\nnoise(seed: 1).ridge(level: 0.4).write(o0)\nrender(o0)\n',
  mrtNoise3d: 'search synth3d, render\nnoise3d(volumeSize: x16, octaves: 1, speed: 0, seed: 1).render3d().write(o0)\nrender(o0)\n',
  repeatFeedback: 'search synth\nreactionDiffusion(zoom: x16, iterations: 2, seed: 1).write(o0)\nrender(o0)\n',
  marker: readFileSync(join(ROOT, 'parity/marker.dsl'), 'utf8'),
  mrtProbe: readFileSync(join(ROOT, 'parity/mrt.dsl'), 'utf8'),
  samplerProbe: readFileSync(join(ROOT, 'parity/sampler.dsl'), 'utf8'),
  sampled3dProbe: readFileSync(join(ROOT, 'parity/sampled3d.dsl'), 'utf8'),
  sampled3dLinearProbe: readFileSync(join(ROOT, 'parity/sampled3d-linear.dsl'), 'utf8'),
  storage3dProbe: readFileSync(join(ROOT, 'parity/storage3d.dsl'), 'utf8')
}
const PORTABLE_CASES = {
  marker: { definition: 'marker.portable.json', shaders: { marker: 'marker.marker.wgsl' } },
  mrtProbe: { definition: 'mrt.portable.json', shaders: { split: 'mrt.split.wgsl', combine: 'mrt.combine.wgsl' } },
  samplerProbe: { definition: 'sampler.portable.json', shaders: { pattern: 'sampler.pattern.wgsl', sample: 'sampler.sample.wgsl' } },
  sampled3dProbe: { definition: 'sampled3d.portable.json', shaders: { show: 'sampled3d.show.wgsl' } },
  sampled3dLinearProbe: { definition: 'sampled3d-linear.portable.json', shaders: { show: 'sampled3d-linear.show.wgsl' } },
  storage3dProbe: { definition: 'storage3d.portable.json', shaders: { fill: 'storage3d.fill.wgsl', show: 'storage3d.show.wgsl' } }
}

const sha256 = bytes => createHash('sha256').update(bytes).digest('hex')
const own = (v, key) => Object.prototype.hasOwnProperty.call(v, key)

// All objects use ordered entry pairs; special values have explicit tags. No
// JSON.stringify omission or accidental Map-to-empty-object conversion.
export function encode(value, active = new Set()) {
  if (value === undefined) return { $type: 'undefined' }
  if (typeof value === 'function') return { $type: 'function', source: Function.prototype.toString.call(value) }
  if (typeof value === 'bigint') return { $type: 'bigint', value: value.toString() }
  if (typeof value === 'number' && Object.is(value, -0)) return { $type: 'number', value: '-0' }
  if (typeof value === 'number' && !Number.isFinite(value)) return { $type: 'number', value: String(value) }
  if (value === null || typeof value !== 'object') return value
  if (active.has(value)) throw new Error('cyclic authority value cannot be exported')
  active.add(value)
  let out
  if (Array.isArray(value)) out = value.map(item => encode(item, active))
  else if (value instanceof Map) out = { $type: 'map', entries: [...value].map(([k, v]) => [encode(k, active), encode(v, active)]) }
  else if (value instanceof Set) out = { $type: 'set', values: [...value].map(item => encode(item, active)) }
  else if (ArrayBuffer.isView(value)) out = { $type: value.constructor.name, values: [...value].map(item => encode(item, active)) }
  else if (value instanceof ArrayBuffer) out = { $type: 'ArrayBuffer', bytes: [...new Uint8Array(value)] }
  else if (value instanceof Date) out = { $type: 'Date', value: value.toISOString() }
  else out = { $type: 'object', entries: Object.keys(value).map(key => [key, encode(value[key], active)]) }
  active.delete(value)
  return out
}

// Token.position is intentionally nonenumerable upstream. Expose it only in
// the lexical oracle without changing the generic graph value encoder.
export function fullTokenView(tokens) {
  return tokens.map(token => encode({ ...token, position: token.position }))
}

export function countDefineVariants(def) {
  const dimensions = []
  const openNumericDefines = []
  for (const [parameter, spec] of Object.entries(def.globals || {})) {
    if (!spec?.define) continue
    let values
    if (spec.choices) values = [...new Set(Object.entries(spec.choices).filter(([name]) => !name.endsWith(':')).map(([, value]) => JSON.stringify(value)))].map(JSON.parse)
    else if (spec.type === 'boolean') values = [false, true]
    else if (spec.type === 'int' && Number.isInteger(spec.min) && Number.isInteger(spec.max) &&
      spec.max >= spec.min && Number.isInteger(spec.step ?? 1) && (spec.step ?? 1) > 0) {
      values = []
      for (let value = spec.min; value <= spec.max; value += spec.step ?? 1) values.push(value)
    }
    else values = [spec.default]
    // Choices and min/max describe UI/sample values. The DSL can still accept
    // numeric literals beyond them (for example noise(type: 12)).
    const numeric = spec.type === 'int' || spec.type === 'float' || typeof spec.default === 'number' ||
      Object.values(spec.choices || {}).some(value => typeof value === 'number')
    if (numeric) openNumericDefines.push(spec.define)
    dimensions.push({ parameter, define: spec.define, values, allowsOtherLiterals: numeric })
  }
  let declaredSampleCombinations = 1
  for (const d of dimensions) declaredSampleCombinations *= d.values.length
  if (!Number.isSafeInteger(declaredSampleCombinations)) throw new Error('define sample count exceeds safe integer range')
  const passDefines = [...new Set((def.passes || []).filter(p => p.defines).map(p => JSON.stringify(p.defines)))]
  return { dimensions, declaredSampleCombinations, passVariants: passDefines.length,
    passDefines: passDefines.map(JSON.parse), openNumericDefines }
}

export function captureProtocols() {
  const cases = Object.fromEntries(Object.entries(CASES).map(([name, source]) => [name, {
    dslSha256: sha256(source), seed: ['resourceHeavy', 'compute', 'numericDefineOutsideChoices', 'builtinEnum', 'multipassBlur', 'computeFilter', 'mrtNoise3d', 'repeatFeedback'].includes(name) ? 1 : null,
    externalInputs: ['sampled3dProbe', 'sampled3dLinearProbe'].includes(name) ? [{ id: 'node_0_volume', kind: 'texture3d', frame: 0 }] : [],
    inputAssets: ['sampled3dProbe', 'sampled3dLinearProbe'].includes(name) ? [{ path: 'parity/inputs/sampled3d-v1.rgba8',
      sha256: sha256(readFileSync(join(ROOT, 'parity/inputs/sampled3d-v1.rgba8'))) }] : [],
    size: PORTABLE_CASES[name] || ['multipassBlur', 'computeFilter', 'repeatFeedback', 'mrtNoise3d'].includes(name) ? [257, 129] : [256, 256],
    normalizedTime: 0.25, deltaTime: 0, frames: 8, resetState: 'clear pipeline writes; preserve host inputs; reset surfaces, frameIndex, lastTime and globals',
    sample: 'presented surface after frame 8', orientation: 'top-down RGBA8 PNG'
  }]))
  return {
    goldenBackend: 'webgpu',
    presentedSurface: true,
    assertion: 'pipeline.backend.getName() === WebGPU inside page before every capture',
    cases,
    static: { size: [256, 256], normalizedTime: 0.25, frames: 8, resetState: true, orientation: 'top-down RGBA8 PNG' },
    marker: { size: [257, 129], asymmetricCorners: true, frames: 8, resetState: true, orientation: 'top-down RGBA8 PNG' },
    timed: { runSeconds: 5, sampleEverySeconds: 1, sampleFrames: [1, 2, 4, 10, 30], frameTime: '((frame + 1) / 600) % 1', firstDeltaTime: 0, laterDeltaTime: '1/600 except at wrap', resetState: true }
  }
}

function filesUnder(dir, suffix) {
  if (!existsSync(dir)) return []
  return readdirSync(dir, { withFileTypes: true }).flatMap(entry => {
    const path = join(dir, entry.name)
    return entry.isDirectory() ? filesUnder(path, suffix) : entry.isFile() && entry.name.endsWith(suffix) ? [path] : []
  }).sort()
}

function authorityInputs(ref) {
  return [join(ref, 'package.json'), join(ref, 'share/palettes.json'),
    ...filesUnder(join(ref, 'share/meshes'), ''),
    ...filesUnder(join(ref, 'demo/shaders'), ''),
    ...filesUnder(join(ref, 'vendor/shade-mcp/harness'), '.js'),
    ...filesUnder(join(ref, 'shaders/src'), '.js'),
    ...filesUnder(join(ref, 'shaders/effects'), '.js'),
    ...filesUnder(join(ref, 'shaders/effects'), '.wgsl'),
    ...filesUnder(join(ref, 'shaders/effects'), 'parity-case.json'),
    join(ref, 'shaders/effects/manifest.json')]
}

export function sourceManifest(ref, lock) {
  const files = authorityInputs(ref).map(p => sourceEntry(ref, p))
  const contentSha256 = sha256(files.map(s => `${s.path}\0${s.sha256}\n`).join(''))
  return { repository: lock.repository, commit: lock.commit, files, contentSha256 }
}

export function sourceIdentity(ref, lock, verifiedArchive = false) {
  if (lock.licenseSha256 && sha256(readFileSync(join(ref, 'LICENSE'))) !== lock.licenseSha256) {
    throw new Error('authority license hash mismatch')
  }
  if (verifiedArchive) return lock.commit
  if (!existsSync(join(ref, '.git'))) {
    if (!lock.sourceManifestSha256) throw new Error('archive authority requires a pinned source manifest hash')
    const found = sourceManifest(ref, lock).contentSha256
    if (found !== lock.sourceManifestSha256) throw new Error(`archive authority source hash mismatch: ${found}`)
    return lock.commit
  }
  const head = execFileSync('git', ['-C', ref, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim()
  if (head !== lock.commit) throw new Error(`authority commit mismatch: expected ${lock.commit}, found ${head}`)
  const dirty = execFileSync('git', ['-C', ref, 'status', '--porcelain', '--untracked-files=all', '--', 'package.json', 'share/palettes.json', 'share/meshes', 'shaders/src', 'shaders/effects', 'demo/shaders', 'vendor/shade-mcp/harness'], { encoding: 'utf8' }).trim()
  if (dirty) throw new Error('authority shader source has local modifications or untracked files')
  const tracked = new Set(execFileSync('git', ['-C', ref, 'ls-files', '-z', '--', 'package.json', 'share/palettes.json', 'share/meshes', 'shaders/src', 'shaders/effects', 'demo/shaders', 'vendor/shade-mcp/harness'])
    .toString('utf8').split('\0').filter(Boolean))
  for (const path of authorityInputs(ref)) {
    if (!tracked.has(relative(ref, path).replaceAll('\\', '/'))) throw new Error(`authority contains an untracked or ignored source: ${relative(ref, path)}`)
  }
  return head
}

// A development-only fallback for a machine without NM_REFERENCE_ROOT. Fetch an
// object into a temporary bare store and archive only compiler inputs. No
// branch, checkout, worktree, or persistent sibling repository is created.
export function fetchVerifiedArchive(lock, fetchUrl = REPOSITORY) {
  const temporary = mkdtempSync(join(tmpdir(), 'nm-swift-authority-'))
  const bare = join(temporary, 'objects.git')
  const root = join(temporary, 'source')
  const paths = ['LICENSE', 'package.json', 'share/palettes.json', 'share/meshes', 'shaders/src', 'shaders/effects', 'demo/shaders', 'vendor/shade-mcp/harness']
  try {
    execFileSync('git', ['init', '--bare', bare], { stdio: 'ignore' })
    execFileSync('git', ['--git-dir', bare, 'fetch', '--depth=1', fetchUrl, lock.commit], { stdio: 'pipe', maxBuffer: 1 << 20 })
    const fetched = execFileSync('git', ['--git-dir', bare, 'rev-parse', 'FETCH_HEAD'], { encoding: 'utf8' }).trim()
    if (fetched !== lock.commit) throw new Error(`fetched authority mismatch: expected ${lock.commit}, found ${fetched}`)
    const tree = execFileSync('git', ['--git-dir', bare, 'ls-tree', '-r', '-z', fetched, '--', ...paths], { maxBuffer: 1 << 24 })
    if (tree.toString('utf8').split('\0').some(line => line.startsWith('120000 '))) throw new Error('authority archive contains a symlink')
    const archive = execFileSync('git', ['--git-dir', bare, 'archive', '--format=tar', fetched, ...paths], { maxBuffer: 1 << 27 })
    mkdirSync(root)
    execFileSync('tar', ['-xf', '-', '-C', root], { input: archive, maxBuffer: 1 << 20 })
    return { root, commit: fetched, cleanup: () => rmSync(temporary, { recursive: true, force: true }) }
  } catch (error) {
    rmSync(temporary, { recursive: true, force: true })
    throw error
  }
}

function writeJson(path, value) {
  mkdirSync(dirname(path), { recursive: true })
  writeFileSync(path, JSON.stringify(value, null, 2) + '\n')
}

function sourceEntry(ref, path) {
  const bytes = readFileSync(path)
  return { path: relative(ref, path).replaceAll('\\', '/'), sha256: sha256(bytes), bytes: bytes.length }
}

function injectDefines(source, defines) {
  let prefix = ''
  for (const [key, value] of Object.entries(defines || {})) {
    if (typeof value === 'boolean') prefix += `const ${key}: bool = ${value};\n`
    else if (typeof value === 'number') prefix += `const ${key}: ${Number.isInteger(value) ? 'i32' : 'f32'} = ${value};\n`
    else prefix += `const ${key} = ${value};\n`
  }
  return prefix + source
}

export async function exportAuthority(ref, out, lock, verifiedArchive = false) {
  sourceIdentity(ref, lock, verifiedArchive)
  const idx = await import(pathToFileURL(join(ref, 'shaders/src/index.js')).href)
  const { compileGraph, lex, parse, validate, expand, allocateResources, registerEffect,
    registerOp, registerStarterOps, mergeIntoEnums, sanitizeEnumName } = idx
  const { stdEnums } = await import(pathToFileURL(join(ref, 'shaders/src/lang/std_enums.js')).href)
  await mergeIntoEnums(stdEnums)
  registerStarterOps()
  const effectDir = join(ref, 'shaders/effects')
  const paths = filesUnder(effectDir, 'definition.js')
  const manifestSource = sourceManifest(ref, lock)
  const sources = manifestSource.files
  if (lock.sourceManifestSha256 && manifestSource.contentSha256 !== lock.sourceManifestSha256) throw new Error('pinned authority source manifest hash mismatch')
  const inventory = []
  const catalogEffects = []
  const enumMerges = [{ source: 'std', value: encode(stdEnums) }]
  const paramAliasPairs = []
  const effectAliasPairs = []
  const allChoices = {}
  const starterNames = []
  const { registerParamAliases } = await import(pathToFileURL(join(ref, 'shaders/src/lang/paramAliases.js')).href)
  const { registerEffectAlias } = await import(pathToFileURL(join(ref, 'shaders/src/lang/effectAliases.js')).href)
  const manifest = JSON.parse(readFileSync(join(effectDir, 'manifest.json'), 'utf8'))
  for (const path of paths) {
    const ns = relative(effectDir, path).split('/')[0]
    const name = relative(effectDir, path).split('/')[1]
    const exported = (await import(pathToFileURL(path).href)).default
    const def = typeof exported === 'function' ? new exported() : exported
    if (!def) throw new Error(`empty definition: ${ns}/${name}`)
    if (!def.namespace) def.namespace = ns
    const func = def.func || name
    const shaderPaths = filesUnder(join(effectDir, ns, name, 'wgsl'), '.wgsl')
    def.shaders ||= {}
    for (const shaderPath of shaderPaths) {
      const prog = shaderPath.slice(shaderPath.lastIndexOf('/') + 1, -'.wgsl'.length)
      ;(def.shaders[prog] ||= {}).wgsl = readFileSync(shaderPath, 'utf8')
    }
    const declared = new Set((def.passes || []).map(p => p.program).filter(Boolean))
    for (const prog of declared) if (manifest[`${ns}/${name}`]?.wgsl?.[prog] && !own(def.shaders, prog)) throw new Error(`missing WGSL ${ns}/${name}/${prog}`)
    registerEffect(func, def)
    registerEffect(`${ns}.${func}`, def)
    registerEffect(`${ns}/${name}`, def)
    registerEffect(`${ns}.${name}`, def)
    const args = Object.entries(def.globals || {}).map(([key, spec]) => {
      let enumPath = spec.enum || spec.enumPath
      if (spec.choices && !enumPath) {
        enumPath = `${ns}.${func}.${key}`
        const bucket = ((allChoices[ns] ||= {})[func] ||= {})[key] ||= {}
        for (const [choice, value] of Object.entries(spec.choices)) {
          if (choice.endsWith(':')) continue
          bucket[choice] = { type: 'Number', value }
          const sanitized = sanitizeEnumName(choice)
          if (sanitized && sanitized !== choice) bucket[sanitized] = { type: 'Number', value }
        }
      }
      return { name: key, type: spec.type === 'vec4' ? 'color' : spec.type, default: spec.default,
        enum: enumPath, enumPath, min: spec.min, max: spec.max, uniform: spec.uniform, choices: spec.choices }
    })
    registerOp(`${ns}.${func}`, { name: func, args })
    if (def.paramAliases) {
      registerParamAliases(`${ns}.${func}`, def.paramAliases)
      paramAliasPairs.push([`${ns}.${func}`, def.paramAliases])
    }
    if (def.hidden && def.deprecatedBy) {
      registerEffectAlias(`${ns}.${func}`, def.deprecatedBy)
      effectAliasPairs.push([`${ns}.${func}`, def.deprecatedBy])
    }
    if (def.enums) {
      await mergeIntoEnums(def.enums)
      enumMerges.push({ source: `${ns}/${name}`, value: encode(def.enums) })
    }
    const inputs = new Set(['inputTex', 'inputTex3d', 'inputGeo', 'inputXyz', 'inputVel', 'inputRgba', 'src', 'o0', 'o1', 'o2', 'o3', 'o4', 'o5', 'o6', 'o7'])
    if (!(def.passes || []).some(p => Object.values(p.inputs || {}).some(v => inputs.has(v)))) starterNames.push(`${ns}.${func}`)
    const lifecycle = {
      onInit: !!def._configOnInit || def.onInit !== idx.Effect.prototype.onInit,
      onUpdate: !!def._configOnUpdate || def.onUpdate !== idx.Effect.prototype.onUpdate,
      onDestroy: !!def._configOnDestroy || def.onDestroy !== idx.Effect.prototype.onDestroy,
      asyncInit: !!def._configAsyncInit || def.asyncInit !== idx.Effect.prototype.asyncInit
    }
    inventory.push({ namespace: ns, name, func, definition: sourceEntry(ref, path),
      wgsl: shaderPaths.map(p => sourceEntry(ref, p)), programs: [...declared],
      defineVariants: countDefineVariants(def), lifecycle })
    catalogEffects.push({ key: `${ns}/${name}`, namespace: ns, name, func,
      definition: sourceEntry(ref, path), wgsl: shaderPaths.map(p => sourceEntry(ref, p)),
      registrationKeys: [func, `${ns}.${func}`, `${ns}/${name}`, `${ns}.${name}`],
      starter: starterNames.includes(`${ns}.${func}`), lifecycle,
      externalTexture: def.externalTexture ?? null, externalMesh: def.externalMesh ?? null,
      value: encode(def) })
  }
  if (starterNames.length) registerStarterOps(starterNames)
  if (Object.keys(allChoices).length) {
    await mergeIntoEnums(allChoices)
    enumMerges.push({ source: 'choices', value: encode(allChoices) })
  }
  const { ops } = await import(pathToFileURL(join(ref, 'shaders/src/lang/ops.js')).href)
  const enumModule = await import(pathToFileURL(join(ref, 'shaders/src/lang/enums.js')).href)
  const defaultShaders = await import(pathToFileURL(join(ref, 'shaders/src/runtime/default-shaders.js')).href)
  const { expandPalette } = await import(pathToFileURL(join(ref, 'shaders/src/runtime/palette-expansion.js')).href)
  // The source exposes palette expansion rather than its private table. Query
  // every one-based entry in order, preserving its exact JS numeric values.
  const paletteTable = []
  for (let index = 1; index <= 10000; index++) {
    const value = expandPalette(index)
    if (value === null) break
    paletteTable.push({ amp: value.paletteAmp, freq: value.paletteFreq,
      offset: value.paletteOffset, phase: value.palettePhase, mode: value.paletteMode })
  }
  if (!paletteTable.length || paletteTable.length === 10000 || expandPalette(0) !== null ||
      expandPalette(paletteTable.length + 1) !== null) {
    throw new Error('upstream palette expansion does not have a finite one-based table')
  }
  const license = readFileSync(join(ref, 'LICENSE'), 'utf8')
  if (sha256(license) !== lock.licenseSha256) throw new Error('authority license hash mismatch')
  if (catalogEffects.length !== paths.length ||
      new Set(catalogEffects.map(effect => effect.key)).size !== catalogEffects.length ||
      Object.keys(ops).length !== catalogEffects.length) {
    throw new Error('source catalog inventory, unique keys, and validator registrations disagree')
  }
  // Upstream expander emits this program for a normal render(o0) graph.
  // Take the emitted value rather than copying a WGSL/GLSL literal by hand.
  const blitProgram = compileGraph(CASES.solid).programs.blit
  if (!blitProgram?.wgsl || !blitProgram?.fragment) throw new Error('upstream blit program missing')
  writeJson(join(out, 'catalog.json'), {
    schemaVersion: 1,
    authority: { repository: lock.repository, commit: lock.commit, sourceManifestSha256: manifestSource.contentSha256 },
    license: { path: 'LICENSE', sha256: sha256(license), text: license },
    effectCount: catalogEffects.length,
    effects: catalogEffects,
    stdEnums: encode(stdEnums),
    enumMerges,
    mergedEnums: encode(enumModule.default),
    validatorOps: encode(ops),
    starterOps: starterNames,
    paramAliases: encode(new Map(paramAliasPairs)),
    effectAliases: encode(new Map(effectAliasPairs)),
    paletteTable: encode(paletteTable),
    blitProgram: encode(blitProgram),
    defaultVertex: { wgsl: defaultShaders.DEFAULT_VERTEX_SHADER_WGSL,
      entryPoint: defaultShaders.DEFAULT_VERTEX_ENTRY_POINT,
      sourceSha256: sha256(defaultShaders.DEFAULT_VERTEX_SHADER_WGSL) }
  })
  const portable = {}
  const portableRenderer = new idx.CanvasRenderer()
  for (const [name, spec] of Object.entries(PORTABLE_CASES)) {
    const definitionBytes = readFileSync(join(ROOT, 'parity', spec.definition))
    const shaderBytes = Object.values(spec.shaders).map(file => readFileSync(join(ROOT, 'parity', file)))
    const definition = JSON.parse(definitionBytes)
    definition.shaders = Object.fromEntries(Object.keys(spec.shaders).map((program, index) =>
      [program, { wgsl: shaderBytes[index].toString('utf8') }]))
    await portableRenderer.registerPortableEffect(definition)
    portable[name] = { definition, fixtureSha256: sha256(Buffer.concat([Buffer.from(CASES[name]), definitionBytes, ...shaderBytes])) }
  }
  const cases = {}
  for (const [name, source] of Object.entries(CASES)) {
    const tokens = lex(source)
    const ast = parse(tokens)
    const validated = validate(ast)
    const expanded = expand(validated)
    if (expanded.errors?.length) throw new Error(`${name}: expansion errors: ${JSON.stringify(expanded.errors)}`)
    const allocated = allocateResources(expanded.passes)
    const graph = compileGraph(source)
    const executionGraphId = compileGraph(source.trim()).id
    // compiledAt is wall-clock metadata, not an execution input. Keep its
    // position and omission explicit so stage dumps are byte reproducible.
    const stableGraph = { ...graph, compiledAt: { $type: 'volatile-timestamp' } }
    const stages = { source, lex: fullTokenView(tokens), parse: encode(ast), validate: encode(validated),
      expand: encode(expanded), allocate: encode(allocated), graph: encode(stableGraph) }
    const programs = {}
    for (const [id, spec] of Object.entries(graph.programs || {})) {
      if (!spec.wgsl) throw new Error(`${name}: ${id} has no WGSL source`)
      const resolved = injectDefines(spec.wgsl, spec.defines)
      programs[id] = { originalSha256: sha256(spec.wgsl), resolvedSha256: sha256(resolved),
        defines: encode(spec.defines), originalWGSL: spec.wgsl, resolvedWGSL: resolved,
        entryPoints: [...resolved.matchAll(/@(vertex|fragment|compute)\s+(?:@\w+(?:\([^)]*\))?\s+)*fn\s+(\w+)/g)].map(m => ({ stage: m[1], name: m[2] })) }
    }
    const passPrograms = graph.passes.map(pass => pass.program).filter(Boolean)
    for (const id of passPrograms) if (!own(programs, id)) throw new Error(`${name}: pass refers to missing program ${id}`)
    const referencedPrograms = [...new Set(passPrograms)]
    const referenced = new Set(referencedPrograms)
    const templatePrograms = Object.keys(programs).filter(id => !referenced.has(id))
    writeJson(join(out, 'cases', `${name}.json`), { stages, programs, passPrograms, referencedPrograms, templatePrograms, executionGraphId,
      ...(portable[name] ? { portableDefinition: portable[name].definition,
        fixtureSha256: portable[name].fixtureSha256 } : {}) })
    cases[name] = { sourceSha256: sha256(source), graphId: graph.id, passes: graph.passes.length,
      programs: Object.keys(programs).length, referencedPrograms: referencedPrograms.length,
      templatePrograms: templatePrograms.length,
      ...(portable[name] ? { fixtureSha256: portable[name].fixtureSha256 } : {}) }
  }
  writeJson(join(out, 'source-manifest.json'), manifestSource)
  writeJson(join(out, 'inventory.json'), { effects: inventory.length, wgslFiles: sources.filter(s => s.path.endsWith('.wgsl')).length, entries: inventory })
  writeJson(join(out, 'capture-protocols.json'), captureProtocols())
  writeJson(join(out, 'default-vertex.json'), {
    wgsl: defaultShaders.DEFAULT_VERTEX_SHADER_WGSL,
    entryPoint: defaultShaders.DEFAULT_VERTEX_ENTRY_POINT,
    sourceSha256: sha256(defaultShaders.DEFAULT_VERTEX_SHADER_WGSL),
    authorityFile: 'shaders/src/runtime/default-shaders.js'
  })
  writeJson(join(out, 'summary.json'), { authority: manifestSource.contentSha256, cases,
    effects: inventory.length, wgslFiles: manifestSource.files.filter(s => s.path.endsWith('.wgsl')).length })
  return { authority: manifestSource.contentSha256, cases, effects: inventory.length }
}

async function main() {
  const lock = JSON.parse(readFileSync(join(ROOT, 'parity/reference.json'), 'utf8'))
  if (lock.repository !== REPOSITORY || !/^[0-9a-f]{40}$/.test(lock.commit)) throw new Error('invalid authority lock')
  const out = resolve(process.argv[2] || join(ROOT, '.build/reference'))
  const archive = process.env.NM_REFERENCE_ROOT ? null : fetchVerifiedArchive(lock)
  try {
    const summary = await exportAuthority(resolve(process.env.NM_REFERENCE_ROOT || archive.root), out, lock, !!archive)
    process.stdout.write(JSON.stringify(summary) + '\n')
  } finally { archive?.cleanup() }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch(error => { process.stderr.write(`${error?.stack || (typeof error === 'object' ? JSON.stringify(error) : String(error))}\n`); process.exitCode = 1 })
}
