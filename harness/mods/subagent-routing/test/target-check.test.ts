// When a spawn may be passed on as another agent type: only when the engine
// last offered that type in the session and no Agent permission rule names it.
// The engine checks a retyped spawn after the agent.spawn chain has handed it
// over, so these facts are read before the rewrite. Planted inputs: an
// unhinted gsd-executor dispatch in a specialized project, which routes to
// lisp-developer.

import { expect, test, type Engine } from 'claude-code/testing'
import type { AgentSpawnInput, On } from 'claude-code'
import { permissionRuleAgainst } from '../hooks/route'

// The planning directory gsd-core reads, named once.
const PLANNING_DIR = '.planning'
const PLAN = `/proj/${PLANNING_DIR}/phases/01-x/01-01-PLAN.md`
const FILES: Record<string, string> = {
  [`/proj/${PLANNING_DIR}/config.json`]: JSON.stringify({
    planning: { agents: { executor: 'lisp-developer', specialized: true } },
  }),
  [PLAN]: '---\nwave: 1\n---\n',
}
const REQUESTED = { type: 'gsd-executor', model: 'opus' }
const ROUTED = { type: 'lisp-developer', model: null }

type Spawned = { type: string; model: string | null }
type Setup = {
  /** isOffered per type the chain beneath answers; a type left out is offered. */
  isOffered?: Record<string, boolean>
  /** The settings' `permissions`; a function that throws makes the read fail. */
  permissions?: () => unknown
}
type Eng = { beneath: Spawned[]; toasts: string[]; line: () => Record<string, unknown> }

// Each test runs in its own session, so no other test's offers apply.
function engine(on: On, session: string, setup: Setup = {}): Eng {
  const beneath: Spawned[] = []
  const toasts: string[] = []
  let log = ''
  on('env.get', (_$, e) => ({ value: e.name === 'CLAUDE_CONFIG_DIR' ? '/cfg' : e.name === 'HOME' ? '/home/x' : undefined }))
  on('session.cwd', () => ({ value: '/proj' }))
  on('session.root', () => ({ value: '/proj' }))
  on('session.id', () => ({ value: session }))
  on('fs.exists', (_$, e) => ({ value: e.path === '/cfg/agents/lisp-developer.md' || (e.path.endsWith('.jsonl') && log !== '') }))
  on('fs.read', (_$, e) => {
    if (e.path.endsWith('.jsonl') && log !== '') return { value: log }
    const text = FILES[e.path]
    if (text === undefined) throw new Error(`ENOENT: ${e.path}`)
    return { value: text }
  })
  on('fs.write', (_$, e) => {
    if (e.path.endsWith('.jsonl')) log = e.text
    return { value: undefined }
  })
  on('ui.toast', (_$, e) => {
    toasts.push(String(e.text))
    return { value: undefined }
  })
  on('agent.offer', (_$, e) => ({ isOffered: setup.isOffered?.[e.agent] ?? true }))
  on('settings.read', () => {
    const permissions = setup.permissions?.()
    return { value: permissions === undefined ? {} : { permissions } }
  })
  on('agent.spawn', (_$, e) => {
    beneath.push({ type: e.subagentType, model: e.model ?? null })
    return { model: e.model ?? 'definition', agentId: 'a' }
  })
  return { beneath, toasts, line: () => JSON.parse(log.trim().split('\n').at(-1) ?? '{}') as Record<string, unknown> }
}

const spawn = (id: string, extra: Partial<AgentSpawnInput> = {}): AgentSpawnInput =>
  ({
    tool_use_id: id,
    prompt: `<files_to_read>\n- ${PLAN} (Plan)\n</files_to_read>`,
    description: 'execute plan',
    subagentType: 'gsd-executor',
    model: 'opus',
    provider: { plugin: 'user', tier: 'user' },
    parentModel: 'opus',
    background: false,
    fork: false,
    ...extra,
  }) as AgentSpawnInput

/** Offers `types` as a dispatch does, then raises the spawn. */
async function dispatch($: Engine, input: AgentSpawnInput, types: readonly string[]): Promise<void> {
  for (const agent of types) {
    await $.agent.offer({ agent, description: '', source: 'userSettings', provider: { plugin: 'user', tier: 'user' } })
  }
  await $.agent.spawn(input)
}

function expectAsRequested(eng: Eng, why: string): void {
  expect(eng.beneath).toEqual([REQUESTED])
  const line = eng.line()
  expect(line.action).toBe('cannot-decide')
  expect(line.set).toEqual(REQUESTED)
  expect(String(line.reason)).toContain(why)
  expect(eng.toasts.length).toBe(1)
}

test('control: an offered type no rule names is passed on', async ($, on) => {
  const eng = engine(on, 'tc-control')
  await dispatch($, spawn('toolu_control'), ['gsd-executor', 'lisp-developer'])
  expect(eng.beneath).toEqual([ROUTED])
  expect(eng.line().action).toBe('rewrote')
})

test('a type the session was never offered is not passed on', async ($, on) => {
  const eng = engine(on, 'tc-never')
  await dispatch($, spawn('toolu_never'), ['gsd-executor'])
  expectAsRequested(eng, 'lisp-developer has not been offered in this session')
})

test('a type the chain beneath refused to offer is not passed on', async ($, on) => {
  const eng = engine(on, 'tc-refused', { isOffered: { 'lisp-developer': false } })
  await dispatch($, spawn('toolu_refused'), ['gsd-executor', 'lisp-developer'])
  expectAsRequested(eng, 'lisp-developer is not offered in this session')
})

test('the latest offer answer stands: offered, then refused', async ($, on) => {
  const isOffered: Record<string, boolean> = {}
  const eng = engine(on, 'tc-latest', { isOffered })
  await dispatch($, spawn('toolu_latest_1'), ['gsd-executor', 'lisp-developer'])
  isOffered['lisp-developer'] = false
  await dispatch($, spawn('toolu_latest_2'), ['gsd-executor', 'lisp-developer'])
  expect(eng.beneath).toEqual([ROUTED, REQUESTED])
})

for (const list of ['deny', 'ask', 'allow'] as const) {
  test(`a permissions.${list} rule on Agent(lisp-developer) keeps the spawn as requested`, async ($, on) => {
    const eng = engine(on, `tc-${list}`, { permissions: () => ({ [list]: ['Agent(lisp-developer)'] }) })
    await dispatch($, spawn(`toolu_${list}`), ['gsd-executor', 'lisp-developer'])
    expectAsRequested(eng, `permissions.${list} holds Agent(lisp-developer)`)
  })
}

test('a glob rule naming the target and not the requested type keeps the spawn as requested', async ($, on) => {
  const eng = engine(on, 'tc-glob', { permissions: () => ({ deny: ['Agent(lisp-*)'] }) })
  await dispatch($, spawn('toolu_glob'), ['gsd-executor', 'lisp-developer'])
  expectAsRequested(eng, 'permissions.deny holds Agent(lisp-*)')
})

test('control: a rule naming both types, or another type, does not stop the rewrite', async ($, on) => {
  const eng = engine(on, 'tc-both', {
    permissions: () => ({ allow: ['Agent(*)', 'Agent(shell-developer)', 'Bash(ls)'], ask: ['Agent'] }),
  })
  await dispatch($, spawn('toolu_both'), ['gsd-executor', 'lisp-developer'])
  expect(eng.beneath).toEqual([ROUTED])
})

test('permission rules that cannot be read keep the spawn as requested', async ($, on) => {
  const eng = engine(on, 'tc-unreadable', {
    permissions: () => {
      throw new Error('settings read failed')
    },
  })
  await dispatch($, spawn('toolu_unreadable'), ['gsd-executor', 'lisp-developer'])
  expectAsRequested(eng, 'could not be read')
})

test('a malformed permissions list keeps the spawn as requested', async ($, on) => {
  const eng = engine(on, 'tc-malformed', { permissions: () => ({ deny: 'Agent(lisp-developer)' }) })
  await dispatch($, spawn('toolu_malformed'), ['gsd-executor', 'lisp-developer'])
  expectAsRequested(eng, 'permissions.deny is not a list')
})

test('a spawn from a subagent keeps its requested type', async ($, on) => {
  const eng = engine(on, 'tc-parent')
  await dispatch($, spawn('toolu_parent', { parentAgentId: 'agent-1' }), ['gsd-executor', 'lisp-developer'])
  expectAsRequested(eng, 'agent-1, whose dispatchable agent types are not known')
})

test('a model cleared on the requested type needs no offer', async ($, on) => {
  const eng = engine(on, 'tc-cleared')
  await $.agent.spawn(spawn('toolu_cleared', { subagentType: 'lisp-developer', model: 'sonnet', prompt: 'hello' }))
  expect(eng.beneath).toEqual([ROUTED])
  expect(eng.line().action).toBe('cleared-model')
})

test('permissionRuleAgainst reads Agent and Task rules and nothing else', () => {
  expect(permissionRuleAgainst(undefined, 'lisp-developer', 'gsd-executor')).toBe(null)
  expect(permissionRuleAgainst({}, 'lisp-developer', 'gsd-executor')).toBe(null)
  expect(permissionRuleAgainst({ deny: ['Task(lisp-developer)'] }, 'lisp-developer', 'gsd-executor')).toBe(
    'permissions.deny holds Task(lisp-developer)',
  )
  expect(permissionRuleAgainst({ deny: ['Agent(lisp-developer-2)'] }, 'lisp-developer', 'gsd-executor')).toBe(null)
  expect(permissionRuleAgainst({ deny: ['Agent(lisp.developer)'] }, 'lisp-developer', 'gsd-executor')).toBe(null)
  expect(permissionRuleAgainst(['Agent(lisp-developer)'], 'lisp-developer', 'gsd-executor')).toBe(
    'permissions is not an object',
  )
})
