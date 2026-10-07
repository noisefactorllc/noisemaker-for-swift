#!/usr/bin/env node
// Locked upstream parser oracle for the native Swift frontend.
import { createHash } from 'node:crypto'
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { encode, fetchVerifiedArchive, sourceIdentity } from './export-reference.mjs'

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const lock = JSON.parse(readFileSync(join(root, 'parity/reference.json'), 'utf8'))
const sha256 = value => createHash('sha256').update(value).digest('hex')
const cases = [
  ['empty missing search', ''],
  ['basic chain', 'search synth\nnoise(seed: 1).grain().write(o0)\nrender(o0)'],
  ['search multiple namespaces', 'search synth, filter, mixer\nnoise().write(o0)'],
  ['comments', '// lead\nsearch synth\n/* before */ noise() // between\n .grain().write(o0) // trailing'],
  ['let arithmetic', 'search synth\nlet x = 1 + 2 * (3 - 4); let y = -2'],
  ['negative zero', 'search synth\nlet z = -0; let values = [-0, 1 / -0]'],
  ['arrays and colors', 'search synth\nlet a = [1, 2, #aBc, #12345678]; solid(color: [0.2, 0.3, 0.4]).write(o0)'],
  ['enums and member keywords', 'search synth\nlet a = oscKind.sine; let b = disp.source.o1; let c = Math.PI'],
  ['arrow function', 'search synth\nlet fn = () => (x + 1)\nnoise(scale: fn).write(o0)'],
  ['oscillator', 'search synth\nlet v = osc(type: oscKind.sine, min: 1, max: 3, speed: 2)'],
  ['effect osc', 'search synth\nosc(freq: 2).write(o0)'],
  ['read and write3d', 'search synth3d\nread3d(vol0, geo0).render3d().write3d(vol0, geo0)'],
  ['read skip', 'search synth\nread(tex: o1, _skip: true).write(o0)'],
  ['subchain', 'search synth\nnoise().subchain(name: "soft", id: "s1") { .blur(radius: 2) .grain() }.write(o0)'],
  ['subchain default warnings', 'search synth\nnoise().subchain(foo: "ignored", name: "first" name: "last") { .grain() }.write(o0)'],
  ['subchain strict unknown', 'search synth\nnoise().subchain(foo: "ignored") { .grain() }.write(o0)', true],
  ['subchain strict duplicate', 'search synth\nnoise().subchain(name: "a", name: "b") { .grain() }.write(o0)', true],
  ['subchain strict separator', 'search synth\nnoise().subchain(name: "a" id: "b") { .grain() }.write(o0)', true],
  ['if elif else', 'search synth\nif (true) { noise().write(o0) } elif (false) { break } else { continue }'],
  ['return nested call', 'search synth\nif (true) { return noise(seed: 1) }'],
  ['nested chain expression', 'search synth\nlet x = noise().grain(); blend(src: x).write(o0)'],
  ['from override', 'search synth\nlet x = from(synth, noise(seed: 1))'],
  ['midi automation', 'search synth\nlet x = midi(1, mode: midiMode.velocity, min: 0, max: 1)'],
  ['audio automation', 'search synth\nlet x = audio(audioBand.low, min: 0, max: 1)'],
  ['missing search', 'noise().write(o0)'],
  ['bad search namespace', 'search bogus\nnoise()'],
  ['duplicate render', 'search synth\nrender(o0) render(o1)'],
  ['inline namespace', 'search synth\nsynth.noise().write(o0)'],
  ['write in expression', 'search synth\nlet x = noise().write(o0)'],
  ['bad output target', 'search synth\nnoise().write(s0)'],
  ['bad subchain body', 'search synth\nnoise().subchain(name: "x") { blur() }.write(o0)'],
  ['missing array bracket', 'search synth\nlet x = [1, 2'],
  ['bad number expression', 'search synth\nlet x = [1] + 2'],
  ['CRLF UTF16 diagnostic', '// 😀\r\nsearch synth\r\n\tnoise().write(s0)']
]

cases.push(
  ['expect opening paren', 'search synth\nrender o0'],
  ['expect closing paren EOF', 'search synth\nrender(o0'],
  ['expect identifier', 'search synth\nlet = 1'],
  ['expect assignment', 'search synth\nlet x 1'],
  ['expect block', 'search synth\nif(true) return 1'],
  ['expect end of input', 'search synth\nrender(o0) xyz'],
  ['expect call close', 'search synth\nfoo(1'],
  ['expect write3d separator', 'search synth\nfoo().write3d(tex3d0 geo0)'],
  ['expect CRLF tab', '// 😀\r\nsearch synth\r\n\trender(o0'],
  ['expect UTF16 column', 'search synth\nlet x = "😀"; render o0'],
  ['multiline function legacy drift', 'search synth\nlet x = () => (1\n + 2); render o0'],
  ['escaped LF legacy drift', 'search synth\nlet x = "a\\\nb"; render o0'],
  ['osc bad parameter', 'search synth\nlet x = osc(bogus: 1)'],
  ['midi no channel', 'search synth\nlet x = midi()'],
  ['midi unknown keyword', 'search synth\nlet x = midi(bogus: 1)'],
  ['midi channel zone conflict', 'search synth\nlet x = midi(1, zone: 1)'],
  ['midi missing name for id', 'search synth\nlet x = midi(1, id: "port")'],
  ['midi bad name type', 'search synth\nlet x = midi(1, name: 1)'],
  ['midi empty name', 'search synth\nlet x = midi(1, name: "")'],
  ['audio no band', 'search synth\nlet x = audio()'],
  ['audio unknown keyword', 'search synth\nlet x = audio(bogus: 1)'],
  ['audio missing channel for name', 'search synth\nlet x = audio(1, name: "device")'],
  ['audio missing name for id', 'search synth\nlet x = audio(1, id: "device")'],
  ['from keyword forbidden', 'search synth\nlet x = from(namespace: synth, call: noise())'],
  ['from missing call', 'search synth\nlet x = from(synth, 1)'],
  ['caller token missing position', 'search synth\nrender o0', false, true],
  ['caller token automation error', 'search synth\nlet x = midi()', false, true],
  ['caller token numeric AST error', 'search synth\nlet x = [1] + 2', false, true]
)

cases.push(
  ['prototype keyword argument', 'search synth\nfoo(__proto__: 1)'],
  ['constructor keyword argument', 'search synth\nfoo(constructor: 1)'],
  ['toString keyword argument', 'search synth\nfoo(toString: 1)'],
  ['constructor assignment name', 'search synth\nlet constructor = 1'],
  ['constructor assignment value', 'search synth\nlet x = constructor'],
  ['prototype member call', 'search synth\nfoo().__proto__()'],
  ['constructor search namespace', 'search constructor\nfoo()']
)

async function main() {
  const archive = process.env.NM_REFERENCE_ROOT ? null : fetchVerifiedArchive(lock)
  try {
    const ref = resolve(process.env.NM_REFERENCE_ROOT || archive.root)
    sourceIdentity(ref, lock, !!archive)
    const lexerPath = join(ref, 'shaders/src/lang/lexer.js')
    const parserPath = join(ref, 'shaders/src/lang/parser.js')
    const tagsPath = join(ref, 'shaders/src/runtime/tags.js')
    const { lex } = await import(pathToFileURL(lexerPath).href)
    const { parse } = await import(pathToFileURL(parserPath).href)
    const { VALID_NAMESPACES } = await import(pathToFileURL(tagsPath).href)
    const collectWarnings = (value, found = []) => {
      if (!value || typeof value !== 'object') return found
      if (Array.isArray(value.subchainArgumentDiagnostics)) {
        found.push(...value.subchainArgumentDiagnostics.map(issue => ({ stage: 'parser', ...issue })))
      }
      for (const child of Object.values(value)) collectWarnings(child, found)
      return found
    }
    const results = cases.map(([name, source, strict, callerTokens]) => {
      const item = { name, source, strict: !!strict, callerTokens: !!callerTokens }
      try {
        const tokens = callerTokens ? lex(source).map(({ type, lexeme, line, col }) => ({ type, lexeme, line, col })) : lex(source)
        const ast = parse(tokens, strict ? { subchainArguments: 'strict' } : {})
        item.ast = encode(ast)
        item.warnings = collectWarnings(ast)
      }
      catch (error) {
        if (error?.name !== 'SyntaxError' || !error.diagnostic) throw error
        item.error = { message: error.message, diagnostic: error.diagnostic }
      }
      return item
    })
    const out = resolve(process.argv[2] || join(root, '.build/reference/parser.json'))
    mkdirSync(dirname(out), { recursive: true })
    writeFileSync(out, JSON.stringify({
      authority: {
        commit: lock.commit,
        sourceManifestSha256: lock.sourceManifestSha256,
        lexerSha256: sha256(readFileSync(lexerPath)),
        parserSha256: sha256(readFileSync(parserPath)),
        tagsSha256: sha256(readFileSync(tagsPath)),
        namespaces: [...VALID_NAMESPACES]
      }, cases: results
    }, null, 2) + '\n')
    process.stdout.write(JSON.stringify({ output: out, cases: results.length, errors: results.filter(item => item.error).length }) + '\n')
  } finally { archive?.cleanup() }
}

main().catch(error => { process.stderr.write(`${error?.stack || error}\n`); process.exitCode = 1 })
