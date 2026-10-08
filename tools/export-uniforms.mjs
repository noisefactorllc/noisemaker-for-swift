#!/usr/bin/env node
import { readFileSync, mkdirSync, writeFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { createHash } from 'node:crypto'
import { fetchVerifiedArchive, sourceIdentity, encode } from './export-reference.mjs'
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const lock = JSON.parse(readFileSync(join(root, 'parity/reference.json'), 'utf8'))
const archive = process.env.NM_REFERENCE_ROOT ? null : fetchVerifiedArchive(lock)
try {
  const ref = resolve(process.env.NM_REFERENCE_ROOT || archive.root)
  sourceIdentity(ref, lock)
  const { WebGPUBackend } = await import(pathToFileURL(join(ref, 'shaders/src/runtime/backends/webgpu.js')).href)
  const { Pipeline } = await import(pathToFileURL(join(ref, 'shaders/src/runtime/pipeline.js')).href)
  const backend = Object.create(WebGPUBackend.prototype)
  const frameState = {globalUniforms:{},width:257,height:129,frameIndex:7,externalState:{}}
  Pipeline.prototype.updateGlobalUniforms.call(frameState,0.25,0)
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
  const curl = (await import(pathToFileURL(join(ref,
    'shaders/effects/synth/curl/definition.js')).href)).default
  const derivedInputs = [
    {name:'palette array inference', sourcePath:'shaders/effects/filter/palette/wgsl/palette.wgsl',
      uniformName:'uniforms', values:{paletteIndex:3,rotation:-1,offset:14.25,repeat:2,alpha:0.75,time:0.25}},
    {name:'smooth declared array floor', sourcePath:'shaders/effects/filter/smooth/wgsl/smoothEdge.wgsl',
      uniformName:'uniforms', values:{smoothType:2,threshold:0.375}},
    {name:'CRT annotated named fields and aliases', sourcePath:'shaders/effects/filter/crt/wgsl/crt.wgsl',
      uniformName:'params', values:{resolution:[257,129],time:0.25,speed:1.5,seed:4,alpha:0.8}},
    {name:'colorLab mixed byte struct and JS int wrap',
      sourcePath:'shaders/effects/classicNoisedeck/colorLab/wgsl/colorLab.wgsl',
      uniformName:'u', values:{resolution:[257,129],time:0.25,frame:7.5,colorMode:-1.5,
        palette:4294967297,paletteMode:true,paletteOffset:[0.125,-0.5,1.25],
        paletteAmp:[0.5,0.75,1],invert:true}},
    {name:'colorLab missing fields zero',
      sourcePath:'shaders/effects/classicNoisedeck/colorLab/wgsl/colorLab.wgsl',
      uniformName:'u', values:{resolution:[257,129],time:0.25,frame:0}},
    {name:'curl explicit mixed struct layout', sourcePath:'shaders/effects/synth/curl/wgsl/curl.wgsl',
      uniformName:'u', explicitLayout:curl.uniformLayout,
      values:{resolution:[257,129],time:0.25,aspectRatio:257/129,scale:4,
        seed:7,speed:2,intensity:0.875,tileOffset:[3,5],fullResolution:[512,512]}},
    {name:'params component access after array', uniformName:'params',
      wgsl:'struct DemoParams { data: array<vec4<f32>, 1>, dims: vec4<f32>, }\n' +
        '@group(0) @binding(0) var<uniform> params: DemoParams;\n' +
        'fn useParams() { let width = params.dims.x; let height = params.dims.y; }',
      values:{width:257,height:129}},
    {name:'byte aliases and signed unsigned rounding', uniformName:'u',
      wgsl:'struct DemoUniforms { width: f32, height: f32, channels: f32, ' +
        'channelCount: f32, count: i32, mask: u32, negative: i32, }\n' +
        '@group(0) @binding(0) var<uniform> u: DemoUniforms;\n' +
        'fn useUniforms() { let v = u.width + u.height + u.channels + u.channelCount + ' +
        'f32(u.count + i32(u.mask) + u.negative); }',
      values:{resolution:[257,129],count:1.5,mask:4294967297,negative:-1.5}}
  ]
  const derivedCases = derivedInputs.map(input => {
    const wgsl = input.wgsl ?? readFileSync(join(ref,input.sourcePath),'utf8')
    const escaped = input.uniformName.replace(/[.*+?^${}()|[\]\\]/g,'\\$&')
    const match = new RegExp(`var<uniform>\\s+${escaped}\\s*:\\s*(\\w+)\\s*;`).exec(wgsl)
    if (!match) throw new Error(`${input.name}: uniform declaration missing`)
    const layout = input.explicitLayout || backend.parsePackedUniformLayout(wgsl)
    if (!layout) throw new Error(`${input.name}: source could not infer layout`)
    const merged = {...frameState.globalUniforms,...input.values}
    const packed = backend.packUniformsWithLayout(merged,layout)
    const declaredMin = backend.parseDeclaredUniformBufferSize(wgsl)
    const bufferSize = Math.max(packed.byteLength,declaredMin,16)
    const bytes = [...packed,...new Array(bufferSize-packed.byteLength).fill(0)]
    return {name:input.name,sourcePath:input.sourcePath ?? null,
      sourceSha256:createHash('sha256').update(wgsl).digest('hex'),wgsl,
      uniformName:input.uniformName,type:match[1],
      layoutSource:input.explicitLayout ? 'explicit' : 'inferred',
      layoutKind:layout.type === 'byte' ? 'byte' : 'packed',
      explicitLayout:input.explicitLayout ? encode(input.explicitLayout) : null,
      values:encode(input.values),declaredMin,packedByteLength:packed.byteLength,bytes}
  })
  // Exercise the actual direct-binding branch in createBindGroup, including
  // its value admission/default choice and createSingleUniformBuffer writer.
  // The fake device only captures bytes; it does not reinterpret either rule.
  const directInputs = [
    {name:'missing float',type:'f32',values:{}},
    {name:'invalid object float',type:'f32',values:{value:{fn:'unused'}}},
    {name:'boolean float',type:'f32',values:{value:true}},
    {name:'rounded signed int',type:'i32',values:{value:1.5}},
    {name:'wrapped unsigned int',type:'u32',values:{value:-1.5}},
    {name:'missing vec2',type:'vec2<f32>',values:{}},
    {name:'direct int vector uses float array bytes',type:'vec2<i32>',values:{value:[1,2]}},
    {name:'direct uint vector uses float array bytes',type:'vec3<u32>',values:{value:[1,2,3]}},
    {name:'invalid vec3',type:'vec3f',values:{value:{bad:true}}},
    {name:'missing mat3 identity',type:'mat3x3<f32>',values:{}},
    {name:'null mat3 identity',type:'mat3x3<f32>',values:{value:null}},
    {name:'missing vec4 array',type:'array<vec4<f32>, 3>',values:{}},
    {name:'host vec4 array',type:'array<vec4<f32>, 2>',values:{value:[1,2,3,4,5,6,7,8]}},
    {name:'undefined pass shadows global',type:'f32',values:{value:undefined},globals:{value:7}}
  ]
  globalThis.GPUBufferUsage = {UNIFORM:1,COPY_DST:2}
  const directCases = directInputs.map(input => {
    backend._singleUniformFloat32 = new Float32Array(128)
    backend._singleUniformInt32 = new Int32Array(128)
    backend._singleUniformMat3Float32 = new Float32Array(12)
    backend.activeUniformBuffers = []
    backend.getBufferFromPool = () => null
    backend.device = {
      createBuffer({size}) { return {size,bytes:new Uint8Array(size)} },
      createBindGroup({entries}) { return {entries} }
    }
    backend.queue = {writeBuffer(buffer,at,data,offset,length) {
      buffer.bytes.set(new Uint8Array(data,offset,length),at)
      buffer.written = length
    }}
    const wgsl = `@group(0) @binding(0) var<uniform> value: ${input.type};\n` +
      'fn useValue() { let v = value; }'
    const binding = {group:0,binding:0,type:'uniform',name:'value',typeDecl:input.type}
    const program = {bindings:[binding],pipeline:{getBindGroupLayout(){return {}}}}
    const group = backend.createBindGroup({uniforms:input.values},program,
      {globalUniforms:input.globals || {}})
    const buffer = group.entries[0]?.resource?.buffer
    if (!buffer) throw new Error(`${input.name}: source did not bind uniform`)
    return {name:input.name,type:input.type,wgsl,
      values:encode(input.values),globals:encode(input.globals || {}),
      writtenByteLength:buffer.written,bytes:[...buffer.bytes]}
  })
  const output = resolve(process.argv[2] || join(root,'.build/reference/uniforms.json'))
  mkdirSync(dirname(output),{recursive:true})
  writeFileSync(output,JSON.stringify({reference:lock,cases:results,derivedCases,directCases},null,2)+'\n')
  console.log(`Uniform oracle: ${results.length} explicit + ${derivedCases.length} derived + ${directCases.length} direct byte fixtures`)
} finally { archive?.cleanup() }
