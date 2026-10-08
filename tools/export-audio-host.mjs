#!/usr/bin/env node
// Source-executed host audio samples for the scope/spectrum render fixtures.
import { createHash } from 'node:crypto'
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { exportAuthority, fetchVerifiedArchive } from './export-reference.mjs'

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const OUT = join(ROOT, 'parity/inputs')
const sha256 = bytes => createHash('sha256').update(bytes).digest('hex')
const waveformBytes = Array.from({ length: 128 }, (_, i) => 48 + 5 * Math.abs((i % 64) - 32))
const spectrumBytes = Array.from({ length: 128 }, (_, i) => 32 + Math.floor(192 * (127 - i) / 127))

function f32le(values) {
  const bytes = Buffer.alloc(values.length * 4)
  for (let index = 0; index < values.length; index++) bytes.writeFloatLE(values[index], index * 4)
  return bytes
}

async function main() {
  const mode = process.argv[2] || '--check'
  if (!['--check', '--write'].includes(mode) || process.argv.length > 3) {
    throw new Error('usage: node tools/export-audio-host.mjs [--check|--write]')
  }
  const lock = JSON.parse(readFileSync(join(ROOT, 'parity/reference.json')))
  const fetched = process.env.NM_REFERENCE_ROOT ? null : fetchVerifiedArchive(lock)
  const ref = resolve(process.env.NM_REFERENCE_ROOT || fetched.root)
  const scratch = mkdtempSync(join(tmpdir(), 'nm-audio-authority-'))
  try {
    await exportAuthority(ref, scratch, lock, !!fetched || !existsSync(join(ref, '.git')))
    const { AudioState } = await import(pathToFileURL(join(ref, 'shaders/src/runtime/external-input.js')).href)
    const state = new AudioState({ deviceRegistry: false })
    state.setWaveform(Uint8Array.from(waveformBytes))
    state.setSpectrum(Uint8Array.from(spectrumBytes))
    if (state.waveform.length !== 128 || state.spectrum.length !== 128) {
      throw new Error('locked AudioState changed its sample count')
    }
    const waveformF32 = f32le(state.waveform)
    const spectrumF32 = f32le(state.spectrum)
    const payload = {
      schemaVersion: 1,
      authority: { repository: lock.repository, commit: lock.commit,
        sourceManifestSha256: lock.sourceManifestSha256 },
      sourceAPI: 'AudioState.setWaveform/setSpectrum',
      frame: 0,
      updatePolicy: 'static-before-frame-1',
      inputFormat: 'analyser-uint8',
      shaderFormat: 'array<vec4<f32>,32>',
      sampleCount: 128,
      normalization: 'locked AudioState byte/255 rounded to float32',
      waveformBytes,
      spectrumBytes,
      waveformF32: { path: 'audio-v1.waveform.f32le', sha256: sha256(waveformF32), bytes: waveformF32.length },
      spectrumF32: { path: 'audio-v1.spectrum.f32le', sha256: sha256(spectrumF32), bytes: spectrumF32.length }
    }
    const artifacts = [
      ['audio-v1.json', Buffer.from(JSON.stringify(payload, null, 2) + '\n')],
      [payload.waveformF32.path, waveformF32],
      [payload.spectrumF32.path, spectrumF32]
    ]
    if (mode === '--write') mkdirSync(OUT, { recursive: true })
    for (const [name, bytes] of artifacts) {
      const path = join(OUT, name)
      if (mode === '--write') writeFileSync(path, bytes)
      else if (!existsSync(path) || !readFileSync(path).equals(bytes)) {
        throw new Error(`source audio host oracle differs: ${name}`)
      }
    }
    process.stdout.write(JSON.stringify({ mode, artifacts: artifacts.length,
      sha256: sha256(artifacts[0][1]) }) + '\n')
  } finally {
    fetched?.cleanup()
    rmSync(scratch, { recursive: true, force: true })
  }
}

main().catch(error => { process.stderr.write(`${error?.stack || error}\n`); process.exitCode = 1 })
