#!/usr/bin/env node
// Reuse unchanged, hashed source captures when a source-derived corpus grows.
import { copyFileSync, existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { ARTIFACT_KEYS, assertRecord, buildPlan, checkedArtifact, hash, same } from './merge-goldens-core.mjs'

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const json = path => JSON.parse(readFileSync(path, 'utf8'))
const [oldCorpusArg, oldDirArg, selectedDirArg, outDirArg] = process.argv.slice(2)
if (!oldCorpusArg || !oldDirArg || !selectedDirArg || !outDirArg || process.argv.length !== 6) {
  throw new Error('usage: node parity/merge-goldens.mjs <old-corpus.json> <old-goldens-dir> <selected-goldens-dir> <out-dir>')
}

const oldCorpusPath = resolve(oldCorpusArg)
const oldDir = resolve(oldDirArg)
const selectedDir = resolve(selectedDirArg)
const outDir = resolve(outDirArg)
if (new Set([oldDir, selectedDir, outDir]).size !== 3) throw new Error('golden directories must be distinct')

const currentCorpusPath = join(ROOT, 'parity/corpus.json')
const currentCorpusBytes = readFileSync(currentCorpusPath)
const currentCorpus = JSON.parse(currentCorpusBytes)
const oldCorpusBytes = readFileSync(oldCorpusPath)
const oldCorpus = JSON.parse(oldCorpusBytes)
const lock = json(join(ROOT, 'parity/reference.json'))
const stages = json(join(ROOT, 'parity/corpus-stages.json'))
const refusals = json(join(ROOT, 'parity/source-refusals.json'))
const oldLedger = json(join(oldDir, 'goldens.json'))
const selectedLedger = json(join(selectedDir, 'goldens.json'))
const currentSha = hash(currentCorpusBytes)
if (oldCorpus.sourceManifestSha256 !== lock.sourceManifestSha256 ||
    currentCorpus.sourceManifestSha256 !== lock.sourceManifestSha256 ||
    stages.corpusSha256 !== currentSha || refusals.corpusSha256 !== currentSha) {
  throw new Error('corpus, stages, or refusal inventory differs from locked source')
}
for (const [ledger, bytes, corpus] of [[oldLedger, oldCorpusBytes, oldCorpus],
                                      [selectedLedger, currentCorpusBytes, currentCorpus]]) {
  if (ledger.schemaVersion !== 1 || !same(ledger.authority, lock) ||
      ledger.corpusSha256 !== hash(bytes) || !Array.isArray(ledger.cases) ||
      !Number.isSafeInteger(ledger.expected) || ledger.expected !== ledger.cases.length ||
      ledger.cases.length > corpus.cases.length) {
    throw new Error('golden ledger does not match its complete locked corpus selection')
  }
}
if (oldLedger.expected !== oldCorpus.cases.length ||
    !oldLedger.cases.every((record, index) => record.id === oldCorpus.cases[index].id)) {
  throw new Error('previous golden ledger is not the complete previous corpus')
}
const refusalIds = new Set(refusals.cases.map(item => item.id))

function copyRecord(record, item, sourceDir) {
  assertRecord(record, item, refusalIds)
  const clone = structuredClone(record)
  for (const key of ARTIFACT_KEYS) {
    for (const descriptor of clone[key] || []) {
      const { path, name } = checkedArtifact(descriptor, sourceDir, item.id)
      const target = join(outDir, name)
      mkdirSync(dirname(target), { recursive: true })
      if (existsSync(target)) {
        if (hash(readFileSync(target)) !== descriptor.sha256) throw new Error(`destination artifact differs: ${target}`)
      } else copyFileSync(path, target)
      descriptor.path = target
    }
  }
  return clone
}

const plan = buildPlan(currentCorpus.cases, oldCorpus.cases, oldLedger.cases, selectedLedger.cases)
const records = []
let reused = 0
let captured = 0
for (const row of plan) {
  records.push(copyRecord(row.record, row.item, row.reused ? oldDir : selectedDir))
  if (row.reused) reused++
  else captured++
}
const result = { schemaVersion: 1, authority: lock, corpusSha256: currentSha,
  expected: currentCorpus.cases.length, cases: records }
mkdirSync(outDir, { recursive: true })
const path = join(outDir, 'goldens.json')
writeFileSync(`${path}.tmp`, JSON.stringify(result, null, 2) + '\n')
renameSync(`${path}.tmp`, path)
process.stdout.write(JSON.stringify({ expected: records.length, reused, captured,
  refused: records.filter(record => record.status === 'fail').map(record => record.id),
  corpusSha256: currentSha }) + '\n')
