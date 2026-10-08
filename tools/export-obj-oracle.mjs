#!/usr/bin/env node
// Run the locked OBJ parser and texture packer; keep full-mesh evidence compact.
import { createHash } from 'node:crypto'
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { encode, fetchVerifiedArchive, sourceIdentity } from './export-reference.mjs'

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const SOURCE_PATH = 'shaders/src/runtime/obj-parser.js'
const MESH_DIR = 'share/meshes'
const hash = bytes => createHash('sha256').update(bytes).digest('hex')

// These deliberately exercise the source's 1-based-only index handling, fan
// triangulation, smooth-normal grouping, degenerate fallback and truncation.
const EDGE_CASES = [
  { id: 'negative-and-missing', width: 4, height: 2,
    text: 'v 1 2 3\nvn 0 1 0\nf -1 1//1 nope\n' },
  { id: 'pentagon-explicit-uv-normal', width: 4, height: 3,
    text: 'v 0 0 0\nv 1 0 0\nv 2 1 0\nv 1 2 0\nv 0 1 0\nvt 0 0\nvt 1 0\nvt 1 1\nvt 0.5 1\nvt 0 1\nvn 0 0 1\nf 1/1/1 2/2/1 3/3/1 4/4/1 5/5/1\n' },
  { id: 'smooth-shared-positions', width: 4, height: 2,
    text: 'v 0 0 0\nv 1 0 0\nv 0 1 0\nv 0 0 1\nf 1 2 3\nf 1 4 2\n' },
  { id: 'degenerate-face', width: 2, height: 2,
    text: 'v 0 0 0\nv 0 0 0\nv 0 0 0\nf 1 2 3\n' },
  { id: 'truncated-quad', width: 1, height: 2,
    text: 'v 0 0 0\nv 1 0 0\nv 1 1 0\nv 0 1 0\nf 1 2 3 4\n' },
  { id: 'empty', width: 2, height: 1, text: '# no faces\nv 1 2 3\n' }
]

function floatRecord(values, full) {
  if (!(values instanceof Float32Array)) throw new Error('source returned non-Float32Array mesh data')
  const bytes = Buffer.allocUnsafe(values.length * 4)
  for (let i = 0; i < values.length; i++) bytes.writeFloatLE(values[i], i * 4)
  const result = { length: values.length, encoding: 'float32-little-endian',
    sha256: hash(bytes), head: encode(Array.from(values.subarray(0, Math.min(24, values.length)))),
    tail: encode(Array.from(values.subarray(Math.max(0, values.length - 24)))) }
  if (full) result.values = encode(Array.from(values))
  return result
}

function snapshot(parseOBJ, packMeshDataForTextures, source, width, height, full = false) {
  const mesh = parseOBJ(source.text)
  const packed = packMeshDataForTextures(mesh.positions, mesh.normals, mesh.uvs, width, height)
  if (mesh.positions.length !== mesh.vertexCount * 3 || mesh.normals.length !== mesh.vertexCount * 3 ||
      mesh.uvs.length !== mesh.vertexCount * 2 || packed.vertexCount !== Math.min(mesh.vertexCount, width * height)) {
    throw new Error('locked OBJ parser returned inconsistent mesh lengths')
  }
  return { source, texture: { width, height }, vertexCount: mesh.vertexCount,
    packedVertexCount: packed.vertexCount,
    parsed: { positions: floatRecord(mesh.positions, full), normals: floatRecord(mesh.normals, full),
      uvs: floatRecord(mesh.uvs, full) },
    packed: { positions: floatRecord(packed.positionData, full),
      normals: floatRecord(packed.normalData, full), uvs: floatRecord(packed.uvData, full) } }
}

async function generate(ref, lock) {
  sourceIdentity(ref, lock)
  const sourceBytes = readFileSync(join(ref, SOURCE_PATH))
  const { parseOBJ, packMeshDataForTextures } = await import(pathToFileURL(join(ref, SOURCE_PATH)).href)
  const names = readdirSync(join(ref, MESH_DIR)).filter(name => /^[A-Za-z0-9_-]+\.obj$/.test(name)).sort()
  if (names.length !== 7) throw new Error(`expected seven locked OBJ meshes, found ${names.length}`)
  const builtins = names.map(name => {
    const bytes = readFileSync(join(ref, MESH_DIR, name))
    return { id: name.slice(0, -4), ...snapshot(parseOBJ, packMeshDataForTextures,
      { path: `${MESH_DIR}/${name}`, sha256: hash(bytes), bytes: bytes.length, text: bytes.toString('utf8') },
      256, 256) }
  }).map(item => { delete item.source.text; return item })
  const edgeCases = EDGE_CASES.map(item => ({ id: item.id,
    ...snapshot(parseOBJ, packMeshDataForTextures,
      { text: item.text, sha256: hash(Buffer.from(item.text)) }, item.width, item.height, true) }))
  const result = { schemaVersion: 1, authority: { repository: lock.repository, commit: lock.commit,
    sourceManifestSha256: lock.sourceManifestSha256 },
  implementation: { path: SOURCE_PATH, sha256: hash(sourceBytes), bytes: sourceBytes.length },
  packing: { builtinTextureWidth: 256, builtinTextureHeight: 256, format: 'rgba32float-arrays' },
  builtins, edgeCases }
  return Buffer.from(JSON.stringify(result, null, 2) + '\n')
}

async function main() {
  const [mode = '--check', pathArg = join(ROOT, 'parity/obj-oracle.json')] = process.argv.slice(2)
  if (!['--check', '--write'].includes(mode) || process.argv.length > 4) {
    throw new Error('usage: node tools/export-obj-oracle.mjs [--check|--write] [output.json]')
  }
  const lock = JSON.parse(readFileSync(join(ROOT, 'parity/reference.json')))
  const archive = process.env.NM_REFERENCE_ROOT ? null : fetchVerifiedArchive(lock)
  try {
    const bytes = await generate(resolve(process.env.NM_REFERENCE_ROOT || archive.root), lock)
    const path = resolve(pathArg)
    if (mode === '--check') {
      if (!existsSync(path) || !readFileSync(path).equals(bytes)) {
        throw new Error('OBJ parser oracle differs from locked upstream source')
      }
    } else {
      mkdirSync(dirname(path), { recursive: true })
      writeFileSync(path, bytes)
    }
    process.stdout.write(JSON.stringify({ mode, sha256: hash(bytes), builtins: 7,
      edgeCases: EDGE_CASES.length }) + '\n')
  } finally { archive?.cleanup() }
}

main().catch(error => { process.stderr.write(`${error?.stack || String(error)}\n`); process.exitCode = 1 })
