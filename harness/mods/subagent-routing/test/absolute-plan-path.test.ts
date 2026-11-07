// A gsd-executor prompt with no plan line may name its plan as one absolute
// path ending in -PLAN.md anywhere in its text.
//
// Sources of the fixtures:
// - The plan tag prompts copy the structure of two recorded execute-phase
//   dispatches of 2026-11-07 (an opening line, a blank line, a `<plan>` line,
//   then a `<required_reading>` list of absolute non-plan paths), with every
//   path moved under the planted /proj tree.
// - The glob line is copied verbatim from a recorded gsd-planner prompt of
//   2026-10-29.
// - The `.pre-count-note` name is a real backup file name from a GSD
//   planning directory.
// - The `for p in "$PHASE_DIR"/...` line is copied verbatim from a shell
//   command in a recorded session transcript of 2026-05-24. The
//   `"${PROJECT_ROOT}"/` and `"$PHASE_DIR"/` lines beside it are planted in
//   the same shape.
// - The audit-fix opening comes from the gsd-core audit-fix workflow's prompt
//   template; no recorded audit-fix dispatch exists.
// The config, the plan files and their frontmatter are planted.

import { expect, test } from 'claude-code/testing'
import type { AgentSpawnInput, On } from 'claude-code'
import { absolutePlanPaths, decide, type RouteIo } from '../hooks/route'

// The planning directory gsd-core reads, named once.
const PLANNING_DIR = '.planning'
const PHASE = `/proj/${PLANNING_DIR}/phases/01-x`
const UNHINTED_PLAN = `${PHASE}/01-02-PLAN.md`
const SHELL_PLAN = `${PHASE}/01-01-PLAN.md`
const FILES: Record<string, string> = {
  [`/proj/${PLANNING_DIR}/config.json`]: JSON.stringify({
    planning: { agents: { executor: 'lisp-developer', specialized: true } },
  }),
  [UNHINTED_PLAN]: '---\nphase: 01-x\nplan: 02\nwave: 1\n---\n',
  [SHELL_PLAN]: '---\nphase: 01-x\nplan: 01\nagent_hint: shell-developer\n---\n',
}
const AGENTS = ['/cfg/agents/lisp-developer.md', '/cfg/agents/shell-developer.md', '/cfg/agents/gsd-executor.md']

/** A prompt in the recorded plan tag shape, naming `plan`. */
function planTag(plan: string, extra = ''): string {
  return (
    'Execute GSD plan 01-02 of phase 01 in the proj repo.\n\n' +
    `<plan>${plan}</plan>\n\n` +
    '<required_reading>\n' +
    '- the plan above (in full)\n' +
    `- ${PHASE}/01-CONTEXT.md (locked decisions)\n` +
    `- /proj/${PLANNING_DIR}/STATE.md\n` +
    extra +
    '</required_reading>\n'
  )
}

/** Route io over the planted files; every path read is pushed to `reads`. */
function io(reads: string[] = []): RouteIo {
  return {
    configDir: '/cfg',
    projectDir: '/proj',
    homeDir: '/home/x',
    read: async p => {
      reads.push(p)
      return FILES[p] ?? null
    },
    exists: async p => AGENTS.includes(p),
  }
}

const executor = (prompt: string) => ({ subagentType: 'gsd-executor', prompt, fork: false })

type Spawned = { type: string; model: string | null }

function engine(on: On, session: string): { beneath: Spawned[]; line: () => Record<string, unknown> } {
  const beneath: Spawned[] = []
  let log = ''
  on('env.get', (_$, e) => ({ value: e.name === 'CLAUDE_CONFIG_DIR' ? '/cfg' : e.name === 'HOME' ? '/home/x' : undefined }))
  on('session.cwd', () => ({ value: '/proj' }))
  on('session.root', () => ({ value: '/proj' }))
  on('session.id', () => ({ value: session }))
  on('fs.exists', (_$, e) => ({ value: AGENTS.includes(e.path) || (e.path.endsWith('.jsonl') && log !== '') }))
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
  on('ui.toast', () => ({ value: undefined }))
  on('agent.offer', () => ({ isOffered: true }))
  on('settings.read', () => ({ value: {} }))
  on('agent.spawn', (_$, e) => {
    beneath.push({ type: e.subagentType, model: e.model ?? null })
    return { model: e.model ?? 'definition', agentId: 'a' }
  })
  return { beneath, line: () => JSON.parse(log.trim().split('\n').at(-1) ?? '{}') as Record<string, unknown> }
}

test('a plan named in a plan tag routes to the project executor', async ($, on) => {
  const eng = engine(on, 'app-tag')
  for (const agent of ['gsd-executor', 'lisp-developer']) {
    await $.agent.offer({ agent, description: '', source: 'userSettings', provider: { plugin: 'user', tier: 'user' } })
  }
  await $.agent.spawn({
    tool_use_id: 'toolu_tag',
    prompt: planTag(UNHINTED_PLAN),
    description: 'execute plan',
    subagentType: 'gsd-executor',
    provider: { plugin: 'user', tier: 'user' },
    parentModel: 'opus',
    background: false,
    fork: false,
  } as AgentSpawnInput)
  expect(eng.beneath).toEqual([{ type: 'lisp-developer', model: null }])
  const line = eng.line()
  expect(line.action).toBe('rewrote')
  expect(line.plan).toBe(UNHINTED_PLAN)
  expect(line.shape).toBe('execute-phase')
})

test('a plan tag naming a shell-developer plan routes to shell-developer', async () => {
  const d = await decide(executor(planTag(SHELL_PLAN)), io())
  expect([d.action, d.subagentType, d.model ?? null]).toEqual(['rewrote', 'shell-developer', null])
  expect(d.planPath).toBe(SHELL_PLAN)
})

test('the same absolute plan path named twice counts as one plan', async () => {
  const prompt = planTag(UNHINTED_PLAN, `- ${UNHINTED_PLAN}\n`)
  expect(absolutePlanPaths(prompt)).toEqual([UNHINTED_PLAN])
  const d = await decide(executor(prompt), io())
  expect([d.action, d.subagentType]).toEqual(['rewrote', 'lisp-developer'])
})

test('a plan line wins over an absolute plan path elsewhere', async () => {
  const reads: string[] = []
  const prompt = `<files_to_read>\n- ${SHELL_PLAN} (Plan)\n</files_to_read>\n\n<plan>${UNHINTED_PLAN}</plan>\n`
  const d = await decide(executor(prompt), io(reads))
  expect([d.action, d.subagentType]).toEqual(['rewrote', 'shell-developer'])
  expect(d.planPath).toBe(SHELL_PLAN)
  expect(reads).not.toContain(UNHINTED_PLAN)
})

test('an audit-fix finding that mentions a plan path keeps the audit-fix route', async () => {
  const reads: string[] = []
  const prompt =
    `Fix finding CR-01: the plan ${UNHINTED_PLAN} names a stale path. Files: hooks/route.ts. ` +
    'Make the minimal change to resolve this specific finding. Do not refactor surrounding code.'
  const d = await decide(executor(prompt), io(reads))
  expect(d.shape).toBe('audit-fix')
  expect(d.planPath).toBe(null)
  expect([d.action, d.subagentType]).toEqual(['rewrote', 'lisp-developer'])
  expect(reads).not.toContain(UNHINTED_PLAN)
})

test('a glob, relative, tilde, or PROJECT_ROOT path is not an absolute plan path', () => {
  const glob = 'SCOPE="$(cat "${PHASE_DIR}"/*-PLAN.md 2>/dev/null) $(gsd_run query roadmap.get-phase "${PHASE}" 2>/dev/null || true)"'
  expect(absolutePlanPaths(glob)).toEqual([])
  expect(absolutePlanPaths(`- ${PLANNING_DIR}/phases/01-x/01-01-PLAN.md (THE PLAN)`)).toEqual([])
  expect(absolutePlanPaths('read ~/x/01-01-PLAN.md first')).toEqual([])
  expect(absolutePlanPaths('read ${PROJECT_ROOT}/x/01-01-PLAN.md first')).toEqual([])
  expect(absolutePlanPaths('read $PROJECT_ROOT/x/01-01-PLAN.md first')).toEqual([])
  expect(absolutePlanPaths('see https://example.com//x/01-01-PLAN.md')).toEqual([])
})

test('a name that runs past -PLAN.md is not a plan path', () => {
  expect(absolutePlanPaths(`/proj/${PLANNING_DIR}/phases/01-x/01-01-PLAN.md.pre-count-note`)).toEqual([])
  expect(absolutePlanPaths('/proj/x/01-01-PLAN.mdx')).toEqual([])
  expect(absolutePlanPaths('Read /proj/x/01-01-PLAN.md.')).toEqual(['/proj/x/01-01-PLAN.md'])
  expect(absolutePlanPaths('/proj/x/01-01-PLAN.md: the plan')).toEqual(['/proj/x/01-01-PLAN.md'])
})

test('a path after a closing quote or a shell variable is not an absolute plan path', async () => {
  const recorded = 'for p in "$PHASE_DIR"/04-01-PLAN.md "$PHASE_DIR"/04-02-PLAN.md "$PHASE_DIR"/04-03-PLAN.md; do'
  expect(absolutePlanPaths(recorded)).toEqual([])
  expect(absolutePlanPaths(`cat "\${PROJECT_ROOT}"/${PLANNING_DIR}/phases/01-x/01-01-PLAN.md`)).toEqual([])
  expect(absolutePlanPaths('cat "$PHASE_DIR"/01-01-PLAN.md')).toEqual([])
  expect(absolutePlanPaths("cat '${PHASE_DIR}'/01-01-PLAN.md")).toEqual([])
  expect(absolutePlanPaths('cat ${PHASE_DIR}/01-01-PLAN.md')).toEqual([])
  // Control: an opening quote still sets a path off.
  expect(absolutePlanPaths(`cat "${SHELL_PLAN}"`)).toEqual([SHELL_PLAN])
  const d = await decide(executor(planTag(UNHINTED_PLAN, `- shell: cat "$PHASE_DIR"/01-01-PLAN.md\n`)), io())
  expect([d.action, d.subagentType]).toEqual(['rewrote', 'lisp-developer'])
  expect(d.planPath).toBe(UNHINTED_PLAN)
})

test('one absolute plan spelled two ways counts as one plan', async () => {
  const spelled = `/proj/${PLANNING_DIR}/./phases//01-x/01-02-PLAN.md`
  expect(absolutePlanPaths(planTag(UNHINTED_PLAN, `- ${spelled}\n`))).toEqual([UNHINTED_PLAN])
  const d = await decide(executor(planTag(spelled)), io())
  expect([d.action, d.subagentType]).toEqual(['rewrote', 'lisp-developer'])
  expect(d.planPath).toBe(UNHINTED_PLAN)
})

test('a plan name with a trailing character after -PLAN.md is not a plan path', () => {
  for (const tail of ['~', '#', '%', '@', '+']) expect(absolutePlanPaths(`/proj/x/01-01-PLAN.md${tail}`)).toEqual([])
  expect(absolutePlanPaths('(/proj/x/01-01-PLAN.md)')).toEqual(['/proj/x/01-01-PLAN.md'])
  expect(absolutePlanPaths('/proj/x/01-01-PLAN.md, then')).toEqual(['/proj/x/01-01-PLAN.md'])
})
