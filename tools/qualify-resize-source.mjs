#!/usr/bin/env node
// Exact source-backend pixels for feedback halves and ordinary persistent textures.
import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { readFileSync } from 'node:fs'
import { resolve, join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { sourceIdentity, sourceManifest } from './export-reference.mjs'

const referenceRoot = process.env.NM_REFERENCE_ROOT
if (!referenceRoot) throw new Error('NM_REFERENCE_ROOT must name the current source checkout')
const root = resolve(referenceRoot)
const lock = JSON.parse(readFileSync(new URL('../parity/reference.json', import.meta.url)))
// Diagnostic probes may use an in-progress checkout; qualification must prove
// the exact committed source and manifest before accepting GPU pixels.
const diagnostic = process.env.NM_UNPINNED_PROBE === '1'
if (!diagnostic) sourceIdentity(root, lock)
const sourceManifestBefore = sourceManifest(root, lock)
if (!diagnostic) assert.equal(sourceManifestBefore.contentSha256, lock.sourceManifestSha256,
  'source manifest before resize captures differs from pinned authority')
const provenance = diagnostic ? { qualification: 'diagnostic-unpinned',
  expectedAuthorityCommit: lock.commit } : { qualification: 'pinned',
  authorityCommit: lock.commit, authorityManifestSha256: lock.sourceManifestSha256 }
process.env.SHADE_VIEWER_ROOT = root
process.env.SHADE_VIEWER_PATH = '/demo/shaders/'
process.env.SHADE_EFFECTS_DIR = join(root, 'shaders/effects')
process.env.SHADE_GLOBALS_PREFIX = '__noisemaker'
process.env.SHADE_HEADLESS = '1'
const { BrowserSession } = await import(pathToFileURL(join(root, 'vendor/shade-mcp/harness/index.js')).href)
const digest = bytes => createHash('sha256').update(Buffer.from(bytes)).digest('hex')

function expectedSource(width, height, variant) {
  const bytes = new Uint8Array(width * height * 4)
  for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) {
    const i = (y * width + x) * 4
    bytes[i] = (x * 41 + variant * 13) % 256
    bytes[i + 1] = (y * 31 + variant * 17) % 256
    bytes[i + 2] = (x * 17 + y * 29 + variant * 19) % 256
    bytes[i + 3] = 255
  }
  return bytes
}

function centerNearest(bytes, width, height, targetWidth, targetHeight) {
  bytes = Uint8Array.from(bytes)
  const output = new Uint8Array(targetWidth * targetHeight * 4)
  for (let y = 0; y < targetHeight; y++) for (let x = 0; x < targetWidth; x++) {
    const sx = Math.min(width - 1, Math.floor((x + 0.5) * width / targetWidth))
    const sy = Math.min(height - 1, Math.floor((y + 0.5) * height / targetHeight))
    output.set(bytes.subarray((sy * width + sx) * 4, (sy * width + sx + 1) * 4),
      (y * targetWidth + x) * 4)
  }
  return output
}

async function runBackend(name) {
  const session = new BrowserSession({ backend: name })
  await session.setup()
  try {
    await session.setBackend(name)
    const page = session.page
    await page.evaluate(() => {
      const editor = document.getElementById('dsl-editor')
      editor.value = 'search synth\nsolid(color: [0.2, 0.6, 0.9]).write(o0)\nrender(o0)'
      editor.dispatchEvent(new Event('input', { bubbles: true }))
      document.getElementById('dsl-run-btn').click()
    })
    await page.waitForFunction(() => {
      const status = document.getElementById('status')?.textContent || ''
      if (/error|failed/i.test(status)) throw new Error(status)
      return window.__noisemakerRenderingPipeline?.backend && /compiled/i.test(status)
    }, null, { timeout: 120000 })
    const capture = await page.evaluate(async backendName => {
      const pipeline = window.__noisemakerRenderingPipeline
      const backend = pipeline.backend
      const actualBackend = backend.getName?.()
      if (actualBackend?.toLowerCase() !== backendName) {
        throw new Error(`requested ${backendName} but source renderer selected ${actualBackend}`)
      }
      const gl = backendName === 'webgl2' ? backend.gl : null
      const adapter = backendName === 'webgpu' ? await navigator.gpu.requestAdapter() : null
      const adapterInfo = adapter?.info
      const device = gl ? (() => {
        const debug = gl.getExtension('WEBGL_debug_renderer_info')
        return { vendor: gl.getParameter(debug?.UNMASKED_VENDOR_WEBGL || gl.VENDOR),
          renderer: gl.getParameter(debug?.UNMASKED_RENDERER_WEBGL || gl.RENDERER),
          version: gl.getParameter(gl.VERSION) }
      })() : { vendor: adapterInfo?.vendor || '',
        architecture: adapterInfo?.architecture || '', device: adapterInfo?.device || '',
        description: adapterInfo?.description || '',
        maxTextureDimension2D: backend.device.limits.maxTextureDimension2D }
      const results = []
      const mips = []
      const sizes = [[7, 5, 13, 9], [13, 9, 7, 5],
        [1, 7, 1, 13], [1, 13, 1, 7], [7, 1, 13, 1], [13, 1, 7, 1]]
      if (backendName === 'webgpu') backend.device.pushErrorScope('validation')
      for (const [width, height, targetWidth, targetHeight] of sizes) {
        for (const kind of ['feedback', 'ordinary']) {
          const ids = kind === 'feedback'
            ? ['__resize_feedback_read', '__resize_feedback_write']
            : ['__resize_ordinary']
          for (const [variant, id] of ids.entries()) {
            const spec = { width, height, format: 'rgba8', persistent: true,
              usage: ['render', 'sample', 'copySrc', 'copyDst'] }
            backend.createTexture(id, spec)
            const pixels = new Uint8Array(width * height * 4)
            for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) {
              const offset = (y * width + x) * 4
              pixels[offset] = (x * 41 + variant * 13) % 256
              pixels[offset + 1] = (y * 31 + variant * 17) % 256
              pixels[offset + 2] = (x * 17 + y * 29 + variant * 19) % 256
              pixels[offset + 3] = 255
            }
            const texture = backend.textures.get(id)
            if (gl) {
              const upload = new Uint8Array(pixels.length)
              for (let y = 0; y < height; y++) {
                upload.set(pixels.subarray(y * width * 4, (y + 1) * width * 4),
                  (height - 1 - y) * width * 4)
              }
              gl.bindTexture(gl.TEXTURE_2D, texture.handle)
              gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, 0, width, height,
                gl.RGBA, gl.UNSIGNED_BYTE, upload)
              gl.bindTexture(gl.TEXTURE_2D, null)
            } else {
              backend.device.queue.writeTexture({ texture: texture.handle }, pixels,
                { bytesPerRow: width * 4, rowsPerImage: height }, [width, height, 1])
            }
            const source = await backend.readPixels(id)
            pipeline.recreateTexturePreserving(id, { ...spec,
              width: targetWidth, height: targetHeight })
            const resized = await backend.readPixels(id)
            results.push({ kind, id, variant, width, height, targetWidth, targetHeight,
              source: Array.from(source.data), resized: Array.from(resized.data) })
            backend.destroyTexture(id)
          }
        }
      }
      for (const [width, height] of [[5, 3], [1, 7]]) {
        const id = `__mip_${width}_${height}`
        backend.createTexture(id, { width, height, format: 'rgba8', mipmaps: true,
          usage: ['render', 'sample', 'copySrc', 'copyDst'] })
        const texture = backend.textures.get(id)
        const pixels = new Uint8Array(width * height * 4)
        for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) {
          const i = (y * width + x) * 4
          pixels[i] = x * 41
          pixels[i + 1] = y * 31
          pixels[i + 2] = x * 17 + y * 29
          pixels[i + 3] = 255
        }
        if (gl) {
          const upload = new Uint8Array(pixels.length)
          for (let y = 0; y < height; y++) {
            upload.set(pixels.subarray(y * width * 4, (y + 1) * width * 4),
              (height - 1 - y) * width * 4)
          }
          gl.bindTexture(gl.TEXTURE_2D, texture.handle)
          gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, 0, width, height,
            gl.RGBA, gl.UNSIGNED_BYTE, upload)
          gl.bindTexture(gl.TEXTURE_2D, null)
        } else {
          backend.device.queue.writeTexture({ texture: texture.handle }, pixels,
            { bytesPerRow: width * 4, rowsPerImage: height }, [width, height, 1])
        }
        backend.generateMipmaps([id])
        if (!gl) await backend.device.queue.onSubmittedWorkDone()
        const levels = []
        for (let level = 0; level < texture.mipLevels; level++) {
          const w = Math.max(1, width >> level), h = Math.max(1, height >> level)
          const bytes = new Uint8Array(w * h * 4)
          if (gl) {
            const fbo = gl.createFramebuffer()
            gl.bindFramebuffer(gl.FRAMEBUFFER, fbo)
            gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0,
              gl.TEXTURE_2D, texture.handle, level)
            if (gl.checkFramebufferStatus(gl.FRAMEBUFFER) !== gl.FRAMEBUFFER_COMPLETE) {
              throw new Error(`WebGL2 mip framebuffer incomplete at level ${level}`)
            }
            const bottomUp = new Uint8Array(bytes.length)
            gl.readPixels(0, 0, w, h, gl.RGBA, gl.UNSIGNED_BYTE, bottomUp)
            for (let y = 0; y < h; y++) {
              bytes.set(bottomUp.subarray((h - 1 - y) * w * 4, (h - y) * w * 4),
                y * w * 4)
            }
            gl.bindFramebuffer(gl.FRAMEBUFFER, null)
            gl.deleteFramebuffer(fbo)
          } else {
            const stride = Math.ceil(w * 4 / 256) * 256
            const buffer = backend.device.createBuffer({ size: stride * h,
              usage: GPUBufferUsage.COPY_DST | GPUBufferUsage.MAP_READ })
            const encoder = backend.device.createCommandEncoder()
            encoder.copyTextureToBuffer({ texture: texture.handle, mipLevel: level },
              { buffer, bytesPerRow: stride, rowsPerImage: h }, [w, h, 1])
            backend.device.queue.submit([encoder.finish()])
            await buffer.mapAsync(GPUMapMode.READ)
            const mapped = new Uint8Array(buffer.getMappedRange())
            for (let y = 0; y < h; y++) {
              bytes.set(mapped.subarray(y * stride, y * stride + w * 4), y * w * 4)
            }
            buffer.unmap()
            buffer.destroy()
          }
          levels.push({ width: w, height: h, bytes: Array.from(bytes) })
        }
        mips.push({ width, height, levels })
        backend.destroyTexture(id)
      }
      const error = backendName === 'webgpu' ? await backend.device.popErrorScope() : null
      return { results, mips, runtimeEnvironment: { backend: actualBackend, device },
        error: error?.message || (gl && gl.getError() !== gl.NO_ERROR
          ? 'WebGL2 error after resize matrix' : null) }
    }, name)
    return { ...capture, runtimeEnvironment: { ...capture.runtimeEnvironment,
      browser: session.browser.version() } }
  } finally {
    await session.teardown()
  }
}

const webgl2 = await runBackend('webgl2')
const webgpu = await runBackend('webgpu')
const sourceManifestAfter = sourceManifest(root, lock)
assert.deepEqual(sourceManifestAfter, sourceManifestBefore,
  'source manifest changed during resize captures')
if (!diagnostic) {
  assert.equal(sourceManifestAfter.contentSha256, lock.sourceManifestSha256,
    'source manifest after resize captures differs from pinned authority')
  sourceIdentity(root, lock)
}
assert.equal(webgl2.error, null)
assert.equal(webgpu.error, null)
assert.equal(webgl2.results.length, 18)
assert.equal(webgpu.results.length, 18)
assert.equal(webgl2.mips.length, 2)
assert.equal(webgpu.mips.length, 2)
for (let index = 0; index < webgl2.results.length; index++) {
  const left = webgl2.results[index], right = webgpu.results[index]
  const label = `${left.kind}/${left.id} ${left.width}x${left.height} to ${left.targetWidth}x${left.targetHeight}`
  const source = expectedSource(left.width, left.height, left.variant)
  const resized = centerNearest(source, left.width, left.height, left.targetWidth, left.targetHeight)
  assert.deepEqual(left.source, Array.from(source), `${label}: WebGL2 source`)
  assert.deepEqual(right.source, Array.from(source), `${label}: WebGPU source`)
  assert.deepEqual(left.resized, Array.from(resized), `${label}: WebGL2 resized`)
  assert.deepEqual(right.resized, Array.from(resized), `${label}: WebGPU resized`)
  console.log(JSON.stringify({ ...provenance, label, sourceSha256: digest(source),
    resizedSha256: digest(resized), exactBackends: ['WebGL2', 'WebGPU'],
    runtimeEnvironments: [webgl2.runtimeEnvironment, webgpu.runtimeEnvironment] }))
}
for (let index = 0; index < webgl2.mips.length; index++) {
  const left = webgl2.mips[index], right = webgpu.mips[index]
  assert.deepEqual([left.width, left.height], [right.width, right.height])
  assert.equal(left.levels.length, right.levels.length)
  for (let level = 0; level < left.levels.length; level++) {
    const actual = left.levels[level], other = right.levels[level]
    assert.deepEqual(actual, other, `${left.width}x${left.height} mip ${level} source backends`)
    if (level > 0) {
      const prior = left.levels[level - 1]
      assert.deepEqual(actual.bytes, Array.from(centerNearest(prior.bytes,
        prior.width, prior.height, actual.width, actual.height)),
      `${left.width}x${left.height} mip ${level} center-nearest pixels`)
    }
    console.log(JSON.stringify({ ...provenance,
      mip: [left.width, left.height, level], size: [actual.width, actual.height],
      pixelsSha256: digest(actual.bytes), exactBackends: ['WebGL2', 'WebGPU'],
      runtimeEnvironments: [webgl2.runtimeEnvironment, webgpu.runtimeEnvironment] }))
  }
}
