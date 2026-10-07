#!/usr/bin/env node
// Locked upstream lexer oracle for the native Swift frontend.
import { createHash } from 'node:crypto'
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { runInNewContext } from 'node:vm'
import { fetchVerifiedArchive, sourceIdentity } from './export-reference.mjs'

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const lock = JSON.parse(readFileSync(join(root, 'parity/reference.json'), 'utf8'))
const sha256 = value => createHash('sha256').update(value).digest('hex')
const cases = [
  ['empty', ''],
  ['basic program', 'search synth\nsolid(color: [0.2, 0.6, 0.9]).write(o0)\nrender(o0)\n'],
  ['keywords', 'let render write write3d true false if elif else break continue return search subchain _other'],
  ['references', 'o0 o7 s0 s42 vol0 vol99 geo7 xyz0 vel2 rgba3 mesh19 foo.o99 foo.s01'],
  ['numeric and punctuation', '.5 1. 12.34 [x,y]:=+-*/;{}() .'],
  ['hex colors', '#abc #A1b2C3 #01234567'],
  ['quoted strings', '"a\\"b" \'c\\\'d\' "😀"'],
  ['triple string legacy location', '/* a\nb */ search synth\n"""\nmulti\nline\n""" render(o0)'],
  ['CRLF tab and UTF16', '// 😀\r\nsearch synth\r\n\tlet x = "a\\\nb"; render o0'],
  ['arrow expression', 'search synth\nlet x = () => (1\n + 2); render o0'],
  ['arrow trim', '() \t=> \t x + (y, z)  , () => z; () => tail'],
  ['source coords after member', '/*x*/\nfoo.o99 "😀"'],
  ['line comment retains carriage return', '// comment\r\nnext'],
  ['inherited keyword token types', 'constructor __proto__ toString valueOf hasOwnProperty'],
  ['unexpected after CRLF tab UTF16', '// 😀\r\n\t@'],
  ['unterminated double string', '"abc'],
  ['unterminated single string', " 'abc\nnext"],
  ['unterminated triple string', '\n  """a\nb'],
  ['unterminated block comment', '\n /* a\nb'],
  ['output range', 'search synth\nrender(o99)'],
  ['leading zero output range', 'o00'],
  ['bad hex length', '#ab'],
  ['UTF16 legacy error column', '"😀" @'],
  ['unquoted astral error raw UTF16', '😀'],
  ['multiline function error position', '() => (1\n + 2), @'],
  ['escaped LF legacy error', '"a\\\nb" @']
]

async function main() {
  const archive = process.env.NM_REFERENCE_ROOT ? null : fetchVerifiedArchive(lock)
  try {
    const ref = resolve(process.env.NM_REFERENCE_ROOT || archive.root)
    sourceIdentity(ref, lock, !!archive)
    const lexerPath = join(ref, 'shaders/src/lang/lexer.js')
    const compilerPath = join(ref, 'shaders/src/runtime/compiler.js')
    if (!existsSync(lexerPath) || !existsSync(compilerPath)) throw new Error('locked lexer/compiler source missing')
    const { lex } = await import(pathToFileURL(lexerPath).href)
    // hashSource is private upstream. Extract its complete top-level function
    // from the verified pinned source, so expected hashes execute that source.
    const compilerSource = readFileSync(compilerPath, 'utf8')
    const hashDefinition = compilerSource.match(/^function hashSource\(source\) \{[\s\S]*?^\}/m)?.[0]
    if (!hashDefinition) throw new Error('locked compiler hashSource definition missing')
    const hashSource = runInNewContext(`(${hashDefinition})`)
    const results = cases.map(([name, source]) => {
      const item = { name, source, hash: hashSource(source) }
      try {
        // position is nonenumerable on the upstream token, so copy explicitly.
        item.tokens = lex(source).map(token => ({
          ...token,
          type: String(token.type),
          ...(typeof token.type === 'string' ? {} : { jsTypeKind: typeof token.type }),
          position: token.position
        }))
      } catch (error) {
        if (error?.name !== 'SyntaxError' || !error.diagnostic) throw error
        const messageUTF16 = Array.from({ length: error.message.length }, (_, i) => error.message.charCodeAt(i))
        // Swift String cannot contain a lone surrogate; keep exact code units
        // separately and use the same replacement display text on both sides.
        const message = new TextDecoder().decode(new TextEncoder().encode(error.message))
        item.error = { message, diagnostic: { ...error.diagnostic, message, messageUTF16 } }
      }
      return item
    })
    const out = resolve(process.argv[2] || join(root, '.build/reference/lexer.json'))
    mkdirSync(dirname(out), { recursive: true })
    writeFileSync(out, JSON.stringify({
      authority: {
        commit: lock.commit,
        sourceManifestSha256: lock.sourceManifestSha256,
        lexerSha256: sha256(readFileSync(lexerPath)),
        compilerSha256: sha256(readFileSync(compilerPath))
      },
      cases: results
    }, null, 2) + '\n')
    process.stdout.write(JSON.stringify({ output: out, cases: results.length, errors: results.filter(item => item.error).length }) + '\n')
  } finally {
    archive?.cleanup()
  }
}

main().catch(error => { process.stderr.write(`${error?.stack || error}\n`); process.exitCode = 1 })
