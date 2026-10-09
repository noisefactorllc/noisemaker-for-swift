import test from 'node:test'
import assert from 'node:assert/strict'
import vm from 'node:vm'
import { spawn } from 'node:child_process'
import { mkdtempSync, readFileSync, writeFileSync, chmodSync, existsSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { installAsyncInitTracker } from './batch-golden.mjs'

test('async init tracker waits for a delayed source pipeline before wrapping its prototype', { timeout: 5000 }, async () => {
  const window = { __noisemakerRenderingPipeline: null }
  let signalWaitStarted
  const waitStarted = new Promise(resolve => { signalWaitStarted = resolve })
  let checkReady
  let evaluations = 0
  const page = {
    waitForFunction(predicate, argument, options) {
      assert.equal(argument, null)
      assert.equal(options.timeout, 120000)
      signalWaitStarted()
      return new Promise(resolve => {
        checkReady = () => {
          if (vm.runInNewContext(`(${predicate.toString()})()`, { window })) resolve()
        }
        checkReady()
      })
    },
    evaluate(callback) {
      evaluations++
      return vm.runInNewContext(`(${callback.toString()})()`, { window })
    }
  }
  const installing = installAsyncInitTracker(page)
  await Promise.race([waitStarted, installing.then(() => { throw new Error('tracker installed before pipeline readiness') })])
  assert.equal(evaluations, 0)

  let finishInit
  const proto = { _startAsyncInit(nodeId, effectDef) { return effectDef.asyncInit({}) } }
  window.__noisemakerRenderingPipeline = Object.create(proto)
  checkReady()
  await installing
  assert.equal(proto.__nmTracksAsyncInit, true)
  assert.equal(window.__nmAsyncInitPending, 0)
  assert.equal(evaluations, 1)

  const effectDef = { asyncInit: () => new Promise(resolve => { finishInit = resolve }) }
  const running = window.__noisemakerRenderingPipeline._startAsyncInit('node_0', effectDef, {})
  assert.equal(window.__nmAsyncInitPending, 1)
  assert.equal(window.__nmAsyncInitNodes.has('node_0'), true)
  finishInit()
  await running
  await Promise.resolve()
  assert.equal(window.__nmAsyncInitPending, 0)
})

const root = resolve(fileURLToPath(new URL('..', import.meta.url)))
const waitFor = async (predicate, timeout = 5000) => {
  const deadline = Date.now() + timeout
  while (!predicate()) {
    if (Date.now() > deadline) throw new Error('timed out waiting for subprocess state')
    await new Promise(resolve => setTimeout(resolve, 20))
  }
}

for (const [signal, expectedExit] of [['SIGINT', 130], ['SIGTERM', 143]]) test(`capture ${signal} closes the active session and prevents later case dispatch`, { timeout: 10000 }, async () => {
  const temp = mkdtempSync(join(tmpdir(), 'nm-golden-cancel-'))
  const script = `
    import { writeFileSync } from 'node:fs'
    import { createCaptureCancellation } from ${JSON.stringify(pathToFileURL(join(root, 'parity/batch-golden.mjs')).href)}
    const cancellation = createCaptureCancellation()
    const keepAlive = setInterval(() => {}, 1000)
    let release
    const currentCase = new Promise(resolve => { release = resolve })
    const session = { async teardown() { writeFileSync(${JSON.stringify(join(temp, 'closed'))}, 'yes'); release() } }
    cancellation.setSession(session)
    writeFileSync(${JSON.stringify(join(temp, 'ready'))}, 'yes')
    try {
      await currentCase
      cancellation.throwIfCancelled()
      writeFileSync(${JSON.stringify(join(temp, 'later-case'))}, 'started')
    } catch (error) {
      if (!cancellation.cancelled) throw error
    } finally {
      clearInterval(keepAlive)
      await cancellation.closeSession(session)
      cancellation.dispose()
    }
  `
  const child = spawn(process.execPath, ['--input-type=module', '-e', script], { stdio: 'ignore' })
  try {
    await waitFor(() => existsSync(join(temp, 'ready')) || child.exitCode !== null)
    assert.equal(child.exitCode, null, `capture child exited before ${signal}`)
    child.kill(signal)
    await waitFor(() => child.exitCode !== null)
    assert.equal(child.exitCode, expectedExit)
    assert.equal(readFileSync(join(temp, 'closed'), 'utf8'), 'yes')
    assert.equal(existsSync(join(temp, 'later-case')), false)
  } finally {
    if (child.exitCode === null) child.kill('SIGKILL')
    rmSync(temp, { recursive: true, force: true })
  }
})

test('capture cancellation during setup closes a browser created after the first teardown', { timeout: 10000 }, async () => {
  const temp = mkdtempSync(join(tmpdir(), 'nm-golden-setup-cancel-'))
  const script = `
    import { writeFileSync } from 'node:fs'
    import { createCaptureCancellation } from ${JSON.stringify(pathToFileURL(join(root, 'parity/batch-golden.mjs')).href)}
    const cancellation = createCaptureCancellation()
    const keepAlive = setInterval(() => {}, 1000)
    let releaseSetup
    const session = {
      browser: null,
      async setup() {
        const pending = new Promise(resolve => { releaseSetup = resolve })
        writeFileSync(${JSON.stringify(join(temp, 'ready'))}, 'yes')
        await pending
        this.browser = { open: true }
      },
      async teardown() {
        if (!this.browser) releaseSetup()
        else {
          this.browser = null
          writeFileSync(${JSON.stringify(join(temp, 'closed'))}, 'yes')
        }
      }
    }
    cancellation.setSession(session)
    try {
      try {
        await session.setup()
        cancellation.throwIfCancelled()
        writeFileSync(${JSON.stringify(join(temp, 'later-case'))}, 'started')
      } finally {
        clearInterval(keepAlive)
        await cancellation.closeSession(session)
        cancellation.dispose()
      }
    } catch { process.exitCode ||= 1 }
  `
  const child = spawn(process.execPath, ['--input-type=module', '-e', script], { stdio: 'ignore' })
  try {
    await waitFor(() => existsSync(join(temp, 'ready')) || child.exitCode !== null)
    assert.equal(child.exitCode, null, 'capture child exited before setup began')
    child.kill('SIGTERM')
    await waitFor(() => child.exitCode !== null)
    assert.equal(child.exitCode, 143)
    assert.equal(readFileSync(join(temp, 'closed'), 'utf8'), 'yes')
    assert.equal(existsSync(join(temp, 'later-case')), false)
  } finally {
    if (child.exitCode === null) child.kill('SIGKILL')
    rmSync(temp, { recursive: true, force: true })
  }
})

test('parity-summary stops after a cancelled golden batch without grading', { timeout: 10000 }, async () => {
  const temp = mkdtempSync(join(tmpdir(), 'nm-summary-cancel-'))
  const bin = join(temp, 'bin')
  const fake = (name, body) => { const path = join(bin, name); writeFileSync(path, `#!/bin/sh\n${body}\n`); chmodSync(path, 0o755) }
  try {
    const { mkdirSync } = await import('node:fs')
    mkdirSync(bin)
    fake('node', `case "$1" in parity/batch-golden.mjs) touch "$NM_TEST_GOLDEN_MARKER"; exit 143;; esac\nexit 0`)
    fake('python3', `case "$1" in parity/summarize.py) touch "$NM_TEST_MARKER";; tools/qualification-fingerprint.py) printf 'same\\n';; esac\nexit 0`)
    fake('swift', `case "$*" in *--show-bin-path*) printf '%s\\n' "$NM_TEST_BIN_DIR";; esac\nexit 0`)
    const native = join(temp, 'nm-render')
    writeFileSync(native, `#!/bin/sh\ntouch "$NM_TEST_NATIVE_MARKER"\nexit 0\n`)
    chmodSync(native, 0o755)
    const child = spawn('sh', [join(root, 'scripts/parity-summary'), 'coverage/filter_blur'], {
      cwd: root, env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, NM_REFERENCE_ROOT: temp,
        NM_TEST_BIN_DIR: temp, NM_TEST_GOLDEN_MARKER: join(temp, 'golden'),
        NM_TEST_MARKER: join(temp, 'summary'), NM_TEST_NATIVE_MARKER: join(temp, 'native') }, stdio: ['ignore', 'pipe', 'pipe']
    })
    let stderr = ''
    child.stderr.on('data', chunk => { stderr += chunk })
    await waitFor(() => child.exitCode !== null)
    assert.equal(existsSync(join(temp, 'golden')), true, stderr)
    assert.notEqual(child.exitCode, 0)
    assert.equal(existsSync(join(temp, 'native')), false)
    assert.equal(existsSync(join(temp, 'summary')), false)
  } finally { rmSync(temp, { recursive: true, force: true }) }
})

test('parity-summary stops after a cancelled native batch without grading', { timeout: 10000 }, async () => {
  const temp = mkdtempSync(join(tmpdir(), 'nm-native-cancel-'))
  const bin = join(temp, 'bin')
  const fake = (name, body) => { const path = join(bin, name); writeFileSync(path, `#!/bin/sh\n${body}\n`); chmodSync(path, 0o755) }
  try {
    const { mkdirSync } = await import('node:fs')
    mkdirSync(bin)
    fake('node', `case "$1" in parity/batch-golden.mjs) touch "$NM_TEST_GOLDEN_MARKER";; esac\nexit 0`)
    fake('python3', `case "$1" in parity/summarize.py) touch "$NM_TEST_MARKER";; tools/qualification-fingerprint.py) printf 'same\\n';; esac\nexit 0`)
    fake('swift', `case "$*" in *--show-bin-path*) printf '%s\\n' "$NM_TEST_BIN_DIR";; esac\nexit 0`)
    const native = join(temp, 'nm-render')
    writeFileSync(native, `#!/bin/sh\ntouch "$NM_TEST_NATIVE_MARKER"\nexit 143\n`)
    chmodSync(native, 0o755)
    const child = spawn('sh', [join(root, 'scripts/parity-summary'), 'coverage/filter_blur'], {
      cwd: root, env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, NM_REFERENCE_ROOT: temp,
        NM_TEST_BIN_DIR: temp, NM_TEST_GOLDEN_MARKER: join(temp, 'golden'),
        NM_TEST_MARKER: join(temp, 'summary'), NM_TEST_NATIVE_MARKER: join(temp, 'native') },
      stdio: 'ignore'
    })
    await waitFor(() => child.exitCode !== null)
    assert.equal(child.exitCode, 143)
    assert.equal(existsSync(join(temp, 'golden')), true)
    assert.equal(existsSync(join(temp, 'native')), true)
    assert.equal(existsSync(join(temp, 'summary')), false)
  } finally { rmSync(temp, { recursive: true, force: true }) }
})

test('parity-summary forwards termination to its active native child', { timeout: 10000 }, async () => {
  const temp = mkdtempSync(join(tmpdir(), 'nm-native-signal-'))
  const bin = join(temp, 'bin')
  const fake = (name, body) => { const path = join(bin, name); writeFileSync(path, `#!/bin/sh\n${body}\n`); chmodSync(path, 0o755) }
  let child
  let nativePid
  try {
    const { mkdirSync } = await import('node:fs')
    mkdirSync(bin)
    fake('node', 'exit 0')
    fake('python3', `case "$1" in parity/summarize.py) touch "$NM_TEST_MARKER";; tools/qualification-fingerprint.py) printf 'same\\n';; esac\nexit 0`)
    fake('swift', `case "$*" in *--show-bin-path*) printf '%s\\n' "$NM_TEST_BIN_DIR";; esac\nexit 0`)
    const captureScript = join(temp, 'native.cjs')
    writeFileSync(captureScript, `
      const fs = require('node:fs')
      fs.writeFileSync(process.env.NM_TEST_NATIVE_PID, String(process.pid))
      process.on('SIGTERM', () => { fs.writeFileSync(process.env.NM_TEST_NATIVE_CLOSED, 'yes'); process.exit(143) })
      setInterval(() => {}, 1000)
    `)
    const native = join(temp, 'nm-render')
    writeFileSync(native, `#!/bin/sh\nexec "$NM_TEST_NODE_BIN" "$NM_TEST_CAPTURE_SCRIPT"\n`)
    chmodSync(native, 0o755)
    child = spawn('sh', [join(root, 'scripts/parity-summary'), 'coverage/filter_blur'], {
      cwd: root, env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, NM_REFERENCE_ROOT: temp,
        NM_TEST_BIN_DIR: temp, NM_TEST_NODE_BIN: process.execPath,
        NM_TEST_CAPTURE_SCRIPT: captureScript, NM_TEST_NATIVE_PID: join(temp, 'native-pid'),
        NM_TEST_NATIVE_CLOSED: join(temp, 'native-closed'), NM_TEST_MARKER: join(temp, 'summary') },
      stdio: 'ignore'
    })
    await waitFor(() => existsSync(join(temp, 'native-pid')) || child.exitCode !== null)
    assert.equal(child.exitCode, null, 'summary exited before native child started')
    nativePid = Number(readFileSync(join(temp, 'native-pid'), 'utf8'))
    child.kill('SIGTERM')
    await waitFor(() => child.exitCode !== null)
    assert.equal(child.exitCode, 143)
    assert.equal(readFileSync(join(temp, 'native-closed'), 'utf8'), 'yes')
    assert.equal(existsSync(join(temp, 'summary')), false)
  } finally {
    if (child?.exitCode === null) child.kill('SIGKILL')
    if (nativePid && !existsSync(join(temp, 'native-closed'))) {
      try { process.kill(nativePid, 'SIGKILL') } catch {}
    }
    rmSync(temp, { recursive: true, force: true })
  }
})

for (const [signal, expectedExit] of [['SIGINT', 130], ['SIGTERM', 143]]) test(`parity-summary forwards ${signal} to its active golden child`, { timeout: 10000 }, async () => {
  const temp = mkdtempSync(join(tmpdir(), 'nm-summary-signal-'))
  const bin = join(temp, 'bin')
  const fake = (name, body) => { const path = join(bin, name); writeFileSync(path, `#!/bin/sh\n${body}\n`); chmodSync(path, 0o755) }
  let child
  let goldenPid
  try {
    const { mkdirSync } = await import('node:fs')
    mkdirSync(bin)
    const captureScript = join(temp, 'capture.cjs')
    writeFileSync(captureScript, `
      const fs = require('node:fs')
      fs.writeFileSync(process.env.NM_TEST_GOLDEN_PID, String(process.pid))
      process.on('SIGTERM', () => { fs.writeFileSync(process.env.NM_TEST_GOLDEN_CLOSED, 'yes'); process.exit(143) })
      setInterval(() => {}, 1000)
    `)
    fake('node', `case "$1" in parity/batch-golden.mjs) exec "$NM_TEST_NODE_BIN" "$NM_TEST_CAPTURE_SCRIPT";; esac\nexit 0`)
    fake('python3', `case "$1" in parity/summarize.py) touch "$NM_TEST_MARKER";; tools/qualification-fingerprint.py) printf 'same\\n';; esac\nexit 0`)
    fake('swift', `case "$*" in *--show-bin-path*) printf '%s\\n' "$NM_TEST_BIN_DIR";; esac\nexit 0`)
    const native = join(temp, 'nm-render')
    writeFileSync(native, `#!/bin/sh\ntouch "$NM_TEST_NATIVE_MARKER"\nexit 0\n`)
    chmodSync(native, 0o755)
    child = spawn('sh', [join(root, 'scripts/parity-summary'), 'coverage/filter_blur'], {
      cwd: root, env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, NM_REFERENCE_ROOT: temp,
        NM_TEST_BIN_DIR: temp, NM_TEST_NODE_BIN: process.execPath, NM_TEST_CAPTURE_SCRIPT: captureScript,
        NM_TEST_GOLDEN_PID: join(temp, 'golden-pid'), NM_TEST_GOLDEN_CLOSED: join(temp, 'golden-closed'),
        NM_TEST_MARKER: join(temp, 'summary'), NM_TEST_NATIVE_MARKER: join(temp, 'native') }, stdio: 'ignore'
    })
    await waitFor(() => existsSync(join(temp, 'golden-pid')) || child.exitCode !== null)
    assert.equal(child.exitCode, null, 'summary exited before golden child started')
    goldenPid = Number(readFileSync(join(temp, 'golden-pid'), 'utf8'))
    child.kill(signal)
    await waitFor(() => child.exitCode !== null)
    assert.equal(child.exitCode, expectedExit)
    assert.equal(readFileSync(join(temp, 'golden-closed'), 'utf8'), 'yes')
    assert.equal(existsSync(join(temp, 'native')), false)
    assert.equal(existsSync(join(temp, 'summary')), false)
  } finally {
    if (child?.exitCode === null) child.kill('SIGKILL')
    if (goldenPid && !existsSync(join(temp, 'golden-closed'))) {
      try { process.kill(goldenPid, 'SIGKILL') } catch {}
    }
    rmSync(temp, { recursive: true, force: true })
  }
})
