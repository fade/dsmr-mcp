// Routing decision for one subagent spawn.
//
// decide() reads the spawn's own fields and whatever the injected io answers,
// nothing else, so a recorded spawn and its io tape replay the same decision.

/** The fields of an `agent.spawn` input the decision reads. */
export type SpawnFacts = {
  subagentType: string
  model?: string
  prompt: string
  cwd?: string
  fork: boolean
  resume?: { agentId: string }
  workflow?: { runId: string; agentIndex: number }
  isTeammate?: true
}

/** File access and fixed directories the decision runs against. */
export type RouteIo = {
  /** Text of the file, or null when it is absent or unreadable. */
  read: (path: string) => Promise<string | null>
  exists: (path: string) => Promise<boolean>
  /** Claude Code configuration directory, absolute. */
  configDir: string
  /** Directory a relative plan path resolves against, absolute. */
  projectDir: string
  /** Home directory for a plan path written with a leading tilde; empty when unknown. */
  homeDir: string
}

/**
 * - `rewrote`: the agent type changed, or a gsd-executor spawn lost its per-call model.
 * - `cleared-model`: a specialist kept its type and lost its per-call model.
 * - `unchanged`: passed on as requested, nothing to change.
 * - `cannot-decide`: passed on as requested because the rules could not place it.
 */
export type Action = 'rewrote' | 'cleared-model' | 'unchanged' | 'cannot-decide'

/** The workflow a dispatch prompt came from, as far as its text shows. */
export type Shape = 'execute-phase' | 'quick' | 'quick-batch' | 'audit-fix' | 'other'

export type Decision = {
  action: Action
  subagentType: string
  /** Model to pass on; undefined lets the agent definition's own model apply. */
  model: string | undefined
  reason: string
  /** Kind of spawn: subagent, fork, resume, workflow or teammate. */
  kind: string
  shape: Shape
  /** Absolute path of the plan the prompt names, when one was found. */
  planPath: string | null
}

/** What the project's planning config says about routing. */
export type ProjectConfig = {
  /** `planning.agents.specialized === true`. */
  specialized: boolean
  /** `planning.agents.executor` when it is an agent name, else null. */
  executor: string | null
  /** `workflow.agent_hint_routing === false`. */
  routingOff: boolean
}

// The planning directory gsd-core reads, named once.
const PLANNING_DIR = '.planning'
const EXECUTOR = 'gsd-executor'
const SHELL_DEVELOPER = 'shell-developer'
const LISP_DEVELOPER = 'lisp-developer'
const AGENT_NAME = /^[a-z0-9][a-z0-9-]*$/
// A dispatch prompt's plan line: "- <path>-PLAN.md (Plan)", or "(Plan, authoritative)" and kin.
const PLAN_LINE = /^[ \t]*- (\S+-PLAN\.md)[ \t]+\(Plan/gm
// execute-phase writes plan paths under the repository root it names PROJECT_ROOT.
const PROJECT_ROOT_REF = /^(\$\{PROJECT_ROOT\}|\$PROJECT_ROOT)\//
const PROJECT_ROOT_SET = /^[ \t]*PROJECT_ROOT=['"]?(\/[^'"\s]*)['"]?[ \t]*$/m
const AUDIT_FIX_OPENING = 'Fix finding '
const QUICK_BATCH_OPENING = 'Execute quick-batch item'

/**
 * Directories the decision needs, from the environment and the session.
 * Configuration falls back to `$HOME/.claude` when CLAUDE_CONFIG_DIR is unset.
 */
export function ioDirs(
  configEnv: string | undefined,
  homeEnv: string | undefined,
  cwd: string,
): Pick<RouteIo, 'configDir' | 'projectDir' | 'homeDir'> {
  const home = homeEnv ?? ''
  const configDir = configEnv && configEnv !== '' ? configEnv : `${home}/.claude`
  return { configDir: trimSlash(configDir), projectDir: trimSlash(cwd), homeDir: trimSlash(home) }
}

export function spawnKind(e: SpawnFacts): string {
  if (e.fork) return 'fork'
  if (e.resume) return 'resume'
  if (e.workflow) return 'workflow'
  if (e.isTeammate) return 'teammate'
  return 'subagent'
}

/** Distinct plan paths named on plan lines of `prompt`, in order of first appearance. */
export function planPaths(prompt: string): string[] {
  const seen = new Set<string>()
  for (const m of prompt.matchAll(PLAN_LINE)) {
    if (m[1] !== undefined) seen.add(m[1])
  }
  return [...seen]
}

/**
 * Dispatch shape of `prompt`, given the first plan path it names (as written).
 */
export function dispatchShape(prompt: string, plan: string | null): Shape {
  const opening = prompt.trimStart()
  if (prompt.includes('[gsd:dispatch') || (plan !== null && /(^|\/)phases\//.test(plan))) return 'execute-phase'
  if (opening.startsWith(QUICK_BATCH_OPENING)) return 'quick-batch'
  if (opening.startsWith(AUDIT_FIX_OPENING)) return 'audit-fix'
  if (plan !== null) return 'quick'
  return 'other'
}

/**
 * Absolute form of `path`, or null when it starts with a tilde and no home is
 * known. A leading `${PROJECT_ROOT}/` takes the absolute value `prompt`
 * assigns to PROJECT_ROOT on a line of its own, else the project directory.
 */
export function resolvePath(
  path: string,
  io: Pick<RouteIo, 'projectDir' | 'homeDir'>,
  prompt = '',
): string | null {
  if (PROJECT_ROOT_REF.test(path)) {
    const root = trimSlash(PROJECT_ROOT_SET.exec(prompt)?.[1] ?? io.projectDir)
    path = path.replace(PROJECT_ROOT_REF, `${root}/`)
  }
  if (path.startsWith('/')) return path
  if (path.startsWith('~/')) return io.homeDir === '' ? null : `${io.homeDir}${path.slice(1)}`
  return `${io.projectDir}/${path.replace(/^(\.\/)+/, '')}`
}

/**
 * Value of `key` in the YAML frontmatter of `text` (between the first two `---`
 * lines), unquoted and without a trailing comment; null when the key is absent.
 * Reads top-level scalar keys only.
 */
export function frontmatterValue(text: string, key: string): string | null {
  const lines = text.split(/\r?\n/)
  if (lines[0]?.trim() !== '---') return null
  for (let i = 1; i < lines.length; i++) {
    const line = lines[i] ?? ''
    if (line.trim() === '---') return null
    const m = /^([A-Za-z0-9_-]+):(.*)$/.exec(line)
    if (m !== null && m[1] === key) return scalar(m[2] ?? '')
  }
  return null
}

/**
 * Routing fields of a planning config's text; unreadable or invalid JSON
 * reads as no config.
 */
export function parseConfig(text: string | null): ProjectConfig {
  let parsed: unknown = null
  if (text !== null) {
    try {
      parsed = JSON.parse(text)
    } catch {
      parsed = null
    }
  }
  const agents = field(field(parsed, 'planning'), 'agents')
  const executor = field(agents, 'executor')
  return {
    specialized: field(agents, 'specialized') === true,
    executor: typeof executor === 'string' && AGENT_NAME.test(executor) ? executor : null,
    routingOff: field(field(parsed, 'workflow'), 'agent_hint_routing') === false,
  }
}

function field(value: unknown, key: string): unknown {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)[key]
    : undefined
}

function scalar(raw: string): string {
  const v = raw.trim()
  const quote = v[0]
  if (quote === '"' || quote === "'") {
    const end = v.indexOf(quote, 1)
    return end > 0 ? v.slice(1, end) : v.slice(1)
  }
  if (v.startsWith('#')) return ''
  const comment = v.search(/\s#/)
  return (comment >= 0 ? v.slice(0, comment) : v).trim()
}

function trimSlash(dir: string): string {
  return dir.length > 1 ? dir.replace(/\/+$/, '') : dir
}

function hasModel(model: string | null | undefined): model is string {
  return typeof model === 'string' && model !== ''
}

/** Text cut to `n` characters for a reason line. */
function clip(text: string, n = 80): string {
  return text.length > n ? `${text.slice(0, n)}...` : text
}

async function hasDefinition(name: string, io: RouteIo): Promise<boolean> {
  for (const definition of [`${io.configDir}/agents/${name}.md`, `${io.projectDir}/.claude/agents/${name}.md`]) {
    if (await io.exists(definition)) return true
  }
  return false
}

/**
 * Routing decision for one spawn, by these rules in order:
 *
 * 1. A fork, resume, workflow agent or teammate passes unchanged.
 * 2. gsd-executor: with `workflow.agent_hint_routing` false it stays
 *    gsd-executor, model cleared. Otherwise the prompt must name exactly one
 *    readable plan: its `agent_hint`, when it is shell-developer, gsd-executor
 *    or the project executor and has an installed definition, becomes the
 *    agent type, model cleared; with no hint the project default applies. A
 *    prompt opening "Fix finding " with no plan takes the project default too.
 *    The project default is `planning.agents.executor` when
 *    `planning.agents.specialized` is true and that agent is installed, else
 *    gsd-executor; either way the model is cleared. Anything else is
 *    `cannot-decide` and passes exactly as requested.
 * 3. shell-developer, lisp-developer or the project executor keeps its type
 *    and loses any per-call model.
 * 4. Every other agent type passes unchanged.
 */
export function decide(input: SpawnFacts, io: RouteIo): Promise<Decision> {
  return route(input, io)
}

async function route(input: SpawnFacts, io: RouteIo): Promise<Decision> {
  const kind = spawnKind(input)
  const named = planPaths(input.prompt)
  const shape = dispatchShape(input.prompt, named[0] ?? null)
  const asRequested = (action: Action, reason: string, planPath: string | null = null): Decision => ({
    action,
    subagentType: input.subagentType,
    model: input.model,
    reason,
    kind,
    shape,
    planPath,
  })
  const setType = (subagentType: string, action: Action, reason: string, planPath: string | null): Decision => ({
    action,
    subagentType,
    model: undefined,
    reason,
    kind,
    shape,
    planPath,
  })
  const keepExecutor = (reason: string, planPath: string | null): Decision =>
    hasModel(input.model)
      ? setType(EXECUTOR, 'rewrote', `${reason}; per-call model ${input.model} cleared, gsd-executor follows the leader`, planPath)
      : asRequested('unchanged', `${reason}; gsd-executor follows the leader`, planPath)

  if (kind !== 'subagent') return asRequested('unchanged', `a ${kind} spawn is not routed`)

  const config = parseConfig(await io.read(`${io.projectDir}/${PLANNING_DIR}/config.json`))
  const type = input.subagentType

  const projectDefault = async (reason: string, planPath: string | null): Promise<Decision> => {
    const executor = config.executor
    if (!config.specialized) return keepExecutor(`${reason}; planning.agents.specialized is not true`, planPath)
    if (executor === null) return keepExecutor(`${reason}; no planning.agents.executor`, planPath)
    if (executor === EXECUTOR) return keepExecutor(`${reason}; the project executor is gsd-executor`, planPath)
    if (!(await hasDefinition(executor, io))) {
      return keepExecutor(`${reason}; project executor ${executor} has no installed definition`, planPath)
    }
    return setType(executor, 'rewrote', `${reason}; project executor ${executor} on its own model`, planPath)
  }

  if (type === EXECUTOR) {
    if (config.routingOff) return keepExecutor('workflow.agent_hint_routing is false', null)
    if (named.length > 1) return asRequested('cannot-decide', `the prompt names ${named.length} plans`)
    if (named.length === 0) {
      if (input.prompt.trimStart().startsWith(AUDIT_FIX_OPENING)) {
        return projectDefault('an audit-fix finding names no plan', null)
      }
      return asRequested('cannot-decide', 'the prompt names no plan and is not an audit-fix finding')
    }

    const planPath = resolvePath(named[0] ?? '', io, input.prompt)
    if (planPath === null) return asRequested('cannot-decide', 'the plan path needs a home directory and none is known')
    const text = await io.read(planPath)
    if (text === null) return asRequested('cannot-decide', `the plan ${clip(planPath, 200)} is not readable`, planPath)

    const hint = frontmatterValue(text, 'agent_hint')
    if (hint === null || hint === '') return projectDefault('the plan carries no agent_hint', planPath)
    if (!AGENT_NAME.test(hint)) {
      return asRequested('cannot-decide', `agent_hint ${JSON.stringify(clip(hint))} is not an agent name`, planPath)
    }
    const routable = [SHELL_DEVELOPER, EXECUTOR, ...(config.executor === null ? [] : [config.executor])]
    if (!routable.includes(hint)) {
      return asRequested('cannot-decide', `agent_hint ${hint} is outside the routable set (${routable.join(', ')})`, planPath)
    }
    if (!(await hasDefinition(hint, io))) {
      return asRequested('cannot-decide', `agent_hint ${hint} names no installed definition`, planPath)
    }
    if (hint === EXECUTOR) return keepExecutor('agent_hint gsd-executor', planPath)
    return setType(hint, 'rewrote', `agent_hint ${hint}; model cleared so the definition's own model applies`, planPath)
  }

  if (type === SHELL_DEVELOPER || type === LISP_DEVELOPER || type === config.executor) {
    return hasModel(input.model)
      ? setType(type, 'cleared-model', `${type} runs on its own model; per-call model ${input.model} cleared`, null)
      : asRequested('unchanged', `${type} requested with no per-call model`)
  }

  return asRequested('unchanged', `${type} is not routed`)
}
