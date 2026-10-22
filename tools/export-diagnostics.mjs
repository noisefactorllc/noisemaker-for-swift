#!/usr/bin/env node
// Invalid-program diagnostics from the locked JS compiler.
import { createHash } from 'node:crypto'
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { exportAuthority, fetchVerifiedArchive } from './export-reference.mjs'

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const OUTPUT = join(ROOT, 'parity/invalid-programs.json')
const sha256 = bytes => createHash('sha256').update(bytes).digest('hex')
const program = body => `search synth, filter, mixer\n${body}\nrender(o0)\n`

const FIXTURES = [
  ['unknown-effect', 'noiz(seed: 1).write(o0)'],
  ['unknown-effect-mid-chain', 'noise().blurr().write(o0)'],
  ['unknown-argument', 'noise(bogus: 1).write(o0)'],
  ['retired-parameter-alias', 'noise(xScale: 4).write(o0)'],
  ['filter-at-chain-root', 'blur().write(o0)'],
  ['starter-with-input', 'noise().noise().write(o0)'],
  ['missing-write', 'noise()'],
  ['string-for-number', 'noise(scaleX: "big").write(o0)'],
  ['undefined-identifier', 'noise(scaleX: big).write(o0)'],
  ['unassigned-variable', 'let v = missing\nnoise(scaleX: v).write(o0)'],
  ['unresolved-enum', 'noise(type: foo.bar).write(o0)'],
  ['read-invalid-surface', 'read(foo).write(o0)'],
  ['read-inline', 'noise().read(o1).write(o0)'],
  ['string-for-boolean', 'noise(ridges: "yes").write(o0)'],
  ['undefined-boolean-identifier', 'noise(ridges: maybe).write(o0)'],
  ['string-for-color', 'solid(color: "red").write(o0)'],
  ['string-for-vec3', 'noise().celShading(lightDirection: "up").write(o0)'],
  ['string-for-surface', 'noise().blendMode(tex: "o1").write(o0)'],
  ['string-for-member', 'noise().channel(channel: "r").write(o0)'],
  ['unquoted-string-parameter', 'noise().text(style: bogus).write(o0)'],
  ['number-for-string-parameter', 'noise().text(style: 3).write(o0)'],
  ['variable-cycle', 'let a1x = b1x\nlet b1x = a1x\nnoise(scaleX: a1x).write(o0)'],
  ['null-variable', 'let v = null\nnoise(scaleX: v).write(o0)'],
  ['read-before-let', 'noise(scaleX: v, scaleY: v).write(o0)\nlet v = 4']
].map(([id, body]) => ({ id, source: program(body) }))

// Valid programs that compileGraph rejects with ERR_EXPANSION_FAILED: the
// runtime does not execute control flow.
const EXPANSION = [
  ['if-block-let-and-comments', 'if (1) {\n// lead\nlet q = 2\nnoise(seed: q).write(o0)\n// tail\n}'],
  ['break-statement', 'noise().write(o0)\nbreak']
].map(([id, body]) => ({ id, source: program(body) }))

// Programs that the locked compiler accepts with warning diagnostics.
const WARNINGS = [
  ['parameter-alias', 'search synth, points, render\nsolid().pointsEmit().flow(fieldTex: o1).pointsRender().write(o0)\nrender(o0)\n']
].map(([id, source]) => ({ id, source }))

// Programs that the locked compiler accepts. The port may not compile them
// yet, but it must never report them as invalid.
const ACCEPTED = [
  ['unresolved-member-identifier', 'noise().channel(channel: qq).write(o0)'],
  ['unresolved-member-path', 'noise().channel(channel: foo.bar).write(o0)'],
  ['color-identifier', 'solid(color: red).write(o0)'],
  ['surface-identifier', 'noise().blendMode(tex: foo).write(o0)']
].map(([id, body]) => ({ id, source: program(body) }))

function runFixture(fixture, api) {
  const validated = api.validate(api.parse(api.lex(fixture.source)))
  const diagnostics = validated.diagnostics.map(item => ({ code: item.code, severity: item.severity,
    message: item.message, location: item.location ? { line: item.location.line,
      column: item.location.column } : null }))
  if (!diagnostics.some(item => item.severity === 'error')) throw new Error(`${fixture.id} has no error`)
  let failure = null
  try { api.compileGraph(fixture.source) } catch (error) { failure = error }
  if (failure?.code !== 'ERR_COMPILATION_FAILED') throw new Error(`${fixture.id} compiled`)
  return { id: fixture.id, source: fixture.source, sourceSha256: sha256(fixture.source), diagnostics }
}

function expansionFixture(fixture, api) {
  const validated = api.validate(api.parse(api.lex(fixture.source)))
  if (validated.diagnostics.length) throw new Error(`${fixture.id} has diagnostics`)
  let failure = null
  try { api.compileGraph(fixture.source) } catch (error) { failure = error }
  if (failure?.code !== 'ERR_EXPANSION_FAILED') throw new Error(`${fixture.id} did not fail expansion`)
  return { id: fixture.id, source: fixture.source, sourceSha256: sha256(fixture.source),
    errors: failure.errors.map(item => item.message) }
}

function warningFixture(fixture, api) {
  const validated = api.validate(api.parse(api.lex(fixture.source)))
  const diagnostics = validated.diagnostics.map(item => ({ code: item.code, severity: item.severity,
    message: item.message, location: item.location ? { line: item.location.line,
      column: item.location.column } : null }))
  if (!diagnostics.length || diagnostics.some(item => item.severity !== 'warning')) {
    throw new Error(`${fixture.id} does not have only warnings`)
  }
  api.compileGraph(fixture.source)
  return { id: fixture.id, source: fixture.source, sourceSha256: sha256(fixture.source), diagnostics }
}

function acceptFixture(fixture, api) {
  const validated = api.validate(api.parse(api.lex(fixture.source)))
  if (validated.diagnostics.some(item => item.severity === 'error')) throw new Error(`${fixture.id} has an error`)
  api.compileGraph(fixture.source)
  return { id: fixture.id, source: fixture.source, sourceSha256: sha256(fixture.source) }
}

async function main() {
  const mode = process.argv[2] || '--check'
  if (!['--check', '--write'].includes(mode) || process.argv.length > 3) {
    throw new Error('usage: node tools/export-diagnostics.mjs [--check|--write]')
  }
  const lock = JSON.parse(readFileSync(join(ROOT, 'parity/reference.json')))
  const fetched = process.env.NM_REFERENCE_ROOT ? null : fetchVerifiedArchive(lock)
  const ref = resolve(process.env.NM_REFERENCE_ROOT || fetched.root)
  const output = mkdtempSync(join(tmpdir(), 'nm-diagnostics-authority-'))
  try {
    await exportAuthority(ref, output, lock, !!fetched || !existsSync(join(ref, '.git')))
    const api = await import(pathToFileURL(join(ref, 'shaders/src/index.js')).href)
    const cases = FIXTURES.map(fixture => runFixture(fixture, api))
    const accepted = ACCEPTED.map(fixture => acceptFixture(fixture, api))
    const expansionFailures = EXPANSION.map(fixture => expansionFixture(fixture, api))
    const warnings = WARNINGS.map(fixture => warningFixture(fixture, api))
    const oracle = { schemaVersion: 1, authority: { repository: lock.repository, commit: lock.commit,
      sourceManifestSha256: lock.sourceManifestSha256 }, cases, accepted, expansionFailures, warnings }
    const bytes = Buffer.from(JSON.stringify(oracle, null, 2) + '\n')
    if (mode === '--write') writeFileSync(OUTPUT, bytes)
    else if (!existsSync(OUTPUT) || !readFileSync(OUTPUT).equals(bytes)) {
      throw new Error('invalid-program diagnostics differ from pinned source')
    }
    process.stdout.write(JSON.stringify({ mode, cases: cases.length, accepted: accepted.length,
      expansionFailures: expansionFailures.length, warnings: warnings.length, sha256: sha256(bytes) }) + '\n')
  } finally {
    fetched?.cleanup()
    rmSync(output, { recursive: true, force: true })
  }
}

main().catch(error => { process.stderr.write(`${error?.stack || error}\n`); process.exitCode = 1 })
