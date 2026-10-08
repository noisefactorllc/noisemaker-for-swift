#!/usr/bin/env node
// Import the shared port fixtures with exact source and sidecar provenance.
import { createHash } from 'node:crypto'
import { execFileSync } from 'node:child_process'
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs'
import { dirname, join, relative, resolve } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { tmpdir } from 'node:os'
import { CASES, captureProtocols, fetchVerifiedArchive, sourceIdentity } from './export-reference.mjs'

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const OUT = join(ROOT, 'parity/corpus.json')
const RUST_COMMIT = '61d81dfd1f64294ad3b67ee6c2b49aa5f2ae230a'
const QT_COMMIT = 'a572b7c4902918d4f68def112146f312cc689ff9'
const FAMILIES = ['programs', 'coverage', 'timed', 'curated', 'portable', 'qtPrograms', 'upstream', 'micro']
const RUST_URL = 'https://github.com/noisefactorllc/noisemaker-for-rust-gpu.git'
const QT_URL = 'https://github.com/noisefactorllc/noisemaker-for-qt.git'
const MICRO_ASSETS = {
  marker: ['marker.portable.json', 'marker.marker.wgsl'],
  mrtProbe: ['mrt.portable.json', 'mrt.split.wgsl', 'mrt.combine.wgsl'],
  samplerProbe: ['sampler.portable.json', 'sampler.pattern.wgsl', 'sampler.sample.wgsl'],
  sampled3dProbe: ['sampled3d.portable.json', 'sampled3d.show.wgsl']
}
const hash = bytes => createHash('sha256').update(bytes).digest('hex')
const readJson = path => JSON.parse(readFileSync(path, 'utf8'))

function gitSource(root, commit, paths) {
  if (execFileSync('git', ['-C', root, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim() !== commit) {
    throw new Error(`sibling fixture commit mismatch: ${root}`)
  }
  const dirty = execFileSync('git', ['-C', root, 'status', '--porcelain', '--untracked-files=all', '--', ...paths], { encoding: 'utf8' }).trim()
  if (dirty) throw new Error(`sibling fixture source has local changes: ${root}`)
  const tracked = new Set(execFileSync('git', ['-C', root, 'ls-files', '-z', '--', ...paths]).toString('utf8').split('\0').filter(Boolean))
  for (const path of paths) {
    for (const name of readdirSync(join(root, path))) {
      const sourcePath = `${path}/${name}`
      if (!tracked.has(sourcePath)) throw new Error(`untracked sibling fixture: ${sourcePath}`)
    }
  }
}

function siblingArchive(commit, url, paths) {
  const temporary = mkdtempSync(join(tmpdir(), 'nm-swift-corpus-'))
  const bare = join(temporary, 'objects.git')
  const root = join(temporary, 'source')
  try {
    execFileSync('git', ['init', '--bare', bare], { stdio: 'ignore' })
    execFileSync('git', ['--git-dir', bare, 'fetch', '--depth=1', url, commit], { stdio: 'pipe', maxBuffer: 1 << 20 })
    const fetched = execFileSync('git', ['--git-dir', bare, 'rev-parse', 'FETCH_HEAD'], { encoding: 'utf8' }).trim()
    if (fetched !== commit) throw new Error(`sibling fixture fetch returned ${fetched}, expected ${commit}`)
    const tree = execFileSync('git', ['--git-dir', bare, 'ls-tree', '-r', '-z', commit, '--', ...paths], { maxBuffer: 1 << 24 })
    if (tree.toString('utf8').split('\0').some(line => line.startsWith('120000 '))) throw new Error('sibling fixture archive contains a symlink')
    const archive = execFileSync('git', ['--git-dir', bare, 'archive', '--format=tar', commit, ...paths], { maxBuffer: 1 << 27 })
    mkdirSync(root)
    execFileSync('tar', ['-xf', '-', '-C', root], { input: archive, maxBuffer: 1 << 20 })
    return { root, cleanup: () => rmSync(temporary, { recursive: true, force: true }) }
  } catch (error) {
    rmSync(temporary, { recursive: true, force: true })
    throw error
  }
}

function asset(root, path) {
  const bytes = readFileSync(join(root, path))
  return { path, sha256: hash(bytes), text: bytes.toString('utf8') }
}

function parityFiles(directory) {
  return readdirSync(directory, { withFileTypes: true }).flatMap(item => {
    const path = join(directory, item.name)
    return item.isDirectory() ? parityFiles(path) : item.name === 'parity-case.json' ? [path] : []
  }).sort()
}

function definitionFiles(directory) {
  return readdirSync(directory, { withFileTypes: true }).flatMap(item => {
    const path = join(directory, item.name)
    return item.isDirectory() ? definitionFiles(path) : item.name === 'definition.js' ? [path] : []
  }).sort()
}

const fileToken = text => String(text).replace(/[^A-Za-z0-9]+/g, '_').replace(/^_+|_+$/g, '') || 'x'
const choiceToken = (name, value) => {
  if (/^[A-Za-z_][A-Za-z0-9_]*$/.test(name)) return name
  const safe = name.replace(/\s+(.)/g, (_, next) => next.toUpperCase()).replace(/\s+/g, '').replace(/[^A-Za-z0-9_]/g, '')
  return /^[A-Za-z_][A-Za-z0-9_]*$/.test(safe) ? safe : String(value)
}

function withCallArg(source, func, parameter, token) {
  const match = new RegExp(`(^|[^A-Za-z0-9_])${func}\\s*\\(`, 'g').exec(source)
  if (!match) throw new Error(`coverage base has no ${func} call`)
  const open = match.index + match[0].length - 1
  let depth = 0
  let close = -1
  for (let index = open; index < source.length; index++) {
    if (source[index] === '(') depth++
    if (source[index] === ')' && --depth === 0) { close = index; break }
  }
  if (close < 0) throw new Error(`coverage base has unterminated ${func} call`)
  const before = source.slice(open + 1, close).trim()
  if (new RegExp(`(?:^|,)\\s*${parameter}\\s*:`).test(before)) {
    return source.replace(new RegExp(`(${parameter}\\s*:\\s*)[^,)]+`), `$1${token}`)
  }
  return source.slice(0, close) + (before ? `, ${parameter}: ${token}` : `${parameter}: ${token}`) + source.slice(close)
}

function protocol(family, upstreamCase = {}) {
  if (family === 'timed') return {
    size: [256, 256], resetState: true, frameTime: '((frame + 1) / 600) % 1',
    sampleFrames: [1, 2, 4, 10, 30], runSeconds: 5, sampleEverySeconds: 1,
    sample: 'WebGPU presented surface', orientation: 'top-down RGBA8 PNG'
  }
  return { size: upstreamCase.resolution || [256, 256], normalizedTime: 0.25,
    deltaTime: 0, frames: 8, resetState: true, sample: 'WebGPU presented surface',
    orientation: 'top-down RGBA8 PNG' }
}

function entry(id, source, origin, family, assets = [], extra = {}) {
  const bytes = Buffer.from(source)
  return { id, family, source, sourceSha256: hash(bytes), origin,
    assets, capture: protocol(family, extra.upstreamCase), ...extra }
}

function verifyCorpus(corpus) {
  if (corpus.schemaVersion !== 1) throw new Error('unsupported parity corpus version')
  const expected = Object.values(corpus.expected).reduce((a, b) => a + b, 0)
  if (corpus.cases.length !== expected) throw new Error(`corpus denominator changed: ${corpus.cases.length} != ${expected}`)
  if (FAMILIES.some(family => !Number.isSafeInteger(corpus.expected[family]) || corpus.expected[family] < 1) ||
      Object.keys(corpus.expected).length !== FAMILIES.length) throw new Error('invalid corpus family counts')
  const counts = Object.fromEntries(FAMILIES.map(key => [key, 0]))
  const ids = new Set()
  for (const item of corpus.cases) {
    if (!(item.family in counts) || ids.has(item.id)) throw new Error(`invalid or duplicate case ${item.id}`)
    ids.add(item.id)
    counts[item.family]++
    if (hash(item.source) !== item.sourceSha256) throw new Error(`corpus source differs: ${item.id}`)
    for (const sidecar of item.assets) if (hash(sidecar.text) !== sidecar.sha256) throw new Error(`corpus asset differs: ${item.id}/${sidecar.path}`)
  }
  if (JSON.stringify(counts) !== JSON.stringify(corpus.expected)) throw new Error(`corpus family denominator changed: ${JSON.stringify(counts)}`)
  if (corpus.sourceManifestSha256 !== readJson(join(ROOT, 'parity/reference.json')).sourceManifestSha256) {
    throw new Error('corpus upstream source manifest lock differs')
  }
  return counts
}

async function makeCorpus() {
  const rustLocal = process.env.NM_RUST_CORPUS_ROOT || null
  const qtLocal = process.env.NM_QT_CORPUS_ROOT || null
  const upstreamLocal = process.env.NM_REFERENCE_ROOT || null
  const rustArchive = rustLocal ? null : siblingArchive(RUST_COMMIT, RUST_URL,
    ['parity/programs', 'parity/coverage', 'parity/timed', 'parity/curated', 'parity/portable'])
  const qtArchive = qtLocal ? null : siblingArchive(QT_COMMIT, QT_URL, ['parity/programs'])
  const lock = readJson(join(ROOT, 'parity/reference.json'))
  const upstreamArchive = upstreamLocal ? null : fetchVerifiedArchive(lock)
  const rust = resolve(rustArchive?.root || rustLocal)
  const qt = resolve(qtArchive?.root || qtLocal)
  const upstream = resolve(upstreamArchive?.root || upstreamLocal)
  try {
  sourceIdentity(upstream, lock, !!upstreamArchive)
  const families = ['programs', 'coverage', 'timed', 'curated', 'portable']
  if (!rustArchive) gitSource(rust, RUST_COMMIT, families.map(name => `parity/${name}`))
  if (!qtArchive) gitSource(qt, QT_COMMIT, ['parity/programs'])
  const cases = []
  const timedManifest = readJson(join(rust, 'parity/timed/manifest.json'))
  for (const family of families) {
    const directory = join(rust, 'parity', family)
    for (const name of readdirSync(directory).filter(name => name.endsWith('.dsl')).sort()) {
      const stem = name.slice(0, -4)
      const path = `parity/${family}/${name}`
      const assets = readdirSync(directory).filter(other => other.startsWith(`${stem}.`) && other !== name).sort()
        .map(other => asset(rust, `parity/${family}/${other}`))
      if (family === 'portable') {
        const def = assets.find(a => a.path.endsWith('.portable.json'))
        if (!def) throw new Error(`portable fixture lacks definition: ${path}`)
        const definition = JSON.parse(def.text)
        for (const program of Object.keys(definition.shaders || {})) {
          const shader = `parity/portable/${stem}.${program}.wgsl`
          if (existsSync(join(rust, shader))) assets.push(asset(rust, shader))
          else if (!definition.shaders[program].wgsl) throw new Error(`portable fixture lacks WGSL: ${shader}`)
        }
      }
      cases.push(entry(`${family}/${stem}`, readFileSync(join(rust, path), 'utf8'),
        { repository: 'noisemaker-for-rust-gpu', commit: RUST_COMMIT, path }, family, assets,
        family === 'timed' ? { timed: timedManifest.cases[stem] || null } : {}))
    }
  }
  const rustNames = new Set(cases.filter(c => c.family === 'programs').map(c => `${c.id.slice('programs/'.length)}.dsl`))
  for (const name of readdirSync(join(qt, 'parity/programs')).filter(name => name.endsWith('.dsl') && !rustNames.has(name)).sort()) {
    const path = `parity/programs/${name}`
    const stem = name.slice(0, -4)
    cases.push(entry(`qtPrograms/${stem}`, readFileSync(join(qt, path), 'utf8'),
      { repository: 'noisemaker-for-qt', commit: QT_COMMIT, path }, 'qtPrograms'))
  }
  const covered = new Set(cases.filter(item => item.family === 'coverage').map(item => item.id))
  for (const definitionPath of definitionFiles(join(upstream, 'shaders/effects'))) {
    const path = relative(upstream, definitionPath).replaceAll('\\', '/')
    const [, , namespace, name] = path.split('/')
    const exported = (await import(pathToFileURL(definitionPath).href)).default
    const definition = typeof exported === 'function' ? new exported() : exported
    const func = definition.func || name
    const baseId = `coverage/${namespace}_${func}`
    const base = cases.find(item => item.id === baseId)
    if (!base) throw new Error(`locked effect lacks default coverage: ${namespace}/${name}`)
    for (const [parameter, spec] of Object.entries(definition.globals || {})) {
      const variants = []
      if (spec.choices && typeof spec.choices === 'object') {
        for (const [choiceName, value] of Object.entries(spec.choices)) {
          if (choiceName.endsWith(':') || value === spec.default ||
              (typeof value === 'number' && Number(spec.default) === value && spec.type !== 'member')) continue
          variants.push([choiceName, choiceToken(choiceName, value)])
        }
      } else if (spec.type === 'boolean') {
        const flipped = !(spec.default === true)
        variants.push([String(flipped), String(flipped)])
      }
      for (const [label, token] of variants) {
        const id = `${baseId}__${fileToken(parameter)}_${fileToken(label)}`
        if (covered.has(id)) continue
        const source = withCallArg(base.source, func, parameter, token)
        cases.push(entry(id, source, { repository: lock.repository, commit: lock.commit,
          path, sha256: hash(readFileSync(definitionPath)), generator: 'locked choice/boolean coverage' }, 'coverage',
        base.assets, { claimedEffects: [`${namespace}/${name}`] }))
        covered.add(id)
      }
    }
  }
  for (const sourcePath of parityFiles(join(upstream, 'shaders/effects'))) {
    const original = readFileSync(sourcePath)
    const definition = JSON.parse(original)
    const path = relative(upstream, sourcePath).replaceAll('\\', '/')
    const [, , namespace, name] = path.split('/')
    cases.push(entry(`upstream/${namespace}/${name}`, definition.dsl,
      { repository: lock.repository, commit: lock.commit, path, sha256: hash(original) },
      'upstream', [], { upstreamCase: definition, claimedEffects: definition.effects || [] }))
  }
  for (const [name, source] of Object.entries(CASES)) {
    const assets = (MICRO_ASSETS[name] || []).map(file => asset(ROOT, `parity/${file}`))
    const capture = structuredClone(captureProtocols().cases[name])
    if (name === 'sampled3dProbe') {
      const path = 'parity/inputs/sampled3d-v1.rgba8'
      const bytes = readFileSync(join(ROOT, path))
      if (bytes.length !== 8 * 8 * 8 * 4) throw new Error('sampled 3D input byte count differs')
      for (let z = 0; z < 8; z++) for (let y = 0; y < 8; y++) for (let x = 0; x < 8; x++) {
        const offset = ((z * 8 + y) * 8 + x) * 4
        if (bytes[offset] !== x * 31 || bytes[offset + 1] !== y * 31 ||
            bytes[offset + 2] !== z * 31 || bytes[offset + 3] !== 255) {
          throw new Error('sampled 3D input differs from source-proven patterned volume')
        }
      }
      capture.volumeInput = { id: 'node_0_volume', assetPath: path,
        assetSha256: hash(bytes), width: 8, height: 8, depth: 8,
        format: 'rgba8unorm', orientation: 'x-fastest-y-next-z-outermost',
        bytesPerRow: 32, bytesPerImage: 256, frame: 0,
        updatePolicy: 'static-before-frame-1' }
    }
    cases.push(entry(`micro/${name}`, source,
      { repository: 'noisemaker-for-swift', path: `tools/export-reference.mjs:CASES.${name}` }, 'micro', assets,
      { capture }))
  }
  const audioAsset = asset(ROOT, 'parity/inputs/audio-v1.json')
  for (const id of ['coverage/synth_scope', 'coverage/synth_spectrum']) {
    const item = cases.find(entry => entry.id === id)
    if (!item) throw new Error(`locked audio effect lacks default coverage: ${id}`)
    item.assets.push(audioAsset)
    item.capture.audioInput = { assetPath: audioAsset.path, assetSha256: audioAsset.sha256,
      frame: 0, updatePolicy: 'static-before-frame-1' }
    const name = id === 'coverage/synth_scope' ? 'audioScopeArray' : 'audioSpectrumArray'
    const capture = structuredClone(item.capture)
    capture.audioInput.representation = 'plain-array'
    cases.push(entry(`micro/${name}`, item.source,
      { ...item.origin, generator: 'locked AudioState samples copied into the supported Pipeline.setAudioState plain-array host interface' },
      'micro', item.assets, { capture }))
  }
  const roll = cases.find(item => item.id === 'coverage/synth_roll')
  if (!roll || !roll.assets.some(sidecar => sidecar.path.endsWith('.midi.json'))) {
    throw new Error('locked MIDI roll coverage lacks source and message sidecar')
  }
  cases.push(entry('timed/rollQualification', withCallArg(roll.source, 'roll', 'speed', '5'),
    { ...roll.origin, generator: 'locked MIDI roll source with speed 5 and timed capture' },
    'timed', roll.assets, { capture: { ...protocol('timed'), runSeconds: 1, sampleFrames: [600] } }))
  const counts = Object.fromEntries(FAMILIES.map(family => [family, cases.filter(item => item.family === family).length]))
  const corpus = { schemaVersion: 1, sourceManifestSha256: lock.sourceManifestSha256,
    imports: { rustCommit: RUST_COMMIT, qtCommit: QT_COMMIT, upstreamCommit: lock.commit },
    expected: counts, cases: cases.sort((a, b) => a.id < b.id ? -1 : a.id > b.id ? 1 : 0) }
  verifyCorpus(corpus)
  return corpus
  } finally {
    rustArchive?.cleanup()
    qtArchive?.cleanup()
    upstreamArchive?.cleanup()
  }
}

async function main() {
  const mode = process.argv[2] || '--check'
  if (!['--check', '--write'].includes(mode) || process.argv.length > 3) throw new Error('usage: node tools/import-corpus.mjs [--check|--write]')
  const corpus = await makeCorpus()
  const counts = verifyCorpus(corpus)
  if (mode === '--write') writeFileSync(OUT, JSON.stringify(corpus, null, 2) + '\n')
  else if (!existsSync(OUT) || !readFileSync(OUT).equals(Buffer.from(JSON.stringify(corpus, null, 2) + '\n'))) {
    throw new Error('bundled corpus differs from pinned source repositories')
  }
  process.stdout.write(JSON.stringify({ mode, expected: corpus.cases.length, counts,
    sha256: hash(readFileSync(OUT)) }) + '\n')
}

main().catch(error => { process.stderr.write(`${error?.stack || String(error)}\n`); process.exitCode = 1 })
