// The spawn log under failure: a log that cannot be read, one near the size
// limit, and one whose writes are refused. Planted inputs.

import { expect, test } from 'claude-code/testing'
import type { AgentSpawnInput, On } from 'claude-code'

const SID = '11111111-2222-3333-4444-555555555555'
const LOG = `/cfg/logs/subagent-routing/${SID}.jsonl`
// Just under the length at which the hooks module moves the log aside.
const NEAR_LIMIT = 1024 * 1024 - 64

type Engine = { writes: { path: string; text: string }[]; toasts: string[] }

function engine(
  on: On,
  opts: { exists?: (path: string) => boolean; readLog: () => string; writeLog?: (text: string) => void },
): Engine {
  const eng: Engine = { writes: [], toasts: [] }
  on('env.get', (_$, e) => ({ value: e.name === 'CLAUDE_CONFIG_DIR' ? '/cfg' : e.name === 'HOME' ? '/home/x' : undefined }))
  on('session.cwd', () => ({ value: '/proj' }))
  on('session.root', () => ({ value: '/proj' }))
  on('session.id', () => ({ value: SID }))
  on('fs.exists', (_$, e) => ({ value: opts.exists?.(e.path) ?? e.path === LOG }))
  on('fs.read', (_$, e) => {
    if (e.path === LOG) return { value: opts.readLog() }
    throw new Error(`ENOENT: ${e.path}`)
  })
  on('fs.write', (_$, e) => {
    if (e.path === LOG) opts.writeLog?.(e.text)
    eng.writes.push({ path: e.path, text: e.text })
    return { value: undefined }
  })
  on('ui.toast', (_$, e) => {
    eng.toasts.push(e.text)
    return { value: undefined }
  })
  on('agent.spawn', (_$, e) => ({ model: e.model ?? 'definition', agentId: 'a' }))
  return eng
}

const spawn = (id: string, subagentType: string, prompt = 'hello'): AgentSpawnInput =>
  ({
    tool_use_id: id,
    prompt,
    description: 'd',
    subagentType,
    provider: { plugin: 'user', tier: 'user' },
    parentModel: 'opus',
    background: false,
    fork: false,
  }) as AgentSpawnInput

// With no readable project config a gsd-executor spawn is cannot-decide: loud.
const loud = (id: string): AgentSpawnInput => spawn(id, 'gsd-executor', 'no plan here')
const asRequestedToasts = (eng: Engine): string[] => eng.toasts.filter(t => t.includes('left a spawn as requested'))

test('a log that exists but cannot be read is never overwritten', async ($, on) => {
  const eng = engine(on, {
    readLog: () => {
      throw new Error('EACCES: permission denied')
    },
  })
  await $.agent.spawn(spawn('toolu_A', 'gsd-planner'))
  expect(eng.writes.filter(w => w.path === LOG).length).toBe(0)
  expect(eng.toasts.filter(t => t.includes('could not write its log')).length).toBe(1)
})

test('a log near the size limit is moved aside and the new line starts a fresh log', async ($, on) => {
  const prior = `${'x'.repeat(NEAR_LIMIT - 1)}\n`
  const eng = engine(on, { readLog: () => prior })
  await $.agent.spawn(spawn('toolu_B', 'gsd-planner'))
  expect(eng.writes.find(w => w.path === `${LOG}.1`)?.text === prior).toBe(true)
  const fresh = eng.writes.filter(w => w.path === LOG)
  expect(fresh.length).toBe(1)
  expect(fresh[0]?.text.split('\n').filter(Boolean).length).toBe(1)
  expect(JSON.parse(fresh[0]?.text ?? '{}').toolUseId).toBe('toolu_B')
})

test('a moved-aside log never replaces an earlier one', async ($, on) => {
  const prior = `${'x'.repeat(NEAR_LIMIT - 1)}\n`
  const eng = engine(on, { exists: p => p === LOG || p === `${LOG}.1`, readLog: () => prior })
  await $.agent.spawn(spawn('toolu_C', 'gsd-planner'))
  expect(eng.writes.some(w => w.path === `${LOG}.1`)).toBe(false)
  expect(eng.writes.find(w => w.path === `${LOG}.2`)?.text === prior).toBe(true)
})

test('an unreadable log still toasts each loud action once per session', async ($, on) => {
  const eng = engine(on, {
    readLog: () => {
      throw new Error('EIO: i/o error')
    },
  })
  await $.agent.spawn(loud('toolu_D1'))
  await $.agent.spawn(loud('toolu_D2'))
  expect(asRequestedToasts(eng).length).toBe(1)
  expect(eng.toasts.filter(t => t.includes('could not write its log')).length).toBe(1)
})

test('a log whose writes are refused does not repeat a toast its lines already raised', async ($, on) => {
  const prior = '{"toolUseId":"old","action":"cannot-decide"}\n'.repeat(10)
  const eng = engine(on, {
    readLog: () => prior,
    writeLog: () => {
      throw new Error('over 4 MiB')
    },
  })
  await $.agent.spawn(loud('toolu_E1'))
  await $.agent.spawn(loud('toolu_E2'))
  expect(asRequestedToasts(eng)).toEqual([])
  expect(eng.toasts.filter(t => t.includes('could not write its log')).length).toBe(1)
})
