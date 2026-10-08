import test from 'node:test'
import assert from 'node:assert/strict'
import vm from 'node:vm'
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
