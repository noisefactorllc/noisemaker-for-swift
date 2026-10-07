import test, { after } from 'node:test'
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { appendFileSync, cpSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { encode, fullTokenView, countDefineVariants, captureProtocols, fetchVerifiedArchive, sourceIdentity } from './export-reference.mjs'

const lock = JSON.parse(readFileSync('parity/reference.json', 'utf8'))
let sharedArchive
function referenceRoot() {
  if (process.env.NM_REFERENCE_ROOT) return process.env.NM_REFERENCE_ROOT
  sharedArchive ||= fetchVerifiedArchive(lock)
  return sharedArchive.root
}
after(() => sharedArchive?.cleanup())

test('encoding preserves order, maps, undefined, functions, and special numbers', () => {
  const value = { z: undefined, a: new Map([['two', 2], ['one', 1]]), fn: (x) => x + 1, nan: NaN }
  const encoded = encode(value)
  assert.deepEqual(encoded.entries.map(([key]) => key), ['z', 'a', 'fn', 'nan'])
  assert.deepEqual(encoded.entries[0][1], { $type: 'undefined' })
  assert.deepEqual(encoded.entries[1][1].entries, [['two', 2], ['one', 1]])
  assert.match(encoded.entries[2][1].source, /x \+ 1/)
  assert.deepEqual(encoded.entries[3][1], { $type: 'number', value: 'NaN' })
  assert.deepEqual(encode(-0), { $type: 'number', value: '-0' })
  assert.deepEqual(JSON.parse(JSON.stringify(encode(-0))), { $type: 'number', value: '-0' })
})

test('lexical snapshot retains nonenumerable UTF-16 token positions', async () => {
  const { lex } = await import(pathToFileURL(join(referenceRoot(), 'shaders/src/lang/lexer.js')).href)
  const token = fullTokenView(lex('"😀" a')).find(t => t.entries.some(([key, value]) => key === 'lexeme' && value === 'a'))
  const position = token.entries.find(([key]) => key === 'position')[1]
  assert.deepEqual(position.entries, [['line', 1], ['column', 6], ['start', 5], ['end', 6]])
})

test('define counts keep exact values and pass variants separate', () => {
  const counts = countDefineVariants({ globals: {
    mode: { define: 'MODE', default: 0, choices: { a: 0, b: 1, aliasB: 1 } },
    high: { define: 'HIGH', default: false, type: 'boolean' },
    dynamic: { define: 'DYNAMIC', default: 3, min: 1, max: 9 },
  }, passes: [{ defines: { VIEW: 0 } }, { defines: { VIEW: 1 } }] })
  assert.equal(counts.declaredSampleCombinations, 4)
  assert.equal(counts.passVariants, 2)
  assert.deepEqual(counts.openNumericDefines, ['MODE', 'DYNAMIC'])
})

test('integer define ranges count every declared step', () => {
  const counts = countDefineVariants({ globals: {
    radius: { define: 'RADIUS', type: 'int', default: 2, min: 1, max: 3, step: 1 },
    enabled: { define: 'ENABLED', type: 'boolean', default: false }
  } })
  assert.equal(counts.declaredSampleCombinations, 6)
  assert.deepEqual(counts.dimensions[0].values, [1, 2, 3])
  assert.deepEqual(counts.openNumericDefines, ['RADIUS'])
})

test('capture protocol identifies odd marker and timed frames', () => {
  const protocols = captureProtocols()
  assert.deepEqual(protocols.marker.size, [257, 129])
  assert.deepEqual(protocols.cases.computeFilter.size, [257, 129])
  assert.deepEqual(protocols.timed.sampleFrames, [1, 2, 4, 10, 30])
  assert.equal(protocols.goldenBackend, 'webgpu')
})

test('locked export carries exact default vertex and is reproducible', async () => {
  const out = mkdtempSync(join(tmpdir(), 'nm-swift-export-'))
  const run = () => execFileSync(process.execPath, ['tools/export-reference.mjs', out], { env: process.env })
  const hashes = () => [out, join(out, 'cases')].flatMap(dir => readdirSync(dir).filter(name => name.endsWith('.json')).map(name => {
    const bytes = readFileSync(join(dir, name))
    return [name, createHash('sha256').update(bytes).digest('hex')]
  }))
  try {
    run()
    const vertex = JSON.parse(readFileSync(join(out, 'default-vertex.json'), 'utf8'))
    const inventory = JSON.parse(readFileSync(join(out, 'inventory.json'), 'utf8'))
    const sources = JSON.parse(readFileSync(join(out, 'source-manifest.json'), 'utf8')).files
    assert.ok(sources.some(file => file.path === 'package.json'))
    assert.ok(sources.some(file => file.path === 'demo/shaders/lib/program-state.js'))
    assert.ok(sources.some(file => file.path === 'demo/shaders/index.html'))
    assert.ok(sources.some(file => file.path === 'vendor/shade-mcp/harness/index.js'))
    assert.ok(sources.some(file => file.path === 'share/palettes.json'))
    const noise = inventory.entries.find(entry => entry.namespace === 'synth' && entry.name === 'noise')
    assert.ok(noise.defineVariants.openNumericDefines.includes('NOISE_TYPE'))
    const numericCase = JSON.parse(readFileSync(join(out, 'cases/numericDefineOutsideChoices.json'), 'utf8'))
    assert.ok(Object.values(numericCase.programs).some(program =>
      program.defines.entries.some(([name, value]) => name === 'NOISE_TYPE' && value === 12)))
    const resourceHeavy = JSON.parse(readFileSync(join(out, 'cases/resourceHeavy.json'), 'utf8'))
    assert.equal(resourceHeavy.referencedPrograms.length, 21)
    assert.equal(resourceHeavy.templatePrograms.length, 2)
    assert.deepEqual([...new Set(resourceHeavy.passPrograms)].sort(), [...resourceHeavy.referencedPrograms].sort())
    assert.ok(resourceHeavy.passPrograms.every(id => id in resourceHeavy.programs))
    assert.ok(resourceHeavy.templatePrograms.every(id => id in resourceHeavy.programs && !resourceHeavy.referencedPrograms.includes(id)))
    const marker = JSON.parse(readFileSync(join(out, 'cases/marker.json'), 'utf8'))
    assert.equal(marker.stages.source, readFileSync('parity/marker.dsl', 'utf8'))
    assert.ok(Object.values(marker.programs).some(program => program.originalWGSL === readFileSync('parity/marker.marker.wgsl', 'utf8')))
    assert.ok(marker.passPrograms.every(id => id in marker.programs))
    assert.equal(marker.executionGraphId, '-r74o43')
    const object = encoded => Object.fromEntries(encoded.entries)
    const mrt = JSON.parse(readFileSync(join(out, 'cases/mrtProbe.json'), 'utf8'))
    const mrtPasses = object(mrt.stages.graph).passes.map(object)
    assert.equal(mrtPasses.length, 3)
    assert.equal(mrtPasses[0].drawBuffers, 2)
    assert.deepEqual(object(mrtPasses[0].outputs), {
      first: 'node_0_firstTarget', second: 'node_0_secondTarget' })
    assert.deepEqual(object(mrtPasses[1].inputs), {
      firstTex: 'node_0_firstTarget', secondTex: 'node_0_secondTarget' })
    assert.ok(mrt.passPrograms.every(id => id in mrt.programs))
    assert.ok(Object.values(mrt.programs).some(program => program.originalWGSL.includes('@location(1) second')))
    const sampler = JSON.parse(readFileSync(join(out, 'cases/samplerProbe.json'), 'utf8'))
    const samplerPasses = object(sampler.stages.graph).passes.map(object)
    assert.equal(samplerPasses.length, 3)
    assert.equal(object(samplerPasses[1].inputs).inputTex, 'node_0_patternTex')
    assert.ok(Object.values(sampler.programs).some(program =>
      program.originalWGSL.includes('textureSample(inputTex, inputSampler, uv)')))
    assert.equal(sampler.stages.source, readFileSync('parity/sampler.dsl', 'utf8'))
    const blur = JSON.parse(readFileSync(join(out, 'cases/multipassBlur.json'), 'utf8'))
    assert.deepEqual(object(blur.stages.graph).passes.map(pass => object(pass).name).slice(1, 3), ['blurH', 'blurV'])
    const computeFilter = JSON.parse(readFileSync(join(out, 'cases/computeFilter.json'), 'utf8'))
    assert.equal(typeof computeFilter.executionGraphId, 'string')
    assert.ok(Object.values(computeFilter.programs).some(program =>
      program.entryPoints.some(point => point.stage === 'compute') && program.originalWGSL.includes('output_buffer')))
    const feedback = JSON.parse(readFileSync(join(out, 'cases/repeatFeedback.json'), 'utf8'))
    assert.equal(object(object(feedback.stages.graph).passes[0]).repeat, 'iterations')
    const enumProbe = JSON.parse(readFileSync(join(out, 'cases/builtinEnum.json'), 'utf8'))
    assert.match(enumProbe.stages.source, /oscKind\.sine/)
    const original = await import(pathToFileURL(join(referenceRoot(), 'shaders/src/runtime/default-shaders.js')).href)
    assert.equal(vertex.wgsl, original.DEFAULT_VERTEX_SHADER_WGSL)
    assert.equal(vertex.entryPoint, original.DEFAULT_VERTEX_ENTRY_POINT)
    assert.equal(vertex.sourceSha256, createHash('sha256').update(vertex.wgsl).digest('hex'))
    const first = hashes()
    run()
    assert.deepEqual(hashes(), first)
  } finally { rmSync(out, { recursive: true, force: true }) }
})

test('fallback fetches and verifies the pinned commit without a branch or worktree', () => {
  const archive = fetchVerifiedArchive(lock, process.env.NM_REFERENCE_ROOT || lock.repository)
  try {
    assert.equal(archive.commit, lock.commit)
    assert.equal(readFileSync(join(archive.root, 'shaders/src/runtime/default-shaders.js'), 'utf8'),
      readFileSync(join(referenceRoot(), 'shaders/src/runtime/default-shaders.js'), 'utf8'))
  } finally { archive.cleanup() }
})

test('authority refuses an untracked shader helper or effect', () => {
  const root = mkdtempSync(join(tmpdir(), 'nm-swift-dirty-'))
  try {
    for (const path of ['package.json', 'share/palettes.json', 'shaders/src', 'shaders/effects', 'demo/shaders', 'vendor/shade-mcp/harness']) {
      cpSync(join(referenceRoot(), path), join(root, path), { recursive: true, dereference: true })
    }
    execFileSync('git', ['init', '-b', 'main', root], { stdio: 'ignore' })
    execFileSync('git', ['-C', root, 'add', 'package.json', 'share/palettes.json', 'shaders/src', 'shaders/effects', 'demo/shaders', 'vendor/shade-mcp/harness'])
    execFileSync('git', ['-C', root, 'add', '-f', 'demo/shaders/img/.DS_Store'])
    execFileSync('git', ['-C', root, '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', 'commit', '-m', 'authority fixture'], { stdio: 'ignore' })
    const localLock = { ...lock, commit: execFileSync('git', ['-C', root, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim() }
    assert.equal(sourceIdentity(root, localLock), localLock.commit)
    const helper = join(root, 'shaders/src/runtime/untracked-helper.js')
    writeFileSync(helper, 'export default 1\n')
    assert.throws(() => sourceIdentity(root, localLock), /untracked files/)
    rmSync(helper)
    const effect = join(root, 'shaders/effects/untracked.js')
    writeFileSync(effect, 'export default 1\n')
    assert.throws(() => sourceIdentity(root, localLock), /untracked files/)
    rmSync(effect)
    appendFileSync(join(root, '.git/info/exclude'), '\nshaders/src/runtime/ignored-probe.js\n')
    writeFileSync(join(root, 'shaders/src/runtime/ignored-probe.js'), 'export default 1\n')
    assert.throws(() => sourceIdentity(root, localLock), /untracked|ignored/)
  } finally { rmSync(root, { recursive: true, force: true }) }
})
