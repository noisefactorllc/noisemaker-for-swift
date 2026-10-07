#!/usr/bin/env node
import { readFileSync, mkdirSync, writeFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { fetchVerifiedArchive, sourceIdentity, encode } from './export-reference.mjs'
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const lock = JSON.parse(readFileSync(join(root, 'parity/reference.json'), 'utf8'))
const archive = process.env.NM_REFERENCE_ROOT ? null : fetchVerifiedArchive(lock)
try {
  const ref = resolve(process.env.NM_REFERENCE_ROOT || archive.root)
  sourceIdentity(ref, lock)
  const { WebGPUBackend } = await import(pathToFileURL(join(ref, 'shaders/src/runtime/backends/webgpu.js')).href)
  const backend = Object.create(WebGPUBackend.prototype)
  const cases = [
    {name:'mixed',slots:3, values:{gain:0.25,enabled:true,uv:[0.125,0.75],direction:[1,-2,3],alpha:0.6,color:[0.2,0.4,0.8,1]},
      layout:{gain:{slot:0,components:'x'},enabled:{slot:0,components:'y'},uv:{slot:0,components:'zw'},
        direction:{slot:1,components:'xyz'},alpha:{slot:1,components:'w'},color:{slot:2,components:'xyzw'}}},
    {name:'numeric rounding',slots:1, values:{rgba:[-0,1/3,-1/7,16777217]},layout:{rgba:{slot:0,components:'xyzw'}}},
    {name:'false and padding',slots:3,values:{flag:false,value:19.125},layout:{flag:{slot:0,components:'w'},value:{slot:2,components:'z'}}},
    {name:'global frame fallback',slots:1,values:{},globals:{time:0.25,resolution:[257,129],frame:7},
      layout:{time:{slot:0,components:'x'},resolution:{slot:0,components:'yz'},frame:{slot:0,components:'w'}}}
  ]
  const results = cases.map(fixture => ({...fixture, values:encode(fixture.values),layout:encode(fixture.layout),
    bytes:[...backend.packUniformsWithLayout({...fixture.globals,...fixture.values},fixture.layout)]}))
  const output = resolve(process.argv[2] || join(root,'.build/reference/uniforms.json'))
  mkdirSync(dirname(output),{recursive:true})
  writeFileSync(output,JSON.stringify({reference:lock,cases:results},null,2)+'\n')
  console.log(`Uniform oracle: ${results.length} byte fixtures`)
} finally { archive?.cleanup() }
