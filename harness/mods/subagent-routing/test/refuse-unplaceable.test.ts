// A gsd-executor spawn the rules cannot place is refused in a project whose
// config sets planning.agents.specialized true, and runs as requested in any
// other project or with no readable config.
//
// Sources of the fixtures:
// - The no-plan prompt copies the structure of a recorded hand-written
//   executor dispatch of 2026-10-18: a `<files_to_read>` list whose plan paths
//   are relative and sit on "(THE PLAN)" lines, with paths moved under /proj.
// - The two-path prompt is planted: the recorded 2026-11-07 `<plan>` shape
//   with a second `<plan>` line. No recorded executor prompt names two
//   distinct absolute plans.
// - The two-plan-line and cause fixtures reuse the recorded execute-phase list
//   shape test/target-check.test.ts uses, with planted plan frontmatter.
// - The audit-fix opening comes from the gsd-core audit-fix workflow's prompt
//   template; no recorded audit-fix dispatch exists.
// The config files and the plan files are planted.

import { expect, test } from 'claude-code/testing'
import type { AgentSpawnInput, AgentSpawnResult, On } from 'claude-code'
import { decide, type RouteIo } from '../hooks/route'

// The planning directory gsd-core reads, named once.
const PLANNING_DIR = '.planning'
const CONFIG = `/proj/${PLANNING_DIR}/config.json`
const PHASE = `/proj/${PLANNING_DIR}/phases/01-x`
const PLAN_ONE = `${PHASE}/01-01-PLAN.md`
const PLAN_TWO = `${PHASE}/01-02-PLAN.md`
const SPECIALIZED = JSON.stringify({ planning: { agents: { executor: 'lisp-developer', specialized: true } } })
const UNSPECIALIZED = JSON.stringify({ model_profile: 'balanced', planning: { agents: {} } })
const UNHINTED = '---\nwave: 1\n---\n'
const ALL_AGENTS = ['/cfg/agents/lisp-developer.md', '/cfg/agents/shell-developer.md', '/cfg/agents/gsd-executor.md']

const NO_PLAN =
  'You are the executor for one GSD plan in the proj repository at /proj. Execute plan 01-02 end to end, ' +
  'following the GSD execute-plan protocol.\n\n' +
  '<files_to_read>\n' +
  'Read these first, in full:\n' +
  `- ${PLANNING_DIR}/phases/01-x/01-02-PLAN.md (THE PLAN)\n` +
  `- ${PLANNING_DIR}/phases/01-x/01-CONTEXT.md (decisions)\n` +
  `- ${PLANNING_DIR}/phases/01-x/01-01-PLAN.md (its EXECUTION RULES apply)\n` +
  '</files_to_read>\n'

const TWO_TAGS =
  'Execute GSD plans 01-01 and 01-02 of phase 01 in the proj repo.\n\n' +
  `<plan>${PLAN_ONE}</plan>\n` +
  `<plan>${PLAN_TWO}</plan>\n\n` +
  '<required_reading>\n' +
  '- the plans above (in full)\n' +
  `- ${PHASE}/01-CONTEXT.md\n` +
  '</required_reading>\n'

const planLines = (...plans: string[]): string =>
  `<files_to_read>\n${plans.map(p => `- ${p} (Plan)\n`).join('')}</files_to_read>`

type Files = Record<string, string>

function io(files: Files, agents = ALL_AGENTS, homeDir = '/home/x'): RouteIo {
  return {
    configDir: '/cfg',
    projectDir: '/proj',
    homeDir,
    read: async p => files[p] ?? null,
    exists: async p => agents.includes(p),
  }
}

const executor = (prompt: string) => ({ subagentType: 'gsd-executor', model: 'opus', prompt, fork: false })

type Spawned = { type: string; model: string | null }
type Eng = { beneath: Spawned[]; toasts: string[]; lines: () => Record<string, unknown>[] }

/** Stand-in engine; with `failSessionId`, its session.id hook throws once. */
function engine(on: On, session: string, files: Files, failSessionId = false): Eng {
  const beneath: Spawned[] = []
  const toasts: string[] = []
  let log = ''
  let idFailures = failSessionId ? 1 : 0
  on('env.get', (_$, e) => ({ value: e.name === 'CLAUDE_CONFIG_DIR' ? '/cfg' : e.name === 'HOME' ? '/home/x' : undefined }))
  on('session.cwd', () => ({ value: '/proj' }))
  on('session.root', () => ({ value: '/proj' }))
  on('session.id', () => {
    if (idFailures > 0) {
      idFailures -= 1
      throw new Error('session id unavailable')
    }
    return { value: session }
  })
  on('fs.exists', (_$, e) => ({ value: ALL_AGENTS.includes(e.path) || (e.path.endsWith('.jsonl') && log !== '') }))
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
  on('ui.toast', (_$, e) => {
    toasts.push(String(e.text))
    return { value: undefined }
  })
  on('agent.offer', () => ({ isOffered: true }))
  on('settings.read', () => ({ value: {} }))
  on('agent.spawn', (_$, e) => {
    beneath.push({ type: e.subagentType, model: e.model ?? null })
    return { model: e.model ?? 'definition', agentId: 'a' }
  })
  return {
    beneath,
    toasts,
    lines: () =>
      log
        .trim()
        .split('\n')
        .filter(l => l !== '')
        .map(l => JSON.parse(l) as Record<string, unknown>)
        .filter(l => typeof l.toolUseId === 'string'),
  }
}

const spawn = (id: string, prompt: string): AgentSpawnInput =>
  ({
    tool_use_id: id,
    prompt,
    description: 'execute plan',
    subagentType: 'gsd-executor',
    model: 'opus',
    provider: { plugin: 'user', tier: 'user' },
    parentModel: 'opus',
    background: false,
    fork: false,
  }) as AgentSpawnInput

const REQUESTED = { type: 'gsd-executor', model: 'opus' }

function expectRefused(eng: Eng, result: AgentSpawnResult, cause: string): string {
  const deny = String(result.deny)
  expect(deny.startsWith('subagent-routing refused')).toBe(true)
  expect(deny).toContain(cause)
  expect(eng.beneath).toEqual([])
  const lines = eng.lines()
  expect(lines.length).toBe(1)
  expect(lines[0]?.action).toBe('refused')
  return deny
}

function expectAsRequested(eng: Eng, result: AgentSpawnResult): void {
  expect(result.deny).toBe(undefined)
  expect(eng.beneath).toEqual([REQUESTED])
  expect(eng.lines()[0]?.action).toBe('cannot-decide')
}

test('two distinct absolute plan paths are refused in a specialized project', async ($, on) => {
  const eng = engine(on, 'ru-two-paths', { [CONFIG]: SPECIALIZED, [PLAN_ONE]: UNHINTED, [PLAN_TWO]: UNHINTED })
  const result = await $.agent.spawn(spawn('toolu_two_paths', TWO_TAGS))
  expectRefused(eng, result, '2 absolute plan paths')
})

test('a prompt naming no plan is refused in a specialized project', async ($, on) => {
  const eng = engine(on, 'ru-no-plan', { [CONFIG]: SPECIALIZED })
  const result = await $.agent.spawn(spawn('toolu_no_plan', NO_PLAN))
  const deny = expectRefused(eng, result, 'names no plan')
  for (const part of ['(Plan', '-PLAN.md', 'absolute path', 're-spawn']) expect(deny).toContain(part)
})

test('a prompt naming no plan runs as requested in a project that is not specialized', async ($, on) => {
  const eng = engine(on, 'ru-unspecialized', { [CONFIG]: UNSPECIALIZED })
  expectAsRequested(eng, await $.agent.spawn(spawn('toolu_unspecialized', NO_PLAN)))
})

test('a prompt naming no plan runs as requested with no readable project config', async ($, on) => {
  const eng = engine(on, 'ru-no-config', {})
  expectAsRequested(eng, await $.agent.spawn(spawn('toolu_no_config', NO_PLAN)))
})

/**
 * decide() in a specialized project must refuse, naming `cause`. Only a cause
 * a new prompt can fix invites a re-spawn; the refusal returns its reason.
 */
async function refusedFor(
  prompt: string,
  files: Files,
  cause: string,
  agents?: string[],
  home?: string,
  config = SPECIALIZED,
): Promise<string> {
  const d = await decide(executor(prompt), io({ [CONFIG]: config, ...files }, agents, home))
  expect(d.action).toBe('refused')
  expect([d.subagentType, d.model]).toEqual(['gsd-executor', 'opus'])
  expect(d.reason).toContain(cause)
  const promptCause = cause.includes('names no plan') || /names \d+ (absolute )?plan/.test(cause)
  if (promptCause) expect(d.reason).toContain('re-spawn')
  else expect(d.reason).not.toContain('re-spawn')
  return d.reason
}

/** Occurrences of `word` in `text`. */
const count = (text: string, word: string): number => text.split(word).length - 1

test('two plan lines naming different plans are refused in a specialized project', async () => {
  await refusedFor(planLines(PLAN_ONE, PLAN_TWO), { [PLAN_ONE]: UNHINTED, [PLAN_TWO]: UNHINTED }, 'names 2 plans')
})

test('an unreadable plan is refused in a specialized project', async () => {
  const reason = await refusedFor(planLines(PLAN_ONE), {}, 'is not readable')
  expect(reason).toContain('must exist and be readable')
})

test('an agent_hint that is not an agent name is refused in a specialized project', async () => {
  await refusedFor(planLines(PLAN_ONE), { [PLAN_ONE]: '---\nagent_hint: "not a name!"\n---\n' }, 'is not an agent name')
})

test('an agent_hint outside the routable set is refused in a specialized project', async () => {
  await refusedFor(planLines(PLAN_ONE), { [PLAN_ONE]: '---\nagent_hint: general-purpose\n---\n' }, 'outside the routable set')
})

test('an agent_hint with no installed definition is refused in a specialized project', async () => {
  await refusedFor(
    planLines(PLAN_ONE),
    { [PLAN_ONE]: '---\nagent_hint: shell-developer\n---\n' },
    'shell-developer names no installed definition',
    ['/cfg/agents/lisp-developer.md', '/cfg/agents/gsd-executor.md'],
  )
})

test('a tilde plan path with no home directory is refused in a specialized project', async () => {
  const reason = await refusedFor(planLines('~/x/01-01-PLAN.md'), {}, 'needs a home directory', undefined, '')
  expect(reason).toContain('absolute path')
})

test('a refusal writes one log line and raises one toast', async ($, on) => {
  const eng = engine(on, 'ru-toast', { [CONFIG]: SPECIALIZED })
  await $.agent.spawn(spawn('toolu_toast_1', NO_PLAN))
  await $.agent.spawn(spawn('toolu_toast_2', NO_PLAN))
  const lines = eng.lines()
  expect(lines.length).toBe(2)
  for (const line of lines) {
    expect(line.action).toBe('refused')
    expect(line.set).toEqual(REQUESTED)
    expect(line.resolvedModel).toBe(null)
    expect(line.agentId).toBe(null)
    expect(line.error).toBe(undefined)
  }
  expect(eng.toasts.length).toBe(1)
  expect(eng.toasts[0]).toContain('refused a gsd-executor spawn it could not place')
  expect(eng.toasts[0]).not.toContain('changed spawn')
  expect(eng.toasts[0]).not.toContain('as requested')
})

test('a refusal stands when the hook fails after deciding to refuse', async ($, on) => {
  const eng = engine(on, 'ru-fail-after', { [CONFIG]: SPECIALIZED }, true)
  const result = await $.agent.spawn(spawn('toolu_fail_after', NO_PLAN))
  expect(String(result.deny).startsWith('subagent-routing refused')).toBe(true)
  expect(String(result.deny)).toContain('names no plan')
  expect(eng.beneath).toEqual([])
  // The engine skips a stand-in hook once it throws, so the session id stays
  // unknown and the failure handler may write no line; any line it writes reads refused.
  for (const line of eng.lines()) expect(line.action).toBe('refused')
})

test('a hint refusal lists only installed routable agents and never gsd-executor', async () => {
  const installed = ['/cfg/agents/lisp-developer.md', '/cfg/agents/gsd-executor.md']
  const reason = await refusedFor(
    planLines(PLAN_ONE),
    { [PLAN_ONE]: '---\nagent_hint: general-purpose\n---\n' },
    'agent_hint general-purpose is outside the routable set',
    installed,
  )
  expect(reason).toContain('lisp-developer')
  expect(reason).not.toContain('shell-developer')
  // The one mention is the statement that the spawn does not run as gsd-executor.
  expect(count(reason, 'gsd-executor')).toBe(1)
})

test('a hint with no installed definition asks for the definition, not another hint', async () => {
  const reason = await refusedFor(
    planLines(PLAN_ONE),
    { [PLAN_ONE]: '---\nagent_hint: lisp-developer\n---\n' },
    'agent_hint lisp-developer names no installed definition',
    ['/cfg/agents/shell-developer.md', '/cfg/agents/gsd-executor.md'],
  )
  expect(reason).toContain('install')
  expect(count(reason, 'gsd-executor')).toBe(1)
})

test('an unhinted plan whose project executor is not installed is refused in a specialized project', async () => {
  await refusedFor(
    planLines(PLAN_ONE),
    { [PLAN_ONE]: UNHINTED },
    'project executor lisp-developer has no installed definition',
    ['/cfg/agents/shell-developer.md', '/cfg/agents/gsd-executor.md'],
  )
})

test('an audit-fix finding whose project executor is not installed is refused in a specialized project', async () => {
  const prompt =
    'Fix finding CR-01: a stale path. Files: hooks/route.ts. ' +
    'Make the minimal change to resolve this specific finding. Do not refactor surrounding code.'
  await refusedFor(
    prompt,
    {},
    'project executor lisp-developer has no installed definition',
    ['/cfg/agents/shell-developer.md', '/cfg/agents/gsd-executor.md'],
  )
})

test('an unhinted plan with no usable project executor is refused in a specialized project', async () => {
  const unset = JSON.stringify({ planning: { agents: { specialized: true } } })
  const misnamed = JSON.stringify({ planning: { agents: { executor: 'Lisp-Developer', specialized: true } } })
  for (const config of [unset, misnamed]) {
    await refusedFor(planLines(PLAN_ONE), { [PLAN_ONE]: UNHINTED }, 'planning.agents.executor', undefined, undefined, config)
  }
})

test('a missing project executor still runs as requested in a project that is not specialized', async () => {
  const d = await decide(
    executor(planLines(PLAN_ONE)),
    io({ [CONFIG]: UNSPECIALIZED, [PLAN_ONE]: UNHINTED }, ['/cfg/agents/gsd-executor.md']),
  )
  expect([d.action, d.subagentType]).toEqual(['unchanged', 'gsd-executor'])
})

test('one plan spelled two ways on plan lines counts as one plan', async () => {
  const spelled = [`/proj/${PLANNING_DIR}/./phases//01-x/01-01-PLAN.md`, `\${PROJECT_ROOT}/${PLANNING_DIR}/phases/01-x/01-01-PLAN.md`]
  for (const other of spelled) {
    const d = await decide(executor(planLines(PLAN_ONE, other)), io({ [CONFIG]: SPECIALIZED, [PLAN_ONE]: UNHINTED }))
    expect([d.action, d.subagentType]).toEqual(['rewrote', 'lisp-developer'])
    expect(d.planPath).toBe(PLAN_ONE)
  }
})
