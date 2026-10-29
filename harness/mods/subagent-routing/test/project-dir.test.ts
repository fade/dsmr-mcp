// Where the hooks module looks for the project's planning config, and what it
// does when none is readable. Planted inputs: the drift case mirrors a recorded
// quick dispatch whose session cwd had moved into the out-of-repository
// planning directory while the plan path stayed absolute.

import { expect, test } from 'claude-code/testing'
import type { AgentSpawnInput, On } from 'claude-code'

const SID = '11111111-2222-3333-4444-555555555555'
// The planning directory gsd-core reads, named once.
const PLANNING_DIR = '.planning'
const ROOT = '/proj'
const DRIFTED = '/home/x/.cache/opencode/projects/proj_0000/planning'
const PLAN = `${ROOT}/${PLANNING_DIR}/phases/01-x/01-01-PLAN.md`
const SPECIALIZED = JSON.stringify({ planning: { agents: { executor: 'lisp-developer', specialized: true } } })

type Spawned = { type: string; model: string | null }

function engine(on: On, files: Record<string, string>, cwd: string): { beneath: Spawned[]; log: () => string } {
  const beneath: Spawned[] = []
  let log = ''
  on('env.get', (_$, e) => ({ value: e.name === 'CLAUDE_CONFIG_DIR' ? '/cfg' : e.name === 'HOME' ? '/home/x' : undefined }))
  on('session.cwd', () => ({ value: cwd }))
  on('session.root', () => ({ value: ROOT }))
  on('session.id', () => ({ value: SID }))
  on('fs.exists', (_$, e) => ({ value: e.path === '/cfg/agents/lisp-developer.md' || (e.path.endsWith('.jsonl') && log !== '') }))
  on('fs.read', (_$, e) => {
    if (e.path.endsWith('.jsonl') && log !== '') return { value: log }
    const text = files[e.path]
    if (text === undefined) throw new Error(`ENOENT: ${e.path}`)
    return { value: text }
  })
  on('fs.write', (_$, e) => {
    if (e.path.endsWith('.jsonl')) log = e.text
    return { value: undefined }
  })
  on('agent.spawn', (_$, e) => {
    beneath.push({ type: e.subagentType, model: e.model ?? null })
    return { model: e.model ?? 'definition', agentId: 'a' }
  })
  return { beneath, log: () => log }
}

const spawn = (id: string): AgentSpawnInput =>
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
  }) as AgentSpawnInput

const lastAction = (log: string): unknown => JSON.parse(log.trim().split('\n').at(-1) ?? '{}').action

test('a session cwd moved by a shell cd still reads the project root config', async ($, on) => {
  const eng = engine(on, { [`${ROOT}/${PLANNING_DIR}/config.json`]: SPECIALIZED, [PLAN]: '---\nwave: 1\n---\n' }, DRIFTED)
  await $.agent.spawn(spawn('toolu_drift'))
  expect(eng.beneath).toEqual([{ type: 'lisp-developer', model: null }])
  expect(lastAction(eng.log())).toBe('rewrote')
})

test('no project config leaves a gsd-executor spawn as requested and says so', async ($, on) => {
  const eng = engine(on, { [PLAN]: '---\nwave: 1\n---\n' }, ROOT)
  await $.agent.spawn(spawn('toolu_noconfig'))
  expect(eng.beneath).toEqual([{ type: 'gsd-executor', model: 'opus' }])
  expect(lastAction(eng.log())).toBe('cannot-decide')
})

test('an unparsable project config leaves a gsd-executor spawn as requested', async ($, on) => {
  const eng = engine(on, { [`${ROOT}/${PLANNING_DIR}/config.json`]: '{"planning": ', [PLAN]: '---\nwave: 1\n---\n' }, ROOT)
  await $.agent.spawn(spawn('toolu_badconfig'))
  expect(eng.beneath).toEqual([{ type: 'gsd-executor', model: 'opus' }])
  expect(lastAction(eng.log())).toBe('cannot-decide')
})
