import test from 'node:test'
import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { authoredInputAssets } from './import-corpus.mjs'

test('upstream roll notes reach the existing MIDI sidecar interface in source order', () => {
  const source = { midiInputs: [{ effect: 'synth/roll', notes: [
    { channel: 1, key: 40, velocity: 110 }, { channel: 1, key: 60, velocity: 75 },
    { channel: 3, key: 67, velocity: 90 }, { channel: 7, key: 36, velocity: 64 },
    { channel: 7, key: 84, velocity: 100 }
  ] }] }
  const assets = authoredInputAssets(source, () => { throw new Error('MIDI must not read a mesh') })
  assert.equal(assets.length, 1)
  assert.match(assets[0].path, /\.midi\.json$/)
  assert.equal(assets[0].sha256, createHash('sha256').update(assets[0].text).digest('hex'))
  assert.deepEqual(JSON.parse(assets[0].text), { messages: [
    [0x90, 40, 110], [0x90, 60, 75], [0x92, 67, 90], [0x96, 36, 64], [0x96, 84, 100]
  ] })
})

test('upstream mesh input uses the authored mesh instead of the builtin default', () => {
  const cube = { path: 'share/meshes/cube.obj', sha256: 'source-hash', text: 'source OBJ bytes' }
  const requests = []
  const assets = authoredInputAssets({ meshInputs: [{ mesh: 'mesh0', path: cube.path }] }, path => {
    requests.push(path)
    return cube
  })
  assert.deepEqual(requests, [cube.path])
  assert.deepEqual(assets, [cube])
})

test('cases without authored inputs preserve their empty sidecars', () => {
  assert.deepEqual(authoredInputAssets({}, () => { throw new Error('unexpected asset read') }), [])
})

test('authored mesh inputs retain the single mesh0 host contract', () => {
  assert.throws(() => authoredInputAssets({ meshInputs: [{ mesh: 'mesh1', path: 'share/meshes/cube.obj' }] },
    () => { throw new Error('unsupported mesh must not be read') }), /mesh0 host surface/)
  assert.throws(() => authoredInputAssets({ meshInputs: [{ mesh: 'mesh0' }, { mesh: 'mesh0' }] },
    () => { throw new Error('unsupported meshes must not be read') }), /mesh0 host surface/)
})
