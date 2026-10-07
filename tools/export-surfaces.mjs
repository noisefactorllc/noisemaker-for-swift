#!/usr/bin/env node
// Run the authority's surface binding methods without a GPU backend.
import { readFileSync, mkdirSync, writeFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { fetchVerifiedArchive, sourceIdentity } from './export-reference.mjs'
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const lock = JSON.parse(readFileSync(join(root, 'parity/reference.json'), 'utf8'))
const archive = process.env.NM_REFERENCE_ROOT ? null : fetchVerifiedArchive(lock)
try {
  const ref = resolve(process.env.NM_REFERENCE_ROOT || archive.root)
  sourceIdentity(ref, lock)
  const { Pipeline } = await import(pathToFileURL(join(ref, 'shaders/src/runtime/pipeline.js')).href)
  const cases = []
  for (const surface of ['state', 'o0', 'points_trail_node_2', 'custom']) {
    for (const repeat of [1, 2, 3, 4]) {
      const p = Object.create(Pipeline.prototype)
      p.surfaces = new Map([[surface, {read: `global_${surface}_read`, write: `global_${surface}_write`} ]])
      p.frameIndex = 0
      const frames = []
      for (let frame = 0; frame < 2; frame++) {
        p.frameReadTextures = new Map([...p.surfaces].map(([name,s]) => [name,s.read]))
        p.frameWriteTextures = new Map([...p.surfaces].map(([name,s]) => [name,s.write]))
        const steps = []
        const pass = { outputs: {color: `global_${surface}`} }
        for (let step = 0; step <= repeat; step++) {
          steps.push({read:p.frameReadTextures.get(surface),write:p.frameWriteTextures.get(surface)})
          const state = {writeSurfaces:Object.fromEntries(p.frameWriteTextures)}
          p.updateFrameSurfaceBindings(pass, state)
          if (step > 0 && repeat > 1) p.adoptIterationBindings(pass)
        }
        const finalRead = p.frameReadTextures.get(surface)
        p.swapBuffers()
        frames.push({steps,finalRead,nextRead:p.surfaces.get(surface).read,nextWrite:p.surfaces.get(surface).write})
        p.frameIndex++
      }
      cases.push({surface,repeat,frames})
    }
  }
  const output = resolve(process.argv[2] || join(root, '.build/reference/surfaces.json'))
  mkdirSync(dirname(output), {recursive:true})
  writeFileSync(output, JSON.stringify({reference:lock,cases},null,2)+'\n')
  console.log(`Surface oracle: ${cases.length} cases, two frames each`)
} finally { archive?.cleanup() }
