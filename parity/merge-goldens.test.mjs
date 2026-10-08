import assert from 'node:assert/strict'
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'
import { ARTIFACT_KEYS, assertRecord, buildPlan, checkedArtifact, hash } from './merge-goldens-core.mjs'

const item = (id, sourceSha256 = 'source') => ({ id, sourceSha256,
  source: 'search user\nsolid().write(o0)\n', capture: { frames: 8 } })
const record = (caseItem, status = 'ok') => ({ id: caseItem.id,
  sourceSha256: caseItem.sourceSha256, capture: caseItem.capture, backend: 'WebGPU',
  status, images: status === 'ok' ? [{ path: 'presented.png' }] : undefined })

test('unchanged successful captures can be reused, but every new or changed case needs a fresh capture', () => {
  const old = item('micro/old')
  const added = item('micro/new')
  assert.deepEqual(buildPlan([old, added], [old], [record(old)], [record(added)]).map(row => row.reused), [true, false])
  assert.throws(() => buildPlan([old, added], [old], [record(old)], []), /lacks a fresh source capture: micro\/new/)
  assert.throws(() => buildPlan([item('micro/old', 'changed')], [old], [record(old)], []), /lacks a fresh source capture/)
  assert.throws(() => buildPlan([old], [old], [record(old, 'fail')], []), /lacks a fresh source capture/)
  assert.throws(() => buildPlan([old], [old], [record(old)], [record(old), record(old)]), /invalid selected case/)
})

test('a fresh record must match the exact source, protocol and backend; unexpected failures stay red', () => {
  const source = item('micro/new')
  assert.doesNotThrow(() => assertRecord(record(source), source, new Set()))
  assert.throws(() => assertRecord({ ...record(source), sourceSha256: 'stale' }, source, new Set()), /differs from current case/)
  assert.throws(() => assertRecord({ ...record(source), capture: { frames: 7 } }, source, new Set()), /differs from current case/)
  assert.throws(() => assertRecord({ ...record(source), backend: 'WebGL2' }, source, new Set()), /differs from current case/)
  assert.throws(() => assertRecord(record(source, 'fail'), source, new Set()), /unexpected source failure/)
  assert.throws(() => assertRecord({ ...record(source), images: [] }, source, new Set()), /lacks presented images/)
})

test('artifact paths and bytes must match the selected source ledger', () => {
  const dir = mkdtempSync(join(tmpdir(), 'nm-merge-goldens-'))
  const inRoot = join(dir, 'goldens')
  const outside = join(dir, 'outside.png')
  const valid = join(inRoot, 'micro', 'new.frame8.png')
  try {
    mkdirSync(join(inRoot, 'micro'), { recursive: true })
    writeFileSync(valid, Buffer.from('presented image'))
    writeFileSync(outside, Buffer.from('presented image'))
    const descriptor = { path: valid, sha256: hash(Buffer.from('presented image')) }
    assert.equal(checkedArtifact(descriptor, inRoot, 'micro/new').path, valid)
    assert.throws(() => checkedArtifact({ ...descriptor, sha256: hash('stale') }, inRoot, 'micro/new'), /differs from source ledger/)
    assert.throws(() => checkedArtifact({ ...descriptor, path: outside }, inRoot, 'micro/new'), /differs from source ledger/)
  } finally { rmSync(dir, { recursive: true, force: true }) }
})

test('same-run volume inputs are copied and SHA-verified as source artifacts', () => {
  assert.ok(ARTIFACT_KEYS.includes('hostVolumes'))
  const dir = mkdtempSync(join(tmpdir(), 'nm-merge-volume-'))
  const inRoot = join(dir, 'goldens')
  const volume = join(inRoot, 'micro', 'sampled3dProbe.host.node_0_volume.frame0.rgba8')
  try {
    mkdirSync(join(inRoot, 'micro'), { recursive: true })
    writeFileSync(volume, Buffer.alloc(2048, 7))
    const descriptor = { path: volume, sha256: hash(Buffer.alloc(2048, 7)) }
    assert.equal(checkedArtifact(descriptor, inRoot, 'micro/sampled3dProbe').path, volume)
    writeFileSync(volume, Buffer.alloc(2048, 8))
    assert.throws(() => checkedArtifact(descriptor, inRoot, 'micro/sampled3dProbe'), /differs from source ledger/)
  } finally { rmSync(dir, { recursive: true, force: true }) }
})
