import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import test from 'node:test'

const root = new URL('../', import.meta.url).pathname
const oracle = JSON.parse(readFileSync(join(root, 'parity/parameter-updates.json')))
const lock = JSON.parse(readFileSync(join(root, 'parity/reference.json')))
const hash = text => createHash('sha256').update(text).digest('hex')
const unpack = value => value?.$type === 'object' || value?.$type === 'map'
  ? Object.fromEntries(value.entries.map(([key, nested]) => [key, unpack(nested)]))
  : Array.isArray(value) ? value.map(unpack) : value
const fixture = id => oracle.cases.find(item => item.id === id)
const pass = (item, stage, id) => unpack(item[stage].passes.find(row => row.id === id).uniforms)
const texture = (item, stage, id) => unpack(item[stage].textures)[id]

test('per-step oracle is bound to the pinned source and existing corpus', () => {
  assert.equal(oracle.authority.commit, lock.commit)
  assert.equal(oracle.authority.sourceManifestSha256, lock.sourceManifestSha256)
  assert.equal(new Set(oracle.cases.map(item => item.id)).size, 22)
  assert.equal(new Set(oracle.refusals.map(item => item.id)).size, 5)
  assert.equal(new Set([...oracle.cases, ...oracle.refusals].map(item => item.id)).size, 27)
  for (const item of [...oracle.cases, ...oracle.refusals]) {
    assert.equal(hash(item.source), item.sourceSha256)
    assert.equal(item.originCaseId === 'coverage/classicNoisedeck_cellNoise' ||
      !item.id.startsWith('palette-'), true)
  }
})

test('same-effect updates isolate the selected step and honor alias, scope, and palette semantics', () => {
  const same = fixture('same-effect-step')
  assert.equal(pass(same, 'before', 'node_1_pass_0').radiusX, 5)
  assert.equal(pass(same, 'after', 'node_1_pass_0').radiusX, 5)
  assert.equal(pass(same, 'after', 'node_2_pass_0').radiusX, 17)
  assert.equal(pass(same, 'after', 'node_2_pass_1').radiusX, 17)

  const alias = fixture('uniform-alias')
  assert.equal(pass(alias, 'after', 'node_3_pass_0').mixAmt, 37)
  assert.deepEqual(unpack(alias.after.passes.find(row => row.id === 'node_3_pass_0').uniformAliases),
    { mixAmt: 'mix' })

  const volume = fixture('inherited-volume')
  assert.equal(pass(volume, 'after', 'node_1_pass_0').volumeSize, 32)
  assert.equal(pass(volume, 'after', 'node_1_pass_0').volumeSize_chain_0, 32)
  assert.equal(texture(volume, 'after', 'node_0_volumeCache').height, 1024)
  assert.equal(texture(fixture('scoped-zoom'), 'after', 'global_ca_state_chain_0_read').width, 32)
  assert.equal(texture(fixture('node-state-size'), 'after', 'global_xyz_node_1_read').width, 128)
  assert.deepEqual(pass(fixture('host-media-dimensions'), 'after', 'node_0_pass_0').imageSize,
    [768, 576])

  const palette = pass(fixture('palette-post-write'), 'after', 'node_0_pass_0')
  assert.equal(palette.palette, 12)
  assert.deepEqual(palette.paletteOffset, [0, 0, 0.43])
  assert.equal(palette.paletteMode, 1)

  assert.equal(pass(fixture('int-string-prefix'), 'after', 'node_0_pass_0').octaves, 12)
  assert.deepEqual(pass(fixture('int-negative-half'), 'after', 'node_0_pass_0').octaves,
    { $type: 'number', value: '-0' })
  assert.equal(pass(fixture('float-string-prefix'), 'after', 'node_0_pass_0').scaleX, 12.5)
})

test('source palette boundaries retain derived uniforms or reject malformed indexes', () => {
  const palette = item => pass(item, 'after', 'node_0_pass_0')
  const before = pass(fixture('palette-zero'), 'before', 'node_0_pass_0')
  for (const [id, value] of [
    ['palette-zero', 0], ['palette-negative', -1], ['palette-above-count', 56],
    ['palette-positive-infinity', { $type: 'number', value: 'Infinity' }],
    ['palette-negative-infinity', { $type: 'number', value: '-Infinity' }],
    ['palette-fractional-above-count', 55.5], ['palette-false', false],
    ['palette-null', null]
  ]) {
    const after = palette(fixture(id))
    assert.deepEqual(after.palette, value, id)
    for (const name of ['paletteOffset', 'paletteAmp', 'paletteFreq', 'palettePhase', 'paletteMode']) {
      assert.deepEqual(after[name], before[name], `${id}: ${name}`)
    }
  }
  assert.equal(palette(fixture('palette-numeric-string')).palette, '2')
  assert.deepEqual(palette(fixture('palette-numeric-string')).paletteOffset, [0.5, 0.5, 0.5])
  for (const [id, value] of [
    ['palette-bom-numeric-string', '\uFEFF2'],
    ['palette-nbsp-numeric-string', '\u00A02']
  ]) {
    assert.equal(palette(fixture(id)).palette, value, id)
    assert.deepEqual(palette(fixture(id)).paletteOffset, [0.5, 0.5, 0.5], id)
  }
  assert.equal(palette(fixture('palette-true')).palette, true)
  assert.deepEqual(palette(fixture('palette-true')).paletteOffset, [0.93, 0.97, 0.52])

  for (const [id, value] of [
    ['palette-refusal-fractional-positive', 1.5],
    ['palette-refusal-fractional-below-one', 0.5],
    ['palette-refusal-nan', { $type: 'number', value: 'NaN' }],
    ['palette-refusal-malformed-string', '2px'],
    ['palette-refusal-nel-numeric-string', '\u00852']
  ]) {
    const refusal = oracle.refusals.find(item => item.id === id)
    assert.equal(refusal.error.name, 'TypeError', id)
    assert.deepEqual(palette(refusal).palette, value, `${id}: source writes palette before throwing`)
    assert.deepEqual(palette(refusal).paletteOffset, before.paletteOffset, id)
  }
})
