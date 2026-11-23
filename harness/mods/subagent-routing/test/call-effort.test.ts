// An Agent call for gsd-plan-checker that names no effort reaches the Agent
// tool at effort high or at the higher level its definition sets; every other
// Agent call reaches it with no effort the mod added, and the spawn log line
// records the effort the mod set.
//
// Sources of the fixtures:
// - The gsd-plan-checker call shapes copy recorded Agent calls: description,
//   prompt, run_in_background, and subagent_type with no model (2026-11-23 on
//   Claude Code 2.1.330), and the same keys with model sonnet (2026-11-21 on
//   Claude Code 2.1.327). No recorded gsd-plan-checker call names an effort.
// - The recorded gsd-integration-checker and gsd-nyquist-auditor calls carry
//   description, model, prompt, and subagent_type, with no run_in_background;
//   the sonnet case below copies that key set. The other types' calls reuse
//   the gsd-plan-checker key set and are planted.
// - Every prompt and description is planted: the recorded ones hold dispatch
//   text.
// Planted, with no recorded counterpart:
// - a gsd-plan-checker call that names its own effort;
// - a gsd-ui-checker call;
// - agent definitions that set an effort;
// - the tool.call and agent.spawn pair on one tool_use_id: each recording
//   holds one event, so the stand-in for the Agent tool raises the spawn.

import { expect, test, type Engine } from 'claude-code/testing'
import type { AgentSpawnInput, On } from 'claude-code'
import { callEffort, callEffortTypes, definitionEffort } from '../hooks/route'

const LOG_PATH = /\/logs\/subagent-routing\/[^/]+\.jsonl$/
const PROMPT = 'Check the plans under /proj for coverage.'
const DESCRIPTION = 'Check plan quality'

type AgentArgs = Record<string, unknown>

/** An Agent call in the recorded key set, with `extra` keys beside them. */
function agentCall(subagentType: string | undefined, extra: AgentArgs = {}): AgentArgs {
  return {
    description: DESCRIPTION,
    prompt: PROMPT,
    run_in_background: false,
    ...(subagentType === undefined ? {} : { subagent_type: subagentType }),
    ...extra,
  }
}

/** The Agent tool's arguments in a tool.call input: the input less its envelope keys. */
function argsOf(e: Record<string, unknown>): AgentArgs {
  const { tool: _tool, tool_use_id: _id, agentId: _agent, requestMeta: _meta, consent: _consent, ...args } = e
  return args
}

/** A spawn input for the Agent call `args`, as core raises agent.spawn for it. */
function spawnFor(args: AgentArgs, toolUseId: string): AgentSpawnInput {
  return {
    tool_use_id: toolUseId,
    subagentType: String(args.subagent_type ?? 'general-purpose'),
    prompt: String(args.prompt),
    description: String(args.description),
    provider: { plugin: 'user', tier: 'user' },
    parentModel: 'unknown',
    background: args.run_in_background === true,
    fork: false,
    ...(typeof args.model === 'string' ? { model: args.model } : {}),
  } as AgentSpawnInput
}

type Seen = { calls: AgentArgs[]; spawns: AgentSpawnInput[]; log: { text: string }; definitionReads: string[] }

const AGENT_DEFINITION = /\/agents\/[^/]+\.md$/

/**
 * Stand-ins beneath the hooks module: the Agent tool records each call it
 * receives and, with `spawn`, raises agent.spawn for it on its tool_use_id
 * before answering. The spawn log is kept in `log`. `files` holds readable
 * files by path; every read of an agent definition is recorded, readable or not.
 */
function standIns($: Engine, on: On, spawn: boolean, files: Readonly<Record<string, string>> = {}): Seen {
  const seen: Seen = { calls: [], spawns: [], log: { text: '' }, definitionReads: [] }
  on('env.get', (_$, e) => ({ value: e.name === 'CLAUDE_CONFIG_DIR' ? '/cfg' : e.name === 'HOME' ? '/home/x' : undefined }))
  on('session.cwd', () => ({ value: '/proj' }))
  on('session.root', () => ({ value: '/proj' }))
  on('session.id', () => ({ value: 'effort-test' }))
  on('settings.read', () => ({ value: {} }))
  on('fs.read', (_$, e) => {
    if (AGENT_DEFINITION.test(e.path)) seen.definitionReads.push(e.path)
    if (LOG_PATH.test(e.path) && seen.log.text !== '') return { value: seen.log.text }
    const text = files[e.path]
    if (text !== undefined) return { value: text }
    throw new Error(`ENOENT: ${e.path}`)
  })
  on('fs.exists', (_$, e) => ({ value: LOG_PATH.test(e.path) && seen.log.text !== '' }))
  on('fs.write', (_$, e) => {
    if (LOG_PATH.test(e.path)) seen.log.text = e.text
    return { value: undefined }
  })
  on('agent.spawn', (_$, e) => {
    seen.spawns.push(e)
    return { model: e.model ?? 'definition', agentId: 'effort-agent' }
  })
  on('tool.call', { tool: 'Agent' }, async (_$, e) => {
    const args = argsOf(e as unknown as Record<string, unknown>)
    seen.calls.push(args)
    if (spawn) await $.agent.spawn(spawnFor(args, e.tool_use_id))
    return { result: { status: 'completed', agentId: 'effort-agent', content: [{ type: 'text', text: 'done' }] } }
  })
  return seen
}

/** The parsed spawn log lines. */
function logLines(text: string): Record<string, unknown>[] {
  return text
    .split('\n')
    .filter(l => l.trim() !== '')
    .map(l => JSON.parse(l) as Record<string, unknown>)
}

async function callAgent($: Engine, args: AgentArgs): Promise<void> {
  await $.tool.call({ tool: 'Agent', ...args } as Parameters<Engine['tool']['call']>[0])
}

/** Agent definition text that sets `effort` to `level`. */
function definition(level: string): string {
  return `---\nname: gsd-plan-checker\neffort: ${level}\n---\nCheck plans.\n`
}

test('callEffort sets high on a gsd-plan-checker call that names no effort, whose definition sets less', () => {
  for (const defined of [null, 'low', 'medium', '', '4096']) {
    expect(callEffort('gsd-plan-checker', undefined, defined)).toBe('high')
  }
})

test('callEffort never lowers a gsd-plan-checker definition that sets high or more', () => {
  for (const defined of ['high', 'xhigh', 'max']) {
    expect(callEffort('gsd-plan-checker', undefined, defined)).toBe(undefined)
  }
})

test('callEffort leaves the effort a gsd-plan-checker call names', () => {
  expect(callEffort('gsd-plan-checker', 'low', null)).toBe(undefined)
  expect(callEffort('gsd-plan-checker', 'xhigh', 'low')).toBe(undefined)
})

const OTHER_TYPES = [
  'gsd-planner',
  'gsd-verifier',
  'gsd-code-reviewer',
  'gsd-integration-checker',
  'gsd-nyquist-auditor',
  'gsd-ui-checker',
  'gsd-executor',
  'lisp-developer',
  'shell-developer',
  'general-purpose',
]

test('callEffort sets no effort for any other agent type, or for a call with no type', () => {
  for (const type of OTHER_TYPES) expect(callEffort(type, undefined, null)).toBe(undefined)
  expect(callEffort(undefined, undefined, null)).toBe(undefined)
})

test('definitionEffort reads the project definition first, then the configuration one', async () => {
  const io = (files: Record<string, string>) => ({
    configDir: '/cfg',
    projectDir: '/proj',
    read: async (path: string) => files[path] ?? null,
  })
  const project = '/proj/.claude/agents/gsd-plan-checker.md'
  const user = '/cfg/agents/gsd-plan-checker.md'
  expect(await definitionEffort('gsd-plan-checker', io({ [project]: definition('xhigh'), [user]: definition('low') }))).toBe('xhigh')
  expect(await definitionEffort('gsd-plan-checker', io({ [user]: definition('low') }))).toBe('low')
  expect(await definitionEffort('gsd-plan-checker', io({ [project]: '---\nname: x\n---\n', [user]: definition('max') }))).toBe(null)
  expect(await definitionEffort('gsd-plan-checker', io({}))).toBe(null)
  expect(await definitionEffort('../gsd-plan-checker', io({ [user]: definition('low') }))).toBe(null)
})

test('a gsd-plan-checker call with no model reaches the Agent tool at effort high, otherwise as written', async ($, on) => {
  const seen = standIns($, on, false)
  await callAgent($, agentCall('gsd-plan-checker'))
  expect(seen.calls).toEqual([{ ...agentCall('gsd-plan-checker'), effort: 'high' }])
})

test('a gsd-plan-checker call with model sonnet reaches the Agent tool at effort high with model sonnet', async ($, on) => {
  const seen = standIns($, on, false)
  await callAgent($, agentCall('gsd-plan-checker', { model: 'sonnet' }))
  expect(seen.calls).toEqual([{ ...agentCall('gsd-plan-checker', { model: 'sonnet' }), effort: 'high' }])
})

test('a gsd-plan-checker call that names effort low reaches the Agent tool at effort low', async ($, on) => {
  const seen = standIns($, on, false)
  await callAgent($, agentCall('gsd-plan-checker', { effort: 'low' }))
  expect(seen.calls).toEqual([agentCall('gsd-plan-checker', { effort: 'low' })])
})

test('a gsd-plan-checker call whose definition sets low reaches the Agent tool at effort high', async ($, on) => {
  const seen = standIns($, on, false, { '/cfg/agents/gsd-plan-checker.md': definition('low') })
  await callAgent($, agentCall('gsd-plan-checker'))
  expect(seen.calls).toEqual([{ ...agentCall('gsd-plan-checker'), effort: 'high' }])
})

test('a gsd-plan-checker call whose definition sets xhigh reaches the Agent tool with no effort added', async ($, on) => {
  const seen = standIns($, on, false, { '/cfg/agents/gsd-plan-checker.md': definition('xhigh') })
  await callAgent($, agentCall('gsd-plan-checker'))
  expect(seen.calls).toEqual([agentCall('gsd-plan-checker')])
  expect('effort' in (seen.calls[0] ?? {})).toBe(false)
})

test('a project definition that sets max outranks a configuration one that sets low', async ($, on) => {
  const seen = standIns($, on, false, {
    '/proj/.claude/agents/gsd-plan-checker.md': definition('max'),
    '/cfg/agents/gsd-plan-checker.md': definition('low'),
  })
  await callAgent($, agentCall('gsd-plan-checker'))
  expect('effort' in (seen.calls[0] ?? {})).toBe(false)
})

test('a gsd-integration-checker call in its recorded key set reaches the Agent tool with no effort', async ($, on) => {
  const seen = standIns($, on, false)
  const call = { description: DESCRIPTION, model: 'sonnet', prompt: PROMPT, subagent_type: 'gsd-integration-checker' }
  await callAgent($, call)
  expect(seen.calls).toEqual([call])
  expect('effort' in (seen.calls[0] ?? {})).toBe(false)
})

for (const type of [...OTHER_TYPES, undefined]) {
  test(`a ${type ?? 'typeless'} call reaches the Agent tool with no effort`, async ($, on) => {
    const seen = standIns($, on, false)
    await callAgent($, agentCall(type))
    expect(seen.calls).toEqual([agentCall(type)])
    expect('effort' in (seen.calls[0] ?? {})).toBe(false)
  })
}

// The hook reads the definition of whatever type its matcher lets through, so
// a definition read shows which Agent calls the matcher matches.
test('the Agent hook matches a call for every type CALL_EFFORT names', async ($, on) => {
  expect(callEffortTypes().length > 0).toBe(true)
  const seen = standIns($, on, false)
  for (const type of callEffortTypes()) {
    seen.definitionReads.length = 0
    await callAgent($, agentCall(type))
    expect(seen.definitionReads.some(path => path.endsWith(`/agents/${type}.md`))).toBe(true)
  }
})

test('the Agent hook matches no call for any other agent type', async ($, on) => {
  const seen = standIns($, on, false)
  for (const type of OTHER_TYPES) await callAgent($, agentCall(type))
  expect(seen.definitionReads).toEqual([])
})

test('the spawn log line of a gsd-plan-checker call records effort high and says so', async ($, on) => {
  const seen = standIns($, on, true)
  await callAgent($, agentCall('gsd-plan-checker'))
  expect(seen.spawns.length).toBe(1)
  const lines = logLines(seen.log.text).filter(l => typeof l.toolUseId === 'string')
  expect(lines.length).toBe(1)
  expect(lines[0]?.effort).toBe('high')
  expect(String(lines[0]?.reason).endsWith('; the Agent call was set to effort high')).toBe(true)
})

test('the spawn log line of a lisp-developer call records no effort', async ($, on) => {
  const seen = standIns($, on, true)
  await callAgent($, agentCall('lisp-developer'))
  expect(seen.spawns.length).toBe(1)
  expect('effort' in (seen.calls[0] ?? {})).toBe(false)
  const lines = logLines(seen.log.text).filter(l => typeof l.toolUseId === 'string')
  expect(lines.length).toBe(1)
  expect(lines[0]?.effort).toBe(null)
  expect(String(lines[0]?.reason)).not.toContain('effort')
})
