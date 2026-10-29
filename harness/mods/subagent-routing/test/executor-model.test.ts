// Which projects lose a gsd-executor spawn's per-call model. Only a project
// whose config sets planning.agents.specialized true has gsd-executor follow
// the leader; every other project keeps the model its own profile asked for.
// Planted inputs.

import { expect, test } from 'claude-code/testing'
import { decide, type RouteIo } from '../hooks/route'

// The planning directory gsd-core reads, named once.
const PLANNING_DIR = '.planning'
const CONFIG = `/proj/${PLANNING_DIR}/config.json`
const PLAN = `/proj/${PLANNING_DIR}/phases/01-x/01-01-PLAN.md`
const PROMPT = `<files_to_read>\n- ${PLAN} (Plan)\n</files_to_read>`
const AGENTS = ['/cfg/agents/lisp-developer.md', '/cfg/agents/shell-developer.md', '/cfg/agents/gsd-executor.md']

function io(config: object, plan: string): RouteIo {
  const files: Record<string, string> = { [CONFIG]: JSON.stringify(config), [PLAN]: plan }
  return {
    configDir: '/cfg',
    projectDir: '/proj',
    homeDir: '/home/x',
    read: async p => files[p] ?? null,
    exists: async p => AGENTS.includes(p),
  }
}

const BALANCED = { model_profile: 'balanced', planning: { agents: {} } }
const SPECIALIZED = { planning: { agents: { executor: 'lisp-developer', specialized: true } } }
const UNHINTED = '---\nwave: 1\n---\n'
const run = (model: string, prompt = PROMPT) => ({ subagentType: 'gsd-executor', model, prompt, fork: false })

test('an unspecialized project keeps the model it asked for on an unhinted plan', async () => {
  const d = await decide(run('sonnet'), io(BALANCED, UNHINTED))
  expect([d.action, d.subagentType, d.model ?? null]).toEqual(['unchanged', 'gsd-executor', 'sonnet'])
  expect(d.reason).toContain('keeps the requested model sonnet')
})

test('an unspecialized project keeps the model it asked for on a gsd-executor hint', async () => {
  const d = await decide(run('sonnet'), io(BALANCED, '---\nagent_hint: gsd-executor\n---\n'))
  expect([d.action, d.subagentType, d.model ?? null]).toEqual(['unchanged', 'gsd-executor', 'sonnet'])
})

test('an unspecialized project with hint routing off keeps the model it asked for', async () => {
  const off = { ...BALANCED, workflow: { agent_hint_routing: false } }
  const d = await decide(run('opus'), io(off, UNHINTED))
  expect([d.action, d.subagentType, d.model ?? null]).toEqual(['unchanged', 'gsd-executor', 'opus'])
})

test('an unspecialized audit-fix finding keeps the model it asked for', async () => {
  const d = await decide(run('sonnet', 'Fix finding F-1 in src/x.lisp'), io(BALANCED, UNHINTED))
  expect([d.action, d.subagentType, d.model ?? null]).toEqual(['unchanged', 'gsd-executor', 'sonnet'])
})

test('a specialized project with hint routing off still clears the model', async () => {
  const off = { ...SPECIALIZED, workflow: { agent_hint_routing: false } }
  const d = await decide(run('opus'), io(off, UNHINTED))
  expect([d.action, d.subagentType, d.model ?? null]).toEqual(['rewrote', 'gsd-executor', null])
})

test('a specialized project whose executor is gsd-executor still clears the model', async () => {
  const own = { planning: { agents: { executor: 'gsd-executor', specialized: true } } }
  const d = await decide(run('opus'), io(own, UNHINTED))
  expect([d.action, d.subagentType, d.model ?? null]).toEqual(['rewrote', 'gsd-executor', null])
})
