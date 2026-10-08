import { createHash } from 'node:crypto'
import { existsSync, lstatSync, readFileSync } from 'node:fs'
import { isAbsolute, relative, resolve } from 'node:path'

export const hash = value => createHash('sha256').update(value).digest('hex')
export const same = (left, right) => JSON.stringify(left) === JSON.stringify(right)
export const ARTIFACT_KEYS = Object.freeze(['images', 'hostTextures', 'hostVolumes',
  'intermediates', 'uniformBuffers'])

export function buildPlan(currentCases, oldCases, oldRecords, selectedRecords) {
  const oldById = new Map(oldCases.map(item => [item.id, item]))
  const oldRecordById = new Map(oldRecords.map(record => [record.id, record]))
  const selectedById = new Map()
  const currentIds = new Set(currentCases.map(item => item.id))
  for (const record of selectedRecords) {
    if (!currentIds.has(record.id) || selectedById.has(record.id)) throw new Error(`invalid selected case ${record.id}`)
    selectedById.set(record.id, record)
  }
  const plan = currentCases.map(item => {
    const fresh = selectedById.get(item.id)
    const old = oldById.get(item.id)
    if (fresh) return { item, record: fresh, reused: false }
    if (old && same(old, item) && oldRecordById.get(item.id)?.status === 'ok') {
      return { item, record: oldRecordById.get(item.id), reused: true }
    }
    throw new Error(`current case lacks a fresh source capture: ${item.id}`)
  })
  if (plan.filter(row => !row.reused).length !== selectedById.size) {
    throw new Error('selected ledger has unused source captures')
  }
  return plan
}

export function assertRecord(record, item, refusalIds) {
  if (record.sourceSha256 !== item.sourceSha256 || !same(record.capture, item.capture) ||
      record.backend !== 'WebGPU' || !['ok', 'fail'].includes(record.status)) {
    throw new Error(`golden record differs from current case: ${item.id}`)
  }
  if (record.status === 'fail' && !refusalIds.has(item.id)) {
    throw new Error(`unexpected source failure cannot be reused: ${item.id}`)
  }
  if (record.status === 'ok' && (!Array.isArray(record.images) || record.images.length === 0)) {
    throw new Error(`successful golden lacks presented images: ${item.id}`)
  }
}

export function checkedArtifact(descriptor, root, id) {
  if (!descriptor || typeof descriptor.path !== 'string' || typeof descriptor.sha256 !== 'string' ||
      !/^[0-9a-f]{64}$/.test(descriptor.sha256)) throw new Error(`invalid artifact descriptor: ${id}`)
  const path = resolve(descriptor.path)
  const name = relative(root, path)
  if (!name || name.startsWith('..') || isAbsolute(name) ||
      !name.startsWith(`${id}.`) || !existsSync(path) || !lstatSync(path).isFile() ||
      hash(readFileSync(path)) !== descriptor.sha256) {
    throw new Error(`golden artifact differs from source ledger: ${id}/${name}`)
  }
  return { path, name }
}
