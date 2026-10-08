import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { readFileSync } from 'node:fs'
import { test } from 'node:test'

const root = new URL('../parity/inputs/', import.meta.url)
const payload = JSON.parse(readFileSync(new URL('audio-v1.json', root), 'utf8'))
const sha256 = bytes => createHash('sha256').update(bytes).digest('hex')

test('source audio host snapshots preserve 128 analyser values and exact float32 bytes', () => {
  assert.equal(payload.sampleCount, 128)
  assert.equal(payload.frame, 0)
  assert.equal(payload.updatePolicy, 'static-before-frame-1')
  assert.equal(payload.shaderFormat, 'array<vec4<f32>,32>')
  for (const [name, samples] of [['waveform', payload.waveformBytes],
    ['spectrum', payload.spectrumBytes]]) {
    assert.equal(samples.length, 128)
    assert.ok(samples.every(value => Number.isInteger(value) && value >= 0 && value <= 255))
    assert.ok(new Set(samples).size > 32)
    const descriptor = payload[`${name}F32`]
    const bytes = readFileSync(new URL(descriptor.path, root))
    assert.equal(bytes.length, 512)
    assert.equal(descriptor.bytes, bytes.length)
    assert.equal(sha256(bytes), descriptor.sha256)
    for (let index = 0; index < 128; index++) {
      assert.equal(bytes.readFloatLE(index * 4), Math.fround(samples[index] / 255))
    }
  }
})
